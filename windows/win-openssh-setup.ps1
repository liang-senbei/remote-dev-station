# win-openssh-setup.ps1 — 客户 Windows 一键:开 OpenSSH Server + 生成并打印本机 SSH 公钥
# 新客户 Windows 部署第 1 步:
#   ① 装+起 OpenSSH Server(服务器才能反向进来做文件桥);
#   ② 生成本机 SSH 密钥(没有才建);
#   ③ 打印本机【公钥】—— 把它加进服务器 ~/.ssh/authorized_keys,客户就能免密 `ssh cloud`。
# 用法(管理员 PowerShell):
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\win-openssh-setup.ps1
#   (或右键『开始』→『终端(管理员)』,把整段粘进去回车)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- 0) 必须管理员 ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Write-Host "X 需要管理员。右键『开始』→『终端(管理员)』/『PowerShell(管理员)』,再跑本脚本。" -ForegroundColor Red
  Read-Host "按回车退出"; exit 1
}

# ===== [1/3] 装 + 起 OpenSSH Server(GitHub 直装,绕开又慢又常卡的 Windows Update「按需功能」)=====
Write-Host "== [1/3] 开启 OpenSSH Server ==" -ForegroundColor Cyan
if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
  $dst = 'C:\Program Files\OpenSSH'
  if (-not (Test-Path "$dst\OpenSSH-Win64\install-sshd.ps1")) {
    Write-Host "  下载 Win32-OpenSSH(~15MB,直连 GitHub)..." -ForegroundColor DarkGray
    $zip = Join-Path $env:TEMP 'OpenSSH-Win64.zip'
    Invoke-WebRequest 'https://github.com/PowerShell/Win32-OpenSSH/releases/latest/download/OpenSSH-Win64.zip' -OutFile $zip -UseBasicParsing
    Expand-Archive $zip $dst -Force
  }
  & "$dst\OpenSSH-Win64\install-sshd.ps1"
}
Set-Service sshd -StartupType Automatic
Start-Service sshd
Set-Service ssh-agent -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service ssh-agent -ErrorAction SilentlyContinue
if (-not (Get-NetFirewallRule -Name sshd -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
}
Write-Host "  OK  sshd = $((Get-Service sshd).Status);防火墙 22 已放行" -ForegroundColor Green

# ===== [2/3] 生成本机 SSH 密钥(已有则复用)=====
Write-Host "== [2/3] 本机 SSH 密钥 ==" -ForegroundColor Cyan
$sshDir = Join-Path $env:USERPROFILE '.ssh'
New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
$key = Join-Path $sshDir 'id_ed25519'
$keygen = (Get-Command ssh-keygen.exe -ErrorAction SilentlyContinue).Source
if (-not $keygen) {
  foreach ($p in @('C:\Windows\System32\OpenSSH\ssh-keygen.exe','C:\Program Files\OpenSSH\OpenSSH-Win64\ssh-keygen.exe')) {
    if (Test-Path $p) { $keygen = $p; break }
  }
}
if (-not (Test-Path "$key.pub")) {
  & $keygen -t ed25519 -f $key -N '""' -C "$env:USERNAME@$env:COMPUTERNAME" -q
  Write-Host "  已生成新密钥:$key" -ForegroundColor Green
} else {
  Write-Host "  已有密钥,复用:$key" -ForegroundColor Green
}

# ===== [3/3] 打印本机公钥 =====
$pub = (Get-Content "$key.pub" -Raw).Trim()
$out = Join-Path ([Environment]::GetFolderPath('Desktop')) 'my-ssh-pubkey.txt'
$pub | Out-File -FilePath $out -Encoding ascii
Write-Host ""
Write-Host "================= 本机公钥(把下面这一整行发给运维)=================" -ForegroundColor Yellow
Write-Host $pub -ForegroundColor White
Write-Host "===================================================================" -ForegroundColor Yellow
Write-Host ""
Write-Host "机器名: $env:COMPUTERNAME    用户名: $env:USERNAME" -ForegroundColor Cyan
Write-Host "OpenSSH Server: $((Get-Service sshd).Status)    (公钥也存了一份到桌面 my-ssh-pubkey.txt)" -ForegroundColor Cyan
Write-Host ""
Read-Host "完成。按回车关闭"
