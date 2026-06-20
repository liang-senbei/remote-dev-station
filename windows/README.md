# Windows 笔电 + Wave 客户端层

> 对应主仓库的 **Mac 客户端层**(hammerspoon / macget·put / OSC52→Mac 剪贴板)。
> 本目录补上**从 Windows 笔电用 Wave Terminal 远程操作服务器上 tmux+Claude** 的那条线,
> 以及一个主仓库没有的能力:**Wave「按标签页一键恢复终端」GUI 层**。
>
> 服务器侧的"会话登记 + 断线自愈"**直接复用主仓库现成的 `cc-state`(hook 驱动登记)+
> `cloud-watchdog`(内存守卫自愈)**——那套比这里的最小参考实现更好。本层只加两样:
> ① Windows 的接入/隧道;② Wave 的多标签页恢复 UI。

---

## 0. 这层解决什么

主仓库假设客户端是 Mac、网络走 Tailscale。Windows 笔电有几处不一样,踩过的坑都在这:

| 约束 | Windows 这边的做法 |
|---|---|
| 没接 Tailscale,要从公网回连服务器/被服务器回连笔电 | **反向 SSH 隧道 + NSSM 常驻服务**(`§1`) |
| Windows 无原生 mosh | **WSL2 里跑 mosh**(`§2`),有个 known_hosts 静默坑 |
| Wave 在 Windows 跑 PowerShell,中文/配置编码易翻车 | **编码铁律**:`.ps1` 要 BOM、`widgets.json` 不要 BOM(`§3`) |
| 服务器 tmux 全死后,Wave 标签页里一排终端没人重建 | **「恢复本页」widget 按标签页一键复活**(`§4`,本层原创) |

---

## 1. 反向 SSH 隧道(NSSM 常驻服务)

笔电主动建反向隧道,服务器经 `127.0.0.1:2222` 回连笔电(也用来给隧道判活)。做成 **NSSM 服务**断线自动重连、开机自启。

- 服务 `LaptopReverseTunnel`,以 LocalSystem 跑 → **读不了用户 `~/.ssh` 私钥**(`Load key: Permission denied`)。
  解法:密钥副本放 `C:\ProgramData\ssh\tunnel_id_ed25519`(ACL 仅 SYSTEM+Administrators 可读),`known_hosts` 同放 `C:\ProgramData\ssh\`。
- ssh 参数:`-N -R 2222:localhost:22 -o ServerAliveInterval=30 -o ExitOnForwardFailure=yes -o IdentityFile=C:\ProgramData\ssh\tunnel_id_ed25519 -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=C:\ProgramData\ssh\known_hosts_tunnel -o BatchMode=yes <user@server>`
- **自愈慢的根治(在服务器侧)**:`/etc/ssh/sshd_config.d/99-tunnel-keepalive.conf` 设 `ClientAliveInterval 30` + `ClientAliveCountMax 2`。否则笔电睡醒重连时,服务器旧的死连接还占着 2222,NSSM 一直 `remote port forwarding failed`,要拖到旧连接超时(~180s)才恢复。
- 判活/重启:`reverse-tunnel/tunnel-check.ps1`(ssh 探服务器有没有在 :2222 监听,没有就 `Restart-Service`)。可做成 Wave widget。

---

## 2. WSL2 + mosh

Windows 无原生 mosh,在 WSL2(Ubuntu)里装 `mosh`,Wave 的 widget 走 `wsl -d Ubuntu -- mosh <server> -- <进会话命令>`。

- **血泪坑**:mosh 内部要先 ssh 握手起 `mosh-server`。若 **WSL 的 `~/.ssh/known_hosts` 没有服务器 host key**,这步**静默卡住**,客户端只看到一直刷清屏码、超时,毫无报错。
  修:`wsl -d Ubuntu -- bash -c 'ssh-keyscan -t ed25519,rsa <server-ip> >> ~/.ssh/known_hosts'`。
  判定:连的时候到服务器 `pgrep mosh-server` 没进程 = 卡在 ssh 握手。
- WSL→服务器免密用 **WSL 自己生成的钥匙**,别搬笔电主私钥。

---

## 3. Wave 配置即代码(编码铁律)

Windows 上改 Wave / 写 PS 脚本,两条**方向相反**的编码规则,搞反必翻车:

| 文件 | 编码 | 搞错的后果 |
|---|---|---|
| `.ps1`(PS5.1 执行,含中文) | **UTF-8 带 BOM** | 无 BOM → PS5.1 按系统 GBK 读 → 中文提示全乱码 |
| Wave `widgets.json` / `settings.json` | **UTF-8 无 BOM** | 带 BOM → Wave 解析失败 → **widget 全部消失** |

- 改 `widgets.json` 用**字符串插入法**(保留原内容不重排)+ `[IO.File]::ReadAllText(p, UTF8)` 读、`UTF8Encoding($false)` 写;插入后先 `ConvertFrom-Json` 校验再落盘。
- **跨两跳 ssh 传含中文的 PowerShell**:用 `powershell -EncodedCommand <UTF-16LE base64>`(`iconv -f UTF-8 -t UTF-16LE | base64 -w0`),纯 ASCII 过隧道,免三层引号地狱。
- 这些都固化在 `wave/install.ps1` 里,直接跑即可。

---

## 4. ★ Wave「按标签页一键恢复终端」(本层原创)

主仓库的 `cloud-watchdog` 在**服务器侧**把 tmux 会话拉回来——但**没人去把 Wave 里那一排终端块重新长出来**;尤其开了多个标签页时,该哪个 tab 复活哪些终端,没人管。这层补上:

```
点 Wave「恢复本页」widget(块内,wsh 可用)
 → 解析当前标签页 id(从 WAVETERM_SWAPTOKEN 解出 blockid → wsh blocks list --json 找到自己 → 读 tabid)
 → 服务器 cc-restore        # 复活所有死掉的登记会话(tmux 层,tab 无关)
 → cc-slugs-by-tab <tabid>  # 只取属于本页的会话
 → 对每个: wsh run -c "ssh -t <server> cc-new <slug>"   # 在本标签页弹一个终端块,接回该会话内容
```

**关键机制(踩出来的)**:
- Wave 的 `controller:cmd` 块**不走 shell 集成**,拿不到 `WAVETERM_JWT`,只有一次性的 `WAVETERM_SWAPTOKEN`。
- 官方换法 = `wsh token <swaptoken> <shell>` 返回含 JWT 的 shell 初始化脚本;**SWAPTOKEN 只能换一次**,所以 `cc-wave-lib.ps1` 只调一次、用正则把 JWT 值抠出来设进 `$env:WAVETERM_JWT`(值与 shell 类型无关)。
- `blockid` 直接从 `WAVETERM_SWAPTOKEN`(base64→json.rpccontext.blockid)解,不依赖 wsh。
- 没有 `WAVETERM_BLOCKID` 这个环境变量(别找它,它不存在);blockid 只在 SWAPTOKEN 里。

**会话身份 = `claude --session-id <uuid>` 出生即钉死**(主仓库是 hook 在创建后抓 uuid;这里在创建时就钉死,更确定,可并入 `cc-state`)。注册表 `cc-registry.tsv` 第 6 列存所属 tab,`cc-slugs-by-tab` 据此按页过滤。

### 安装

```powershell
# 笔电上,在 windows\wave\ 目录:
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
# 然后改 ~/.ssh\cc-restore-tab.ps1 与 cc-launch.ps1 顶部的 $SRV 为你的服务器
```
服务器侧把 `server-side/cc-new`、`cc-restore`、`cc-slugs-by-tab` 放进 `/usr/local/bin/`(或并入主仓库的 `cc-sessions`/`cloud-watchdog`)。

### 用法

- **新会话**(绿色 `+`):在当前标签页建一个命名的可恢复会话(自动归属本页)。
- **恢复本页**(红色 ↻):一键把本页该有的终端全部弹回来,各自接回对话。
- 多标签页各点各的「恢复本页」,互不串。

---

## 5. 验证状态(诚实标注,2026-06)

| 环节 | 状态 |
|---|---|
| `--session-id` 钉死 / `--resume` 拉回有内容会话(31KB 存档,杀后 12s 仍活、对话恢复) | ✅ 实测 |
| `cc-new` 中文名 → tmux `cc-<名>` | ✅ 实测 |
| 三个 `.ps1` PowerShell 解析 | ✅ 语法 OK |
| widgets.json 合并(无 BOM、JSON 合法、原中文不坏) | ✅ 实测 |
| NSSM 反向隧道 + ClientAlive 自愈 | ✅ 实测 |
| **点 widget → wsh token 换 JWT → blocks list 解 tabid → wsh 弹块** 整条链 | ⏳ **实验中**:`wsh token` 换 JWT 的鉴权路径已查实,`blocks list --json` 字段名(`tabid`/`blockid`)仍待一次真机点击在 `~/.ssh/cc-restore-tab.log` 里最终核对。脚本已带探针。 |

> 即:**服务器侧恢复内核 = 已验证可靠;Wave 的 GUI 弹块层 = 机制查实、脚本就位,最后一次真机核对待补。** 不夸大。

---

## 文件清单

```
windows/
├── README.md                    # 本文
├── reverse-tunnel/
│   └── tunnel-check.ps1          # 隧道判活 + 自动重启 NSSM
├── wave/
│   ├── cc-wave-lib.ps1           # 块内解析 blockid/tabid + 换 JWT(被另两个 dot-source)
│   ├── cc-restore-tab.ps1        # 「恢复本页」widget 脚本
│   ├── cc-launch.ps1             # 「新会话」widget 脚本
│   ├── widgets-snippet.json      # 两个 widget 定义(参考)
│   └── install.ps1               # 一键安装(BOM 铁律已固化)
└── server-side/                  # Wave 层最小依赖的服务器脚本(建议并入 cc-sessions/cloud-watchdog)
    ├── cc-new
    ├── cc-restore
    └── cc-slugs-by-tab
```
