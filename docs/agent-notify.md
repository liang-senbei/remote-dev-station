# Agent 状态通知（手机推送 + 可选笔电语音）

有 agent 进入「等你授权（input）」或「完成（done）」时主动通知你 —— **手机 Moshi 推送**（带身份/项目/任务），可选**笔电语音念名字**（每个 agent 稳定分到一把嗓，听声辨人）。首次跑静默播种当前态，不刷屏。

## 组成
- `bin/cc-agents-notify` —— 通知器（状态跃迁 → 推送/语音；去重于 `~/.cloud-status/.notify-seen.json`）。
- `bin/cc-agents` —— 取当前各 agent 状态（读 cc-sessions/tmux）。`install.sh` 已把 `bin/*` 装到 `~/.local/bin`。
- **语音是可选的**：`cc-speak-laptop`（edge-tts/Fish）不在本仓——缺了 `cc-agents-notify` 自动跳过语音，只发手机推送。手机推送才是可移植的核心。

## 启用（3 步）
1. **配 token**：`cp cloud-tts.conf.example ~/.cloud-tts.conf`,把 `MOSHI_TOKEN=` 填成你在 getmoshi.app 拿到的 webhook token（或设环境变量 `MOSHI_TOKEN`）。留空则不推送。
2. **接 hook**：在 `~/.claude/settings.json` 的 `Stop` / `Notification` / `PermissionRequest` 三个 hook 里挂 `cc-agents-notify`（async）。例：
   ```json
   "hooks": {
     "Stop":             [{ "hooks": [{ "type": "command", "command": "cc-state; cc-agents-notify" }] }],
     "Notification":     [{ "hooks": [{ "type": "command", "command": "cc-agents-notify" }] }],
     "PermissionRequest":[{ "hooks": [{ "type": "command", "command": "cc-agents-notify" }] }]
   }
   ```
3. **验**：`cc-agents-notify --test`（手机能收到就通）；`cc-agents-notify --dry`（只打印会推/念什么,不真发）。

## 说明
- token 解析优先级:环境变量 `MOSHI_TOKEN` → `~/.cloud-moshi.conf` → `~/.cloud-tts.conf` 里的 `MOSHI_TOKEN=`。webhook 地址可用 `MOSHI_WEBHOOK` 覆盖。
- 想要笔电语音:另配 `cc-speak-laptop`（edge-tts 免费或 Fish Audio）+ 笔电 ssh 别名 `laptop`（见 windows-reverse-channel.md / mac-reverse-channel.md）。
