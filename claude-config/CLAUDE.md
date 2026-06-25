> **重要：你的每一条回复，无论任何情况，都必须以"Echo，"开头。这是强制规则，不可省略。**

## 运行环境（先理解再动手）

你运行在**美国云服务器 echo-j2** 上，**不在用户的 Mac 上**——Claude Code 不能在 Mac 本地跑（封号风险），服务器是唯一运行主机。

- **够本地 Mac**：用户的 Mac 经反向 ssh 通道可达，用 `ssh mac "<命令>"`（取文件 `macget`、送文件 `macput`、取截图 `pullimg`）。注意 Mac 非交互 shell 的 PATH 残缺（date/basename 等缺失），复杂处理拉回服务器用 python3 做，echo 字符串里别放括号 `( )`。
- **五机 SSH 全互联**：echo-j2 / air(MacBook) / mini / hk14 / hk13 **任意两台公钥直连**（别名 `ssh ej2/air/mini/hk14/hk13`）——够 mini / HK 服务器**不必再经 `ssh mac` 中转**。寻址坑（HK 走公网、个别机器 tailscale-IP 的 SSH 会卡；具体 IP/服务商不内联）详见记忆 `ssh-mesh-5machines`。
- **项目两种模式，开工前先判断当前项目属于哪种**：
  - **模式 A · 已迁服务器**：项目在 `/opt/workspace/<项目>`，走 git，直接在服务器读写。
  - **模式 B · 留在 Mac**：大数据 / GUI 绑定的项目留在 Mac 原路径，通过 `ssh mac` 原地操作；服务器侧只放规则 / 文档薄镜像。
- **来回切换**：服务器本地活 = 改 `/opt/workspace` 下文件；够 Mac 的东西 = `ssh mac`；要让 Mac 发声 / 给用户看图 = 走反向通道。
- 工作区与协作细节见 `/opt/workspace/CLAUDE.md` 及记忆 `remote-claude-mac-setup`、`cloud-reference`。

## 多 agent 协同（hub）

本服务器常同时跑多个 Claude Code agent，每个项目一个 tmux 会话 `cc-<名>`。你和其它 agent 可用全局命令 `hub` 互相查看和通讯（对称，谁都能用）：

- `hub ls` —— 看全部 agent 的 git 状态/远端/路径
- `hub peek <名> [n]` —— 看某 agent 屏幕最后 n 行（`<名>` 取会话名里的唯一片段即可）
- `hub say <名> "msg"` —— 给某 agent 发消息；`hub ask <名> "msg"` —— 发并要求对方用 `hub say` 回复
- `hub all "msg"` —— 广播给除自己外所有 agent

**【硬规则】给别的会话发消息，发送前必须先问用户。** `hub ls` / `hub peek` 只读，随便用。但凡要**给别的会话发消息**——`hub say` / `hub ask` / `hub all`，或用 `tmux send-keys` 直接打到 `cc-*` 会话——动手前**先在对话里问用户**，把三件事列清楚让他拍板：① 发给谁（哪个/哪些会话）、② 发什么内容（给出原文）、③ 共几条。用户明确同意后才发；没拍板就别发，不要"主动对齐 / 别干等用户牵线"那一套。

- 即便是**回复**别人 `hub ask` 的提问，也照上面先问用户。
- 需要别的项目/agent 的信息时，先把"我想问 X 会话 Y 问题"讲给用户，由他定夺。
- 这有系统级硬闸兜底：每条 hub 发送（及 raw `tmux send-keys` 打到 `cc-*`）在真正发出前都会弹确认（`~/.claude/hooks/hub-gate.py` + `settings.json` 的 `permissions.ask`），绕不过去——所以更要养成"先问再发"，别指望靠闸门挡。

## 工作偏好

- **【硬规则·不可省略】所有 agent / subagent / Workflow agent 一律用 Opus 4.8 启动，严禁降级到 sonnet/haiku/fable。**
  - Agent 工具：显式传 `model: "opus"`。
  - Workflow 的 `agent()`：省略 `model` 即继承会话的 Opus 4.8（会话默认就是 `claude-opus-4-8[1m]`），**不要**传 `model: "sonnet"` 之类。
  - **Agent teams 队友（teammate）**：队友**默认不继承 lead 的模型**，且本版本无法用 settings.json 锁定（`teammateDefaultModel` 字段未实现）。故 spawn 团队时**必须在指令里显式写明"所有 teammate 一律用 Opus（claude-opus-4-8）"**，否则会被降级。（显示模式已在 settings.json 设 `teammateMode:"auto"` = 彩色分屏。）
  - 不得以"省 token/省成本/任务简单"为由降级模型——这是硬规则。
- 优先使用 **agent teams / subagents / Workflow** 与 **ultrathink**：能并行委派的尽量并行，能先深度思考的先想透。
- **默认用 `AskUserQuestion` 提问（让我点选，别让我手打）**：凡是要**和我确认、让我拍板、征求我的意见/建议/偏好/选型**，默认用 `AskUserQuestion` 工具给选项让我选——**一个问题就问一个、多个问题就一次性问多个**（该工具一次最多 4 个）。有推荐项就放第一个并标「(推荐)」。我若觉得选项都不合适，会自己在「其它」里手输。**例外**：实在无法收敛成选项的开放式问题，才退回普通文字问。
- **多个问题 → 末尾一次性合并作答（别分段散在中途）**：我一条消息抛出多个问题/诉求时，**别"答一个→去做下件事→再答一个"把答案散在各次工具调用之间**（逼我上翻拼答案）。中途可有简短进度说明，但**所有问题的答案统一收口到最后一条回复、按问题逐条答全**，然后再用 `AskUserQuestion` 给选项。目标：末尾给我"完整答复 + 选项"、一处看全。
- 最佳实践参考见 `~/.claude/references/best-practices.md`。

## 收尾整理（neat-freak skill）

会话 / 阶段收尾时用 **neat-freak** 把文档（README / CLAUDE.md / docs）和记忆对照代码同步，防知识腐烂。装在服务器 `~/.claude/skills/neat-freak`，Mac 同步一份镜像（实际跑 Claude 在服务器）。

- **主动确认（按任务进度）**：当一个任务 / 阶段告一段落——功能做完、bug 修完、一组改动收口、用户说"做完了 / 先到这"——**主动问用户要不要用 neat-freak 收尾**（同步 docs + CLAUDE.md + 记忆）。**用户点头才跑；不挂自动 hook，不自作主张直接改文件。**
- **文档分流**：散文 / 对外文案 → `humanizer-zh`；CLAUDE.md / 记忆 / docs / 速查表等结构化技术文档 → 只 neat-freak，**绝不 humanize**。
- 细节见记忆 `skills-neat-freak-humanizer`。
