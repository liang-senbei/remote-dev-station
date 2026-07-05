# cc-mosh-run.ps1 — WSL 自愈 + 经 mosh(抗断)在服务器跑一条命令。被「指挥中心/选会话」widget 调用。
# 用法: cc-mosh-run.ps1 <服务器命令...>
# 依赖: 笔电装 WSL2(默认发行版 Ubuntu)、WSL 里装 mosh;服务器装 mosh-server。
$dv = Join-Path $env:USERPROFILE '.ssh\deploy-vars.ps1'   # 个人/客户配置层:提供 $SRV
if (-not (Test-Path $dv)) { Write-Host "缺 $dv —— 先跑 wave\install.ps1 或拷 deploy-vars.ps1.example 填 `$SRV" -ForegroundColor Red; exit 1 }
. $dv
$DIST = 'Ubuntu'              # WSL2 发行版名(wsl -l -v 看;不是 Ubuntu 就改这里)
$ErrorActionPreference='SilentlyContinue'
# WSL 自愈: 探活,卡死(>8s)就杀 wsl 进程 + wsl --shutdown 重来(防僵尸 wsl.exe)
$probe = Start-Process -FilePath wsl -ArgumentList '-d',$DIST,'--','true' -PassThru -WindowStyle Hidden
if(-not $probe.WaitForExit(8000)){
  try{$probe.Kill()}catch{}
  Get-Process wsl,wslhost,wslservice -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  wsl --shutdown; Start-Sleep -Seconds 2
}
wsl -d $DIST -- mosh $SRV -- @args
