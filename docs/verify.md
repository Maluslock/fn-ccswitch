# 本地验证记录

在 fnOS（Debian 12，x86_64）上，用「真实应用目录结构 + 真实二进制」跑通，未安装到应用中心。

## 已通过

| 项 | 方法 | 结果 |
| --- | --- | --- |
| 二进制可执行 | 随包 `libssl.so.1.1` / `libcrypto.so.1.1` + `LD_LIBRARY_PATH` | `ldd` 全部解析，服务正常启动 |
| 数据目录隔离 | `CC_SWITCH_CONFIG_DIR` 指向 `var/data` | 生成 `cc-switch.db`、`model-pricing.json`，不写 `HOME` |
| 生命周期 | `cmd/main start/status/stop` | `start`=0、运行中 `status`=0、停止后 `status`=3 |
| 安装向导 | `install_callback`（`wizard_port=17701`） | 写入 `etc/env`（0600），应用自动启动 |
| 配置向导 | `config_callback`（`wizard_port=17702`） | 服务重启并改监听 `127.0.0.1:17702` |
| 卸载 | `uninstall_callback` | 默认保留数据；`wizard_purge_data=true` 时清理 `var/data` |
| 网关静态资源 | `curl --unix-socket app.sock http://x/app/fn-ccswitch/` | 200，5914 B（重建后的 `index.html`） |
| 前端 API 前缀 | `grep` 构建产物 | `app-data-*.js`、`app-platform-*.js` 中均为 `/app/fn-ccswitch/api` |
| HTTP 转发 | `POST /app/fn-ccswitch/api/invoke` | 返回真实 JSON（`get_settings`、`auth.status`） |
| WebSocket | 经网关升级 `/app/fn-ccswitch/api/ws` | `101 Switching Protocols` |
| 健康检查 | `GET /healthz` | `{"status":"ok","upstream":"127.0.0.1:17702"}` |
| 端口冲突保护 | 端口被他人占用时 `start` | 退出码 1，提示去应用设置改端口 |
| 打包 | `fnpack build`（1.2.4） | 生成 `fn-ccswitch.fpk`（14 MB，`app.tgz` 32 MB 展开） |

## 未覆盖

- 未在应用中心真实安装（需要 NAS root 权限与 `appcenter-cli install-fpk`）。
- 未做浏览器端到端（需登录 fnOS 桌面里点开应用）；已验证网关层等价请求与 WS 升级。
- ARM 机型不支持（上游无 arm64 产物）。
