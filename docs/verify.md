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

## 升级（真机实测记录）

`appcenter-cli` 在 1.2.0800 上的行为与直觉不同，升级前务必先备份：

| 命令 | 对已安装应用的行为 |
| --- | --- |
| `appcenter-cli install-fpk <fpk>` | **不会升级**：打印 `Application [x] is installed.`，但文件、manifest、注册版本都不变（实测 0.1.0 → 0.1.3 无变化）。 |
| `appcenter-cli install-local -d <dir>` | 会先**卸载**已安装应用，再安装本地目录；本项目实测以 `[Error]Something wrong with appcenter: code 10237` 失败，此时应用已被卸载、`/vol1/@appdata/<app>` 也被清空。 |

因此本项目的真机升级流程是「备份 → 卸载 → 装新包 → 还原数据」：

```bash
# 1) 备份运行数据（SQLite 库、模型定价、skills）
tar czf /tmp/ccsw-data.tgz -C /vol1/@appdata/fn-ccswitch .
# 2) 卸载旧版本（卸载会删除 /vol1/@appdata/<app>，所以必须先备份）
appcenter-cli uninstall fn-ccswitch
# 3) 安装新版本
appcenter-cli install-fpk -v 1 -e /tmp/install.env dist/fn-ccswitch.fpk
# 4) 还原数据并修正属主
appcenter-cli stop fn-ccswitch
tar xzf /tmp/ccsw-data.tgz -C /vol1/@appdata/fn-ccswitch
chown -R fn-ccswitch:fn-ccswitch /vol1/@appdata/fn-ccswitch
appcenter-cli start fn-ccswitch
```

App Center 图形界面的「更新」是否走同一套逻辑未验证；上表只覆盖 CLI。
