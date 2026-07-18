# 部署 / 连接踩坑记录

> 约定见工作区 CLAUDE.md：一坑一条，`### 标题` + **现象** / **根因** / **修法**。

### 旧笔电 laptop-3p8nh0iq 走 tailscale SSH 直连要用 reverse_tunnel 那把 key

**现象**：`ssh dfhzw@100.113.168.94` 报 `Permission denied (publickey,password,keyboard-interactive)`；但 `~/.ssh/config` 里只有走反向隧道的 `laptop-tunnel`（localhost:2222）条目。

**根因**：旧笔电上 authorized_keys 只收录了 `~/.ssh/reverse_tunnel` 对应的公钥，echo-j1 的默认 key 不在里面。反向隧道和 tailscale 直连用的是同一套账号（dfhzw）+ 同一把 key，只是入口不同。

**修法**：tailscale 直连时显式带 key：`ssh -i ~/.ssh/reverse_tunnel dfhzw@100.113.168.94 "<命令>"`。另注意两台 Windows 默认 shell 不同：**keuury（新笔电）是 PowerShell，旧笔电是 cmd**——发命令前先用一条无害命令探明 shell，别拿 PowerShell 语法喂 cmd（会报 "The filename, directory name, or volume label syntax is incorrect."）。

### SSH 发给 Windows 的命令里带中文路径会编码坏

**现象**：`ssh <win> 'dir E:\comfyui\模型'` 报 "The system cannot find the path specified."，但该目录明明存在；Windows 回传的中文输出也可能变成 `�Ҳ���...` 乱码。

**根因**：命令行经 ssh 传到 Windows 后按 OEM 代码页（GBK）解释，UTF-8 的中文字节被拆坏；回传方向同理。

**修法**：用 **base64 编码的 PowerShell** 彻底绕开：服务器端把脚本转成 UTF-16LE 再 base64，`powershell -NoProfile -EncodedCommand <b64>` 执行；脚本开头加 `[Console]::OutputEncoding=[Text.Encoding]::UTF8` 保证回传是 UTF-8。生成命令：
```bash
B64=$(python3 -c "import base64; print(base64.b64encode(open('x.ps1',encoding='utf-8').read().encode('utf-16-le')).decode())")
ssh -i ~/.ssh/reverse_tunnel dfhzw@100.113.168.94 "powershell -NoProfile -EncodedCommand $B64"
```
纯 ASCII 路径的简单命令不用这么折腾，直接 cmd 语法即可（输出里的中文一般能正常回传）。

### Windows sshd 会话一断，里面起的"后台"进程全被杀（大文件下载别这么挂）

**现象**：ssh 进 Windows 用 `Start-Process`/`start /b` 挂了个大文件 curl 下载，ssh 一退出文件就不再增长；用 `schtasks /Create + /Run` 挂一次性任务，也出现过 Last Result `0xC000013A`（进程被终止）。

**根因**：Windows OpenSSH 会话结束时会清理该会话 job 里的子进程树，"detach"并不真正脱离；schtasks 不带 /RU 创建的交互式任务也受用户会话状态影响。

**修法**：两个可靠姿势：① 服务器端 bash 循环 + `curl.exe -C -` 断点续传，每次 ssh 重连接着下（`for i in $(seq 1 40); do ssh ... "curl.exe -sL -C - -o <file> <url>" && break; sleep 3; done`，放后台跑）；② 真要驻留任务用 `schtasks`+`cmd /c ... > log 2>&1` 落日志排查。另注意 schtasks 任务的 cmd 壳没退干净时任务显示 Running，此时 `/Run` 会静默空转——先确认 Status 是 Ready。

### 秋叶整合包（ComfyUI-aki-v3）的 custom_nodes 有两层，别装错

**现象**：把自定义节点装到 `E:\comfyui\ComfyUI-aki-v3\custom_nodes\`，重启 ComfyUI 后日志 import 列表里没有它。

**根因**：aki v3 的真实 ComfyUI 应用在 `ComfyUI-aki-v3\ComfyUI\` 子目录下，生效的是 `ComfyUI-aki-v3\ComfyUI\custom_nodes\`（同理 input/output/models 都在 `ComfyUI\` 里，`extra_model_paths.yaml` 除外）；根目录那个同名目录不会被加载。

**修法**：装节点/放素材一律用 `E:\comfyui\ComfyUI-aki-v3\ComfyUI\custom_nodes\`、`...\ComfyUI\input\`；装完看启动日志 "Import times for custom nodes" 里有没有它来确认。

### unattended-upgrades 自动升级 systemd 后不重启 → 沙箱服务全崩(226/NAMESPACE)→ DNS 死、chrome 打不开

**现象**:客户机跑了一阵后突然"网页全进不去"(chrome 打不开任何站),但 ssh/tailscale 能连、负载/内存/磁盘都正常、无 OOM。`getent hosts <域名>` 失败(Could not resolve host),而 `nslookup <域名> 8.8.8.8` 直接问公共 DNS 却秒解析。

**根因**:Ubuntu 自带的 `unattended-upgrades`(自动安全更新)后台把 **systemd 升级了**(如 `255.4-1ubuntu8.4`→`8.16`)。systemd 是 PID1,边运行边换二进制后,**新起的带沙箱(`PrivateDevices=`)单元建 mount namespace 失败**,报 `status=226/NAMESPACE — Failed to set up mount namespacing: /dev: Invalid argument`。一整批服务同时崩:`systemd-resolved`、`polkit`、`systemd-timesyncd`、`accounts-daemon`、`systemd-networkd-wait-online`。`resolved` 死 → `/etc/resolv.conf` 指的 stub `127.0.0.53` 没进程接听 → 系统所有域名解析失败 → chrome 打不开任何网页。**注意甄别**:`systemctl daemon-reexec` 和 `mount --make-rshared /` 都救不回来(传播属性本就 shared、KVM 全虚拟环境本身支持 namespace)。

**修法**:**重启机器**是唯一可靠的彻底修法——PID1 全新拉起、namespace 机制对齐,那批服务全部 `active`、`systemctl --failed` 归零。诊断三板斧:`systemctl --failed`(确认是"一批沙箱服务全崩"而非单个)、`grep " upgrade .*systemd" /var/log/dpkg.log`(证实刚升过 systemd)、`journalctl -xeu systemd-resolved`(看 226/NAMESPACE)。
- **不重启的止血**(客户在用、不能马上重启时):`rm /etc/resolv.conf; printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf`,绕过死掉的 stub,DNS 立即恢复;重启后 Tailscale/resolved 会自然接管回标准配置(装了 Tailscale 的机器重启后 resolv.conf 由它托管指向 MagicDNS `100.100.100.100`,公网+tailnet 名都能解)。chrome 那个错误页要 `pgrep -x chrome` 判存活后重拉才会重新解析(**别用 `pkill -f chrome...`,pattern 会匹配到自己的 ssh 命令行,自杀**)。
- **防复发**(三选一,写进部署模板):① 禁用 `unattended-upgrades`(`systemctl disable --now unattended-upgrades apt-daily-upgrade.timer`),更新手动可控+配套重启(顺带解掉装机时它抢 apt 锁那个坑);② 保留但设 `Unattended-Upgrade::Automatic-Reboot "true"` + 凌晨时段自愈;③ `apt-mark hold systemd*` 只冻结 systemd 一类包。

### VSCode 扩展(vsix)装了新版但功能没生效——窗口还在跑内存里的旧版

**现象**:cc-cockpit 0.4.13 的「cloudgo 新会话自动软链进官方插件」功能上线后,vsix 已解进 `~/.vscode-server/extensions/`、extensions.json 也更新了,但 cloudgo 新建的 cc 一个都没被自动软链(手动链的都在),一度误判为功能有 bug。

**根因**:VSCode 扩展宿主把扩展代码加载进内存后**不会因为磁盘上换了新版而热更新**;已开着的窗口(含 Remote-SSH 的 remote exthost)继续跑旧版直到 Reload。exthost 日志证实:磁盘 0.4.13,窗口实际加载 `cc-cockpit-0.4.11`。数据链路(cc-agents --json 的 jsonl 字段)完全正常,代码就是没被执行。

**修法**:任何 vsix 安装/滚更后,**必须让用户 Reload Window(或重开窗口)**,并用日志验证实际加载版本:`grep -o "cc-cockpit-[0-9.]*" ~/.vscode-server/data/logs/<最新时间戳>/exthost*/remoteexthost.log`。应急补链(等不到 reload 时):`ln -s ~/.claude/projects/<enc-agent-dir>/<uuid>.jsonl ~/.claude/projects/-opt-workspace/<uuid>.jsonl`,尾部 64KB 无 `"customTitle"` 则追加一行 `{"type":"custom-title","sessionId":"<uuid>","customTitle":"<cc名>"}`。

### 往 Windows 笔电推文件：别把文件字节塞进 `-EncodedCommand`，会撞 cmd 8191 命令行上限

**现象**：想把文件写到笔电的中文路径（如 `C:\Users\dfhzw\Desktop\业务\ip`），把文件内容 base64 后整个塞进一条 `ssh laptop "powershell -NoProfile -EncodedCommand <大base64>"` 里一把梭。命令**静默失败 / 返回空**，PowerShell 没报错也没输出。同样写法用小 payload（只查目录、只做逻辑）却完全正常。旧笔电 LAPTOP-3P8NH0IQ（`-i ~/.ssh/reverse_tunnel`，默认壳 cmd）尤其必崩。

**根因**：旧笔电 sshd 默认登录壳是 **cmd.exe，命令行硬上限 8191 字符**。`-EncodedCommand` 里嵌了文件字节的 base64 轻松超（实测一个 2.9KB 的 txt，编码后整条命令 18KB）→ cmd 把命令行**截断** → powershell 收到半截非法 base64 → `FromBase64String` 抛异常 / 无输出。keuury 默认壳是 PowerShell，上限高些（~32KB）但一样有界，大文件照样会中招。

**修法**：**命令行只放逻辑，不放数据**。① `scp` 把文件传到 home 的 ASCII 临时名（scp 走 sftp 子系统，不受 cmd 命令行长度限制，且命令里不含中文路径，绕开中文 GBK 坏那个坑）：`scp -i ~/.ssh/reverse_tunnel a.txt dfhzw@100.113.168.94:a.txt`。② 再来一条**短**的 `-EncodedCommand`（UTF-16LE base64，只有 `New-Item -Force $中文dir` + `Move-Item` + 校验，~1.7KB）把文件挪进中文目录。校验想读回中文就让 PS 端 `[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($out))` 再本地 `base64 -d`。实测：18KB 一把梭失败；scp + 1760 字符 move 命令一次成。经验值：`-EncodedCommand` 别超 ~2KB。

### 装完 claude 终端里却敲不到——root 的 PATH 默认不含 ~/.local/bin

**现象**:install.sh 全绿、`~/.local/bin/claude` 存在且能全路径执行,但客户开终端(ssh/VNC)敲 `claude` 报 command not found,`cloudgo` 也因此起不了会话。安装器其实打过"⚠ Setup notes"警告,滚屏里极易被忽略。

**根因**:Ubuntu **root** 账号的 `~/.profile` 是极简版(只 source .bashrc),**不带**普通用户模板里那段"存在 ~/.local/bin 就加进 PATH"的逻辑;claude native 装到 ~/.local/bin 后仅打印提示不强制接线。cloud-watchdog 不受影响(unit 里显式写了 PATH),所以自愈正常、交互坏——更具迷惑性。

**修法**:`~/.bashrc` 首行插 `export PATH="$HOME/.local/bin:$PATH"`(`.profile` 也补一份,幂等 grep 判重)。已固化进 install.sh [4/7](2026-07-18);存量机器验一句:`bash -lc 'command -v claude'` 有输出才算通。

### VNC 桌面里的终端只有光秃秃 "#" 提示符,claude/cloudgo 全敲不到

**现象**:TigerVNC 桌面打开 xfce4-terminal,提示符是孤零零的 `# `,回车只出新 `#`;`cd ~` 能走但 claude/cloudgo 报 command not found。ssh 进来却一切正常。

**根因**:VNC 由 systemd 单元拉起时环境里没有 `SHELL`,xfce 会话默认落 `SHELL=/bin/sh` → xfce4-terminal 开的是 **dash**:bare `#` 提示符、不读 .bashrc,PATH/函数全没有。root 的 /etc/passwd 登录 shell 是 bash 没问题,所以只有"桌面里的终端"坏,极具迷惑性。

**修法**:tigervnc@.service 的 [Service] 加两行后 `daemon-reload && systemctl restart tigervnc@<display>`(会重启桌面,提醒用户重连):
```
Environment=SHELL=/bin/bash
Environment=PATH=/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
```
做一键装机时此单元模板必须自带这两行(cust86 实战,2026-07-18)。

### cloudgo 一敲就报 "invalid info style (expected: default / inline / hidden)"

**现象**:cust86(Ubuntu 22.04)上 `cloudgo` 直接报此错退出,选择器出不来;echo-j1(24.04)同配置正常。

**根因**:`bashrc-shell-enhance.sh` 的 `FZF_DEFAULT_OPTS` 用了 `--info=inline-right`、`separator/label` 配色等 **fzf 0.42+ 语法**;22.04 的 apt 只有 **fzf 0.29**,解析选项即死。报错来自 fzf 而不是 cloudgo 本身,且 `command -v fzf` 有输出,老的"fzf 缺失"检查抓不到它。

**修法**:fzf 低于 0.42 就装官方静态版进 `~/.local/bin`(PATH 前置顶掉 /usr/bin 的):GitHub junegunn/fzf 最新 release 按架构取 `linux_amd64/arm64` tar.gz。已固化进 install.sh 尾段(版本门槛 sort -V 判断,2026-07-18)。验证:`bash -ic 'printf x | fzf --filter=x'` 输出 x = 全部选项被接受。
