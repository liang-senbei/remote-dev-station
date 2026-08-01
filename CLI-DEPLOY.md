# CLI-DEPLOY —— 极简终端版部署(无 Wave)

这一分支是 **纯终端** 版:客户端只用 **SSH**,不装 Wave、不配 widget。会话入口 `cloudgo`(fzf 选单)仍在——服务器侧 bash 函数,在终端里敲即用,纯 SSH 也能用。
进 Claude 两步:**`ssh cloud`** 连上 → 敲 **`claude`** 开始(和本地 Claude Code 一样;断线重连再敲 `claude` 接回同一会话)。

保留的:**会话韧性层**(断线/重启不丢会话,只是藏起来了)、**反向隧穿**(服务器反向操作客户本机)、**Claude 登录**(noVNC 登录桌面**必装**)。
砍掉的:Wave GUI deck、看板/额度(:8088,降级为 `CLOUD_DESKTOP=1` 可选)、mosh/tailscale 硬依赖、手机 Moshi。**保留** `cloudgo` 会话选单(服务器侧函数,纯 SSH 也能用),外加"cd 目录 + 敲 claude"这条更直接的路。

> **怎么做到"敲 claude 就像本地一样"**:服务器 bashrc 把 `claude` 包成一个函数 → 调 `cloud-enter`,
> 自动带 `IS_SANDBOX=1`(绕 root 沙盒)进/按 uuid 恢复**当前目录对应**的受管 tmux 会话(`/opt/workspace/foo` → `cc-foo`)。
> ssh 登录默认落在 `/opt/workspace`,`cd` 到不同项目目录敲 claude = 不同对话,和本地一样。真要原生 claude 带参:`command claude ...`。

---

## 一图流

```
本机 (Mac/Linux/WSL)                          服务器 (Ubuntu/Debian)
  │                                              │
  │  ①本机公钥 ─────────────────────────────────▶ authorized_keys   (登录:本机→服务器)
  │                                              │
  │  ssh cloud → cd <项目> → claude ──────────▶ tmux 会话 cc-<项目> · Claude Code
  │                                              │   (tmux+watchdog:断线/重启不丢,自动接回)
  │  ◀───────────────────────────────── 服务器公钥  authorized_keys (反向:服务器→本机,--reverse)
```

登录方向和反向方向 **公钥交换方向相反**,别搞混:
- **登录**(`ssh cloud`,本机→服务器):**本机公钥** 放到 **服务器**。
- **反向隧穿**(服务器→本机):**服务器公钥** 放到 **本机**。

---

## 服务器侧(一次)

```bash
git clone <this-repo> && cd remote-dev-station
CLOUD_MODEL=claude-opus-4-8[1m] ./install.sh          # 极简:装 claude+会话层+韧性+反向+cloudgo,不装 noVNC
# 想要 GUI 登录/服务器桌面:  CLOUD_DESKTOP=1 CLOUD_MODEL=... ./install.sh
```

装完就绪:cloudgo/watchdog 自愈、systemd 开机恢复、ufw+fail2ban、OOM 硬化。

### Claude 登录(noVNC 登录页,必装)
install.sh 已把 noVNC 桌面必装。让客户完成登录:
1. 服务器上跑 **`claude-login-url`** → 输出一条**临时公网登录页 URL**(cloudflared 把 noVNC :6080 开个公网口);
2. 把这条 URL 发给客户 → 客户在**自己浏览器**打开 → 看到服务器桌面的 Chrome → 在里面登录 Claude 账号完成授权;
3. 登录完 **`pkill cloudflared`** 把公网口拆掉。

> ⚠️ 这是无密码公网暴露,登录完务必 `pkill cloudflared`。

---

## 客户端侧(一次,在你本机)

把仓库里的 `cli/cloud-connect.sh` 拷到本机跑:

```bash
./cli/cloud-connect.sh <服务器IP> root            # 登录免密 + 进 claude
./cli/cloud-connect.sh <服务器IP> root --reverse   # 顺带配反向隧穿的密钥
```

脚本幂等,做:①本机没密钥就生成 ②本机公钥推到服务器 ③写 `~/.ssh/config` 的 `cloud` 别名(带 `RequestTTY yes`+`RemoteCommand cloud-enter`)④`ssh cloud` 进会话。
`--reverse` 再把**服务器公钥**取回放进本机 `authorized_keys`,并提示打开本机 SSH。

以后进 Claude:**`ssh cloud`** 连上 → 敲 **`claude`**(和本地一样;可把 `ssh cloud` 存成快捷方式)。
管理员要裸 shell:`ssh cloud -o RemoteCommand=none -t bash`。

### 反向隧穿(服务器要能反向操作你本机)

**这套没有 Tailscale/内网**,所以不能像内网那样服务器直接 ssh 你本机(你本机多半在 NAT 后、没公网 IP)。改用**反向 SSH 隧道**:让**你本机主动**向服务器建一条常驻连接,把服务器的 `127.0.0.1:2222` 转发到你本机的 SSH(22)。之后服务器 `ssh -p 2222 localhost` 就等于 ssh 进你本机。

一条命令的本质就是:`ssh -N -R 2222:localhost:22 root@<服务器IP>`。要**方便 + 持久**(断线重连、开机自启),按平台:

**除了"开 OpenSSH"外还要做的 3 件事:**
1. **本机开 SSH 服务端**(让服务器能 ssh 进来):
   - Mac:系统设置 → 通用 → 共享 → 远程登录(手动授权);
   - Linux:`sudo systemctl enable --now ssh`;
   - Windows:`Add-WindowsCapability -Online -Name OpenSSH.Server*` 并 `Start-Service sshd; Set-Service sshd -StartupType Automatic`。
2. **常驻反向隧道**(不是敲一次 `ssh -R` 就完,要它断线自动重连、开机自启):
   - **Windows**:跑 `cli/win-setup-tunnel.ps1`(管理员)——**一条命令自动搞定**:开 sshd、生成/复用密钥、建「登录自启 + 断线重连」的反向隧道计划任务(`RemoteDevTunnel`),跑完打印本机公钥给你加到服务器。**一把钥匙 = 登录 + 隧道**(不再单独搞隧道钥匙/NSSM)。实测通过。
   - **Mac/Linux**:`autossh -M 0 -N -R 2222:localhost:22 root@<服务器IP>` 包一个 launchd(Mac)/ systemd(Linux)常驻单元。
3. **服务器侧配好**(cli/win-setup-tunnel.ps1 跑完会提示,或手动):
   - 把本机隧道公钥加进服务器 `~/.ssh/authorized_keys`(否则隧道连不上);
   - `~/.ssh/config` 建 `laptop` 别名走隧道端口:
     ```
     Host laptop
         HostName 127.0.0.1
         Port 2222
         User <本机用户名>
         IdentityFile ~/.ssh/id_ed25519
     ```
   - sshd 开 keepalive(`ClientAliveInterval 30` / `ClientAliveCountMax 3`),让掉线的反向端口及时释放,不然 2222 会被占成僵尸口。

配好后服务器侧 `lapget/lapput/lapls`(Mac 用 `macget/macput`)即可取送本机文件;服务器上的 Claude 也会用(见部署的 `~/.claude/CLAUDE.md` 第 3 节)。

> `ssh laptop` 报 `Connection refused` = 你本机那头的隧道服务断了(关机/睡眠/换网),重启那个服务即可。

---

## 和全功能版的关系

| | 极简 CLI 版(本分支) | 全功能版(main) |
|---|---|---|
| 客户端 | `ssh cloud`,零配置;终端内 `cloudgo` 选单可用 | Wave GUI deck(侧栏「会话」=`cloudgo`) |
| noVNC 登录桌面 | **必装**(登录用) | 必装 |
| 看板/额度(:8088) | 默认无(`CLOUD_DESKTOP=1` 可开) | 有 |
| 登录 | noVNC 公网登录页(`claude-login-url`) | noVNC GUI |
| 会话韧性 / 反向隧穿 | **保留** | 保留 |

两者共用同一套 install.sh;极简版靠默认值 + `CLOUD_DESKTOP` 开关裁剪,不是两份代码。
