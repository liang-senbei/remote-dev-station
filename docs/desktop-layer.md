# 服务器图形桌面层(TigerVNC)· 安装 runbook

> **这是必装层,`install.sh` 已经把它装好了。** 本文是「它到底装了什么 / 怎么排障 / 怎么手工重建」的说明,
> 正常部署**不用照着敲**——跑完 `./install.sh` 桌面就已经在 `:5901` 上跑着了。
> (历史:此层曾是 noVNC + Xvfb + x11vnc + websockify 的 `:6080` tailnet-only 方案,已于 2026-08 全面换成 TigerVNC。
>  换的原因见 §0。仓库里不再有 `novnc.service` / `novnc-start.sh`。)

装完你会得到:一个跑在服务器上的**图形桌面**,客户用任意 VNC 客户端连 `<服务器公网IP>:5901` 就能看到、能点,里面 **Chrome 已经停在 `claude.com`**。

**头号用途 = 让客户完成 Claude 登录**:登录走**服务器自己的干净 IP**(国内 IP 直连 claude.com 登录常被拦),凭据落在服务器上,之后会话免登。其次才是在服务器上跑 GUI 程序(如 AdsPower 指纹浏览器)。

---

## 0. 为什么从 noVNC 换成 TigerVNC

| | 旧:noVNC(:6080) | 新:TigerVNC(:5901) |
|---|---|---|
| 组件 | Xvfb + xfce + x11vnc + websockify,四个进程串起来 | `vncserver` 一个命令全包 |
| 客户怎么连 | 浏览器开 `:6080/vnc.html` | 任意 VNC 客户端连 `:5901` |
| 网络边界 | **只在 tailnet 内可达** | **公网可达**,靠 VncAuth 密码挡 |
| 致命问题 | **客户 Tailscale 还没配好时根本够不着** —— 而客户第一次要用桌面,恰恰就是为了登录 Claude、还没走到配 Tailscale 那步 | 开箱即连,不依赖 tailnet |

就是最后那行把 noVNC 判了死刑:登录桌面是**交付链条的第一环**,不能依赖一个"要先登录才配得好"的前置条件。

---

## 1. install.sh 装了什么

对应 `install.sh` 的 `[+] TigerVNC 图形桌面` 段:

```bash
# ① 包(tigervnc 三件套 + xfce + 中文字体)
apt-get install -y tigervnc-standalone-server tigervnc-common tigervnc-tools \
                   xfce4 xfce4-terminal dbus-x11 fonts-noto-cjk
# ② Chrome(不在 apt 默认源,单独装;登录页要用)
apt-get install -y /tmp/chrome.deb    # google-chrome-stable_current_amd64.deb

# ③ ~/.vnc/ 三件套(仓库模板,已有则不覆盖)
cp     vnc/config   ~/.vnc/config     # geometry/depth/localhost=no/SecurityTypes=VncAuth
install -m755 vnc/xstartup ~/.vnc/xstartup   # 开 xfce + 把 Chrome 停在 claude.com
vncpasswd -f > ~/.vnc/passwd          # 随机 8 位密码,装完打印在屏幕上

# ④ 单元 + 防火墙
cp systemd/cloud-vnc.service /etc/systemd/system/ && systemctl enable --now cloud-vnc.service
ufw allow 5901/tcp comment 'tigervnc public'
```

**ARM64 注意**:那个 Chrome `.deb` 是 amd64,ARM 机器装不上。改 `apt-get install -y chromium`,`~/.vnc/xstartup` 里的 `command -v` 链已经会自动挑到 `chromium`,不用改脚本。

---

## 2. `cloud-vnc.service` 里那两行不能少

单元文件见 [`systemd/cloud-vnc.service`](../systemd/cloud-vnc.service)。核心是 `ExecStart=/usr/bin/vncserver :1 -fg`(`-fg` 前台跑,systemd 才管得住),外加这两行:

```ini
Environment=SHELL=/bin/bash
Environment=PATH=/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
```

**缺了会踩一个极具迷惑性的坑**:VNC 桌面里打开终端,提示符是孤零零一个 `# `,回车只出新 `#`,`claude`/`cloudgo` 全都 command not found —— 但 ssh 进同一台机器却一切正常。

根因:systemd 拉起时环境里没有 `SHELL`,xfce 会话默认落 `SHELL=/bin/sh` → xfce4-terminal 开的是 **dash**,不读 `.bashrc`,PATH 和 shell 函数全都没有。root 在 `/etc/passwd` 里的登录 shell 是 bash,所以只有"桌面里的终端"坏。

改完要 `systemctl daemon-reload && systemctl restart cloud-vnc`(会重启桌面,提前告知客户重连)。

---

## 3. 安全边界(必读)

**`:5901` 是开在公网上的**,和旧的 tailnet-only 方案完全不同,边界靠这几条:

- **VncAuth 密码是唯一屏障**:`~/.vnc/passwd`(600)。`install.sh` 无则随机生成 8 位并打印在安装日志里 —— **那行必须记下来发给客户**,已有则沿用不动。忘了就 `vncpasswd` 重设 + `systemctl restart cloud-vnc`。
- **VNC 协议本身不加密**:VncAuth 是挑战-应答(密码不明文过网),但**桌面画面和键盘输入是明文的**。客户在这个桌面里登录 Claude = 密码明文过公网。要更稳就让客户改用 SSH 隧道(`ssh -L 5901:localhost:5901 root@<IP>` 后连 `localhost:5901`),并把 `~/.vnc/config` 的 `localhost=no` 改回 `localhost=yes` + `ufw delete allow 5901/tcp`。**这是有意的取舍**:优先保证"客户零配置就能登录",登录是一次性动作,之后日常走 SSH/tailnet。
- **登录完可以关掉**:桌面主要是为登录而存在。客户登录完、日常只用命令行的话,`systemctl disable --now cloud-vnc` + `ufw delete allow 5901/tcp` 把面收掉最干净,要用再起。
- **Chrome `--no-sandbox`**:root 跑 Chrome 的已知要求,不是这里新引入的风险。

> 一句话:**这个桌面的安全 = 那个 VNC 密码。** 密码要随机、要私下发给客户、别复用。

---

## 4. 验证 / 排障

```bash
systemctl is-active cloud-vnc.service      # active
ss -ltnp | grep 5901                       # 应有 0.0.0.0:5901 (Xtigervnc)
ls -l ~/.vnc/*.log                         # 会话日志:<主机名>:1.log
```

常见情况:

- **连上是黑屏 / 灰屏没有桌面** → 看 `~/.vnc/<主机名>:1.log`,多半是 `startxfce4` 没起来(xfce4 包没装全)或 `~/.vnc/xstartup` 没有可执行位(`chmod +x`)。
- **桌面里终端只有光秃秃 `#`** → 就是 §2 那个坑,单元缺 `SHELL`/`PATH`。
- **Chrome 没起来** → 看 `/var/log/chrome-vnc.log`;上次非正常退出留了 `Singleton*` 锁的话 `xstartup` 开头那行 `rm -f` 会清掉,清不掉就手动删 `/root/.chrome-vnc/Singleton*`。
- **桌面里中文是方块** → 补 `apt-get install -y fonts-noto-cjk fonts-wqy-zenhei` 再重启服务。
- **改了 `~/.vnc/config` 不生效** → 那是 `vncserver` 启动时读的,必须 `systemctl restart cloud-vnc`。

> 🖥️ **别和 `Xvfb :99` 混**:服务器上另有一个 `Xvfb :99` 是给 `chrome-devtools-mcp` 用的**独立显示**,和本层的 `:1` 桌面无关、互不影响。

---

## 5. 顺带:`cloud-dashboards.service`(:8088 项目看板,选装层)

看板**是**选装的(`CLOUD_DESKTOP=1 ./install.sh` 才装),别和必装的桌面层混了。它只在 `:8088` 上用 `python3 -m http.server` **静态服务 `/root/inbox/dashboards` 这一个目录**:

```bash
cp systemd/cloud-dashboards.service /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now cloud-dashboards.service
```

`ExecStart` 指向 `bin/cloud-dashboards.sh`(wrapper 内 `tailscale ip -4` 自动绑本机 tailnet IP,**无需手改 IP**)。安全边界是老一套:**只绑 tailnet IP、tailnet 内不鉴权**,别给 `:8088` 开公网防火墙。

它和桌面层没有依赖关系,分开装、按需装即可。
