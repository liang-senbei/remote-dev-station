# install-wsl-mosh.ps1 — 给 Windows 笔电装 WSL2 + Ubuntu + mosh(「指挥中心/选会话」等 mosh 抗断 widget 的前置)。
# ⚠️ 要【管理员】+ 一次【重启】。用法(以管理员开 PowerShell):
#      powershell -NoProfile -ExecutionPolicy Bypass -File .\install-wsl-mosh.ps1
#    第一次跑完会让你重启 → 重启后【再跑一次】(幂等,自动接着装 mosh)。
# 干 3 件:① WSL2 + Ubuntu  ② WSL 里装 mosh  ③ 写 %USERPROFILE%\.wslconfig 封顶内存(防 vmmem 膨胀把笔电拖 OOM)。
$ErrorActionPreference = 'Stop'
$DIST = 'Ubuntu'   # WSL2 发行版;想换发行版改这里(wsl -l -o 看可选)

# 0) 必须管理员(开 Windows 功能 / wsl --install 都要)
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { Write-Host "✗ 需要管理员:右键 PowerShell → 以管理员身份运行,再跑本脚本。" -ForegroundColor Red; exit 1 }

# 1) 先写 .wslconfig 封顶内存(重启后生效)——WSL2 不封顶 vmmem 会膨胀吃满内存
$wslcfg = Join-Path $env:USERPROFILE '.wslconfig'
if (-not (Test-Path $wslcfg)) {
@"
[wsl2]
memory=4GB
swap=4GB
processors=4
"@ | Out-File -FilePath $wslcfg -Encoding ascii
  Write-Host "✓ 写了 $wslcfg(WSL2 封顶 4GB 防 OOM;RAM 大想放宽自己改 memory=)" -ForegroundColor Green
} else {
  Write-Host "= 已有 $wslcfg,不覆盖(自己确认有 [wsl2] memory 封顶)" -ForegroundColor DarkGray
}

# 2) 判断 Ubuntu 是否已装 → 决定 第一段(装+重启) 还是 第二段(装 mosh)
$distInstalled = $false
try {
  $list = (& wsl.exe -l -q 2>$null) -replace "`0", ''
  if ($list -match "(?im)^\s*$([regex]::Escape($DIST))\s*$") { $distInstalled = $true }
} catch {}

if (-not $distInstalled) {
  Write-Host "→ 第一段:装 WSL2 + $DIST(自动开 Windows 功能 + 装内核 + 装发行版)..." -ForegroundColor Cyan
  & wsl.exe --install -d $DIST
  Write-Host ""
  Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Yellow
  Write-Host " 第一段完成。接下来:" -ForegroundColor Yellow
  Write-Host "  1) 【重启电脑】" -ForegroundColor Yellow
  Write-Host "  2) 开机后 Ubuntu 会弹出让你【建用户名+密码】(记住它)" -ForegroundColor Yellow
  Write-Host "  3) 再【以管理员】跑一次本脚本 → 自动装 mosh" -ForegroundColor Yellow
  Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Yellow
  exit 0
}

# 3) 第二段:Ubuntu 已在 → 装 mosh
Write-Host "→ 第二段:$DIST 已在,装 mosh ..." -ForegroundColor Cyan
$hasMosh = (& wsl.exe -d $DIST -- bash -lc "command -v mosh >/dev/null 2>&1 && echo yes || echo no") -match 'yes'
if (-not $hasMosh) {
  & wsl.exe -d $DIST -- bash -lc "sudo apt-get update -y && sudo apt-get install -y mosh"
  $hasMosh = (& wsl.exe -d $DIST -- bash -lc "command -v mosh >/dev/null 2>&1 && echo yes || echo no") -match 'yes'
}
if ($hasMosh) {
  & wsl.exe --shutdown   # 让 .wslconfig 内存封顶生效
  Write-Host "✓ 完成:WSL2 + $DIST + mosh 就绪,.wslconfig 封顶已生效。指挥中心/选会话 widget 可用了。" -ForegroundColor Green
  Write-Host "  下一步:装反向隧道(无 Tailscale 时)见 install-tunnel.ps1;改服务器地址见 ~/.ssh\ 下各 ps1 的 `$SRV。" -ForegroundColor Cyan
} else {
  Write-Host "✗ mosh 没装上。手动进 WSL 装: wsl -d $DIST  然后  sudo apt install mosh" -ForegroundColor Red
  exit 1
}
