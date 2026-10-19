# 补丁说明

本目录存放对上游 `cp-yu/cc-switch-web` 前端源码的最小改动。`scripts/build.sh`
在解压源码后按文件名顺序应用，并在应用完成后做**结果校验**（见 `verify_patches()`）：
校验失败会直接中断构建，而不是静默打出一个「看起来成功、实际没打上补丁」的包。

## 0001-app-switch-no-fade.patch —— 去掉切换时的空白闪烁

上游在切换 Agent、切换视图时用 framer-motion 的 `AnimatePresence mode="wait"`
做「旧内容淡出 → 新内容淡入」，两段动画之间内容区是纯空白，在 NAS 的 iframe 里
表现为「闪一下 / 闪两下」。补丁把三处过渡时长都改成 0：

| 位置 | 作用 |
| --- | --- |
| `src/App.tsx:1025` | 供应商列表主内容（切换 Agent） |
| `src/App.tsx:1097` | 主视图（点进技能 / MCP / 提示词 / 会话等面板） |
| `src/App.tsx:1463` | 顶部右侧工具条图标组（按 Agent 切换） |

- 验证方式：`build/pw/bandtest.mjs` 逐帧截图（25 帧 × 10ms），补丁前三处场景分别出现
  1–2 个空白帧，补丁后均为 0。
- 上游若改动这三处，构建会报「补丁未生效或上游代码已变更」。

## 0002-ws-reconnect-retry.patch —— WebSocket 断线自动恢复

上游的传输层（`src/lib/transport/wsTransport.ts`）在 `connect()` 里把 Promise 缓存到
`this.connectPromise`，但**只有在 `onclose` 里才清空**。一旦连接尝试以 `onerror` 失败
（应用重启、网关重启、网络抖动），这个已拒绝的 Promise 会一直被复用，之后每个请求都
立刻拿到 `WebSocket connection failed`，用户必须手动刷新页面才能恢复。

补丁做了三件事：

1. 连接失败时清空缓存的 Promise（`catch` 里 `this.connectPromise = null`），避免永久卡死；
2. 失败后自动重试 5 次、每次间隔 800ms，覆盖应用重启那段窗口；
3. 增加 8 秒握手超时——对端进程突然消失时代理可能既不回 101 也不断开，否则会永远卡在
   `CONNECTING`。

- 验证方式：`build/pw/repro6.mjs` 在页面打开状态下执行 `appcenter-cli stop/start`，
  补丁前连接关闭后再没有新连接（点任何按钮都报 `WebSocket connection failed`，必须刷新），
  补丁后控制台可见 `[WS] Reconnecting...` 并最终 `[WS] Connected`，页面无需刷新即可继续操作。
- 上游若改动 `connect()` 结构，构建会报「补丁未生效或上游代码已变更」。

## 0003-i18n-lazy-locales.patch

- **文件**：`src/i18n/index.ts`、`vite.config.ts`
- **目的**：四个语言包（en 179 KB / ja 223 KB / zh-TW 174 KB / zh 172 KB，合计约 750 KB 源码）原来全部静态导入，首屏必须全部下载。
- **改动**：
  1. `src/i18n/index.ts` 只静态导入中文，其余语言包改成 `import()` 按需加载：首屏按 `localStorage.language` / 浏览器语言只取当前语言；`languageChanged` 时再补加载并重放一次切换。
  2. `vite.config.ts` 的 `manualChunks` 里把 `src/i18n/locales/` 排除在 `app-i18n` 之外——否则语言包会被塞进这个静态 chunk，等于还是全量预加载。
- **效果**：`app-i18n` chunk 从 645 KB（gzip 203 KB）降到 147 KB（gzip 51 KB）。
- **验证**：切换语言时网络面板能看到 `en-*.js` / `ja-*.js` 按需返回 200。
