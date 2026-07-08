# 部署踩坑速查（首次真实客户部署沉淀）

> 给客户部署 `remote-dev-station` 时容易踩的坑，按"现象 → 根因 → 修法"整理。都是 2026-07 首次客户部署（住宅 ISP 云主机 + Windows 笔电 + LightWAN）实测踩过的。配合 [DEPLOY.md](../DEPLOY.md) 用。

---

## 一、服务器 / 网络

### 1. 住宅机公网 IP 重启就变
- **现象**：服务器重启后公网 IP 变了（实测 .199 → .52），之前配的 IP 全失效。
- **根因**：住宅 ISP 云主机公网 IP 非固定，reboot / 租约到期会轮换。
- **修法**：客户端**一律用 Tailscale 内网 IP（`100.x.y.z`，永不变）**连；公网 IP 只作运维应急。反向隧道的公网兜底目标要注明"重启后可能需更新"。

### 2. 重启洗掉 `authorized_keys`
- **现象**：服务器一重启，SSH 免密失效，`/root/.ssh/authorized_keys` 被清空（mtime = 开机时刻）。
- **根因**：部分住宅机服务商的开机代理会重刷 `~/.ssh/authorized_keys`。
- **修法**：公钥**同时写 `~/.ssh/authorized_keys2`**（代理不碰、sshd 默认也认）；`PubkeyAuthentication yes` 放 `/etc/ssh/sshd_config.d/`（重启幸存）。root 密码在服务商面板可查/重置。

### 3. Tailscale 控制台"Connected"≠ 真能通
- **现象**：两端管理台都显示 Connected，但 `tailscale ping` 全超时、`tx>0 rx=0`。
- **根因**："Connected"只代表设备↔协调服务器的控制面；数据面（WireGuard 握手/打洞）是另一回事。Windows 睡醒/换网后客户端数据面会僵死，甚至直接 **Logged out**。
- **修法**：从**掉线那端主动发流量**打洞（笔记本上 `tailscale ping <服务器>`）；真登出了就重新登录 Tailscale。**客户端连不上先查 Tailscale 是不是掉线/登出**，别当成公钥或服务器问题。

### 4. LightWAN / 规则代理劫持 `100.64.0.0/10`
- **现象**：Tailscale 明明在线，但客户 `ssh <tailnet-IP>` 超时；走公网 IP 却通。
- **根因**：规则代理（LightWAN 等）把 Tailscale 的 CGNAT 段（`100.64.0.0/10`）当"海外流量"劫进代理隧道，到不了 tailnet。
- **修法**：在代理软件里把 `100.64.0.0/10` 加进**直连/绕过**规则。

---

## 二、账号 / 会话（最容易让"装完却用不了"）

### 5. `CLOUD_MODEL` 默认是作者专属模型
- **现象**：客户端新建会话 + watchdog 自愈全部启动即死。
- **根因**：仓里默认 `CLOUD_MODEL=claude-fable-5[1m]` 是作者账号特殊模型，普通 Pro/Max 没有。
- **修法**：装完**立刻**两处都改成客户账号可用模型（`~/.bashrc` + `cloud-watchdog.service`），`daemon-reload && restart cloud-watchdog.timer`。

### 6. 全新账号 onboarding 卡死（隐蔽！）
- **现象**：会话起不来、`deploy-test` S1/S5 红、断电自愈失效。
- **根因**：全新 Claude 账号**首次交互**卡在引导（选主题→选登录方式），到不了就绪态 → cc-state 登记写不出。`claude auth login` 只写凭据不标记引导完成，`claude -p` 非交互跳过引导→显得正常，极具迷惑性。
- **修法**：登录后在 `~/.claude.json` 补 `hasCompletedOnboarding=true` + `lastOnboardingVersion="<版本>"` + `theme="dark"`。

### 7. watchdog 的 `KillMode` cgroup 回收（仓库级真 bug）
- **现象**：`deploy-test` S5 红——kill 会话后 watchdog 拉不回来（复活即死、3 次退避）。
- **根因**：`cloud-watchdog.service` 是 `Type=oneshot` 无 `KillMode`（默认 control-group），它 `tmux new-session` 起的会话随 oneshot 退出被 systemd 连带回收。手动跑能活（附到已有 tmux 服务器）、只有真 systemd 定时器触发（=生产重启后）才暴露。
- **修法**：`cloud-watchdog.service` 加 `KillMode=process`。（已进本 PR）

### 8. `fzf` 静默没装 → `cloudgo` 菜单空壳
- **现象**：`cloudgo` 只打印"(无会话)"、没法新建。
- **根因**：install.sh 装 fzf 那行带 `|| true`，apt 抽风时静默失败。
- **修法**：验证 `command -v fzf`，没有就 `apt-get install -y fzf`。

---

## 三、交接洁净化

### 9. 客户仓/检出并非天生"去作者化"
- **现象**：客户翻 `~/remote-dev-station` 能看到作者的 `claude-config/`、开发者文档、git 历史里的作者邮箱/主机名。
- **根因**：给客户建的仓只是主仓副本 + 几个小改动，**仓库层面没去作者化**；install.sh 也不铺 CLAUDE.md。
- **修法**：交接前跑 **DEPLOY.md 阶段六洁净化**（删检出目录 + grep 验证零作者痕迹）；另铺一份**干净客户版 `~/.claude/CLAUDE.md`**（让 cc 知道 hub/lap* 基础能力，不含作者私货）。

---

## 四、客户端 / Windows

### 10. 反向控制的前提：笔记本得先"开一扇门"
- **现象**：Tailscale/隧道都在，但服务器 SSH 不进客户笔记本。
- **根因**：Tailscale 只给网络可达，不给命令执行；服务器要进笔记本，笔记本必须有 sshd 在听（或主动推反向隧道）。
- **修法**：笔记本装 OpenSSH Server + 把服务器公钥加进 `authorized_keys`（管理员账户还要加 `C:\ProgramData\ssh\administrators_authorized_keys`）。

### 11. Windows OpenSSH 默认 shell = cmd → `lapls/lapimg` 报错
- **现象**：`lapls` 报 `'Get-ChildItem' 不是内部或外部命令`。
- **根因**：Windows OpenSSH 默认落 cmd.exe，跑不了 PowerShell cmdlet。
- **修法**：把默认 shell 设成 PowerShell：`reg add "HKLM\SOFTWARE\OpenSSH" /v DefaultShell /t REG_SZ /d "…powershell.exe" /f`。

### 12. PowerShell / SSH 编码坑（一堆）
- `.ps1` 含中文**必须带 BOM**（PS5.1 才认）；`widgets.json` **不能带 BOM**（Wave 带 BOM 解析失败 → widget 全空）。
- 服务器（UTF-8）的中文输出在 Windows 控制台显示**乱码**：脚本里加 `[Console]::OutputEncoding=[Text.Encoding]::UTF8`。
- **双层 ssh 里内嵌中文/复杂引号会被编码破坏** → 用 `iconv -t utf-16le | base64` + `powershell -EncodedCommand`，或写文件后 **binary `scp`**（逐字节不坏）。
- 中文版 Windows 上 `schtasks /V` 字段名是中文，英文 grep 匹配不到属正常。

---

## 五、Wave deck（「新会话/恢复本页」，坑最密）

> deck 原是与主系统脱节的"最小参考实现"，在新版 Wave（实测 0.14.5）上多处失效。我们首次客户部署时逐一踩过下面这些坑（BoomAsset 沉淀，已比旧记录更完整）。
> **Windows Wave 层的最终实现以 `windows-wave-layer` 分支为准**（同事用 WSL mosh 抗断方案，补「指挥中心 cc-agents / 隧道」等 widget）——本 PR 不再带 deck 代码改动，仅把踩过的坑记录在此供参考。以下 13~21 条对任何 Windows widget 实现都适用。

### 13. 新会话 `[exited]` 秒退且 exit 0
- **现象**：新建会话 pane 秒退、标为 `[exited]` 且 exit code 0，看着像正常结束，人肉交互登录又复现不出。
- **根因**：`ssh -t` 非交互链路下 sshd 只给极简 PATH（无 `~/.local/bin`），tmux pane 内 `claude` command-not-found（status 127）；交互登录带全 PATH，所以测不出来。
- **修法**：`cc-new`/`cc-restore` 顶部加 `export PATH="$HOME/.local/bin:$PATH"`（commit 76d7b2c）。取证技法：`tmux set -g remain-on-exit on` 留尸 + `capture-pane` 看 status。

### 14. 「恢复本页」报"没解析到标签页 id" / 登记 tab 恒空
- **现象**：恢复本页报"没解析到标签页 id"，登记出来的 tab 字段永远是空的。
- **根因**：Wave 0.14.5 三路全断——`wsh blocks list` 报 `no workspaces`、swaptoken 的 rpccontext 无 tabid（只有 sockname/routeid/procroute/blockid）、env 里也没有 `WAVETERM_TABID`。
- **修法**：自造本页身份——tab 级持久变量 `CC_TABID`（`wsh setvar/getvar -b tab`，首用生成 uuid，跨重启稳定），`blocks list` 留作兜底（4d4d41c）；孤儿会话直接改账本 json 的 tab 字段即可过继。

### 15. 「恢复本页」打 ✓ 但没窗口弹出
- **现象**：恢复本页脚本打印 ✓/"已恢复"，但根本没有终端窗口弹出来。
- **根因**：`wsh run` 在 cmd 块的 JWT 上下文里**静默失败**（三种形态全 rc=1 零输出，和 P2 同一路由断点）；脚本没查 `$LASTEXITCODE` 就无脑报 ✓。
- **修法**：弃用弹块 API，改成"本块就地 `ssh -t` 接回"（fd09216）。教训：外部命令必须查 rc 再报成功。

### 16. 「恢复本页」恒显示"(注册表空)"空转
- **现象**：恢复本页永远显示"(注册表空)"，明明有会话也读不到。
- **根因**：`cc-new`/`cc-restore`（写 tsv）和 `cc-slugs-by-tab`（读 cloud-sessions）是**两套不同源的账本**。
- **修法**：统一到 `~/.cloud-sessions`（ce3b3c8）。

### 17. 中文乱码（如"娉ㄥ唽琛ㄧ┖"），且中文 slug 会被解坏
- **现象**：回传的中文显示成"娉ㄥ唽琛ㄧ┖"这类乱码，中文 slug 也被解坏。
- **根因**：PS5.1 的 `[Console]::OutputEncoding` 默认按 GBK 解 ssh 回传的 UTF-8。
- **修法**：脚本开头把输出编码设成 UTF8（4d4d41c）。

### 18. BOM 双规（ps1 必须带、json 必须不带）
- **现象**：ps1 中文解析失败，或 widget 全空。
- **根因**：`.ps1` 必须带 BOM（PS5.1 解析中文要它），`widgets.json` 必须**无** BOM（带 BOM 则 Wave 解析失败 → widget 全空）——两者要求相反。
- **修法**：部署后验首 3 字节——ps1 应为 `EF BB BF`，json 应为 `7B`（`{`）。

### 19. 修好后重试同名仍秒退
- **现象**：明明已修好 PATH，重试同一个名字还是秒退。
- **根因**：之前的失败尝试留下了空壳账本（uuid 从没真正生成过会话），重试走 `--resume` 去接一个不存在的 uuid。
- **修法**：删掉空壳 json；建议 `cc-new` 对 resume 失败降级为新建。

### 20. lib 日志报"文件正由另一进程使用"、且 tabid 主路被炸
- **现象**：日志报"文件正由另一进程使用"，连带把 tabid 主逻辑也炸了。
- **根因**：widget 被**双触发**起了两个实例，并发 `Out-File` 同一个日志文件。
- **修法**：日志写入加 try/catch（fd09216）。原则：widget 脚本里的日志写入永远不能穿透 / 中断主逻辑。

### 21. 调试技法合集
- **现象**：Windows sshd + 双层 ssh + tmux + 沙箱交织，调试处处是假象。
- **根因**：多层链路各有陷阱，容易把假象当真 bug。
- **修法**：
  1. Windows sshd 下 `ssh -tt` 必须 `sleep N |` 吊住 stdin，否则 conpty 秒拆、零输出；
  2. 无 PTY 的双层 ssh 嵌套 `ssh.exe` 会卡 stdin（tunnel-check headless 卡死其实是假象）；
  3. `remain-on-exit` 全局开 + attach 客户端 → script 永不退，矩阵实验每步都要 `timeout`；
  4. `pkill -f 模式` 会匹配到自己所在的命令行（把自己也杀了）；
  5. 中文经 PS→ssh 参数传递实测不坏（UTF16→UTF8），编码锅先验尸再定罪。

---

## 六、文件桥 / taildrop / 沙箱（多 cc 通用）

> 取放用户本地文件、跨设备传输、沙箱内清理进程时的通用坑（advertise 沉淀），不限于本项目部署。

### 22. 取放用户本地文件：`lap*` / `mac*` 桥在部分 cc 缺失
- **现象**：某 cc 里 `lapget`/`lapput`/`macget`/`macput` 全 command-not-found。
- **根因**：桥 helper 没装进该 cc 的 shell PATH（不像 `cloud`/`hub` 写在 bashrc 里）。
- **修法**：已把 `lap*` 装进 `/usr/local/bin`（所有 cc 可用：`lapget`/`lapput`/`lapls`，走 tailscale scp，目标配置在 `~/.config/lap.conf`）。备用降级：`tailscale file cp <file> <设备>:` 推 + 端上 `tailscale file get <目录>` 收。

### 23. Taildrop 发给"离线"设备：cp 假成功
- **现象**：目标离线（`tailscale status` 末列是 `-`）时 `tailscale file cp` 返回 exit 0，但设备根本收不到。
- **根因**：taildrop 需目标在线直传，离线不落地；且此版本没有 `-t`（只有 `--name`/`--verbose`/`--targets`）。
- **修法**：先 `tailscale status` 确认目标 active，再 `cp --verbose`，看到 `sent "x" to <dev>/<ip>` 才算真送达。

### 24. `pkill -f` 自杀（exit 144）
- **现象**：`pkill -f "http.server 8899"` 返回 144、清理没生效。
- **根因**：pkill 的模式串出现在执行它的 shell 自身 argv 里，把自己那条 shell 也一起杀了。
- **修法**：按 PID 杀（`ss -tlnpH | grep :端口` 取 pid= 再 kill），或用 `pgrep -x <name>` 精确匹配进程名。

### 25. 沙箱禁前台 `sleep`（exit 144）
- **现象**：命令里含 `sleep 0.3`，整条被信号打断、exit 144。
- **根因**：沙箱拦截前台 `sleep`。
- **修法**：等条件改用 `timeout N sh -c 'tail -f log | grep -m1 pat'` 或 Monitor 工具，别用 sleep 轮询。

### Mac 端 Wave deck:mosh 报 "Error: vector"(缺 UTF-8 locale)
- **现象**:Mac 上点"会话"widget,cloudconn 走 mosh 连服务器,报 `Error: vector`;终端手敲 `mosh host` 也一样。
- **根因**:mosh 客户端要 UTF-8 locale。macOS 的 GUI app(Wave)cmd 块常不带 `LANG/LC_ALL`,非交互/嵌套 ssh 也丢 locale → mosh 挂。
- **修法**:cloudconn 开头 `export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8`。测试链路时也要带上再 `mosh ... -- echo OK`。

### install.sh 的可选层/配置缺口(新客户部署要手动补)
- **现象**:部署后 ①服务器 Claude 不知道自己能力(无 `~/.claude/CLAUDE.md`);②临时会话 widget 瘸(缺 `/usr/local/bin/mosh-server-tmout`);③项目看板/服务器桌面 widget 连不上(cloud-dashboards.service / novnc.service 没装)。
- **根因**:旧版 install.sh 只铺 settings 模板 + 把 `cloud-dashboards.sh/novnc-start.sh` 拷到 /usr/local/bin,但没铺 CLAUDE.md、没装 mosh-server-tmout、没装这两个 service 单元。
- **修法**:已在 install.sh 补齐(铺 CLAUDE.md、装 mosh-server-tmout、noVNC 必装 + 起 novnc/cloud-dashboards/gen-dashboard)。老部署手动补:`CLAUDE.md`→`~/.claude/`;`bin/mosh-server-tmout`→`/usr/local/bin/`;`systemd/{novnc,cloud-dashboards}.service`→`/etc/systemd/system/`+`enable --now`。

### Wave widgets.json 部署:占位符要全替(不止 <YOUR_HOME>)
- **现象**:项目看板/服务器桌面 widget 打开报连接错误,URL 里还是 `http://<SERVER_TAILSCALE_IP>:8088/`。
- **根因**:铺 widgets.json 时只替了 `<YOUR_HOME>`,漏了 `<SERVER_TAILSCALE_IP>`。
- **修法**:两个占位符都替:`<YOUR_HOME>`→用户家目录、`<SERVER_TAILSCALE_IP>`→服务器 tailscale IP。cloudconn 里的 `<SERVER_TAILSCALE_IP>` 同理。

### 客户端缺 cloud/cloud-pub SSH 别名 → widget 报 lookup cloud: no such host
- **现象**:Mac Wave 的"服务器文件"widget(或任何用 `root@cloud` 连接的)报 `Connecting to root@cloud, Error: dial tcp: lookup cloud: no such host`。
- **根因**:`wave-config` 的 `connections.json`/`widgets.json` 用连接名 `root@cloud`/`root@cloud-pub`,但客户端 `~/.ssh/config` 没这两个别名。
- **修法**:客户端 `~/.ssh/config` 建 `cloud`(HostName=服务器 tailscale IP)+ `cloud-pub`(=公网 IP)别名,User root、IdentityFile 指客户端钥匙、IdentitiesOnly yes;并 `ssh-copy-id` 把客户端公钥推进服务器。

### cloud-dashboards / novnc 只绑 Tailscale IP,别在 127.0.0.1 上测
- **现象**:服务 `systemctl is-active` 是 active,但 `curl 127.0.0.1:8088` 返回 000 无响应,以为服务坏了。
- **根因**:`cloud-dashboards.sh`/`novnc-start.sh` 故意 `--bind $(tailscale ip -4)`(tailnet-only 更安全),不监听 127.0.0.1。
- **修法**:验证用 tailscale IP:`curl http://100.x.y.z:8088/`(widget 也是走这个)。

### claude 在 ~/.local/bin,noVNC 桌面终端/systemd 上下文敲 claude 报 command not found(exit127)
- **现象**:客户在 noVNC 桌面(systemd 起的 xfce)的终端里直接敲 `claude` → `command not found`;但 cloudgo 交互会话正常。
- **根因**:claude native 装在 `~/.local/bin`,而桌面终端/systemd 上下文的 `PATH`(`/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/snap/bin`)**不含 `~/.local/bin`**。cloudgo 会话没事是因为 bashrc 里 `export PATH=~/.local/bin:$PATH`。
- **修法**:`ln -sf "$HOME/.local/bin/claude" /usr/local/bin/claude`(/usr/local/bin 在所有 PATH 里,全 shell 可见)。install.sh 装完 claude 后已补这行软链。
