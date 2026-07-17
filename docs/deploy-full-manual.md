# 部署全流程详解 + 复盘(「一键装机」筹备文档)

> 目标读者:准备做**一键装机**的我们自己。内容 = 服务器侧 + 客户电脑侧的**逐步流程**(每步:做什么/怎么验/会踩什么),
> 加上历次部署(echo-j1 自用、ser4121/zzw、38.244.50.24/wanglei、38.244.50.54/寒鹤+杨鑫)的**完整复盘**,
> 最后给出一键化蓝图(哪些能自动、哪些永远要人工)。
> 单坑速查仍以 [`deploy-pitfalls.md`](deploy-pitfalls.md) 为准,本文按流程串起来讲。

---

## 0. 全景:装完的机器长什么样

**服务器(Ubuntu/Debian,≥16G 建议)**
| 层 | 组件 | 位置 |
|---|---|---|
| 入网 | tailscaled(WireGuard 内网 100.x) | apt 装,systemd 常驻 |
| 会话核心 | claude(native)+ tmux + cc-state 钩子 + cloudgo/cloudattach 等 bashrc 函数 | `~/.local/bin` + `~/.bashrc` |
| 自愈 | cloud-watchdog(15s timer)+ cloud-sessions.service(开机)+ 登记表 `~/.cloud-sessions/` | systemd + `~/.local/bin` |
| 防护 | ufw(22/tcp + 60000-61000/udp + tailscale0)+ fail2ban + OOM 硬化(swap/earlyoom/软顶) | install.sh [6/7][7/7] |
| 协同 | hub(多 cc 互联)+ lap*/mac*(反向桥)+ cc-agents(座舱数据源) | `~/.local/bin` |
| VSCode 侧 | vscode-server + cc-cockpit vsix + 官方 anthropic.claude-code | `~/.vscode-server/extensions/` |
| 可选 | TigerVNC/noVNC 桌面、moshi-hook(手机审批)、cc-agents-notify(推送) | 按需 |

**客户电脑(Windows 为主)**:Tailscale + VSCode(Remote-SSH)+ 桌面快捷方式;可选 OpenSSH Server(供服务器反向操作)、反向隧道(兜底)、Wave 终端层、手机 Moshi。

**端口约定**:22(ssh)、60000-61000/udp(mosh)、5901/5902(VNC,仅 localhost 或 tailnet)、6080(noVNC,仅 tailnet)、2222(服务器 localhost,反向隧道落点)。

---

## 1. 服务器侧详细流程(0→1)

### 1.1 开机三清单(缺一后面必卡)
1. **机器**:海外 VPS,root,Ubuntu 22/24(Debian 系),≥16G(会话是重进程,~10 活跃封顶)。
   - ⚠️ 住宅代理机(ser4121 型)有两个变态特性先问清:**重启换公网 IP**、**重启洗 /root/.ssh/authorized_keys**。
2. **Tailscale 账号**:客户自己的。让客户在后台生成 **auth key**(Settings→Keys→Generate:Reusable 关、Ephemeral 关、7 天默认)发给你。**authkey 是硬前置**(.24 部署没先拿 key,返工)。
3. **Claude 账号**:客户自己的 Pro/Max。**红线:登录永远客户自助**,我们不经手凭据、不代注册(养号需求直接拒)。

### 1.2 Tailscale 入网(先于 install.sh!)
```bash
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up --auth-key tskey-auth-XXXX     # 客户后台生成的 key
tailscale ip -4                              # 记下 100.x.y.z —— 后面客户端全用它
tailscale status                             # 应看到客户的其它设备
```
- 装完提醒客户:后台 **Machines → 该服务器 → Disable key expiry**(否则 ~180 天 node key 到期突然全断)。
- 用完的 authkey 让客户 **revoke**(一次性 key 已消耗也照 revoke,卫生习惯)。
- ⚠️ authkey **等于密码**:不进聊天记录截图、不进录屏(这次剪视频就在录屏里抓到过一条完整 key,靠打码救的)、不进仓库。

### 1.3 取部署包(客户机红线:不落仓)
**不要在客户机 `git clone`**。ser4121 审计发现检出目录里全是作者痕迹(reflog/committer/submodule url/私有配置),最后整目录删除才洗干净。标准姿势:
```bash
# 在我方机器(echo-j1)上:
cd remote-dev-station && git archive --format=tar.gz -o /tmp/rds.tgz HEAD
scp /tmp/rds.tgz root@<客户服务器>:/tmp/
ssh root@<客户服务器> 'mkdir -p /tmp/rds && tar xzf /tmp/rds.tgz -C /tmp/rds'
# 装完(1.4-1.8 全做完)再:rm -rf /tmp/rds /tmp/rds.tgz
```
`git archive` 无 `.git`、无历史、无 origin;install.sh 全程 `install/cp` 纯拷贝、装完删源目录零影响(已验证:所有 systemd ExecStart 指向 /usr/local/bin 或 ~/.local/bin)。

### 1.4 install.sh 七步拆解(装的时候盯什么)
```bash
CLOUD_MODEL='claude-opus-4-8[1m]' ./install.sh     # ← 模型参数必须带!见 1.5-①
```
| 步 | 做什么 | 失败点/盯点 |
|---|---|---|
| [1/7] | apt 装 tmux/mosh/git/curl/ufw/fail2ban/python3 | **apt 锁**:新机开机 unattended-upgrades 必抢锁 → 先 `echo 'DPkg::Lock::Timeout "600";' > /etc/apt/apt.conf.d/99lock-timeout`(2remote 在 .24 验证过,主仓 install.sh 待并) |
| [2/7] | 装 Claude Code(native,免 Node) | 网络慢会久;失败重跑幂等 |
| [3/7] | bin/* → ~/.local/bin;cloud-boot/novnc-start/看板/hub/windows server-side → /usr/local/bin | — |
| [4/7] | tmux.conf + bashrc 函数块 + **settings.client.json 铺 ~/.claude/settings.json**(已有则不覆盖) | 客户已有 settings 时 cc-state 钩子要手动合并,否则**自愈静默失效** |
| [5/7] | systemd 单元(watchdog/sessions/moshi-hook*)+ enable --now + **CLOUD_MODEL 写入 bashrc + watchdog.service 两处** | daemon-reload 后 `systemctl is-active cloud-watchdog.timer` |
| [6/7] | ufw 放行 22 + mosh UDP + tailscale0,强制 enable | 若 ssh 端口非 22 先自己加规则再跑 |
| [7/7] | OOM 硬化(8G swapfile、overcommit、earlyoom、user.slice 软顶) | 磁盘小于 10G 时 swapfile 会失败,单独重跑 `bash oom/harden.sh` |
| 尾部 | shell 增强(fzf/starship/ble.sh),`set +e` 尽力而为 | **fzf 静默失败过一次 → cloudgo 菜单空壳**;装完必须 `command -v fzf` 验一下 |

装机脚本纪律(2remote 复盘):**关键步骤别 `| tail`** —— 管道后 `$?` 是 tail 的 0,前面失败被吞;要么去管道,要么 `set -o pipefail`。

### 1.5 装后必改六件套(每台客户机都要,漏一件必返工)
1. **CLOUD_MODEL**(最要命):默认 `claude-fable-5[1m]` 是作者账号专属。没在 install 时带参数就手改两处:`~/.bashrc` 的 `CLOUD_MODEL` + `/etc/systemd/system/cloud-watchdog.service` 的 `Environment=`,然后 `systemctl daemon-reload && systemctl restart cloud-watchdog.timer`。不改 = 新建会话和断电自愈**全部启动即死**。先实测客户账号可用什么:`claude --model claude-opus-4-8[1m] -p "ok"`。
2. **claude onboarding 快进**:全新账号首次交互式启动卡在 onboarding(选主题/登录方式),会话到不了就绪态 → cc-state 登记写不出 → 自愈失效(deploy-test S1 红)。修:`~/.claude.json` 设 `hasCompletedOnboarding=true` + `lastOnboardingVersion="<CLI版本>"`(+theme)。`-p` 探针能过≠交互能过,别被骗。
3. **sshd 公钥认证核查**:有的厂商出厂 `PubkeyAuthentication no`(cust54 踩过)→ 写 `/etc/ssh/sshd_config.d/10-pubkey.conf`;住宅机(ser4121 型)公钥**同时写 authorized_keys2**(重启洗 keys 时幸存)。
4. **客户版全局 `~/.claude/CLAUDE.md`**:install.sh 不铺 CLAUDE.md(作者的是私有层不能给)→ 客户的 cc **不知道**自己有 hub 协同、有 lap*/mac* 能反向操作客户电脑(工具装了没告诉 agent,wanglei/ser4121 都补过课)。铺一份干净客户版:hub 用法 + 收 `[HUB·]` 消息规矩 + 设备访问表(`ssh win`/`ssh mac` 别名)+ 会话/自愈约定。**改完要重启 claude 会话才加载**。
5. **unattended-upgrades 处置**:后台自动升 systemd 后不重启 → 沙箱服务全崩(226/NAMESPACE)→ DNS 死、"网页全打不开"(deploy-pitfalls 有完整条目,.54 实战)。三选一写进装机:禁用+手动维护窗(推荐)/ Automatic-Reboot true / apt-mark hold systemd*。
6. **fail2ban ignoreip 白名单**:install.sh 只装+起 fail2ban,**白名单没写** → 客户自己的出口/反向隧道重连协商失败会把客户 ban 掉(自封门)。写 `/etc/fail2ban/jail.d/00-ignoreip-tunnel.local`:ignoreip = `100.64.0.0/10`(tailscale CGNAT)+ 客户出口 IP + echo-j1 IP。
   (IS_SANDBOX=1 不用单独做:bashrc 各启动函数已内联;只有客户裸敲 `claude` 时才会遇到 root 提示。)

### 1.6 claude 登录(客户自助,无头机流程)
- 有桌面层:TigerVNC/noVNC 里开 Chrome → claude.ai 登录 → 终端 `claude` 走 OAuth 回调。
- 纯无头:`claude` 打印 OAuth URL → 客户在自己电脑打开授权 → 贴回 code(细节 `docs/headless-login.md`)。
- 或 `ssh cloud` 型入口(见 2.2):服务器放一个 `cloud-enter`(`tmux new -A -s cc-login` 直达登录页),客户自己敲一次完成登录。
- 登录后凭据落盘免登;**验收前**记得 1.5-② 的 onboarding 快进。

### 1.7 VSCode 服务器侧预置(客户体验的关键差异点)
1. `~/.vscode-server/extensions/` 预置 **cc-cockpit vsix**(解包目录 + 更新 extensions.json;极简镜像没 unzip 用 python zipfile)。
2. 预置/对版本 **官方 anthropic.claude-code**(客户首连会自动装,预置可免等;版本要和服务器 claude CLI 匹配)。
3. `/opt/workspace` 建好 + `agents.code-workspace`(可选)。
4. ⚠️ **装/更新 vsix ≠ 生效**:已开着的窗口还跑旧版(实锤:0.4.13 装了没 Reload,自动软链功能整整一天没跑,全靠手动补链还误判成功能坏了)。**任何 vsix 动作后都要求客户 Reload Window**,验证方法:`grep -o "cc-cockpit-[0-9.]*" ~/.vscode-server/data/logs/<最新>/exthost*/remoteexthost.log`。
5. cockpit「打开」出空 untitled 的两个已知原因:agent 建在**子目录**(≠窗口打开的 /opt/workspace)、或 agent **无历史对话**。规矩:建 agent 用 /opt/workspace 本身;拿不准点「Attach 终端」永远对。

### 1.8 验收(全绿才算装完)
```bash
bash cloud_infra_check.sh          # 核心服务全绿(可选层 ⏭ 正常)
bash tests/deploy-test.sh all      # 19 PASS / 0 FAIL 基准(含断电自愈真测,只动 cc-ztest-*)
```
- deploy-test 已知盲区:**不探 fzf**;.54 上 novnc 项红是预期(已卸)。
- 手动两条:客户从自己电脑开一个会话跑通;(装了 moshi 的)手机批一次权限。
- **cloud-watchdog KillMode 检查**:`grep KillMode /etc/systemd/system/cloud-watchdog.service` 应为 `process`。旧版 oneshot 会话随 cgroup 被杀,自愈成摆设(ser4121 抓出的真 bug,只有真 systemd 触发才暴露,手动测不出来)。**主仓已修(2026-07-17),存量机器要手动补 + daemon-reload**。
- 交接:部署参数表(IP/账号/端口)给客户留档不入库;明确告知 `--dangerously-skip-permissions` 意味着什么(唯一人工闸是 moshi,不装=无闸)。

### 1.9 可选层
- **桌面**:方向已定 **TigerVNC 为默认**(:1/5901 仅 localhost,ssh 隧道访问;noVNC 弃用趋势,echo-j1 的 noVNC 已删)。不要的卸干净(stop+disable+mask+apt remove)。⚠️ **VNC 密码上限 8 字符**(VncAuth 协议截断,.54 设 12 位实际只前 8 位生效)——一键装机生成密码就按 8 位来。截图排查用的 `scrot` 默认没装,顺手 apt 进模板。
- **手机 Moshi**:`phone/README.md`,主机地址**填 IP 别填 MagicDNS**(`*.ts.net` 手机常解析不了,"验证失败"头号原因)。
- **通知**:cc-agents-notify + MOSHI_TOKEN(不填=静默)。

---

## 2. 客户电脑侧详细流程

### 2.1 Windows(主推:VSCode 方案,cust54 已验证全套)
1. **Tailscale**:装 App → 登客户账号 → `tailscale status` 能看到服务器。
2. **(若服务器要反向操作这台机)OpenSSH Server**:**从 GitHub 直装**(2remote 的 `win-openssh-setup.ps1`,绕开 Windows Update"可选功能"那条又慢又卡的路);`Get-Service sshd` 确认在跑;⚠️ Windows 侧 **PubkeyAuthentication 同样默认关**要开;服务器公钥进 `~/.ssh/authorized_keys`,**管理员账号还要进 `C:\ProgramData\ssh\administrators_authorized_keys`**;DefaultShell 建议改 PowerShell(注册表 `HKLM\SOFTWARE\OpenSSH\DefaultShell`,否则 lapls/lapimg 的 Get-ChildItem 在 cmd 下报错)。
3. **VSCode + Remote-SSH 扩展**:⚠️ 机器上有 Cursor 时 `code` 命令可能指向 Cursor,**用全路径** `"D:\Microsoft VS Code\bin\code.cmd" --install-extension ms-vscode-remote.remote-ssh`。
4. **`~/.ssh/config`** 写服务器别名(HostName=服务器 **tailnet IP**)+ **预置 known_hosts**(首连零弹窗):
   ```
   Host cust-cloud
     HostName 100.x.y.z
     User root
   ```
5. **桌面快捷方式**(一键进座舱):`Code.exe --folder-uri "vscode-remote://ssh-remote+cust-cloud/opt/workspace"`(直开 /opt/workspace,规避 folders.length==0 的 untitled 坑)。
6. 首连:Remote-SSH 自动装 vscode-server → 官方 Claude 插件自动装(或已预置)→ **Reload Window 一次** → 侧栏出现 FLEET COCKPIT。
7. **(兜底)反向隧道**:tailnet 数据面僵死时的后路。**免装软件版**:Windows 计划任务(`/SC ONSTART /RU SYSTEM`)跑 wrapper:循环 `ssh -N -R 2222:localhost:22 <服务器>`,先 tailnet IP、失败落公网。细节坑:密钥副本放 `C:\ProgramData\ssh\`(SYSTEM 读不了用户 ~/.ssh)+ ACL 收紧;**wrapper 里别写中文注释**(双层 ssh 编码坏);ssh 参数别用 PS `@数组` splat(丢 `-i`);服务器侧配 `ClientAliveInterval 30/CountMax 2`(否则笔电睡醒重连,旧死连接占着 2222 要拖 ~180s)。
8. **(选装)Wave 层**:`windows/` 目录三脚本 + widgets.json。编码铁律:`.ps1` 要 **UTF-8 带 BOM**、`widgets.json` 要 **无 BOM**;对空 widgets.json 别用插入逻辑(会产尾逗号非法 JSON),直接 scp 完整文件;装完**重启 Wave** 才见按钮。
9. **多客户机防错**:一台服务器授权多台客户电脑时(如 .54 的寒鹤+杨鑫),别名**认人**(win=寒鹤,yangxin=杨鑫,别复用);任何反向操作先 `ssh <别名> hostname` 核对再动手。

### 2.2 Mac(wanglei 已验证)
1. Tailscale App 登录;装 VSCode 同 2.1(或轻量路线:终端 `ssh cloud`)。
2. **`ssh cloud` 一键入口**:Mac `~/.ssh/config` 写 `Host cloud` + `RequestTTY force` + `RemoteCommand /usr/local/bin/cloud-enter`;服务器放 `cloud-enter`(`tmux new-session -A -s cc-login`)。客户敲 `ssh cloud` 直接进会话。
3. ⚠️ **HostName 可能要填公网而非 tailnet**:客户 tailnet 的 **ACL 会方向性拦截**(wanglei 实测 Mac→server:22 超时但 `tailscale ping` 通、反方向通;拦在 tailscaled 层,关服务器防火墙无效)。要么客户后台 Access Controls 放行,要么直接走公网 22(fail2ban 的 ignoreip 记得加客户出口 NAT)。
4. 反向操作 Mac:服务器公钥进 Mac `authorized_keys` → `ssh mac` 别名 + macget/macput/macls/pullimg。
5. 反向隧道端口规划:多设备时**每台一个端口**(Win=2222、Mac=2223…),wanglei 家 Mac 抢了 2222 导致 Win flapping。

### 2.3 手机(选装)
Tailscale App + Moshi App(客户账号)→ 配对 → 主机地址改成 **IP**。

---

## 3. 复盘:全部踩坑按阶段归类(现象→根因→修法一句话版,详版见 pitfalls/记忆)

**入网层**
- 控制台两端 Connected 但互 ping 超时 → "Connected"只是控制面,数据面(WireGuard)是另一回事;Windows 睡醒常僵死 → 让**笔电侧主动**发一次 `tailscale ping` 打洞复活。
- 客户 tailnet ACL 方向性拦截(A→B 挡、B→A 通)→ 走公网或让客户改 ACL。
- MagicDNS 名手机解析不了 → 一律填 IP。
- Mac 挂代理连不上 100.x → 代理绕过 `100.64.0.0/10`。
- node key ~180 天过期突然全断 → 装完即 Disable key expiry。

**服务器装机层**
- CLOUD_MODEL 默认值是作者专属模型 → 不带参数装 = 会话全启动即死。
- 全新 claude 账号 onboarding 卡交互 → `hasCompletedOnboarding=true` 快进。
- watchdog oneshot 无 KillMode → 自愈拉起的会话被 cgroup 回收连坐杀死(只在真 systemd 路径暴露)→ `KillMode=process`。
- fzf 带 `|| true` 静默失败 → cloudgo 空壳;装完显式验。
- unattended-upgrades 升 systemd → 沙箱服务全崩 DNS 死 → 禁用/自动重启/hold 三选一。
- 出厂 `PubkeyAuthentication no`、住宅机重启洗 authorized_keys/换公网 IP → sshd_config.d 补丁 + authorized_keys2 + 运维走公网客户走 tailnet。
- 客户机不留仓(作者痕迹),部署用 git archive 的 tarball,装完删。
- 客户 cc 不知道 hub/lap* → 铺干净客户版全局 CLAUDE.md(改完重启会话生效)。
- fail2ban 没写白名单 → 把客户自己 ban 了(自封门)→ jail.d ignoreip:100.64.0.0/10 + 客户出口 + 运维机。
- 装机脚本 `| tail` 吞退出码 → 失败被当成功 → 关键步骤去管道或 pipefail。
- `pkill -f <pattern>` 会匹配到自己的 ssh 命令行连壳一起杀(.24 两次 + echo-j1 一次)→ 一律 `pkill -x 精确名` 或按 pid。
- VNC 密码超 8 位静默截断(VncAuth 上限)→ 密码按 8 位生成。

**VSCode/座舱层**
- vsix 装了 ≠ 生效,窗口还跑内存里的旧版 → 必须 Reload Window;查 exthost 日志确认版本。
- 「打开」出空 untitled:窗口 root ≠ agent 目录 / 空会话 → agent 建在 /opt/workspace、日常用 Attach。
- `code` 命令被 Cursor 抢 → 用 VSCode 全路径装扩展。

**Windows 反向操作层**
- 中文经 ssh 到 Windows 必坏(GBK)→ `powershell -EncodedCommand`(UTF-16LE base64);回读用 PS 端 base64。
- scp 中文远端路径坏 → 先 Copy-Item 成 ASCII 名再传。
- ssh 会话断则后台子进程全灭 → 断点续传循环或 schtasks 落日志。
- 两台笔电两把钥匙两个 shell(PowerShell vs cmd)→ 别名认人、动手前 `hostname` 核对。

**安全/红线**
- claude 登录客户自助、不代注册养号;authkey/密码不进录屏聊天(录屏泄过一次靠打码救);服务器→客户机单向信任(客户机公钥绝不进运维机);root 密码暴露过的建议客户重置。

---

## 4. 一键装机蓝图(自动化缺口 → 目标形态)

**服务器侧 `server-setup.sh <tailscale-authkey> <cloud-model> [客户出口IP]`(在现 install.sh 外再包一层;顺序按 2remote 实战优先级)**
1. `DPkg::Lock::Timeout "600"` 先落(不然第一步 apt 就可能卡锁)。
2. 装 tailscale + `up --auth-key`(参数 ①)——Tailscale 必须先于 install.sh(noVNC/看板要绑 tailnet IP,.24 返过工)。
3. **PubkeyAuthentication yes**(sshd_config.d/10-pubkey.conf + reload;.24/.45/.54 三台全中,最高频手动步)+ 住宅机加 authorized_keys2。
4. **unattended-upgrades 处置**(禁用,血泪最该加)。
5. 跑 install.sh(透传 CLOUD_MODEL 参数 ②)。
6. **fail2ban ignoreip**(100.64.0.0/10 + 参数 ③ 客户出口 IP + 运维机 IP)。
7. onboarding 快进(探 CLI 版本写 ~/.claude.json)+ 铺客户版全局 CLAUDE.md(模板入仓,**设备表按参数自动填** win/mac 的 tailnet IP+用户)+ fzf 显式验证。
8. 桌面层默认 **TigerVNC**(8 位密码自动生成)+ scrot。
9. vscode-server 预置:cc-cockpit vsix + 官方插件离线包(vsix 入仓 or 发布位拉取)。
10. 尾声自动跑 cloud_infra_check + deploy-test.sh all,打印一页报告 + "待人工"清单(就两件:客户登 Claude、后台 Disable key expiry/revoke authkey)。

**客户 Windows 侧 `client-setup.ps1 -Server 100.x.y.z`**
1. winget 装 Tailscale + VSCode(检测 Cursor,全路径调 code.cmd)。
2. 写 ~/.ssh/config + 预置 known_hosts;`code --install-extension ms-vscode-remote.remote-ssh`。
3. 生成桌面「远程座舱」快捷方式(folder-uri 指 /opt/workspace)。
4. (勾选)开 OpenSSH Server(GitHub 直装,复用 win-openssh-setup.ps1)+ PubkeyAuth 开 + 收服务器公钥 + DefaultShell=PowerShell。
5. (勾选)注册反向隧道计划任务(全 ASCII wrapper,端口按设备分配)。
6. 唯一人工:Tailscale 登录点一下(客户账号)。

**永远自动化不了的三件**(一键装机的"README 第一行"):客户 Tailscale 账号登录/授权、客户 Claude 账号登录、客户后台 Disable key expiry。设计上就把这三件做成装机脚本结尾的"最后三步"提示卡。

---

*2026-07-17 由 cc-remote-dev-station 汇总,cc-2remote-dev-station 的实战复盘(①坑清单 ②install.sh 自动化优先级)已并入。主仓当日已修:cloud-watchdog KillMode=process。*
