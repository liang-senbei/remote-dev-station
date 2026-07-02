# Mac 反向通道 · `ssh mac` + macget/macput/macls/pullimg 搭建

> **选装。** 只在你想让**服务器上的 Claude 够到你自己的 Mac**（取文件 / 送文件 / 取截图）时才配。
> 不配也不影响会话系统、watchdog、手机审批那些主线——只是 `macget`/`macput`/`macls`/`pullimg`
> 这四条命令会连不上而已。

`install.sh` 已经把这四个脚本装进 `~/.local/bin/`（`install -m755 bin/* ~/.local/bin/`），
收尾也提示你「配 `~/.ssh/config` 的 `mac` 别名」，但没讲**别名指向哪、怎么让服务器够到 Mac**。
本文补这半：先说这通道干嘛的，再说两种搭法（Tailscale 直连 / 反向 SSH 隧道），最后验证。

---

## 1. 这通道是干嘛的

服务器在美国、Mac 在你家/公司，Mac 通常**在 NAT 后、没有公网 IP**——服务器主动去连 Mac 是连不到的。
反向通道就是解决「服务器侧的 Claude 怎么单向够到 Mac」：

- **取文件**：把 Mac 上的东西拉到服务器（`macget`）。
- **送文件**：把服务器上的产物推回 Mac（`macput`）。
- **看目录**：瞄一眼 Mac 某目录最近的文件（`macls`）。
- **取截图**：把你刚在 Wave 里粘贴/截的图抓到服务器给 Claude 看（`pullimg`）。

四个脚本**都只干一件事**：对一个叫 `mac` 的 SSH 目标跑 `scp` / `ssh`。所以搭通道 =
**让服务器上 `ssh mac` 能免密连到你的 Mac**。别名名字可改（下面讲 `MAC` 变量）。

### 四个工具到底跑了什么（读脚本得来，照着对）

| 命令 | 用法 | 实际执行 | 落点 |
|---|---|---|---|
| `macget` | `macget <Mac路径> [目标目录]` | `scp -q mac:<Mac路径> <目标目录>/` | 默认落到服务器 `~/inbox`，打印完整路径 |
| `macput` | `macput <本地文件> [Mac目标]` | `scp -q <本地文件> mac:<Mac目标>` | 默认 `Downloads/`（**相对 Mac 登录用户家目录** = `~/Downloads`）|
| `macls` | `macls [目录]` | `ssh mac "ls -lt <目录> \| head -20"` | 默认看 Mac 的 `~/Downloads`，打印最近 20 条 |
| `pullimg` | `pullimg` | `ssh mac` 找最新的 Wave 粘贴图 → `scp` 回来 | 落到服务器 `~/inbox`，打印路径 |

要点：

- **`pullimg` 挑的是这个路径**：`/var/folders/*/*/T/waveterm-*/waveterm_paste_*.png`。
  这是 **macOS 上 Wave 终端存粘贴图片的临时目录**——所以 `pullimg` 只在
  「Mac 用 Wave + 你刚往 Wave 里粘/截过图」时有东西可取；不用 Wave 就取不到（但 `macget` 照样能取任意文件）。
- **换别名**：四个脚本都认环境变量 `MAC`（默认 `mac`）。比如你的 Mac 别名叫 `air`，可以
  `MAC=air pullimg`、`MAC=air macget ...`，不必改脚本。
- **确保 `~/.local/bin` 在 `PATH`** 里，否则敲 `macget` 会 command not found。Ubuntu 默认
  `~/.profile` 会加，但 root 或精简系统可能没加——没有就往 `~/.bashrc` 加一行
  `export PATH="$HOME/.local/bin:$PATH"`。

---

## 2. 前置：Mac 先能被 SSH 进

1. **Mac 开「远程登录」(sshd)**：系统设置 → 通用 → 共享 → **远程登录** 打开。
   （这样 Mac 上就跑起了 22 端口的 sshd，是整条通道的落点。）
2. **服务器 → Mac 免密**：把**服务器**的公钥（`~/.ssh/id_ed25519.pub`，没有就
   `ssh-keygen -t ed25519` 先生成）加进 **Mac** 的 `~/.ssh/authorized_keys`。
   四个工具都非交互 `scp`/`ssh`，必须免密，否则会卡在要密码。
3. 记下 **Mac 的登录用户名**（`whoami`）——下面 `~/.ssh/config` 的 `User` 要填它。

> 🔒 下面配置里的 **Mac 用户名、Tailscale IP、隧道端口**都是**你自己的值**，别照抄示例里的占位符
> （`<mac-username>` / `100.x.y.z` / `2222`），也别把作者仓里的私有值当默认。

---

## 3. 搭法 A（推荐）：同一 Tailscale tailnet → 直连

如果 Mac 和服务器都进了**同一个 Tailscale tailnet**（这套体系本来就建议如此），Mac 有一个稳定的
`100.x.y.z` 内网 IP，服务器**直接连它就行，根本不用反向隧道**。这也是作者自己在用的方式。

服务器 `~/.ssh/config` 加一段：

```sshconfig
Host mac
    HostName 100.x.y.z          # Mac 的 Tailscale IP（Mac 上 tailscale ip -4 查）
    User <mac-username>          # Mac 登录用户名
    ServerAliveInterval 30
```

搞定。跳到 [§5 验证](#5-验证)。

> Mac 的 Tailscale IP 装完 Tailscale 就固定，不随重启变，所以直连很稳。**能用 Tailscale 就用这个**，
> 反向隧道那套（搭法 B）只在没法让两边同网时才需要。

---

## 4. 搭法 B（备选）：反向 SSH 隧道 + autossh

没有共同 tailnet、Mac 又在 NAT 后连不到时，用**反向隧道**：**Mac 主动**连服务器，
在服务器上开一个本地端口（如 `127.0.0.1:2222`）**回接 Mac 自己的 22**。之后服务器
`ssh -p 2222 <mac-username>@127.0.0.1` 就等于连到了 Mac。

### 4.1 Mac 侧：起隧道（autossh 常驻）

先装 autossh（Homebrew）：`brew install autossh`。手动验证一次隧道能起：

```bash
autossh -M 0 -N -T \
  -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
  -o ExitOnForwardFailure=yes -o StrictHostKeyChecking=accept-new \
  -i ~/.ssh/id_ed25519 \
  -R 2222:localhost:22 \
  <server-user>@<server-host>
```

- `-R 2222:localhost:22` = 在服务器开 `127.0.0.1:2222`，回接 Mac 本机 22。
- `-M 0` = 关掉 autossh 自带的监控端口，靠 `ServerAliveInterval` 判活（更省事）。
- `<server-user>@<server-host>` 这一跳是 **Mac 认证到服务器**，所以要把 **Mac 的公钥**加进
  **服务器**的 `~/.ssh/authorized_keys`（这是第 2 个方向，别和前置 §2 的服务器→Mac 搞混）。

**做成开机常驻**（LaunchAgent，睡醒/断网自动重连）——`~/Library/LaunchAgents/com.local.macreverse.plist`：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.local.macreverse</string>
  <key>ProgramArguments</key><array>
    <string>/opt/homebrew/bin/autossh</string>   <!-- Intel Mac 是 /usr/local/bin/autossh -->
    <string>-M</string><string>0</string>
    <string>-N</string><string>-T</string>
    <string>-o</string><string>ServerAliveInterval=30</string>
    <string>-o</string><string>ServerAliveCountMax=3</string>
    <string>-o</string><string>ExitOnForwardFailure=yes</string>
    <string>-o</string><string>StrictHostKeyChecking=accept-new</string>
    <string>-i</string><string>/Users/&lt;mac-username&gt;/.ssh/id_ed25519</string>
    <string>-R</string><string>2222:localhost:22</string>
    <string>&lt;server-user&gt;@&lt;server-host&gt;</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>AUTOSSH_GATETIME</key><string>0</string>   <!-- 首连很快就断也照样重试 -->
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict></plist>
```

加载：`launchctl load -w ~/Library/LaunchAgents/com.local.macreverse.plist`
（改了 plist 要先 `launchctl unload` 再 `load`）。

### 4.2 服务器侧：`mac` 别名指向隧道端口

服务器 `~/.ssh/config`：

```sshconfig
Host mac
    HostName 127.0.0.1
    Port 2222
    User <mac-username>
    IdentityFile ~/.ssh/id_ed25519
    StrictHostKeyChecking accept-new
    ServerAliveInterval 20
```

> **host key 坑**：`HostName` 是 `127.0.0.1`，容易和「服务器连自己 localhost」的 known_hosts 记录撞车，
> 报 host key changed。要么像上面用 `StrictHostKeyChecking accept-new`，要么加
> `HostKeyAlias mac` / 单独 `UserKnownHostsFile ~/.ssh/known_hosts_mac` 隔开。

### 4.3 服务器侧：让死隧道快点被回收（关键，否则重连很慢）

Mac 睡醒/断网重连时，服务器上那条**旧的死连接**还占着 `:2222`，autossh 会一直报
`remote port forwarding failed`，得干等旧连接超时（默认 ~180s）才恢复。让 sshd 主动探活、快点收尸：

```bash
# /etc/ssh/sshd_config.d/99-tunnel-keepalive.conf
ClientAliveInterval 30
ClientAliveCountMax 2
```

改完 `systemctl reload ssh`（Ubuntu 的服务名是 `ssh`）。

> 这坑和 Windows 笔电那套反向隧道是同一个，见 [`../windows/README.md`](../windows/README.md) §1，可对照。

---

## 5. 验证

按顺序跑，哪步断了就知道卡在哪：

```bash
# 只有搭法 B 需要：确认隧道端口在服务器上起来了
ss -tlnp | grep 2222          # 看到 127.0.0.1:2222 LISTEN = 隧道通

# 两种搭法都跑：别名 + 免密 + 可达 一次性验完
ssh mac echo ok               # 打印 ok = 成了；卡住要密码 = §2 免密没配好

# 四个工具挨个冒烟
macls                         # 列 Mac ~/Downloads 最近文件
macput /etc/hostname          # 推个小文件；去 Mac ~/Downloads 看在不在
macget ~/Downloads/hostname   # 再取回来，落到服务器 ~/inbox
# pullimg：先在 Mac 的 Wave 里粘一张图 / 截个图，再在服务器跑：
pullimg                       # 打印 ~/inbox/waveterm_paste_*.png
```

`ssh mac echo ok` 通、`macls` 有输出，通道就算搭好了。`pullimg` 取不到多半不是通道问题，
而是「Mac 没用 Wave」或「最近没往 Wave 粘过图」（见 §1 那条说明）。

---

## 6. 定位：通用 vs 私有

- **通用**（谁都能照搬）：这四个脚本本身 + 搭通道的**流程**。
- **私有**（换人必换、别入库）：`mac` 别名指向的 **Tailscale IP / 隧道端口 / Mac 用户名**——
  都是每个人自己的值，配的时候现填。这和仓库 [`../README.md`](../README.md) 附二、
  [`../DEPLOY.md`](../DEPLOY.md) 里「通用骨架 vs 个人配置」的红线一致：装通用脚本、填你自己的连法。
