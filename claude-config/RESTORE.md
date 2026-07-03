# Claude Code 配置还原(remote-dev-station/claude-config)

本目录备份服务器 Claude Code 的**可重建配置**(只存 config + 清单 + 本说明;**技能/插件内容不入库**,都能从远端重装)。盘点(2026-07-02):**95 skill · 6 MCP · 9 插件 · 7 市场**。

> ⚠️ 这些 skill/插件是**作者私有的叠加层**:还原到**你自己的新机器**时照本清单重装;**给客户干净部署时不套用**,而是扫描客户机器上他自己的 skill / MCP / 本地资料再迁移。

## 1. 基础 config(拷回 ~/.claude/)
- `CLAUDE.md` → `~/.claude/CLAUDE.md`(全局指令)
- `settings.json` → `~/.claude/settings.json`(钩子:cc-state / moshi-hook / hub-gate)
- `hooks/`(含 cc-state 接线、hub-gate、typecheck 等) `commands/` `references/` `mcpServers.json` → `~/.claude/` 对应位置;仓根 `statusline.py` → `~/.claude/statusline.py`(状态行,settings.json 引用)
- **6 个 MCP**(见 `mcpServers.json`):context7 · sequential-thinking · shopify-dev-mcp · fetch · fakewechat · chrome-devtools

## 2. 插件 + 技能(凭记录重装,不存内容)
- `installed_plugins.json` = **9 插件**清单;`known_marketplaces.json` = **7 市场**。
- 先 re-add 市场再装。各市场远端:
  - 公共,直接 re-add:`anthropic-agent-skills`(anthropics/skills)、`daymade-skills`(daymade/claude-code-skills)、`claude-plugins-official`、`claude-code-plugins`、`openai-codex`、`claude-code-warp`
  - **`hello2cc-local`(本地 directory 市场,关键)**:真源是 `git clone https://github.com/hellowind777/hello2cc.git` → `~/.claude/hello2cc-local`,再以 directory 源 re-add(known_marketplaces 里记的是本地路径,真正可恢复的是这个 git 仓)。
- 再按 `installed_plugins.json` / 各市场 re-install 9 插件 + 95 skill。

> 备份哲学同本仓:**只存配置与清单,不存可重装/可重 clone 的内容**(技能、插件、密钥均不入库)。
