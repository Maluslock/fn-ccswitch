# 补丁说明

上游 `cp-yu/cc-switch-web` 在切换 Agent（Claude / Codex / OpenCode …）时，主区域用
framer-motion 的 `AnimatePresence mode="wait"` 做 150ms 淡出再 150ms 淡入，
中间会有一段内容完全空白的间隔，在 NAS 的 iframe 里表现为「页面闪一下」。
本补丁把该过渡时长改为 0，保持功能不变、只去掉这段空白。

- 影响文件：`src/App.tsx`（`ProviderList` 外层 motion.div 的 `transition`）
- 验证方式：`build/pw/compare3.mjs` 逐帧截图，补丁前 1–2 次白帧，补丁后 0 次。
- 升级上游版本时若该行变动，`scripts/build.sh` 会因补丁冲突而失败，需要重新生成。
