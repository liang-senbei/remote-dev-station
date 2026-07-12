#Requires -RunAsAdministrator
# ============================================================
# 一键部署 · Windows 客户机反向隧道（remote-dev-station · CLI 版）
# 用法（管理员 PowerShell,在客户机上跑）:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\win-setup-tunnel.ps1 -Server <服务器IP> [-Port 2222] [-ServerPubKey "ssh-ed25519 AAAA... srv"]
# 跑完:① 屏幕打印【本机公钥】——发给部署方加到服务器 authorized_keys
#       ② 反向隧道已设登录自启;服务器加好公钥后自动接通
# ============================================================
param(
  [Parameter(Mandatory=$true)][string]$Server,
  [int]$Port = 2222,
  [string]$ServerPubKey = ""
)
$ErrorActionPreference = 'Stop'
if ($Server -notmatch '@') { $Server = "root@$Server" }
$sshUserDir = Join-Path $env:USERPROFILE '.ssh'
$keyPath    = Join-Path $sshUserDir 'id_ed25519'
$pdSsh      = 'C:\ProgramData\ssh'

Write-Host "== [1/5] 开启 OpenSSH 服务端（一次性,开机自启） ==" -ForegroundColor Cyan
$cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*'
if ($cap.State -ne 'Installed') { Add-WindowsCapability -Online -Name $cap.Name | Out-Null }
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd
if (-not (Get-NetFirewallRule -Name 'sshd' -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
}

Write-Host "== [2/5] 生成本机 SSH 密钥（已有则复用） ==" -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $sshUserDir | Out-Null
if (-not (Test-Path $keyPath)) { & ssh-keygen.exe -t ed25519 -f $keyPath -N '""' -C "client-$env:COMPUTERNAME" -q }

Write-Host "== [+] 写 ssh 'cloud' 别名（以后 ssh cloud 直接连服务器 → 敲 claude） ==" -ForegroundColor Cyan
$cfg = Join-Path $sshUserDir 'config'
$hostOnly = $Server.Split('@')[-1]
$userOnly = if ($Server -match '@') { $Server.Split('@')[0] } else { 'root' }
if ((Test-Path $cfg) -and (Select-String -Path $cfg -Pattern '^\s*Host\s+cloud\s*$' -Quiet)) {
  Write-Host "  -> ~/.ssh/config 已有 cloud 别名，不动（要改指向请手动编辑）" -ForegroundColor DarkGray
} else {
  Add-Content -Path $cfg -Value "`r`nHost cloud`r`n    HostName $hostOnly`r`n    User $userOnly`r`n    IdentityFile $keyPath`r`n    IdentitiesOnly yes`r`n    ServerAliveInterval 30" -Encoding ascii
  Write-Host "  -> 已写 cloud 别名 → $hostOnly（ssh cloud 连上 → 敲 claude）" -ForegroundColor Green
}

Write-Host "== [3/5] 授权服务器回连（服务器公钥 -> administrators_authorized_keys） ==" -ForegroundColor Cyan
if ($ServerPubKey -ne "") {
  $adminKeys = Join-Path $pdSsh 'administrators_authorized_keys'
  if (-not (Test-Path $adminKeys) -or -not (Select-String -Path $adminKeys -SimpleMatch $ServerPubKey -Quiet)) {
    Add-Content -Path $adminKeys -Value $ServerPubKey -Encoding ascii
  }
  icacls $adminKeys /inheritance:r /grant 'Administrators:F' 'SYSTEM:F' | Out-Null
  Write-Host "  -> 已授权服务器公钥（服务器可反向读你文件）" -ForegroundColor Green
} else {
  Write-Host "  ! 没传 -ServerPubKey:服务器暂时无法反向读你文件。拿到服务器公钥后重跑一次带上它即可。" -ForegroundColor Yellow
}

Write-Host "== [4/5] 反向隧道设为登录自启（断线自动重连） ==" -ForegroundColor Cyan
$runner = Join-Path $pdSsh 'tunnel-run.ps1'
@"
while (`$true) {
  ssh -N -R ${Port}:localhost:22 -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes -o StrictHostKeyChecking=accept-new -i "`$env:USERPROFILE\.ssh\id_ed25519" $Server
  Start-Sleep -Seconds 5
}
"@ | Set-Content -Path $runner -Encoding UTF8
# 用 schtasks 注册「登录触发」任务(比 Register-ScheduledTask 在 SSH/非交互上下文更稳);/rl LIMITED 非提权即可
$tr = "powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File $runner"
schtasks /create /tn RemoteDevTunnel /sc ONLOGON /rl LIMITED /f /tr $tr | Out-Null
schtasks /run /tn RemoteDevTunnel 2>$null | Out-Null
if (schtasks /query /tn RemoteDevTunnel 2>$null | Select-String 'RemoteDevTunnel') {
  Write-Host "  -> 隧道任务已注册并启动(RemoteDevTunnel:登录自启 + 断线重连)" -ForegroundColor Green
} else {
  Write-Host "  ! 隧道任务注册失败,请在本机【管理员 PowerShell】里重跑本脚本" -ForegroundColor Yellow
}

Write-Host "== [5/5] 完成。把下面这行【本机公钥】发给部署方（加到服务器 authorized_keys）: ==" -ForegroundColor Cyan
$pub = Get-Content "$keyPath.pub"
Write-Host $pub -ForegroundColor Green
$out = Join-Path ([Environment]::GetFolderPath('Desktop')) 'client-pubkey.txt'
$pub | Set-Content -Path $out -Encoding ascii
Write-Host "（也已存到桌面: $out）" -ForegroundColor DarkGray
