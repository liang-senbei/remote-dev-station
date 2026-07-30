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

### 自建 Wave widget 跑命令缺 controller:cmd → 点了黑屏空白终端
- **现象**:手搭的「会话/临时会话」widget,点开是**黑色空终端块、什么都不跑**;但在终端里直接 `cloudgo` 完全正常。
- **根因**:Wave 的 `term` widget 要**执行命令**必须有 `"controller": "cmd"`(配合 `view:"term"` + `cmd`)。只写 `view:term`+`cmd`、漏了 `controller` → Wave 当成空 shell、**不执行 cmd** → 黑屏。仓库 `wave-config/waveterm/widgets.json` 的 cc-go 有这键,**手搭 widget 时容易漏**。
- **修法**:widget meta 补 `"controller": "cmd"`。手搭前照抄仓库 cc-go 的 meta 结构:`{"view":"term","controller":"cmd","cmd":"...","cmd:interactive":true}`。别只凭记忆搭。

### 推文件到 Mac:scp/sftp 卡 → 改 ssh 管道 cat 推(2remote .36 实战)
- **现象**:往客户 Mac scp/sftp 传文件(widgets.json 等)卡住/超时。
- **根因**:某些 macOS + 多层 ssh(反向通道)下 sftp 子系统会卡。
- **修法**:走 ssh 字节流管道推:`ssh mac 'cat > ~/目标文件' < 本地文件`(二进制字节流,不坏编码、不依赖 sftp)。Windows 同理可用 `Set-Content`/base64。

### heredoc 里嵌 ssh 没加 -n 会吞掉 heredoc 的 stdin
- **现象**:`ssh host <<EOF ... ssh other cmd ... EOF` 这类脚本,内层 ssh 把 heredoc 剩余内容当自己的 stdin 吃掉 → 后续命令错乱。
- **根因**:ssh 默认从 stdin 读,heredoc 正在喂 stdin。
- **修法**:heredoc/管道上下文里的**非交互、不需 stdin 的 ssh 都加 `-n`**(`ssh -n host cmd`),让它不读 stdin。

### 客户 Mac 已有 ~/.ssh/config → 追加别名别覆盖
- **现象**:配 cloud/cloud-pub 别名时整份覆盖了客户已有的 ssh config。
- **修法**:**追加**(先 `grep -q 'Host cloud$'` 幂等判断,没有才 `>>` 追加),别 `>` 覆盖;客户已有的别名/配置要保留。

### 部署前先核对客户给的 IP(错 IP → 密码错 → fail2ban 封,越试越连不上)
- **现象**:ssh 客户服务器密码报错,多试几次后变 `Connection ... Not allowed at this time`(fail2ban 封了本机出口 IP)。
- **根因**:客户把服务器 IP 给错了(给成另一台),密码自然对不上;失败几次触发那台的 fail2ban 封禁 → 之后连对的机也可能受影响。
- **修法**:**部署前先核对 IP**(`ssh root@<ip> hostname` 能进+密码对再动手)。已被封:等封禁过期,或换出口/让对方 unban。给错 IP 时别硬试密码,先跟客户确认正确 IP。

### ★客户装 Clash/系统代理:noVNC/看板(:6080/:8088)超时但 SSH/会话正常(代理绕过列表缺 tailnet 100.*)
- **现象**:客户机上「服务器桌面(:6080)」「项目看板/额度(:8088)」网页 widget 打不开/一直转圈/timeout,但「会话(cloudgo)」这种 **ssh 类 widget 一直好**。极具迷惑性,像 tailscale 掉线又不完全是。
- **根因**:客户装了 **Clash/V2Ray 等系统代理**(127.0.0.1:7890)。Windows ProxyOverride(或系统代理)的**绕过列表放行了 `10./172./192.168.*` 私网段,却独缺 Tailscale 的 `100.*` 段** → 浏览器/Wave 网页块访问 tailnet IP(`100.x:6080/8088`)走代理 → 代理够不到 tailnet → 超时。而 **SSH 不走 HTTP 代理**,所以会话 widget 照常通 → 让人误以为"tailscale 好着呢"。
- **诊断**:PowerShell 对比——`(New-Object Net.Sockets.TcpClient).Connect('100.x.y.z',6080)` 直连(通)vs `Invoke-WebRequest http://100.x.y.z:6080`(走代理→timeout),一比就现形。
- **修法**:① 注册表 `HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings` 的 `ProxyOverride` 加 `100.*`;或 ② Clash 配置里加 `IP-CIDR,100.64.0.0/10,DIRECT`(tailnet 段直连不走代理)→ 实测 :6080 HTTP200。

### claude 子进程内存泄漏 → 整机 OOM → claude/noVNC 饿死(2remote .178 事故)
- **现象**:某会话(如大数据任务)claude 子进程内存涨到十几 G → 整机 OOM → claude 起不来 + noVNC 桌面栈被饿死。
- **修法**:`ps aux --sort=-%mem | head` 揪出跑飞进程,`kill` 释放内存,`systemctl restart novnc.service` 重建桌面栈。install.sh 的 `oom/harden.sh` 是兜底(限单会话),但极端泄漏仍可能击穿——留意大任务会话的内存。

### ★Windows 反向隧道一键脚本:SSH 会话里 Register-ScheduledTask 静默失效 + 临时进程被会话清理
- **现象**:经 ssh 远程在客户机跑一键脚本后,"隧道登录自启任务"没建上(`schtasks /query /tn RemoteDevTunnel` 找不到);手动 `Start-Process ssh -R` 起的隧道也一闪就没——服务器端 `ssh -v` 明写 `remote forward success for: listen 2223`,但服务器 `ss` 看不到监听、客户机上 ssh 进程也没了。极迷惑,像转发失败,其实转发是成功的。
- **根因**:① `Register-ScheduledTask` 在**非交互 SSH 会话上下文**里建"登录触发(Interactive)"任务会**静默失败**(不抛错);② 更关键——**Windows OpenSSH 命令会话里 `Start-Process` 起的子进程,随该 ssh 命令返回被会话 job 清理**,隧道进程一起被杀,所以端口只闪一下。机制本身没问题,是进程没常驻。
- **修法**:① 任务注册改 **`schtasks /create /tn RemoteDevTunnel /sc ONLOGON /rl LIMITED /f /tr "powershell ...-File <runner>"`**(比 Register-ScheduledTask 在各上下文都稳)+ 自检回显;② 隧道必须**由计划任务(独立会话)拉起**、别从 ssh 会话临时起 → 独立会话不被清、端口持久。实测:改后 `schtasks /run` → 服务器 2223 持久监听 → `ssh -p 2223 localhost` 成功回连进客户机。见 `cli/win-setup-tunnel.ps1`。

### root 下 claude 被拦 `--dangerously-skip-permissions cannot be used with root/sudo` —— 靠 IS_SANDBOX=1 绕过(与目录无关)
- **现象**:root 直接跑 `claude --dangerously-skip-permissions` 被拒;易误以为是"工作目录在 /root 有沙盒、/opt 没有"。
- **根因**:这是 **root 身份**的限制,**跟工作目录在 /root 还是 /opt/workspace 无关**(实测:`env -i` 干净环境下从 /opt/workspace 跑照样被拦)。
- **修法**:加环境变量 **`IS_SANDBOX=1`** 即放行。`cloud` / `cloud-enter` / bashrc 各函数都已带好,直接用它们、别裸敲 `claude`。

### 够不到客户笔电:tailnet 直连 和 反向隧道 是两条独立通道,别只凭一条超时就判"不可达"
- **现象**:`tailscale ping <笔电>` / `ssh <tailnet-100.x>` 超时,像笔电离线;但笔电其实还在,反向隧道 `ssh laptop-tunnel`(经服务器 127.0.0.1:2222)照样进得去。
- **根因**:笔电有**两条到服务器的通道**——① tailscale 直连(100.x);② 反向 SSH 隧道(服务器 :2222 → 笔电 :22)。两条**各自独立掉线**(用户关了 tailscale 或 tailnet 数据面僵死时直连断,反向隧道走公网仍活;反之亦然)。只测一条就判死 = 误判。
- **修法**:够不到笔电时**两条都试**:先 `ssh laptop-tunnel`(隧道),再 `ssh -i ~/.ssh/reverse_tunnel <user>@100.x`(直连);任一通即可操作,含中文路径的文件操作同理。(实例:2remote 出飞书 docx 全程走隧道完成,当时 tailnet 直连是挂的。)

### Windows 目标文件被占用(WPS/Office 打开中):Move-Item -Force 报错误导成"文件已存在"
- **现象**:后台投递器覆盖笔电上的 docx 时,`Move-Item -Force` 报 `Cannot create a file when that file already exists.`——看着像"目标已存在"的逻辑问题,其实不是。
- **根因**:目标 docx 正被 **WPS/Office/飞书打开**(目录里有 `~$xxx.docx` 锁文件),文件被占用;`Move-Item -Force` 把真因(占用)掩成了"已存在"。
- **修法**:① 换 `Copy-Item -Force`(会暴露真因 `The process cannot access the file ... because it is being used by another process.`)+ `Remove-Item`;② 覆盖前先检测目录里的 `~$` 锁文件 / 相关进程(wps/wpp/et/Feishu),被占用就**别硬覆盖**——把新版暂存成 `_新版待覆盖.docx`,等用户关掉文档再覆盖(顺带防覆盖掉用户在 WPS 里的手动改动)。

### 停 Windows 反向隧道:要杀 tunnel-run.ps1 的 while 循环,光杀 ssh 子进程会自己重连
- **现象**:清理测试用的反向隧道时,`Stop-Process` 杀掉 `ssh.exe`(ssh -R)后,几秒钟服务器上那个转发端口又冒出来了;反复杀反复回。以为没清干净,其实是被自动重连了。
- **根因**:隧道由「计划任务 → `tunnel-run.ps1` 里 `while($true){ ssh -R ...; sleep 5 }` 循环」维持。杀 ssh **子进程**时**循环(powershell)还活着**,5 秒后又把 ssh 拉起 → 端口回来。另外服务器侧那条 ssh -R 死后,sshd 子进程可能**不立即释放**转发监听(留半死 ESTAB / `CLOSE-WAIT` 的孤儿 listener)。
- **修法**:① 先 `schtasks /delete /tn RemoteDevTunnel /f`(去自启);② **杀循环本身**——`Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | ? { $_.CommandLine -match 'tunnel-run' } | % { Stop-Process -Id $_.ProcessId -Force }`,再杀 ssh -R;③ 服务器侧端口仍不释放时,`ss -ltnp | grep :<port>` 找到持有它的 sshd 子进程,**确认非命脉端口、非 master sshd** 后 `kill` 那个孤儿(它服务的反向连接客户端已死)。

### ★客户装隧道被 fail2ban 封:公钥没先上服务器 → 反复失败认证 → IP 被封 → 之后 Connection refused
- **现象**:客户机跑完一键脚本,隧道死活连不上;服务器上该端口不出现;客户手动 `ssh root@<服务器>` 报 **`Connection refused`(不是 timeout)**。别的客户机好好的,唯独这台。极迷惑,像脚本或网络坏了。
- **根因**:一键脚本会**立即起隧道循环**反复连服务器,但此刻**客户公钥还没加到服务器**(那步要操作方手动做)→ 每次 pubkey 认证失败 → 攒够几次 **fail2ban 封了客户 IP** → 之后连 22 口直接被拒。**即使你随后把公钥补上,客户仍进不来**(先被封了)。实测:Mac 首测就这么被封,解封后隧道几十秒自己重连成功。
- **修法**:① 服务器 `fail2ban-client status sshd` 看封禁列表;`journalctl -u ssh --since "35 min ago" | grep -oE 'from [0-9.]+' | sort | uniq -c | sort -rn` 找失败最多的那个客户 IP;② `fail2ban-client set sshd unbanip <客户IP>` 解封 → 公钥已授权的话,隧道几十秒内自己重连(launchd/计划任务的 KeepAlive)。③ **预防**:onboarding 时**先把客户公钥加到服务器、再让客户跑脚本**;或把客户 IP 加进 fail2ban `ignoreip`。④ 判断是 fail2ban 还是网络封 22:解封后客户仍 `refused` 才是网络层问题。

### VS Code Remote-SSH 反复「窗口意外终止(oom)」:exthost 膨胀撑爆 Node 堆,不是系统内存不够
- **现象**:VS Code 反复弹「窗口意外终止(原因:"oom",代码 "-536870904")」,点重载又过一阵再犯;但 `journalctl -u earlyoom`/`dmesg` 里**没有** OOM 击杀记录。
- **根因**:Remote-SSH 下真正跑插件的**扩展宿主(exthost)在服务器上**。两条常同时:①把整个 `~/src/workplace`(十几个仓)当一个多根工作区开,exthost 监视/索引所有文件,**实测单 exthost 2h 涨到 4.6G** 撞 Node 堆上限自崩;②断线重连留下的僵尸 exthost 按默认 **3h 宽限期**继续挂着(每个 0.5~2G),越堆越多。
- **修法**(全服务器侧,详见 [vscode-remote-oom.md](vscode-remote-oom.md)):① Machine settings 铺 `files.watcherExclude`/`search.exclude` 排除 node_modules/.venv/.git 等重目录(模板 [`../vscode-server/machine-settings.template.json`](../vscode-server/machine-settings.template.json));② `~/.vscode-server/server-env-setup` 设 `VSCODE_RECONNECTION_GRACE_TIME=480000`(3h→8min)缩短僵尸存活;③ **两者只在 vscode-server 完整重启时生效**——`F1 → Kill VS Code Server on Host` 重连,或服务器侧按 PID 杀(**别 `pkill -f vscode-server`,会匹配自己命令行自杀 exit 144**);④ 应急:`ps -eo pid,rss,args|grep type=extensionHost|sort -k2 -rn|head` 揪最肥的单杀。⑤ 治本:别一次开整个 workplace,只开当下项目文件夹。

### ★VS Code Remote-SSH 卡死/终端加载不出:国内客户↔海外服务器,链路劣化 VS Code 扛不住(2026-07-30 客户 86.53.110.95 实测,折腾最久的一个)
- **现象**:客户 VS Code Remote-SSH 能"连上"(窗口开出来),但**终端加载不出、cc 座舱奇慢、反复掉线重连**;偏偏客户用**命令行 `ssh` 进去 + `cloudgo` 却很流畅**。客户试遍了:关代理、给 tailnet 加绕过、改走公网 —— 还是卡。极其迷惑,像"服务器/插件坏了"。
- **根因**:客户 Mac 在国内、服务器在海外,**这条直连链路又慢又丢包**。服务器侧 `ss -tni '( sport = :22 )'` 实测:**RTT ~300ms、retrans 10-15% 丢包、拥塞窗口 cwnd 卡在 2**。`raw ssh` 是单向流、对抖动不敏感,能忍;但 **VS Code Remote-SSH 的 exthost 协议一次连接几十个来回**,300ms×丢包 → `resolveAuthority` 花 10 秒(Mac 端日志 `[resolveAuthority] waiting... 10655ms`)、反复 `[ExtensionHostConnection] The client has reconnected.`、终端/座舱起不来。**根子是网络质量,不是服务器(实测 load 0.0、内存充足)、不是插件、不是密码。**
- **诊断手法(直接上客户 Mac 查,别猜)**:反向通道 ssh 进 Mac →
  - `route -n get <服务器公网IP>` 看 `interface`:`utunX`(网关 `198.18.x`)=走进代理;`en0`=还是物理直连;
  - `ps -eo command | grep 'ssh .*cloud'` 看 VS Code 到底连的哪个 host;
  - `time ssh -o BatchMode=yes <公网host> true` 实测建连耗时(**烂直连实测 26 秒,进代理后 1.6 秒**);
  - `scutil --proxy` 看系统代理开没开、`ifconfig | grep utun` 看有没有代理的 TUN 接口。
- **修法(把 SSH 甩进代理的优化线路,下面 4 个条件必须同时满足,缺一个都白搭 —— 这就是折腾这么久的原因)**:
  1. **代理开 TUN 模式** —— 系统代理模式**抓不住 SSH**(ssh 不认 HTTP/SOCKS 系统代理,直接走物理网卡 en0),只有 TUN 在网络层能把 SSH 捕获进代理。判据:`route -n get <公网IP>` 的 interface 变成 `utunX`。⚠️ 有些客户端(Clash Verge 等)TUN 开关是绿的但**没装 service/helper 就不真捕获**(路由还在 en0),要点"安装服务"。
  2. **代理切全局模式(Global)** —— 规则模式下服务器公网 IP 常命中 DIRECT 规则(GEOIP/final DIRECT),被判直连绕开代理。实测:仅开 TUN 还不够,`route get` 仍是 en0;**一切全局,立刻变 utun13、建连 26s→1.6s**。
  3. **VS Code 连公网 IP,别连 tailnet** —— tailnet IP(`100.x`)被 **tailscale 自己的 utun 先截走**、直连服务器(恒 ~300ms),代理是网络层 TUN 也插不进去。**tailnet 这条无论如何加速不了**,只有公网 IP 代理才能提速。给客户的 `~/.ssh/config` 里放两条:`cloud`(公网)+ `cloud-tail`(tailnet),让他连 `cloud`。
  4. **踢掉旧连接** —— 若 ssh config 配了 `ControlMaster`(连接复用,高延迟本是好事),它会把 VS Code **钉死在"修好之前"建的那条烂连接上**,前 3 步做对了也没用。Mac 上 `ssh -O exit cloud; ssh -O exit cloud-tail; rm -f ~/.ssh/cm-*`,再 VS Code `F1→Kill VS Code Server on Host`/关窗重开。
- **保持不卡**:客户**别退全局模式**(退回规则模式,公网 IP 又被判直连、退回烂路);想用规则模式就在代理规则里给 `<公网IP>/32` 单加一条走节点。
- **一句话(教客户)**:国内连海外、VS Code Remote-SSH 卡 → 代理开「TUN + 全局」+ 连公网别连 tailnet + 重连一次。缺一不可。**纯命令行 ssh/mosh 不受此坑影响,要丝滑敲命令用那个。**

### 官方 Claude 插件被 Settings Sync 装成错平台(win32 装到 linux-x64 → "Unsupported platform")
- **现象**:VS Code Remote-SSH 连上后,官方 Claude 插件的会话选择器**永远转「Loading sessions…」**、会话 resume 不了、停在 Untitled。cc 座舱点「打开」也白搭(它调的就是这个瘫痪的官方插件)。
- **根因**:vscode-server 里装的 `anthropic.claude-code` 是**错平台构建**(实测装成了 `win32-arm64`:`resources/` 里只有 win 目录、没 linux 二进制)→ 插件每次处理请求报 `Error: Unsupported platform: linux-x64. No compatible Claude Code binary found.`(见 exthost 日志 `.../exthost*/Anthropic.claude-code/Claude VSCode.log`)。多半是**客户 Windows/Mac 端的 Settings Sync 把本机平台的扩展同步到了 linux 远端**。**实测 2/2 客户都中(ser1582018705 + 86.53.110.95)。**
- **修法**:用 vscode-server 的 code CLI 重装 linux-x64 版:
  ```bash
  CLI=$(ls ~/.vscode-server/bin/*/bin/code-server | head -1)
  "$CLI" --uninstall-extension anthropic.claude-code
  "$CLI" --install-extension anthropic.claude-code --force
  ```
  装完验:`resources/native-binary/claude` 应是 `ELF 64-bit ... x86-64`(`file` 看 / `--version` 能跑);`~/.vscode-server/extensions/extensions.json` 里 claude 的 `targetPlatform` 应是 `linux-x64`、目录带 `-linux-x64` 后缀。**客户端 reload window 才生效**(运行中的 exthost 还挂着旧的,不重载看不到变化)。
- **防复发**:告诉客户**在远端关掉扩展的 Settings Sync**,否则下次连上又被推回错平台。

### `~/.tmux.conf` 是 Windows 换行(CRLF)→ tmux 刷一堆"值无效"
- **现象**:`cloudgo`/起会话时刷 `~/.tmux.conf:N: bad value: off` / `unknown value: on` / `value is invalid: 0`(报错的行全是带值的行 1/3/6/7/8/9);会话其实能起(tmux 跳过坏行继续)。
- **根因**:`~/.tmux.conf` 是 **Windows CRLF 换行**(`file` 报 "with CRLF line terminators"),每行选项值尾多个 `\r` → tmux 把值读成 `off\r`/`on\r`/`latest\r`/`0\r`,判无效。多半是**部署经手了 Windows**(git autocrlf、Windows 编辑器、或经 Windows 中转拷贝)。
- **修法**:`tr -d '\r' < ~/.tmux.conf > /tmp/t && mv /tmp/t ~/.tmux.conf`(或 `dos2unix`)。**顺手扫其它部署文件**:`for f in ~/.bashrc ~/.local/bin/* /usr/local/bin/cloud-* ~/.claude/settings.json; do [ -f "$f" ] && file "$f" | grep -q CRLF && echo "CRLF: $f"; done`。⚠️ **配置文件 CRLF 只是刷警告不致命;但 SCRIPT(带 `#!` shebang)若 CRLF 会 `bad interpreter: no such file` 直接跑不了**——那是硬故障,必须一并清。(86.53.110.95 实测:只 `.tmux.conf` 中招,脚本都是 LF,万幸。)
