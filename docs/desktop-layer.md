# 服务器图形桌面层(noVNC)· 安装 runbook

> **这是选装层,`install.sh` 核心层不装它。** 核心只装会话系统 / systemd 自愈 / tmux / 防火墙那套(见 [README](../README.md) §🚀);
> 图形桌面(Xvfb + xfce + x11vnc + noVNC + Chrome)和它的 `novnc.service` 都得**照本文单独装**。
> `bash cloud_infra_check.sh` 里 `novnc.service` 显示 `⏭`(可选层未装)就是因为这个,属正常。

装完你会得到:一个跑在服务器上的**图形桌面**,从**电脑/手机浏览器**(或 Wave 侧栏「服务器桌面」widget)打开 `http://<服务器Tailscale-IP>:6080/vnc.html` 就能看到、能点。用途两个:① 在服务器上开 GUI 程序(如 **AdsPower** 指纹浏览器);② 桌面里预先开好一个 Chrome 停在 **claude.ai/code**(网页版 Claude Code,富文本输入 + 贴图,从服务器干净 IP 登录、不碰你 Mac)。

---

## 0. 装之前先确认

- **要不要装**:只用命令行跑 Claude Code 的话,**这层不用装**。只有你需要"服务器上的图形界面"(AdsPower / 网页版 Claude / 任何 GUI)才装。
- **架构**:x86_64(amd64)服务器最省心。**ARM64 服务器有坑**——Google 没出官方 arm64 的 `google-chrome`,得改用 `chromium` 并顺手改一下 `novnc-start.sh`(见 §1 末尾的 ⚠️)。
- **跨太平洋看图形桌面天生卡**(物理限制,非 bug):打字(mosh 会话)扛得住,但 VNC 画面刷新会顿。能用命令行解决的别开桌面。

---

## 1. 装依赖(apt + Chrome)

图形桌面那几样在标准 apt 源里,一条装齐;**Chrome 不在 apt 默认源**,单独装。

```bash
# ① 桌面 + VNC + noVNC(标准源,一条装齐)
apt-get update
apt-get install -y xvfb xfce4 x11vnc novnc websockify

# 可选但强烈建议:dbus + 中文字体(不装 dbus 部分 xfce 组件会报 dbus 错;不装字体 Chrome/AdsPower 里中文是豆腐块)
apt-get install -y dbus-x11 fonts-noto-cjk fonts-wqy-zenhei
```

这几个包分别提供 `novnc-start.sh` 用到的:`Xvfb`、`xfwm4`/`xfdesktop`/`xfce4-panel`(都在 `xfce4` 元包里)、`x11vnc`、`/usr/share/novnc/vnc.html`(`novnc` 包)、`/usr/bin/websockify`(`websockify` 包)。

```bash
# ② Google Chrome(单独装;下面这个 .deb 会自动把 Google apt 源写进
#    /etc/apt/sources.list.d/,以后 apt upgrade 就跟着一起更新,不用手工加源)
wget -O /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
apt-get install -y /tmp/chrome.deb
```

> ⚠️ **ARM64 服务器**:上面这个 .deb 是 amd64,装不上。改装 `apt-get install -y chromium`(或 `chromium-browser`),然后把 `bin/novnc-start.sh` 第 20 行的 `google-chrome` 换成 `chromium`(其余 `--no-sandbox` 等参数照旧)。本文其余步骤不变。

验证依赖到位:

```bash
which Xvfb x11vnc websockify google-chrome xfce4-panel   # 五个都能打印路径 = 齐了
ls /usr/share/novnc/vnc.html                              # noVNC 网页资源在 = 齐了
```

---

## 2. 部署并 enable `novnc.service`

`novnc.service` 的 `ExecStart` 指向 **`/usr/local/bin/novnc-start.sh`**。注意一个坑:核心 `install.sh` 的 `install -m755 bin/*` 会把 `novnc-start.sh` 装进 **`~/.local/bin/`**(不是 `/usr/local/bin/`),而 systemd 单元跑的是 root 的 `/usr/local/bin/` 那份——所以**必须再拷一份到 `/usr/local/bin/`**,单元文件本身核心也没部署,一并放好。

```bash
cd /path/to/remote-dev-station        # 你 clone 仓库的目录(本机是 /root/cloud-setup)

# ① 脚本拷到单元指定的路径(和 cloud-boot.sh 一个套路)
install -m755 bin/novnc-start.sh /usr/local/bin/

# ② 部署单元 + 开机自启 + 立即拉起
cp systemd/novnc.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now novnc.service
```

`novnc-start.sh` 起来后会:清掉旧的 Xvfb/x11vnc/websockify → 起 `Xvfb :1`(1600x900)→ 起 xfce(xfwm4 + xfdesktop + xfce4-panel)→ **自动开 Chrome 到 `https://claude.ai/code`**(用独立 profile `/root/.chrome-vnc`,登录态持久保留)→ 起 `x11vnc`(只绑 localhost)→ 起 `websockify`(绑本机 Tailscale IP:6080)。

**健壮性设计**:脚本最后 `wait` 在 Xvfb 进程上——Xvfb 一死脚本就退出,`Restart=on-failure` 让 systemd 把**整套**重拉。这修掉了旧版"Xvfb 死了、websockify 还活着 = 打开 :6080 是个没桌面的空壳"的毛病。

验证:

```bash
systemctl is-active novnc.service          # active
ss -ltnp | grep 6080                       # 应显示  100.x.y.z:6080 (你的 Tailscale IP),不是 0.0.0.0:6080
```

---

## 3. 安全边界(必读)

这层**在 tailnet 内不做任何鉴权**——谁在你的 Tailscale 网里,谁打开 `:6080` 就能操作这个桌面。安全完全靠"只有 tailnet 内可达"这一层兜底,所以边界务必守住:

- **websockify 只绑本机 Tailscale IP**:脚本里
  ```bash
  TS_IP="$(tailscale ip -4 2>/dev/null | head -1)"; TS_IP="${TS_IP:-127.0.0.1}"
  websockify --web=/usr/share/novnc "${TS_IP}:6080" localhost:5900 ...
  ```
  自动取本机 Tailscale IP 来绑(**不写死、无需手改**),取不到就回落 `127.0.0.1`——即 Tailscale 没起时只有本机能连,**失败朝安全的一侧倒**(fail-closed),不会误绑 `0.0.0.0` 把桌面暴露到公网。
- **x11vnc 无密码 + 只听 localhost**:`x11vnc -nopw -localhost -rfbport 5900`——VNC 服务本身没密码(`-nopw`),但只绑 `127.0.0.1:5900`,公网/tailnet 都直连不到 5900;**唯一入口是 websockify 那个 tailnet-only 的 :6080**。所以真正的信任边界 = **是否在你的 tailnet 里**。
- **别给 :6080 开公网防火墙**:核心 `install.sh` 的 ufw 基线已经 `ufw allow in on tailscale0`(整个 tailscale 接口放行),`:6080` 走 tailnet 天然通,**不需要**也**千万别** `ufw allow 6080/tcp`——那会把无密码桌面开到公网上,等于门户大开。
- **Chrome `--no-sandbox`**:脚本以 root 跑 Chrome,必须带 `--no-sandbox` 才起得来(这是 root 运行的已知要求,不是这里新引入的风险);配合 tailnet-only 的访问边界,可接受。

> 一句话:**这个桌面的安全 = 你 tailnet 的安全。** 保证 tailnet 成员可信、别把 6080 漏到公网,就够;反之别装。

---

## 4. 和 Wave 侧栏「服务器桌面」widget + Chrome 自动登 claude.ai/code 怎么串起来

三块拼在一起就是"点一下侧栏图标 → 看到服务器桌面、Chrome 已经停在网页版 Claude Code":

1. **服务器侧(本层)**:`novnc-start.sh` 开机把桌面 + Chrome→claude.ai/code 都摆好,`:6080/vnc.html` 常驻可连。
2. **Wave 侧栏 widget**:Wave 客户端配置 `wave-config/waveterm/widgets.json` 里有个 `server-vnc` 部件(🟢 图标 `desktop`、标签「服务器桌面」),它就是个 web 视图,URL 写死指向:
   ```
   http://100.109.254.125:6080/vnc.html?autoconnect=true&resize=scale
   ```
   点它 = 在 Wave 里内嵌打开这个网页 → `autoconnect` 自动连上桌面 → `resize=scale` 自适应缩放。
3. **落地即用**:连上看到的桌面里,Chrome 已经开在 `https://claude.ai/code`、且用持久 profile(`/root/.chrome-vnc`)保留登录态——所以你能直接用**网页版 Claude Code**(富文本 + 贴图),登录 IP 是服务器的干净 IP、和你 Mac 环境完全隔离。

> ⚠️ **客户必改**:`widgets.json`(`waveterm` 和 `waveterm-dev` 两份)里那个 `100.109.254.125` 是**作者的** Tailscale IP,换成**你自己服务器的** Tailscale IP,否则点了会连到作者的机器。这条已在 [DEPLOY.md](../DEPLOY.md) 阶段二「必改清单」里列了。服务器侧 `novnc-start.sh` 不用改(它自动取本机 IP)。
> 不用 Wave 也行:任何浏览器直接开 `http://<你的Tailscale-IP>:6080/vnc.html` 一样进。

> 🖥️ **别和 `Xvfb :99` 混**:服务器上另有一个 `Xvfb :99` 是给 `chrome-devtools-mcp` 用的**独立显示**,和本层的 `:1` 桌面无关、互不影响。

---

## 5. 验证 / 排障

**日志都在 `/var/log/`**(脚本把每个组件单独重定向了):

```bash
journalctl -u novnc.service -n 50 --no-pager      # 单元级(重启/退出原因)
ls -l /var/log/{xvfb,x11vnc,websockify,chrome-vnc,xfwm4,xfdesktop,xfce4-panel}.log
```

常见情况:

- **打开 :6080 连不上 / 空壳没桌面** → 先 `systemctl restart novnc.service`(健壮版会把整套重拉);再看 `xvfb.log` 有没有起来。
- **`ss -ltnp | grep 6080` 显示的是 `127.0.0.1:6080` 而不是 Tailscale IP** → 多半是**开机时 Tailscale 还没分到 IP**,脚本回落到了 localhost(见 §7 已知限制)。等 `tailscale ip -4` 能出 IP 后 `systemctl restart novnc.service` 即可。
- **桌面里中文是方块** → 没装字体,补 `apt-get install -y fonts-noto-cjk fonts-wqy-zenhei`,再重启服务。
- **Chrome 没起来** → 看 `chrome-vnc.log`;root 跑必须 `--no-sandbox`(脚本已带)。ARM64 机器八成是还在用 amd64 的 google-chrome,按 §1 的 ⚠️ 换 chromium。

---

## 6. 顺带:`cloud-dashboards.service`(:8088 项目看板,另一个选装层)

和 noVNC 一样,`cloud-dashboards.service` 核心 `install.sh` **也不部署**——它是 Wave 侧栏 🩵「项目看板」那个部件的后端,只在 `:8088` 上用 `python3 -m http.server` **静态服务 `/root/inbox/dashboards` 这一个目录**。要用才装:

```bash
cp systemd/cloud-dashboards.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now cloud-dashboards.service
```

> ✅ **看板 service 现在也自动取本机 IP**:`ExecStart` 已指向 `bin/cloud-dashboards.sh`(wrapper 内 `tailscale ip -4` 自动绑,install.sh 会把它装进 `/usr/local/bin`),跟 `novnc-start.sh` 一样、**无需手改 IP**。安全边界同 noVNC:只绑 tailnet IP、tailnet 内不鉴权。

它和桌面层没有依赖关系,分开装、按需装即可。

---

## 7. 已知限制 / 定位

- **开机时序**:`novnc.service` 是 `After=network-online.target`,**没显式等 `tailscaled`**。若开机时 Tailscale 比它先上不能保证,`novnc-start.sh` 取 IP 会回落 `127.0.0.1`(桌面暂时只有本机能连),需 Tailscale 就绪后 `systemctl restart novnc.service` 恢复。想根治可给单元加 `After=tailscaled.service`(本仓默认没加,保持和现网一致)。
- **通用核心 vs 私有叠加**:
  - **通用核心(可给客户照装)**:整套流程 —— apt 依赖、`novnc-start.sh`(已改为自动取本机 IP)、`novnc.service`、安全边界。谁装都一样。
  - **私有叠加(客户必换成自己的)**:Wave `widgets.json` 里的 `:6080`/`:8088` **URL 里那个 Tailscale IP**、`cloud-dashboards.service` 里写死的 `--bind` IP —— 都是作者的值,复用照 [DEPLOY.md](../DEPLOY.md) 阶段二「必改清单」换成客户自己的。
