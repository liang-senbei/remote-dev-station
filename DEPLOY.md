# DEPLOY.md — 给 Claude 看的"整套远程开发体系"部署驱动

> 本文是给 **AI 操作员(Claude)** 读的部署 runbook:照它把 `remote-dev-station` 这套
> "美国服务器跑 Claude Code + 电脑/手机远程遥控" 的体系,给一个**新客户 / 新机器**从零部署好。
>
> 人读的分层说明在 [README.md](README.md);本文只讲**怎么一步步执行、哪里要问客户、哪里要扫客户机器**。
> 各阶段的细节不在这里重复,而是**引用**对应文档([README](README.md) / [phone/](phone/README.md) /
> [windows/](windows/README.md) / [claude-config/RESTORE.md](claude-config/RESTORE.md))。

## 怎么用这份文档

客户对 Claude 说"照 remote-dev-station 的 DEPLOY.md 给我部署",Claude 读本文后:
1. **先收集客户参数**(阶段零),别猜;
2. **按阶段执行,每阶段验证过再进下一阶段**;
3. 遇到"客户本地已有资料",**扫描客户机器迁移他自己的**,绝不套用作者(仓主)的私有值/skill/记忆/凭据。

## 0. 两个概念(先内化,贯穿全程)

- **通用核心** = 这套体系本身:会话层脚本 / systemd 自愈 / tmux / ufw、Wave 客户端配置骨架、Moshi 配对**流程**。谁都一样,直接部署。
- **客户私有叠加** = 客户自己的:云服务器 / 账号 / 凭据 / Tailscale IP / 记忆 / 已有的 skill·MCP·dotfiles。**属于客户**,要么现场问、要么扫客户机器迁移。

> 🚫 **红线:绝不把作者(`xiaoxihexiaoyu`)的私有值、skill、记忆、密钥塞给客户。** 本仓 `claude-config/` 里那 95 个 skill、CLAUDE.md、记忆等,都是**作者的叠加层**,只在"作者自己换新机器"时用(见 [RESTORE.md](claude-config/RESTORE.md))。给客户 = 装通用核心 + 迁**客户自己的**。

## 1. 阶段零 · 收集客户参数(用 AskUserQuestion 逐项问,填一张临时"部署参数表",不入库)

- **服务器**:有海外云服务器吗?root SSH 通吗?Ubuntu/Debian?内存(建议 ≥16G)?→ 没有,先指导客户开一台。
- **Tailscale**:有账号吗?→ 服务器 + 电脑 + 手机都要进**同一 tailnet**。
- **Claude 账号**:客户自己的 Pro/Max —— 部署时**客户自己 `claude` 登录**,你不经手他的凭据。
- **客户端**:Mac / Windows / 两者都要?
- **手机**:要不要 Moshi 远程批准/操作?→ 客户自己的 Moshi 账号。
- **客户已有本地资料**:客户以前用过 Claude Code 吗?有没有想保留的 skill / MCP / CLAUDE.md / 记忆 / dotfiles?→ 决定阶段四扫不扫、扫什么。

## 2. 阶段一 · 服务器 0→1

照 [README.md](README.md) 的「从零部署 Quick Start」执行:**唯一前置 Tailscale**(`tailscale up`,无头授权见 [`docs/tailscale-setup.md`](docs/tailscale-setup.md))→ `git clone` **客户自己的 fork** → `./install.sh`(装依赖 + Claude Code native + 全部会话层 + systemd 自愈 + 防火墙)→ `source ~/.bashrc` → `claude` 登录(无头见 [`docs/headless-login.md`](docs/headless-login.md))。

> **⚠️ 必改·会话模型(最要命)**:仓里默认 `CLOUD_MODEL=claude-sonnet-5`,客户账号**未必有权限访问** → 客户端新建会话 + watchdog 断电自愈 `--resume` **全部启动即死**。装完**核实客户账号**,权限不够就改成客户可用的模型(如 `claude-opus-4-8[1m]`),**两处都改**:① `~/.bashrc` 的 `CLOUD_MODEL`(管交互新建会话);② `/etc/systemd/system/cloud-watchdog.service` 的 `Environment=CLOUD_MODEL=`(管断电自愈)→ 改后 `systemctl daemon-reload && systemctl restart cloud-watchdog.timer`。

- ⚠️ **origin 换成客户自己的**:给客户建一份仓(fork 或新建),别让客户长期依赖作者的 origin。
- ✅ **会话恢复(cc-state 钩子)装完即接线**:install.sh 若客户 `~/.claude/settings.json` **不存在**,会自动铺干净模板 [`claude-config/settings.client.json`](claude-config/settings.client.json)(只含 cc-state 钩子 + skip-permissions);**客户已有 settings.json 则不覆盖** → 需手动把该模板的 cc-state hooks 合并进去(否则会话恢复静默失效;`cloud_infra_check.sh` 会探这一项)。**别照抄作者的 `claude-config/settings.json`**——它挂了作者专属的 moshi-hook / statusline / hub-gate 等钩子(客户没装对应脚本/第三方二进制会每事件报错)。
- **验证**:`cloudgo` 能列会话;`systemctl is-active cloud-watchdog.timer` = active;`bash cloud_infra_check.sh` **核心全绿**(可选层未装显示 ⏭ 属正常)。完整功能验收(含破坏性 selfheal 真测)在**阶段五**统一跑,这里别提前跑。

## 3. 阶段二 · 客户端(电脑)

- **Mac**:照 README「电脑(Mac)0→1」——Tailscale + Wave + mosh。`wave-config/` 是**作者个人层**(README 附二 §🔴,含作者 IP/用户名),**别整份照搬**——拿它当模板,把下列作者私有值全换成客户自己的。
- **Windows**:照 [windows/README.md](windows/README.md)。

> **⚠️ 必改的作者私有值**(客户端凡拷 `wave-config/` / `cloudconn` 都要换,否则会连回作者的服务器):
> - **服务器 IP**:`cloudconn`(两份:仓根 + `wave-config/`)的 `HOST=`(`wave-config` 版还多一个 `HOSTIP=`,探活看守会 nc 它);`wave-config/{waveterm,waveterm-dev}/widgets.json` 里 `:6080` / `:8088` 两处 URL —— 全换成客户自己服务器的 Tailscale IP。
> - **Mac 用户名**:`widgets.json` 的 `cmd` 里 `/Users/xiaoyu/bin/cloudconn`、`com.wavetheme.ui.plist` 里 `/Users/xiaoyu/…` —— 换成客户自己的用户名。
> - `hammerspoon-init.lua` 是作者 Mac 专属(且指向已退役的 :8722),客户忽略或按需重配。
> - 服务器侧的 `bin/novnc-start.sh`(noVNC)与 `bin/cloud-dashboards.sh`(看板 :8088)已改为**自动取本机 Tailscale IP**,无需手改。

### 可选 · 用魔改版 Wave 客户端(汉化 + 自定义主题)

官方 Wave 就能用;想要中文界面 + 作者那套主题/侧栏,就从 `waveterm-zh/` submodule 自己构建:

```bash
git submodule update --init waveterm-zh    # 没用 --recurse-submodules clone 时补拉
cd waveterm-zh
# 前置:Go 1.25+、NodeJS 22 LTS、Task(taskfile.dev);Linux 另需 zip + zig
task init         # 首次装依赖
task package      # 生产构建 + 打包,产物在 make/(Linux ARM64 用 USE_SYSTEM_FPM=1 task package)
```

- 各平台前置 / 打包的**权威步骤**见 [`waveterm-zh/BUILD.md`](waveterm-zh/BUILD.md)。
- **汉化维护 + 上游更新**(Wave 出新版怎么 merge upstream、补翻新增文案)见 [`waveterm-zh/i18n-tooling/UPDATE.md`](waveterm-zh/i18n-tooling/UPDATE.md)。
- 🌏 国内构建:UPDATE.md 里给了一套镜像环境变量(GOPROXY=goproxy.cn、ELECTRON_MIRROR=npmmirror、ALL_PROXY 走本地代理),照它设,否则拉依赖会很慢 / 失败。
- 🔒 **私有 submodule 访问**:`waveterm-zh` 是作者私有仓(SSH URL),客户 `--recurse-submodules` / `submodule update` 会因无权限失败。给客户前二选一:把它设公开(Wave 是 Apache-2.0,合法),或客户 fork 后把 `.gitmodules` 的 url 改成客户自己的 fork。

- **验证**:客户从自己电脑连上、成功开一个会话进 Claude Code。

## 4. 阶段三 · 手机(选装)

照 [phone/README.md](phone/README.md) 配 Moshi:agent 钩子配对(批权限)+ 可选 SSH host setup(开终端)。**用客户自己的 Moshi 账号**,主机地址填 **IP**。

## 5. 阶段四 · 客户本地资料迁移(关键——扫客户的,不套作者的)

仅当阶段零里客户说"有想保留的 Claude 资料"时做。

> **⚠️ 先解决"够到旧机"**:跑在新服务器上的 Claude **够不到客户的旧机器**。先用 AskUserQuestion 跟客户定传输方式,二选一:① 客户在**旧机**上 `tar czf /tmp/claude-migrate.tgz -C ~ .claude`(**先删掉 `.claude/.credentials.json` 等密钥再打包**)→ scp / 面板上传到新服务器 → Claude 解包到临时目录按下面判断;② 客户旧机装 Tailscale 进**同一 tailnet** → Claude 经 `ssh` 直接读。没有这一步,迁移无从下手。

拿到旧机资料后,Claude 扫描 / 判断:

- **扫 `~/.claude/`**:`CLAUDE.md`、`settings.json`、`skills/`、`commands/`、`hooks/`、`mcpServers.json`、`plugins`、以及项目记忆目录。
- **逐类判断**:哪些客户要带走 → 迁到新服务器对应位置;哪些是旧环境专属(绝对路径 / 旧密钥)→ 到新环境重配。
- **skill / MCP**:列出**客户装了哪些**,问客户哪些要带;能从市场重装的重装(只迁清单不搬内容),客户私有的手动迁。
- **记忆**:客户的记忆是客户的,迁过去;**不导入作者的记忆**。⚠️ **编码路径改名**:记忆目录名按**旧绝对路径**编码(Mac `/Users/x/proj` → 目录 `-Users-x-proj`),迁到新服务器**必须按新路径重命名**(→ `-opt-workspace-proj`),否则记忆**静默不加载**(不报错、就是不生效)。
- **settings.json 别整份覆盖**:阶段一已铺了带 cc-state 钩子的 `~/.claude/settings.json`;迁客户旧 settings 时**只合并需要的项**,别整份盖过去(否则丢掉自愈钩子、还带进旧机的 `/Users/...` 死路径)。
- **密钥**:让**客户自己**重新填(`.secrets.env` 等),你不经手明文。

> 对照:作者自己换新机器 = 照 [RESTORE.md](claude-config/RESTORE.md) 还原**作者的**叠加层;给客户则相反 —— 还原**客户的**。同一套"扫描 + 迁移"手法,数据源不同。

## 6. 阶段五 · 收尾验证

- 跑**完整功能验收**:`/deploy-accept`(或 `bash tests/deploy-test.sh all`)——含破坏性自愈真测(只动 `cc-ztest-*` 专用测试会话,测完自动清理,不碰客户真实会话),**全绿**再做下面的人工两条。
- 客户从**电脑**和**手机**各开一个会话、跑一次权限批准,确认远程遥控 + 审批闭环。
- 交接:把"部署参数表"(含服务器 IP / 各账号)交给客户自己留档,**不入库**。
- ⚠️ **明确告知客户**:会话默认 `--dangerously-skip-permissions`(全自主、无逐步权限提示),唯一人工闸是 Moshi 审批、而 Moshi 选装。未装 Moshi = 无人工闸;让客户知情并接受(建议至少配 Moshi)。

## 7. 红线清单(Claude 部署全程必须守)

1. 不把作者的私有值 / skill / 记忆 / 凭据塞给客户;客户的叠加靠**扫客户机器**得到。
2. 不经手客户明文密钥 —— 让客户自己填。
3. origin 换成客户自己的仓,别让客户依赖作者的。
4. 每阶段**验证过**再进下一阶段;拿不准就 **AskUserQuestion 问客户**,别用看似合理的假设填空。

## 深入 runbook(docs/)

某一步卡住时查这些细则(都实测核实过):
- [`docs/deploy-test.md`](docs/deploy-test.md) —— 部署后功能验收:五闭环定义 + 全量测试点(A/S/O/M/H)+ S5 失败定位表;配 `/deploy-accept` 命令与 `tests/deploy-test.sh`(阶段五收尾跑)。
- [`docs/headless-login.md`](docs/headless-login.md) —— 无头 VPS 上 `claude` 首次 OAuth 登录(卡在浏览器那步)。
- [`docs/tailscale-setup.md`](docs/tailscale-setup.md) —— Tailscale 三设备同 tailnet + 无头授权 + IP/key 过期。
- [`docs/mac-reverse-channel.md`](docs/mac-reverse-channel.md) —— (选装)服务器 Claude 够到 Mac 取/送文件、取截图。
- [`docs/windows-reverse-channel.md`](docs/windows-reverse-channel.md) —— (选装)Windows 反向桥:服务器 Claude 够到 Windows 笔电(`laptop` 别名 + `lapget/lapput/lapls/lapimg`)。
- [`docs/desktop-layer.md`](docs/desktop-layer.md) —— (选装)服务器图形桌面层(noVNC + Chrome→claude.ai/code)安装。
- [`docs/agent-notify.md`](docs/agent-notify.md) —— (选装)agent 状态通知:等授权/完成时手机 Moshi 推送 + 可选笔电语音。
