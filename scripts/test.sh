#!/usr/bin/env bash
# 运行全部离线测试（不需要飞牛、不需要 cc-switch 二进制，只需要 node + bash + curl）。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0

echo "== 1/3 语法检查 =="
for f in "$ROOT"/pkg/cmd/*; do
  bash -n "$f" || { echo "  语法错误: $f"; fail=1; }
done
node --check "$ROOT/pkg/app/gateway-proxy.mjs" || fail=1
echo "  ok"

echo "== 2/3 网关行为测试 =="
node "$ROOT/tests/gateway.test.mjs" || fail=1

echo "== 3/3 生命周期测试 =="
bash "$ROOT/tests/lifecycle.sh" || fail=1

if [ "$fail" -ne 0 ]; then echo; echo "测试未全部通过"; exit 1; fi
echo; echo "全部通过"
