# fn-ccswitch

把 [CC Switch](https://github.com/cp-yu/cc-switch-web)（Web 版）打包成飞牛 fnOS 应用：在飞牛桌面窗口里直接管理 Claude Code / Codex / Gemini 等 AI 工具的供应商配置，不额外开放端口。

> 上游 cc-switch 是 Tauri 桌面程序，fnOS 桌面只能以 iframe / 新标签页承载 Web 应用，所以这里包装的是社区维护的 Web 版 `cc-switch-web`。

## 它是怎么跑起来的

```
浏览器（飞牛桌面里的窗口）
        │  https://<你的 NAS>:5667/app/fn-ccswitch/
        ▼
fnOS 统一网关（校验 NAS 登录态，注入 X-Trim-* 头）
        │  Unix Socket: ${TRIM_APPDEST}/app.sock
        ▼
gateway-proxy.mjs  ──静态资源──▶  ${TRIM_APPDEST}/web（本项目重新构建的前端）
        │  /api/*、/api/ws
        ▼
127.0.0.1:17666  cc-switch-web（上游二进制，只监听回环）
```

关键约束与对策：

| 约束 | 对策 |
| --- | --- |
| https 桌面里 iframe 加载 http 端口会被混合内容拦截 | 走统一网关（`gatewayPrefix` + `gatewaySocket`），浏览器只看到同源的 `/app/fn-ccswitch/` |
| 上游前端把 API 地址在编译期写死成 `/api` | 构建期用 `VITE_CC_SWITCH_API_BASE=/app/fn-ccswitch/api` 重新构建前端 |
| 上游二进制依赖 `libssl.so.1.1`（Ubuntu 20.04 构建），Debian 12 只有 OpenSSL 3 | 随包携带 `libssl.so.1.1` / `libcrypto.so.1.1`，启动时设 `LD_LIBRARY_PATH` |
| 上游只监听 TCP，无法直接被网关转发 | 用 Node 单文件网关桥接 UDS ↔ 127.0.0.1，顺带处理前缀、Cookie Path、WebSocket、SSE |
| 上游 Web 版没有 arm64 产物 | `manifest` 里 `platform=x86`，ARM 机型暂不支持 |

## 构建

需要：`curl`、`tar`、`dpkg-deb`、Node ≥ 20、`pnpm`、[`fnpack`](https://developer.fnnas.com/docs/cli/fnpack/)。

```bash
./scripts/build.sh          # 完整构建，产物在 dist/fn-ccswitch.fpk
./scripts/build.sh --skip-web   # 复用 build/web 里已构建好的前端
```

脚本做四件事：下载上游 Linux 二进制 → 取出 OpenSSL 1.1 运行库 → 用源码重建带前缀的前端 → 组装 `pkg/` 并调用 `fnpack build`。

也可以用 GitHub Actions：推送 `v*` 标签后自动构建并上传 `.fpk` 到 Release（见 `.github/workflows/release.yml`）。

## 安装

```bash
# 在飞牛 NAS 上（需要 root）
appcenter-cli install-fpk fn-ccswitch.fpk
appcenter-cli start fn-ccswitch
```

安装向导里只有一个「内部端口」需要填（默认 17666，仅本机回环使用，浏览器不会直接访问）。装好后在应用中心打开 CC Switch，界面就在飞牛桌面窗口里。

## 数据与目录

| 路径 | 内容 |
| --- | --- |
| `/var/apps/fn-ccswitch/target/` | 程序、前端静态资源、`app.sock` |
| `/var/apps/fn-ccswitch/var/data/` | `CC_SWITCH_CONFIG_DIR`：`cc-switch.db` 等配置数据库 |
| `/var/apps/fn-ccswitch/var/log/` | `main.log`、`backend.log`、`gateway.log`、`lifecycle.log` |
| `/var/apps/fn-ccswitch/home/` | `HOME`，存放 `.claude` 等被管理的配置文件 |
| `/var/apps/fn-ccswitch/etc/env` | 向导写入的配置（`wizard_port`） |

默认 `HOME` 指向应用自己的 `home/`，删应用不会影响 NAS 用户家目录里的配置。想让 CC Switch 直接改某个 NAS 用户的 `~/.claude`，目前需要自行用「应用资源」授权目录后再调整启动脚本（见下）。

## 生命周期

`cmd/main` 支持 `start | stop | status`：

- `start`：先清理残留进程，检查端口占用（被占用时提示去「应用设置 → 服务配置」换端口），启动后端并等待端口就绪，再启动网关并等待 `app.sock` 出现。
- `status`：PID 存活且端口可连才返回 `0`，否则 `3`。
- `stop`：先 TERM，10 秒后 KILL，清理 PID 与 socket。

`install_callback` / `config_callback` 会写好 `etc/env` 并重启应用；`uninstall_callback` 默认保留数据，卸载向导里勾选「同时删除应用数据」才会清理。

## 已知限制

- 上游没有 arm64 产物，飞牛 ARM 机型装不了（需要自行交叉编译 `cc-switch-web`）。
- 上游 Web 版缺少桌面端的托盘、开机自启、文件选择框等能力。
- 跟随上游升级时要重新构建前端（`CCSW_TAG` 改成新 tag 即可），并确认二进制仍依赖 `libssl.so.1.1`。
- 本仓库只做打包与适配，不修改上游源码。

## 许可

本项目（打包与适配代码）使用 MIT。上游 `cp-yu/cc-switch-web` 亦为 MIT，二进制与前端产物版权归其作者所有。
