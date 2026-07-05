# Windows 客户端反向通道（server → Windows 笔电）

对标 `mac-reverse-channel.md`：让**服务器**能反向读写**你的 Windows 笔电**上的文件/截图。Mac 用 `mac` ssh 别名 + `macget/macput/macls/pullimg`；Windows 用 `laptop` 别名 + `lapget/lapput/lapls/lapimg`（都在 `bin/`，`install.sh` 会装到 `~/.local/bin`）。

## 1. `laptop` ssh 别名（`~/.ssh/config`，服务器侧）
两条路，主 + 兜底：
```
# 主：Tailscale 直连（抗换网/抗劫持 WiFi）
Host laptop
    HostName 100.x.y.z          # 笔电 tailnet IP（tailscale ip 查）
    User <你的Windows用户名>
    IdentityFile ~/.ssh/id_ed25519_laptop

# 兜底：NSSM 反向隧道（笔电直推服务器 :2222，笔电无公网时用）
Host laptop-tunnel
    HostName localhost
    Port 2222
    User <你的Windows用户名>
    IdentityFile ~/.ssh/id_ed25519_laptop_inbound
```
- 笔电侧需：**OpenSSH Server** 已启（`Get-Service sshd`），公钥进 `C:\Users\<你>\.ssh\authorized_keys`；Tailscale `tailscale up`。
- 兜底隧道做成 **NSSM 服务**（自愈+自启），见仓外记忆 `laptop-reverse-tunnel-nssm`。

## 2. 桥命令（服务器上跑）
| 命令 | 作用 | Mac 对应 |
|---|---|---|
| `lapput <本地文件> [笔电目标]` | 推文件到笔电（默认 `~/Downloads`） | macput |
| `lapget <笔电路径> [目标目录]` | 从笔电取文件（默认落 `~/inbox`） | macget |
| `lapls [目录]` | 列笔电某目录最近文件（默认 Downloads） | macls |
| `lapimg` | 抓笔电上最新一张 Wave 粘贴/截图 → `~/inbox` | pullimg |
- 覆盖别名：`LAPTOP=laptop-tunnel lapget ...`（走兜底隧道）。

## 3. Windows 特有坑
- **笔电落 PowerShell**（不是 bash）：`lapls` 用 `Get-ChildItem` 而非 `ls`；`lapimg` 显式 `powershell -NoProfile -Command`。
- **Wave 粘贴临时目录** = `%TEMP%` 下递归的 `waveterm_paste_*.png`（Mac 是 `/var/folders/*/T/...`）。首次用先探：`ssh laptop 'dir $env:TEMP\waveterm*'`，与 `lapimg` 内的 filter 对齐。
- **scp 走正斜杠**：Windows 路径 `C:\...` 里的反斜杠 scp 吃不下，`lapimg` 已 `\ → /` 转换；手动 scp 也用 `laptop:'C:/Users/.../x.png'`。
- **PowerShell 编码**：远程跑 PS 命令含中文时注意 UTF-8（PS5.1 默认 GBK）。

## 4. 与 Mac 路径的差距（现状）
- ✅ 会话管理**比 Mac 强**：`windows/` 有 `cc-restore-tab`（按 Wave 标签页恢复终端），Mac 无对应。
- ✅ 隧道齐：Tailscale / NSSM 反向隧道 / WSL2 mosh（见 `windows/README.md`）。
- ✅ 文件/截图桥：本文件的 `lap*` 已补齐（对齐 macget/macput/macls/pullimg）。
- ⚠️ 自启悬浮盘：Mac 的 hammerspoon + `com.wavetheme.ui.plist` 在 Windows **无需对应**——Wave widgets（新会话/恢复本页）+ NSSM 隧道服务已平替，不强补。
