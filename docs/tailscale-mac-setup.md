# Tailscale · Mac 客户端安装与「要开的系统设置/权限」

装 Tailscale Mac 版**光装完不够**——首次启动要过 macOS 的两道授权(系统扩展 + VPN 配置),不批就连不上、状态一直转圈。这份把要点的设置一次讲清。下面以较新的 macOS(Ventura/Sonoma/Sequoia,「系统设置 System Settings」)为准,老版本(「系统偏好设置 System Preferences」)路径名略不同、逻辑一样。

## 0. 选哪个版本
Tailscale 在 Mac 上有三种跑法(见官方 [Three ways to run Tailscale on macOS](https://tailscale.com/docs/concepts/macos-variants)):
- **App Store 版**:最省事、沙盒化、自动更新。权限多半靠弹窗点「允许」即可,一般**不需要**手动去开系统扩展。**新手/客户优先选这个。**
- **独立版 standalone**(官网 [tailscale.com/download](https://tailscale.com/download) 下 `.pkg`/`.dmg`):官方推荐,功能最全,但**首次要手动授权「系统扩展」+「VPN 配置」**(下面 §2)。
- **开源 CLI**(`brew install tailscale` 跑 `tailscaled`):最手动,一般不给客户用。

## 1. 装 + 登录
1. 装好后启动 Tailscale(菜单栏出现小图标)。
2. 点菜单栏图标 → **Log in**,浏览器打开 → **用和服务器同一个 tailnet 的账号登录**(⚠️ 必须同一个账号/tailnet,否则两台机器互相看不见)。
3. 登录后回到 App,状态应变 **Connected**。

## 2. ⚠️ 要开的系统设置/权限(独立版首次必做;连不上多半卡这)
首次连接时 macOS 会弹「**系统扩展被阻止 / System Extension Blocked**」或「需要批准」。按下面开:

### ① 批准系统扩展(Network Extension)
- **系统设置 → 通用(General) → 登录项与扩展(Login Items & Extensions)**
- 往下找到 **网络扩展(Network Extensions)** → 点右边 **ⓘ**
- 把 **Tailscale Network Extension** 的开关**打开** → 用 **Touch ID / 密码** 确认。
- (老 macOS:**系统偏好设置 → 安全性与隐私 → 通用**,底部会出现「已阻止来自 Tailscale 的系统软件」→ 点 **允许 Allow**。)

### ② 允许 VPN 配置(在「隐私与安全性」/弹窗里)
- 开完扩展,系统会提示「**Tailscale 想要添加 VPN 配置 / would like to add VPN configurations**」→ 点 **允许 Allow**(可能要再输一次密码)。
- 若没弹或点漏了:**系统设置 → 隐私与安全性(Privacy & Security)**,找到与 **Tailscale** 相关的允许项 → 允许;VPN 配置也可在 **系统设置 → VPN** 里看到并启用。

> 这两步就是你印象里「要在隐私那里打开的设置」。**扩展没批 → App 一直转圈连不上;VPN 配置没批 → 显示已登录但没网络**。批过一次之后,以后开机自动重连,不用再点。

## 3. 验证 + 取 IP
- 菜单栏图标显示 **Connected**、能看到 tailnet 里其它设备。
- 终端:`tailscale ip -4` → 拿到本机 tailnet IP(形如 `100.x.y.z`)。**客户端连服务器一律用这个 IP,别依赖 MagicDNS 名字。**
- 连通性自测:`tailscale ping <服务器tailnet-IP>` 出 `pong` 即通。

## 4. 配套:反向通道要开的另一个设置(顺带)
本套「服务器反向操作 Mac」还要 Mac 开 **SSH**:
- **系统设置 → 通用 → 共享(Sharing) → 远程登录(Remote Login)= 打开**(否则服务器 `ssh mac` 进不来)。
- (可选)想让服务器**截 Mac 的屏**(`pullimg`):**系统设置 → 隐私与安全性 → 屏幕录制(Screen Recording)** 里给对应终端/进程勾上;不给则截屏报「could not create image / 权限不足」。

## 5. 常见卡点
- **一直转圈连不上** → 系统扩展没批(§2①)。到 通用→登录项与扩展→网络扩展 打开 Tailscale。
- **显示已登录但 ping 不通** → VPN 配置没允许(§2②),或两台**不在同一个 tailnet/账号**。
- **系统扩展装失败(System Extension Install Failed)** → 重装 App、重启一次 Mac 再批;或改用 App Store 版免这步。见官方 [排障](https://tailscale.com/docs/reference/troubleshooting/apple/macos-system-extension-errors)。

## 参考
- [Authorizing the Tailscale system extension on macOS](https://tailscale.com/docs/concepts/macos-sysext)
- [Three ways to run Tailscale on macOS](https://tailscale.com/docs/concepts/macos-variants)
- [Troubleshoot macOS system extension errors](https://tailscale.com/docs/reference/troubleshooting/apple/macos-system-extension-errors)
