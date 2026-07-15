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

## 密钥/凭据去哪找（先查别问 —— 避免反复找用户要）
全工作区密钥分三层，需要哪类先去对应仓库查，不确定就都翻一遍，**别急着问用户**（值本身照旧不进对话输出，用「文件名+变量名」引用）：
- **根级/管理员级**（云平台主账号、机器 root 密码等，Echo 本人拥有的高权限凭据）→ 私有仓库 `/opt/workspace/root-secrets`（本机没有先 `git clone`）。目前有：云平台账号(`CLOUDFLARE_ACCOUNT_API_TOKEN`+`CLOUDFLARE_ACCOUNT_EMAIL`、`CLOUDFLARE_LOGTO_TUNNEL_TOKEN`、`ALIYUN_ROOT_AK`/`ALIYUN_ROOT_SK`)、机器 root 密码(`HK13_14_ROOT_PASSWORD`/`HK15_ROOT_PASSWORD`/`ECHOJ3_ROOT_PASSWORD`/`ECHOJ1_ROOT_PASSWORD`)、crm-panel 自身根级密钥、`SERVER_PASSWORD`。新增/更新看 `secrets.env` 里的分类注释，登记规范见该仓 `CLAUDE.md`。
- **团队日常运营层**（各项目服务账号、API key 等）→ `raas-secrets` 仓库（`secrets.env`，各项目 `.env` 靠同步脚本拉取）。
- **crm-panel 资源登记表**（团队协作可见、按项目/资源分类的凭据台账，11 大类：AI模型/账号登录/数据抓取网关/域名云平台/验证码接码/服务器主机/数据库存储/支付财务/浏览器云手机/代理IP/面板内部）→ `/opt/workspace/crm-panel/registry/resources.jsonl`，网页 `bms.omggrow.com`。**要用 AI 模型 API 先查这里**：豆包/DeepSeek/智谱GLM/Gemini反代/CLIProxyAPI(ChatGPT池)/图像生成/TTS 等都已登记，每条 `调用方式` 字段直接给了 base_url + 鉴权头格式（按 `category=="AI模型"` 过滤 jsonl 就能看全部），不用现查文档、更别再问用户要新 key。
- 三层边界：root-secrets 只放 Echo 本人拥有的根级凭据，不放团队日常密钥、不放其他人拥有的凭据（按 owner 区分）；三层互不自动同步，谁改谁负责通知依赖方。

## 常驻脚本 / 排程注册（防静默死 —— 每个项目都遵守）
任何项目在服务器/任意机器挂了**常驻进程或定时任务**(launchd / systemd / cron / 守护循环 / tmux 长跑),**必须在体检中心登记**——**别在各自 CLAUDE.md 里堆排程表**(避免冗余),统一登记到:
- **`references/常驻脚本体检.md`**(分项目:有哪些 / 怎么体检 / 挂了怎么恢复)。
- **新开项目同理**:一旦有常驻,当场来登记。
- **体检**:任一机器重启后必跑 + 每周一次 —— 总检 `bash /opt/workspace/workspace_health_check.sh`(逐项目调各自体检),或单跑你项目那段的体检命令。
- 为什么:服务器随时可能重启、排程可能没起来(尤其 Mac 端 FileVault 卡解锁、launchd 不自动加载),集中登记 + 定期体检才不会"以为在跑、其实早死了"。

## 记忆 / 项目文档 / workspace 文件怎么分工（防新机器/新会话接不上 —— 每个项目都遵守）
三层知识受众和可携带性不同,放错层的后果:换一台全新机器 clone 项目仓,或开一个全新会话接手,该知道的事拿不到。

- **项目 git 仓库**(`<项目>/CLAUDE.md` + `docs/`):随 `git clone` 到任何机器都在。放**这个项目怎么运作**的权威知识——业务规则/操作手册/已知 bug/架构决策/跨仓边界。判据:「换全新机器 clone 这仓,新会话接手这个项目需要知道」→ 必须在这层。
- **workspace 级文件**(本文件 + `references/*.md`):不进 git,是明文件、跟 Mac↔服务器现有备份/迁移机制走。放**跨项目的基建事实**——服务器/SSH 怎么连、密钥去哪找、会话管理工具怎么用,不是任一具体项目的知识,别塞进某个项目自己的 CLAUDE.md。
- **Claude Code 记忆**(`~/.claude/projects/<路径>/memory/`):机器+账号绑定,不随项目走、新机器/新会话默认拿不到。放**我该怎么跟你协作**的经验——沟通偏好/尚未沉淀成规则的边缘案例。记忆天生只增不删,一条记忆若讲的是"项目/系统怎么运作"而非"怎么跟我协作",或反复验证到第 3 次证明是稳定机制,就该"毕业":内容并进对应文档、记忆本身缩成一行指针或直接删,别放着继续囤积。

**判断某条信息该进哪层,按顺序问**:
1. 是"Claude 该怎么跟我协作"(沟通习惯/工作偏好)吗?→ 留记忆,不用毕业。
2. 不是 → 换全新机器/全新会话接手这个项目或这台服务器,不知道这条信息会不会踩坑/卡住?→ 会,必须进文档(项目专属进项目仓,跨项目基建进本文件)。
3. 不会(只是我自己少走弯路的小提示,不影响别人接手)→ 可以留记忆,但优先级低,攒到一定量该收口。
4. 会不会变?一次性事件(某天的决策/复盘)→ 记忆或 git log/commit message 留痕即可;长期稳定机制(系统一直这样运作)→ 必须进文档,且要"就地更新当前状态",不是"追加历史叙事"。

**收口机制**:任务/阶段收尾定期跑 **neat-freak**(`~/.claude/skills/neat-freak`)按上述判据核对记忆库,该毕业的毕业、该删的删——执行细节见该 skill 自身文档,这里只定"哪层放什么"的判据。
