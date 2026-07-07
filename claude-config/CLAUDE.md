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

**【硬规则】给别的会话发消息（`hub say`/`ask`/`all`，或 `tmux send-keys` 打到 `cc-*`）前必须先问我**——列清「发给谁 / 发什么原文 / 共几条」让我拍板，同意才发；回复别人的 `hub ask` 也一样。`hub ls`/`hub peek` 只读，随便用。（有系统硬闸 `hub-gate.py` 兜底弹确认，但别指望它、养成先问。）

## 工作偏好

- **【硬规则·不可省略】所有 agent / subagent / Workflow agent / 队友一律用 Opus 4.8（`claude-opus-4-8[1m]`）**（2026-07-07 起 Fable 5 下架、全面换回 Opus 4.8;不得擅自换成 sonnet/haiku）。
  - Agent 工具显式传 `model: "opus"`；Workflow 的 `agent()` 省略 `model` 即继承会话模型（默认已是 Opus 4.8），别显式传别的。
  - **Agent teams 队友**：队友**默认不继承 lead 模型**、本版本又无法在 settings.json 锁定，故 spawn 团队时**必须在指令里写明"所有 teammate 用 Opus 4.8"**，否则被降级/跑偏。（显示模式保持 `teammateMode:"in-process"`，别设 auto/tmux——这台是嵌套 tmux，分屏会出 shell 空壳。）
- 优先使用 **agent teams / subagents / Workflow** 与 **ultrathink**：能并行委派的尽量并行，能先深度思考的先想透。
- **跟我说人话（别甩术语墙）**：先给结论 +「这对我啥影响」，再按需展开细节；技术黑话（spool / mosh / 嵌套 tmux 之类）第一次出现用一句大白话解释；**少用表格和 ✓❌⚠️ 符号堆砌**——能用正常句子说清就别做成仪表盘。我要听得懂、不累。
- **默认用 `AskUserQuestion` 提问（让我点选，别让我手打）**：凡是要和我确认、让我拍板、征求意见/选型，默认给选项让我选——一个问题就问一个、多个一次问多个（最多 4 个），有推荐项放第一个标「(推荐)」；我不满意会自己在「其它」手输。实在收不成选项的开放题才退回文字问。
- **多个问题 → 末尾一次性合并作答**：我一条消息抛多个问题时，别"答一个→干下件事→再答一个"把答案散在中途（逼我上翻）。中途可有简短进度，但**所有答案收口到最后一条、逐条答全**，再给选项。
- **时间一律换算成北京时间(UTC+8)再对我说**：服务器多在香港/美国（echo-j2 是 UTC），你引用任何时间（日志、mtime、git、预计时刻等）都自动换成北京时间并标「北京时间」；服务器系统时区保持 UTC 别改。
- 最佳实践（含「代码改动纪律」）见 `~/.claude/references/best-practices.md`。

## 代码改动纪律（写/改代码时照做，减少返工）

1. **改动尽量小（外科手术式）**：只改被要求的那块；别顺手重构/重命名/调 import 顺序/重格式化别人的代码（撑大 diff、淹没真改动）；新代码**匹配文件现有风格**；只删自己这次造成的死代码。
2. **别过度设计**：写最少能解决当前问题的代码；别为"以后可能用得上"提前抽象、加配置项、加只有一个实现的接口；重复两次再考虑抽象。
3. **调 bug 先找根因、别靠猜**：错误和 stack trace **读完**再动手；先**复现**再修；**一次只改一件事**；别用"加个 null 检查/try-catch"盖住症状、先搞清它为什么坏。
4. **修 bug 先写能复现的测试**：写测试→看它失败→修→看它通过；改动前后都跑现有测试；本来就在失败的测试要说出来、别让你的改动背锅。
5. **别乱加依赖**：先看项目已有库/标准库能不能干（有 axios 别加 fetch，有 `randomUUID` 别加 uuid）；真要加，说清为什么。
6. **动手前想清楚**：说清假设和取舍；有多方案就列两三个并给推荐；哪儿没搞懂就**停下来问**（AskUserQuestion），别用看似合理的代码填理解的空白。

## 收尾整理（neat-freak skill）

会话/阶段收尾用 **neat-freak** 把文档（README/CLAUDE.md/docs）和记忆对照代码同步，防知识腐烂。装在 `~/.claude/skills/neat-freak`。

- **任务/阶段告一段落时，主动问我要不要用 neat-freak 收尾**（同步 docs+CLAUDE.md+记忆；我点头才跑，不自作主张改文件、不挂自动 hook）。
- 文档分流：散文/对外文案 → `humanizer-zh`；CLAUDE.md/记忆/docs 等技术文档 → 只 neat-freak、**绝不 humanize**。细节见记忆 `skills-neat-freak-humanizer`。
