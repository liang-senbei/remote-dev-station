# DEPLOY.md — 给 Claude 看的"整套远程开发体系"部署驱动

> 本文是给 **AI 操作员(Claude)** 读的部署 runbook:照它把 `remote-dev-station` 这套
> "美国服务器跑 Claude Code + 电脑/手机远程遥控" 的体系,给一个**新客户 / 新机器**从零部署好。
>
> 人读的分层说明在 [README.md](README.md);本文只讲**怎么一步步执行、哪里要问客户、哪里要扫客户机器**。
> 各阶段的细节不在这里重复,而是**引用**对应文档([README](README.md) / [phone/](phone/README.md) /
> [windows/](windows/README.md))。

## 怎么用这份文档

客户对 Claude 说"照 remote-dev-station 的 DEPLOY.md 给我部署",Claude 读本文后:
1. **先收集客户参数**(阶段零),别猜;
2. **按阶段执行,每阶段验证过再进下一阶段**;
3. 遇到"客户本地已有资料",**扫描客户机器迁移他自己的**;别把一台机器的私有值 / skill / 记忆 / 凭据硬套到另一台。

## 0. 两个概念(先内化,贯穿全程)

- **通用核心** = 这套体系本身:会话层脚本 / systemd 自愈 / tmux / ufw、Wave 客户端配置骨架、Moshi 配对**流程**。谁都一样,直接部署。
- **私有叠加** = 每台机器 / 每个人自己的:云服务器 / 账号 / 凭据 / Tailscale IP / 记忆 / 已有的 skill·MCP·dotfiles。**属于使用者本人**,要么现场问、要么扫他的机器迁移。

> 🚫 **红线:每台机器只用它自己的私有值,别把别人的私有值 / skill / 记忆 / 密钥硬塞进去。** 本仓交付的是**干净的通用骨架**(占位符 + 通用脚本,不含任何人的私有 skill / 记忆 / 凭据);部署 = 装通用骨架 + 填**这台机器自己的**真值(IP / 用户名 / 仓库地址 / 账号)+ 使用者自带自己的 Claude 叠加层(skill / MCP / 记忆)。

## 1. 阶段零 · 收集客户参数(用 AskUserQuestion 逐项问,填一张临时"部署参数表",不入库)

> 📄 **每个新客户 → 在你操作端本地建一个以「客户服务器 IP」命名的命令 txt**(如 `23.149.28.51.txt`,放桌面/工作目录)。把**所有要客户/用户手动执行的命令**边部署边写进去、随时更新:Claude 登录 URL、客户端 SSH `cloud`/`cloud-pub` 别名 + `ssh-copy-id` 命令、Mac/Windows 端要跑的、反向通道加公钥等。**一个客户一个文件**,交接时给他这一份即可(含明文命令,**不入库**)。

- **服务器**:有海外云服务器吗?root SSH 通吗?Ubuntu/Debian?内存(建议 ≥16G)?→ 没有,先指导客户开一台。
- **Tailscale**:有账号吗?→ 服务器 + 电脑 + 手机都要进**同一 tailnet**。
- **Claude 账号**:客户自己的 Pro/Max —— 部署时**客户自己 `claude` 登录**,你不经手他的凭据。
- **客户端**:Mac / Windows / 两者都要?
- **手机**:要不要 Moshi 远程批准/操作?→ 客户自己的 Moshi 账号。
- **客户已有本地资料**:客户以前用过 Claude Code 吗?有没有想保留的 skill / MCP / CLAUDE.md / 记忆 / dotfiles?→ 决定阶段四扫不扫、扫什么。

## 2. 阶段一 · 服务器 0→1

照 [README.md](README.md) 的「从零部署 Quick Start」执行:**唯一前置 Tailscale**(`tailscale up`,无头授权见 [`docs/tailscale-setup.md`](docs/tailscale-setup.md))→ `git clone` **客户自己的 fork** → `./install.sh`(装依赖 + Claude Code native + 全部会话层 + systemd 自愈 + 防火墙)→ `source ~/.bashrc` → `claude` 登录(无头见 [`docs/headless-login.md`](docs/headless-login.md))。

> **⚠️ 必改·会话模型(最要命)**:仓里默认 `CLOUD_MODEL` 可能不是**你账号可用的模型**,普通 Pro/Max 账号**大概率没有特殊模型** → 不改则客户端新建会话 + watchdog 断电自愈 `--resume` **全部启动即死**。装完**立刻**改成你账号可用的模型(如 `claude-opus-4-8[1m]` / `claude-sonnet-4-6`),**两处都改**:① `~/.bashrc` 的 `CLOUD_MODEL`(管交互新建会话);② `/etc/systemd/system/cloud-watchdog.service` 的 `Environment=CLOUD_MODEL=`(管断电自愈)→ 改后 `systemctl daemon-reload && systemctl restart cloud-watchdog.timer`。

- ⚠️ **origin 换成你自己的**:给这台机器建一份仓(fork 或新建),别长期依赖别人的 origin。
- ✅ **会话恢复(cc-state 钩子)装完即接线**:install.sh 若 `~/.claude/settings.json` **不存在**,会自动铺干净模板 [`claude-config/settings.client.json`](claude-config/settings.client.json)(只含 cc-state 钩子 + skip-permissions);**已有 settings.json 则不覆盖** → 需手动把该模板的 cc-state hooks 合并进去(否则会话恢复静默失效;`cloud_infra_check.sh` 会探这一项)。⚠️ `claude-config/settings.json` 是一份**较完整的示例配置**(除 cc-state 外还挂了 statusline / hub-gate / typecheck / 铃铛 等钩子,均指向 `~/.claude/` 下随本仓安装的脚本);按需取用即可——某个脚本你没放就删掉对应钩子(否则每次事件报错)。想最省心就用上面那份最小模板 `settings.client.json`(只有 cc-state 钩子)。

- 🚦 **hub 闸门(跨会话发消息前人工确认)—— 可选,默认别开**:`install.sh` 只铺最小模板、**不装 `hooks/`**,
  所以 `hub/来源与说明.md` 里那条「`hub say`/`ask`/`all` 发送前必须人工确认」的硬规则
  **默认是不生效的**(2026-08-01 在自用服务器上核实:`~/.claude/hooks/` 根本不存在,一道拦截都没有)。
  要让它落地,装完跑一次:

  ```bash
  python3 claude-config/enable-hub-gate.py
  ```

  它做三件事:装 `hooks/hub-gate.py` → 自检(普通命令放行 / `hub say` 拦 / `hub ls` 放行 / raw
  `tmux send-keys` 到 cc-* 也拦)→ 往 `~/.claude/settings.json` **追加** `permissions.ask`
  三条规则和一个 PreToolUse 钩子。**只追加不覆盖**(原有 cc-state 钩子、env、模型全保留),
  改前自动备份到 `settings.json.bak-hubgate`,幂等可重复跑。
  ⚠️ 装完**只对新起的会话生效** —— Claude Code 不热重载 settings.json(实测:文件被替换后它
  只用 `O_PATH` 重建 inotify 监听,从不重读内容)。已经在跑的 agent 得重启才受管。
  ⚠️ **生效后 agent 之间每发一条消息都要等人点确认,多 agent 协作会被拖死** —— 自用这台
  常年并行 20+ 个会话、彼此高频对接,启用当天即回退。**除非你的场景是"会话很少、更怕 AI
  乱发消息",否则别开。** 关掉:`python3 claude-config/disable-hub-gate.py`(同样只增删自己
  那两项,不碰 env / 模型 / cc-state 钩子)。
- **验证**:`cloudgo` 能列会话;`systemctl is-active cloud-watchdog.timer` = active;`bash cloud_infra_check.sh` **核心全绿**(可选层未装显示 ⏭ 属正常)。完整功能验收(含破坏性 selfheal 真测)在**阶段五**统一跑,这里别提前跑。

## 3. 阶段二 · 客户端(电脑)

- **Mac**:照 README「电脑(Mac)0→1」——Tailscale + Wave + mosh。⚠️ **Tailscale Mac 版首次要开系统权限(系统扩展 + VPN 配置,在「系统设置→隐私与安全性/登录项与扩展」),不开则一直转圈连不上**——步骤见 [`docs/tailscale-mac-setup.md`](docs/tailscale-mac-setup.md)(顺带含反向通道要开的「远程登录/屏幕录制」)。`wave-config/` 里含**机器专属值**(README 附二 §🔴,IP / 用户名),**别整份照搬**——拿它当模板,把下列占位符全填成这台机器自己的真值。
- **Windows**:照 [windows/README.md](windows/README.md)。

> **⚠️ 必改的机器专属值**(客户端凡拷 `wave-config/` / `cloudconn` 都要填,否则会连不上你的服务器):
> - **服务器 IP**:`cloudconn`(两份:仓根 + `wave-config/`)的 `HOST=`(`wave-config` 版还多一个 `HOSTIP=`,探活看守会 nc 它);`wave-config/{waveterm,waveterm-dev}/widgets.json` 里 `:6080` / `:8088` 两处 URL —— 全填成你自己服务器的 Tailscale IP(占位符 `<SERVER_TAILSCALE_IP>`)。
> - **本机用户名 / 家目录**:`widgets.json` 的 `cmd` 里 `<YOUR_HOME>/bin/cloudconn`、`com.wavetheme.ui.plist` 里 `<YOUR_HOME>/…` —— 换成你自己的家目录路径。
> - 服务器侧的 `bin/novnc-start.sh`(noVNC)与 `bin/cloud-dashboards.sh`(看板 :8088)已改为**自动取本机 Tailscale IP**,无需手改。

- 🎛️ **装哪些 Wave widget:每个客户现场让用户选(Windows / Mac 都是)**。用 **AskUserQuestion** 列出可选项让用户勾,别一套照搬:**核心默认必装** = 会话(`cloudgo`)+ 临时会话(`cloudtmp`);**可选** = 服务器文件(需 wsh,首次连接自动装)、项目看板(:8088)、服务器桌面(:6080 noVNC)、主题(Mac 本地 :8799 `wavetheme-server`)、**额度**(5小时滚动窗口用量/余量,:8088/quota.html,由 `cc-quota` + ccusage 生成)。按用户勾选裁剪 `widgets.json` 再铺。
- 🔑 **客户端 SSH 别名(否则用 `root@cloud` 连接的 widget 报 `lookup cloud: no such host`)**:`wave-config` 的 `connections.json`/`widgets.json` 用连接名 `root@cloud`/`root@cloud-pub` → 客户端 `~/.ssh/config` **必须建 `cloud`(→服务器 Tailscale IP)+ `cloud-pub`(→服务器公网 IP)别名**(`User root`、`IdentityFile` 指客户端自己钥匙、`IdentitiesOnly yes`)。并把**客户端公钥 `ssh-copy-id` 进服务器**(免密)。
- ⚙️ **mosh 要 UTF-8 locale**:`cloudconn` 已在开头 `export LANG/LC_ALL=en_US.UTF-8`(否则 macOS/Wave cmd 块里 mosh 报 `Error: vector`)。**主题** widget 要在 Mac 本地跑 `wavetheme-server`(:8799)+ 铺 `termthemes/*.json`,用 **launchd** 自启;**临时会话**要服务器 `/usr/local/bin/mosh-server-tmout`(install.sh 已装)。**noVNC 已改必装**:客户完成 Claude 无头登录跑 `claude-login-url`(输出临时公网登录页 URL,登录后 `pkill cloudflared` 拆掉)。

### 可选 · 用魔改版 Wave 客户端(汉化 + 自定义主题)

官方 Wave 就能用;想要中文界面 + 自定义主题/侧栏,需要对 Wave 前端源码做一套中文化 + 主题分叉,自己构建 `.app`。**该源码分叉不含在本仓**,思路:

- 从 Wave 官方源码(Apache-2.0)fork 一份,改前端(`theme.scss` / `app.tsx` / `widgets.tsx` 等)加中文化 + 主题,再本地构建打包。
- 构建前置:Go 1.25+、NodeJS 22 LTS、Task(taskfile.dev);Linux 另需 zip + zig。`task init` 装依赖、`task package` 生产构建 + 打包(产物在 `make/`;Linux ARM64 用 `USE_SYSTEM_FPM=1 task package`)。
- 🌏 国内构建:设一套镜像环境变量(GOPROXY=goproxy.cn、ELECTRON_MIRROR=npmmirror、ALL_PROXY 走本地代理),否则拉依赖会很慢 / 失败。
- 不想折腾就用**官方 Wave** + 本仓 `wave-config/` 的运行时配置(termtheme/widgets),功能一样、只是少了界面汉化。

- **验证**:从自己电脑连上、成功开一个会话进 Claude Code。

## 4. 阶段三 · 手机(选装)

照 [phone/README.md](phone/README.md) 配 Moshi:agent 钩子配对(批权限)+ 可选 SSH host setup(开终端)。**用客户自己的 Moshi 账号**,主机地址填 **IP**。

## 5. 阶段四 · 客户本地资料迁移(关键——扫客户自己的,别硬套别人的)

仅当阶段零里客户说"有想保留的 Claude 资料"时做。

> **⚠️ 先解决"够到旧机"**:跑在新服务器上的 Claude **够不到客户的旧机器**。先用 AskUserQuestion 跟客户定传输方式,二选一:① 客户在**旧机**上 `tar czf /tmp/claude-migrate.tgz -C ~ .claude`(**先删掉 `.claude/.credentials.json` 等密钥再打包**)→ scp / 面板上传到新服务器 → Claude 解包到临时目录按下面判断;② 客户旧机装 Tailscale 进**同一 tailnet** → Claude 经 `ssh` 直接读。没有这一步,迁移无从下手。

> **🔎 够"清单外"的机器 · tailnet 自动发现(配置能力)**:走了上面②(旧机进同 tailnet)、或以后需要够一台**不在静态别名清单里**的设备时,不必逐台手配——让 Claude **动态发现**:`tailscale status` 枚举同 tailnet 的设备 → 逐台 `ssh -o BatchMode=yes -o ConnectTimeout=<秒> <user>@100.x.y.z true`(用已有钥匙 + 约定用户名探活,如 `example-laptop` 用 `<user>`;`BatchMode=yes` 保证不通即刻失败、不卡密码提示)→ **探通的**登记进机器清单(字段:主机名 / tailnet-IP / 用户 / 钥匙 / 默认shell / 探测日期),**幂等去重**(已在清单就跳过),**不通的**只记跳过、不登记。该能力段文档化在 `claude-config/CLAUDE.md`(阶段五 A12 会 grep 校验)。真实主机名 / IP / 用户名**不入库**——进部署参数表或本机记忆。

拿到旧机资料后,Claude 扫描 / 判断:

- **扫 `~/.claude/`**:`CLAUDE.md`、`settings.json`、`skills/`、`commands/`、`hooks/`、`mcpServers.json`、`plugins`、以及项目记忆目录。
- **逐类判断**:哪些客户要带走 → 迁到新服务器对应位置;哪些是旧环境专属(绝对路径 / 旧密钥)→ 到新环境重配。
- **skill / MCP**:列出**客户装了哪些**,问客户哪些要带;能从市场重装的重装(只迁清单不搬内容),客户私有的手动迁。
- **记忆**:客户的记忆是客户的,迁过去;**别导入别人的记忆**。⚠️ **编码路径改名**:记忆目录名按**旧绝对路径**编码(Mac `/Users/x/proj` → 目录 `-Users-x-proj`),迁到新服务器**必须按新路径重命名**(→ `-opt-workspace-proj`),否则记忆**静默不加载**(不报错、就是不生效)。
- **settings.json 别整份覆盖**:阶段一已铺了带 cc-state 钩子的 `~/.claude/settings.json`;迁客户旧 settings 时**只合并需要的项**,别整份盖过去(否则丢掉自愈钩子、还带进旧机的 `/Users/...` 死路径)。
- **密钥**:让**客户自己**重新填(`.secrets.env` 等),你不经手明文。

> 要点:同一套"扫描 + 迁移"手法,**数据源永远是使用者本人的旧机器**——迁谁的机器就还原谁的叠加层,别把别人的塞进来。

## 6. 阶段五 · 收尾验证

- 跑**完整功能验收**:`bash tests/deploy-test.sh all`——含破坏性自愈真测(只动 `cc-ztest-*` 专用测试会话,测完自动清理,不碰客户真实会话),**全绿**再做下面的人工两条。
- 客户从**电脑**和**手机**各开一个会话、跑一次权限批准,确认远程遥控 + 审批闭环。
- 交接:把"部署参数表"(含服务器 IP / 各账号)交给客户自己留档,**不入库**。
- ⚠️ **明确告知客户**:会话默认 `--dangerously-skip-permissions`(全自主、无逐步权限提示),唯一人工闸是 Moshi 审批、而 Moshi 选装。未装 Moshi = 无人工闸;让客户知情并接受(建议至少配 Moshi)。

## 7. 红线清单(Claude 部署全程必须守)

1. 不把别人的私有值 / skill / 记忆 / 凭据塞给客户;客户的叠加靠**扫客户自己机器**得到。
2. 不经手客户明文密钥 —— 让客户自己填。
3. origin 换成客户自己的仓,别让客户依赖别人的。
4. 每阶段**验证过**再进下一阶段;拿不准就 **AskUserQuestion 问客户**,别用看似合理的假设填空。

## 深入 runbook(docs/)

某一步卡住时查这些细则(都实测核实过):
- [`docs/deploy-test.md`](docs/deploy-test.md) —— 部署后功能验收:五闭环定义 + 全量测试点(A/S/O/M/H)+ S5 失败定位表;配 `tests/deploy-test.sh`(阶段五收尾跑)。
- [`docs/headless-login.md`](docs/headless-login.md) —— 无头 VPS 上 `claude` 首次 OAuth 登录(卡在浏览器那步)。
- [`docs/tailscale-setup.md`](docs/tailscale-setup.md) —— Tailscale 三设备同 tailnet + 无头授权 + IP/key 过期。
- [`docs/mac-reverse-channel.md`](docs/mac-reverse-channel.md) —— (选装)服务器 Claude 够到 Mac 取/送文件、取截图。
- [`docs/windows-reverse-channel.md`](docs/windows-reverse-channel.md) —— (选装)Windows 反向桥:服务器 Claude 够到 Windows 笔电(`laptop` 别名 + `lapget/lapput/lapls/lapimg`)。
- [`docs/desktop-layer.md`](docs/desktop-layer.md) —— (选装)服务器图形桌面层(noVNC + Chrome→claude.ai/code)安装。
- [`docs/agent-notify.md`](docs/agent-notify.md) —— (选装)agent 状态通知:等授权/完成时手机 Moshi 推送 + 可选笔电语音。
