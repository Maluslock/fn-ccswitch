#!/bin/bash
# 生命周期脚本测试：用假的 cc-switch 后端（一个只听端口的 node 小服务）验证
# cmd/ 下 9 个脚本的契约——安装、启动、状态码、停止、改端口、端口冲突、卸载清理。
# 不需要真的 cc-switch 二进制，可在任意装了 node 的机器上跑。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CMD="$ROOT/pkg/cmd"
PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1（期望 $3，实际 $2）"; fi; }

free_port() {
  node -e 'const n=require("net").createServer();n.listen(0,"127.0.0.1",()=>{console.log(n.address().port);n.close()})'
}

wait_port() {
  local port="$1" i=0
  while [ "$i" -lt 40 ]; do
    if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then exec 3>&- 2>/dev/null; return 0; fi
    i=$((i+1)); sleep 0.25
  done
  return 1
}

TMP="$(mktemp -d)"
export TRIM_APPDEST="$TMP/target"
export TRIM_PKGVAR="$TMP/var"
export TRIM_PKGHOME="$TMP/home"
export TRIM_PKGETC="$TMP/etc"
SOCK="$TRIM_APPDEST/app.sock"

cleanup() {
  [ -f "$TRIM_PKGVAR/app.pid" ] && "$CMD/main" stop >/dev/null 2>&1
  [ -n "${BLOCKER:-}" ] && kill "$BLOCKER" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$TRIM_APPDEST/bin" "$TRIM_APPDEST/web/assets" "$TRIM_APPDEST/lib" "$TRIM_PKGVAR" "$TRIM_PKGHOME" "$TRIM_PKGETC"
cp "$ROOT/pkg/app/gateway-proxy.mjs" "$TRIM_APPDEST/gateway-proxy.mjs"
printf '<!doctype html><title>fn-ccswitch</title>' > "$TRIM_APPDEST/web/index.html"

# 假后端：读 CC_SWITCH_PORT，在该端口起一个最小 JSON 服务
cat > "$TRIM_APPDEST/bin/cc-switch-web" <<'FAKE'
#!/usr/bin/env node
const port = Number(process.env.CC_SWITCH_PORT || 17666);
require("node:http")
  .createServer((req, res) => {
    if (req.url === "/api/invoke") {
      res.writeHead(200, { "content-type": "application/json" });
      return res.end(JSON.stringify({ result: { fake: true } }));
    }
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ backend: true }));
  })
  .listen(port, "127.0.0.1");
FAKE
chmod +x "$TRIM_APPDEST/bin/cc-switch-web"

echo "lifecycle.sh"

# 1. install_init 必须永远成功，且不创建任何目录
EMPTY="$(mktemp -d)"
( TRIM_APPDEST="$EMPTY/t" TRIM_PKGVAR="$EMPTY/v" TRIM_PKGHOME="$EMPTY/h" TRIM_PKGETC="$EMPTY/c" \
  bash "$CMD/install_init" >/dev/null 2>&1 )
check "install_init 在空环境下退出码为 0" "$?" "0"
check "install_init 不创建目录（交给安装器）" "$(find "$EMPTY" -mindepth 1 | wc -l)" "0"
rm -rf "$EMPTY"

# 2. install_callback 写 env 并拉起前后端
P1="$(free_port)"
wizard_port="$P1" bash "$CMD/install_callback" >/dev/null 2>&1
check "install_callback 退出码 0" "$?" "0"
check "env 文件写入端口" "$(cat "$TRIM_PKGETC/env" 2>/dev/null)" "wizard_port=$P1"
check "env 文件权限 600" "$(stat -c %a "$TRIM_PKGETC/env" 2>/dev/null)" "600"
bash "$CMD/main" status >/dev/null 2>&1
check "安装后 main status = 0（运行中）" "$?" "0"
wait_port "$P1" && ok "后端监听 $P1" || bad "后端未监听 $P1"
[ -S "$SOCK" ] && ok "网关 socket 已创建" || bad "网关 socket 缺失"
CODE="$(curl -s -o /dev/null -w '%{http_code}' --unix-socket "$SOCK" http://localhost/healthz 2>/dev/null)"
check "网关 /healthz 返回 200" "$CODE" "200"

# 3. 前端资源经网关可达，且 /api 打到假后端
CODE="$(curl -s -o /dev/null -w '%{http_code}' --unix-socket "$SOCK" http://localhost/app/fn-ccswitch/ 2>/dev/null)"
check "网关返回前端首页 200" "$CODE" "200"
BODY="$(curl -s --unix-socket "$SOCK" -X POST -H 'content-type: application/json' -d '{"command":"auth.status"}' http://localhost/app/fn-ccswitch/api/invoke 2>/dev/null)"
case "$BODY" in *'"fake":true'*) ok "/api/invoke 透传到后端" ;; *) bad "/api/invoke 未透传：$BODY" ;; esac

# 4. stop 后 status 必须是 3（fnOS 的「未运行」约定）
bash "$CMD/main" stop >/dev/null 2>&1
check "main stop 退出码 0" "$?" "0"
sleep 1
bash "$CMD/main" status >/dev/null 2>&1
check "停止后 main status = 3" "$?" "3"

# 5. 改端口（应用设置里的 config_callback）要能重启到新端口
P2="$(free_port)"
wizard_port="$P2" bash "$CMD/config_callback" >/dev/null 2>&1
check "config_callback 退出码 0" "$?" "0"
check "env 端口已更新" "$(cat "$TRIM_PKGETC/env")" "wizard_port=$P2"
wait_port "$P2" && ok "改端口后监听 $P2" || bad "改端口后未监听 $P2"

# 6. 端口被别人占用时，start 必须失败并给出可读提示（不自动换端口）
bash "$CMD/main" stop >/dev/null 2>&1
node -e 'require("node:http").createServer((q,s)=>s.end("x")).listen(process.argv[1],"127.0.0.1")' "$P2" &
BLOCKER=$!
sleep 1
OUT="$(bash "$CMD/main" start 2>&1)"; RC=$?
check "端口冲突时 start 退出码 1" "$RC" "1"
case "$OUT" in *"已被其他程序占用"*) ok "端口冲突提示可读" ;; *) bad "端口冲突提示缺失：$OUT" ;; esac
kill "$BLOCKER" 2>/dev/null; BLOCKER=""
sleep 1

# 7. 卸载默认保留数据，勾选清理才删
mkdir -p "$TRIM_PKGVAR/data"; echo keep > "$TRIM_PKGVAR/data/marker"
bash "$CMD/uninstall_callback" >/dev/null 2>&1
check "卸载默认退出码 0" "$?" "0"
[ -f "$TRIM_PKGVAR/data/marker" ] && ok "默认保留用户数据" || bad "默认不该删数据"
wizard_purge_data=true bash "$CMD/uninstall_callback" >/dev/null 2>&1
check "勾选清理后退出码 0" "$?" "0"
[ -d "$TRIM_PKGVAR/data" ] && bad "勾选清理后 data 应被删除" || ok "勾选清理后数据已删除"

echo
if [ "$FAIL" -eq 0 ]; then echo "lifecycle: 全部通过（$PASS 项）"; exit 0; fi
echo "lifecycle: $FAIL 项失败（通过 $PASS 项）"; exit 1
