> **重要：你的每一条回复，无论任何情况，都必须以"Echo，"开头。这是强制规则，不可省略。**

## 运行环境（先理解再动手）

你运行在**美国云服务器 echo-j2** 上，**不在用户的 Mac 上**——Claude Code 不能在 Mac 本地跑（封号风险），服务器是唯一运行主机。

- **够本地 Mac**：用户的 Mac 经反向 ssh 通道可达，用 `ssh mac "<命令>"`（取文件 `macget`、送文件 `macput`、取截图 `pullimg`）。注意 Mac 非交互 shell 的 PATH 残缺（date/basename 等缺失），复杂处理拉回服务器用 python3 做，echo 字符串里别放括号 `( )`。
- **项目两种模式，开工前先判断当前项目属于哪种**：
  - **模式 A · 已迁服务器**：项目在 `/opt/workspace/<项目>`，走 git，直接在服务器读写。
  - **模式 B · 留在 Mac**：大数据 / GUI 绑定的项目留在 Mac 原路径，通过 `ssh mac` 原地操作；服务器侧只放规则 / 文档薄镜像。
- **来回切换**：服务器本地活 = 改 `/opt/workspace` 下文件；够 Mac 的东西 = `ssh mac`；要让 Mac 发声 / 给用户看图 = 走反向通道。
- 工作区与协作细节见 `/opt/workspace/CLAUDE.md` 及记忆 `remote-claude-mac-setup`、`cloud-reference`。

## 多 agent 协同（hub）

本服务器常同时跑多个 Claude Code agent，每个项目一个 tmux 会话 `cc-<名>`。你和其它 agent 可用全局命令 `hub` 互相查看和通讯（对称，谁都能用）：

- `hub ls` —— 看全部 agent 的 git 状态/远端/路径
- `hub peek <名> [n]` —— 看某 agent 屏幕最后 n 行（`<名>` 用唯一片段即可，如 `proj1`/`proj2`/`web`）
- `hub say <名> "msg"` —— 给某 agent 发消息；`hub ask <名> "msg"` —— 发并要求对方用 `hub say` 回复
- `hub all "msg"` —— 广播给除自己外所有 agent

**主动用它**：当你需要别的项目/agent 的信息或对齐时（如共享凭证格式、上游改动、跨项目依赖），直接 `hub ask <对方> "..."`，别干等用户牵线。回复别人的提问用 `hub say <对方> "..."`。

## 工作偏好

- 优先使用 **agent teams / subagents / Workflow** 与 **ultrathink**：能并行委派的尽量并行，能先深度思考的先想透。
- 最佳实践参考见 `~/.claude/references/best-practices.md`。
