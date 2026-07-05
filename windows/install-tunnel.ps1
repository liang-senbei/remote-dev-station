# install-tunnel.ps1 — 建"笔电 → 服务器"反向 SSH 隧道 + NSSM 常驻服务(无 Tailscale 时,让服务器经 127.0.0.1:2222 公网回连笔电)。
# ⚠️ 【管理员】运行。用法:  powershell -NoProfile -ExecutionPolicy Bypass -File .\install-tunnel.ps1
# 自动做(笔电侧):① 隧道密钥→C:\ProgramData\ssh\(NSSM 以 LocalSystem 跑,读不了用户 ~/.ssh,故放这)
#                ② 取服务器 host key ③ 没 NSSM 就从官方下 ④ 建服务 LaptopReverseTunnel(断线重连+开机自启)
# 你手动做(服务器侧,脚本远端做不了):加隧道公钥 + sshd keepalive —— 脚本结尾会把两条命令打印给你。
$ErrorActionPreference = 'Stop'
$dv = Join-Path $env:USERPROFILE '.ssh\deploy-vars.ps1'   # 个人/客户配置层:提供 $SRV
if (-not (Test-Path $dv)) {
  $ex = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'wave\deploy-vars.ps1.example'
  New-Item -ItemType Directory -Force -Path (Split-Path $dv) | Out-Null
  if (Test-Path $ex) { Copy-Item $ex $dv }
  Write-Host "需要 $dv —— 填好里面的 `$SRV 再跑一次本脚本。" -ForegroundColor Yellow; exit 1
}
. $dv
$SvcName = 'LaptopReverseTunnel'
$Port    = 2222                     # 服务器侧绑的回连端口
$PdSsh   = 'C:\ProgramData\ssh'
$KeyFile = Join-Path $PdSsh 'tunnel_id_ed25519'
$KnownH  = Join-Path $PdSsh 'known_hosts_tunnel'

# 0) 管理员
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { Write-Host "✗ 需要管理员:右键 PowerShell → 以管理员身份运行。" -ForegroundColor Red; exit 1 }

# 1) 隧道密钥(放 ProgramData,ACL 仅 SYSTEM+Administrators 可读)
New-Item -ItemType Directory -Force -Path $PdSsh | Out-Null
if (-not (Test-Path $KeyFile)) {
  & ssh-keygen.exe -t ed25519 -f $KeyFile -N '""' -C 'laptop-reverse-tunnel' -q
  Write-Host "✓ 生成隧道密钥 $KeyFile" -ForegroundColor Green
} else { Write-Host "= 已有 $KeyFile" -ForegroundColor DarkGray }
& icacls.exe $KeyFile /inheritance:r /grant:r "SYSTEM:(R)" "Administrators:(R)" | Out-Null

# 2) 服务器 host key → known_hosts_tunnel(免首连交互)
$hostOnly = $SRV.Split('@')[-1]
& ssh-keyscan.exe -H $hostOnly 2>$null | Out-File -FilePath $KnownH -Encoding ascii
Write-Host "✓ 取 $hostOnly host key → $KnownH" -ForegroundColor Green

# 3) NSSM(PATH/ProgramData 没有就从官方 nssm.cc 下)
$nssm = (Get-Command nssm.exe -ErrorAction SilentlyContinue).Source
if (-not $nssm) { $nssm = Join-Path $PdSsh 'nssm.exe' }
if (-not (Test-Path $nssm)) {
  Write-Host "→ 本机无 NSSM,从官方 nssm.cc 下载 nssm-2.24 ..." -ForegroundColor Cyan
  $zip = Join-Path $env:TEMP 'nssm.zip'; $ex = Join-Path $env:TEMP 'nssm-ex'
  Invoke-WebRequest -Uri 'https://nssm.cc/release/nssm-2.24.zip' -OutFile $zip -UseBasicParsing
  Expand-Archive -Path $zip -DestinationPath $ex -Force
  Copy-Item (Join-Path $ex 'nssm-2.24\win64\nssm.exe') $nssm -Force
  Write-Host "✓ NSSM → $nssm" -ForegroundColor Green
}

# 4) 建/重建服务(ssh -N -R 反向转发,断线自动重连,开机自启)
$sshExe  = (Get-Command ssh.exe).Source
$sshArgs = "-N -R ${Port}:localhost:22 -o ServerAliveInterval=30 -o ExitOnForwardFailure=yes -o IdentityFile=$KeyFile -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$KnownH -o BatchMode=yes $SRV"
& $nssm stop $SvcName 2>$null | Out-Null
& $nssm remove $SvcName confirm 2>$null | Out-Null
& $nssm install $SvcName $sshExe $sshArgs
& $nssm set $SvcName AppExit Default Restart
& $nssm set $SvcName AppRestartDelay 5000
& $nssm set $SvcName Start SERVICE_AUTO_START
& $nssm set $SvcName AppStdout (Join-Path $PdSsh 'nssm-tunnel.log')
& $nssm set $SvcName AppStderr (Join-Path $PdSsh 'nssm-tunnel.log')
& $nssm start $SvcName
Write-Host "✓ NSSM 服务 $SvcName 已建+启动(开机自启,断线 5s 自动重连;日志 $PdSsh\nssm-tunnel.log)" -ForegroundColor Green

# 5) 服务器侧两件事(脚本远端做不了,复制这两条到能 ssh 到服务器的地方跑)
$pub = (Get-Content "$KeyFile.pub" -Raw).Trim()
Write-Host ""
Write-Host "═══ 还要在【服务器】上做两件事(复制下面两条跑)═══" -ForegroundColor Yellow
Write-Host " 1) 加隧道公钥(笔电免密回连):" -ForegroundColor Yellow
Write-Host "    ssh $SRV `"mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '$pub' >> ~/.ssh/authorized_keys`"" -ForegroundColor White
Write-Host " 2) sshd keepalive(否则笔电睡醒重连要等 ~180s):" -ForegroundColor Yellow
Write-Host "    ssh $SRV `"printf 'ClientAliveInterval 30\nClientAliveCountMax 2\n' | sudo tee /etc/ssh/sshd_config.d/99-tunnel-keepalive.conf && sudo systemctl reload ssh`"" -ForegroundColor White
Write-Host ""
Write-Host "验活:服务器上 ss -tln | grep :$Port 应有监听;或用「隧道」widget / tunnel-check.ps1。" -ForegroundColor Cyan
