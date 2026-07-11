# CLI-DEPLOY —— 极简终端版部署(无 Wave)

这一分支是 **纯终端** 版:客户端只用 **SSH**,不装 Wave、不配 widget。
进 Claude 就一条命令:`ssh -t cloud cloudgo`。

保留的:**会话韧性层**(断线/重启不丢会话)、**反向隧穿**(服务器反向操作客户本机)、**Claude 登录**、**cloudgo** 会话选单。
砍掉的:Wave GUI deck、noVNC 桌面(降级为 `CLOUD_DESKTOP=1` 可选)、看板、mosh/tailscale 硬依赖、手机 Moshi。

---

## 一图流

```
本机 (Mac/Linux/WSL)                          服务器 (Ubuntu/Debian)
  │                                              │
  │  ①本机公钥 ─────────────────────────────────▶ authorized_keys   (登录:本机→服务器)
  │                                              │
  │  ssh -t cloud cloudgo ─────────────────────▶ tmux 会话 · Claude Code
  │                                              │   (tmux+watchdog:断线/重启不丢)
  │  ◀───────────────────────────────── 服务器公钥  authorized_keys (反向:服务器→本机,--reverse)
```

登录方向和反向方向 **公钥交换方向相反**,别搞混:
- **登录**(`ssh+cloudgo`,本机→服务器):**本机公钥** 放到 **服务器**。
- **反向隧穿**(服务器→本机):**服务器公钥** 放到 **本机**。

---

## 服务器侧(一次)

```bash
git clone <this-repo> && cd remote-dev-station
CLOUD_MODEL=claude-opus-4-8[1m] ./install.sh          # 极简:装 claude+会话层+韧性+反向+cloudgo,不装 noVNC
# 想要 GUI 登录/服务器桌面:  CLOUD_DESKTOP=1 CLOUD_MODEL=... ./install.sh
```

装完就绪:cloudgo/watchdog 自愈、systemd 开机恢复、ufw+fail2ban、OOM 硬化。

### Claude 登录(无头,不需要 noVNC)
1. 服务器上 `cloudgo` 进一个会话 → 跑 `claude`;
2. 首次会打印一条 `https://…/oauth…` URL;
3. 在**你本机浏览器**打开 → 授权 → 把页面给的 **code 粘回服务器终端**。

> code 交换在服务器完成(密钥留在服务器),浏览器用哪台无所谓。
> 若某环境这条走不通,`CLOUD_DESKTOP=1` 重跑,改用 `claude-login-url` 的 GUI 登录页。

---

## 客户端侧(一次,在你本机)

把仓库里的 `cli/cloud-connect.sh` 拷到本机跑:

```bash
./cli/cloud-connect.sh <服务器IP> root            # 登录免密 + 进 cloudgo
./cli/cloud-connect.sh <服务器IP> root --reverse   # 顺带配反向隧穿的密钥
```

脚本幂等,做:①本机没密钥就生成 ②本机公钥推到服务器 ③写 `~/.ssh/config` 的 `cloud` 别名 ④`ssh -t cloud cloudgo` 进会话。
`--reverse` 再把**服务器公钥**取回放进本机 `authorized_keys`,并提示打开本机 SSH。

以后进 Claude:**`ssh -t cloud cloudgo`**(可自己存成 alias / 双击脚本)。

### 反向隧穿(服务器要能反向操作你本机)
`--reverse` 完成了「服务器公钥→本机」这一半。另一半是让**服务器知道你本机地址**:

1. 本机开 SSH(远程登录):
   - **Mac**:系统设置 → 通用 → 共享 → 远程登录(需手动授权)。
   - **Linux**:`sudo systemctl enable --now ssh`。
   - **Windows**:装 OpenSSH Server,或用 `windows/reverse-tunnel/`(反向 SSH 隧道,穿 NAT)。
2. 在**服务器** `~/.ssh/config` 建指向本机的别名(内网直连或走反向隧道端口):
   ```
   Host laptop
       HostName <本机IP或100.x tailnet IP>   # 走反向隧道则 HostName 127.0.0.1 + Port 2222
       User <本机用户名>
       IdentityFile ~/.ssh/id_ed25519
   ```
3. 之后服务器侧 `macget/macput/lapget/lapput`(bin/ 里)即可取送本机文件。

---

## 和全功能版的关系

| | 极简 CLI 版(本分支) | 全功能版(main) |
|---|---|---|
| 客户端 | SSH + `cloudgo`,零配置 | Wave GUI deck |
| noVNC 桌面 | 默认无(`CLOUD_DESKTOP=1` 可开) | 必装 |
| 看板/额度 | 无 | 有 |
| 登录 | 无头终端(默认) | noVNC GUI |
| 会话韧性 / 反向隧穿 | **保留** | 保留 |

两者共用同一套 install.sh;极简版靠默认值 + `CLOUD_DESKTOP` 开关裁剪,不是两份代码。
