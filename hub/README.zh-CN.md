# hub

[English](./README.md) | **简体中文**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)
![Shell](https://img.shields.io/badge/bash-%2B%20tmux-green.svg)

> 极简、零依赖的 `tmux` 命令行工具:把**一组 CLI 编码 agent**(比如 [Claude Code](https://claude.com/claude-code))跑在各自的 tmux 会话里(一个项目一个),让**你、以及 agent 自己**都能查看状态、在会话之间互发消息。

没有桌面 App、没有 MCP server、没有常驻进程——只要 `tmux` + 一个 shell 脚本。是比 golutra 那类重型编排器**刻意做轻**的替代品。

## 特性

- 🗂️ **一个 agent 一个 tmux 会话**,命名 `cc-<名字>`——`hub` 自动发现全部。
- 👀 **一眼看全局**:`hub ls` 列出每个 agent 的 git 状态、远端、路径。
- 💬 **agent 间通讯**:在一个中控 shell 统一发号,或让 agent 之间直接对接。
- 🧠 **规范的消息措辞**:每条消息自动包成"agent 间通讯"——简洁、机器可读、附回信方式。
- 📬 **可靠投递 + 留言箱**:发送前先确认对方停在空输入框(能识别 Claude Code 的 *agent-teams 子 agent 名册*、忙/思考中、权限模态、草稿、shell)。投不出就**存留言箱、就绪后自动补投**——绝不静默丢弃。
- 🪶 **小而可移植**:单个 Bash 文件,只依赖 `tmux`(看 git 状态再加 `git`)。

## 依赖

- `tmux`、`bash`
- `git` *(可选——仅 `hub ls` 看仓库状态用)*

## 安装

```bash
git clone https://github.com/liang-senbei/agent-hub.git
chmod +x agent-hub/hub.sh
ln -s "$(pwd)/agent-hub/hub.sh" ~/.local/bin/hub   # 确保 ~/.local/bin 在 PATH 里
```

## 用法

| 命令 | 说明 |
|---|---|
| `hub ls` | 列出所有 `cc-*` 会话:git 状态(改动数 / 领先落后)、远端、路径 |
| `hub peek <cc> [n]` | 看某个 agent 最近 *n* 行屏幕(默认 `40`) |
| `hub say <cc> "消息"` | 给某 agent 发消息 |
| `hub ask <cc> "消息"` | 同上,并要求对方用 `hub say` 回信 |
| `hub all "消息"` | 广播给除自己外的所有 agent |
| `hub flush [<cc>]` | 立刻投递留言箱里待发的消息——仅在对方就绪时发(省略 `<cc>` = 所有会话) |
| `hub inbox [<cc>] [clear]` | 查看(或 `clear` 清空)某会话待发的留言 |

`<cc>` 可写完整会话名(`cc-frontend`)或任意唯一片段(`front`)。

```bash
# 在中控 shell 里
hub ls
hub ask backend "把 leads 表的字段名和类型发我。"
# backend agent 在自己会话里这样回:
hub say frontend "leads: id, account_email TEXT, accepted INT(0/1), ..."
```

## 工作原理

### 会话模型
每个 agent 跑在自己的 `cc-<名字>` tmux 会话里。`hub` 发现所有 `cc-*` 会话,
用 `tmux send-keys`(推消息)和 `capture-pane`(读屏)驱动它们。

### agent 间通讯的消息
每条消息都会被包一层 preamble:

1. 标明**发件方 → 收件方**;
2. 声明这是 **agent 间通讯**(简洁、机器可读、别写给人看的排版);
3. `ask` 时附上对方回信的确切命令。

于是 agent 之间**直接协作**——你在一处发号(可 `@` 指定某个 agent),
它们用反方向的 `hub say` 互相回。不靠抓屏解析。

> preamble 文本在 `hub.sh` 的 `_wrap()` 函数里(默认中文),按你的语言/风格改即可。

### 谁是"发件方"?
在某 agent 的 tmux 会话里跑 `hub` → 以**它**的名义发;在普通 shell 里跑 → 以**中控**
名义发。按 `$TMUX` 自动判断。

### 投递、就绪判断与留言箱
发送前,`hub` 读对方屏幕并判定状态:

- **就绪**:停在空的 Claude 输入框。包括 *agent-teams 子 agent 名册* 的空闲态(名册渲染在状态行**下方**、把输入框顶上去——只看"底部有没有 `❯`"的朴素判断会漏掉它),以及忙/思考中但输入框为空的情况(type-ahead 会被安全排队)。→ 立即投递。
- **未就绪**:普通 shell / 已退出的 pane、权限或选择模态、半截草稿、或正在查看某子 agent 的 transcript。→ **不**硬打(否则会被当 shell 命令执行、误答模态、或发错 agent)。

未就绪时,消息会**存入 `~/.hub-inbox/<cc>.tsv`**,并起一个脱离终端、每会话单例的后台看守(`hub _watch`),对方一回到空输入框就自动补投(最长盯 30 分钟)。`hub ls` 显示待发数;`hub flush` / `hub inbox` 可手动驱动。

`HUB_FORCE=1` 跳过就绪判断、无条件发送——仅用于检测器误判时;它**不会**让"打进 shell/模态"变安全。

## 注意事项

- 发送 = 往对方输入框打字 + 回车。`hub` 会先确认对方停在空输入框;草稿、模态、shell、正在看子 agent 都会被识别并改为**存留言箱**,不会拼到一起或误触(见《投递、就绪判断与留言箱》)。
- 消息里的换行会被压成空格(以便单行提交)。长内容 / 代码先落文件,再 `hub say` 告诉路径。
- `hub all` 会发给所有 `cc-*` 会话,注意别刷屏(忙/未就绪的会进留言箱,不是跳过)。

## 许可

[MIT](./LICENSE)
