# Workspace

`/opt/workspace` 是**总工作区 = 我所有项目的根目录**。项目陆续从 Mac 迁移过来,每个项目放一个子目录。

每个项目 = `/opt/workspace/<项目名>/` 一个子目录,各自独立 git 仓库。

## 进会话（Wave 侧边栏「会话」按钮 = `cloudgo`，会话优先）
打开后**平铺列出所有运行中会话**（带最近活动时间、按最近排序、右侧实时画面预览）：
- 选某会话 `↵` 进入；`Ctrl-X` 删该会话。
- **➕ 新建会话(选目录)** → 文件管理器式逐层浏览目录（进/出文件夹、新建文件夹、← 返回）→ 选定目录 → 问你起名 → 启动。
- **⟳ 恢复历史对话** → `claude --resume`，把已杀但存档还在的对话复活。

会话名 `cc-<目录名>`；起名后为 `cc-<目录名>-<名字>`（名字同时进 tmux 名 + Claude `-n` 显示名，列表/恢复处都认得出）。

## 默认参数（开会话时自动带，命令行可覆盖）
- 模型 **Sonnet 5**（`claude-sonnet-5`，改 `~/.bashrc` 里 `CLOUD_MODEL`；2026-07-08 起从 Opus 4.8 换成 Sonnet 5）
- **`--effort max`**（改 `CLOUD_OPTS`）
- 覆盖示例：`cld /opt/workspace/proj --model opus --effort medium`

## 自动恢复
开会话即登记进 `~/.cloud-sessions/<会话>.json`。重启/断电后开机服务 `cloud-sessions`(`cloud-boot.sh`)**只启 tmux server + 拉起 `cloud-watchdog.timer`**——**不一次性全恢复**(14 个重会话齐起会 OOM 雪崩)。之后 `cloud-watchdog` 每 ~15s 一轮、看内存、**一次最多 1 个**地把登记会话 `claude --resume <uuid>` 温和拉回(从 jsonl 续上、历史不丢、用当前账号);`/exit` 主动结束(ended=true)的不恢复。几分钟内陆续回齐,Mac/手机端 Wave/Moshi 重连即接回。

## 环境速记
- 服务器 `echo-j2`（root）。看图：粘贴截图后让我 `pullimg` 取回；产物可 `macput` 回 Mac 或开 `http://100.109.254.125:8088/<文件>`。
- 命令/入口速查见记忆库 `cloud-reference`，协作方式见 `how-we-work`。

## 多会话协同（hub + 会话总览）—— 每个会话都要遵守
本工作区常并行多个 cc 会话（各项目一个），全自动进 `hub`（= 所有 `cc-` 开头的 tmux 会话）。但默认彼此只知道**名字/路径**、不知道在干嘛（尤其几个 `raas-*` 同目录，光名字分不清）。规矩：
- **开工 / 换大方向时，跑一次 `hub iam "一句话：我在做什么"`** —— 自报会写进 `/opt/workspace/会话总览.md`，别的会话和中控靠它认你（光靠会话名不够）。
- **想知道别人在干嘛**：`hub ls`（每条带「在做」）或直接看 `/opt/workspace/会话总览.md`。
- **看板**：你的项目若有看板，跑 `hub dash <url> [auto|manual]` 声明一下（`auto`=自动刷新、不用管；`manual`=你得自己更新它）；没看板就不用管。
- 完整命令/存储/看板规范见 `references/会话协同.md`。
