# tunnel-check.ps1 — 检查反向隧道是否在线;断了就重启 NSSM 服务。可做成 Wave widget 或定时任务。
# 判活方式:ssh 到服务器看它本机有没有在 127.0.0.1:2222 监听(= 隧道这头活着)。
$server = 'root@38.244.38.66'              # ← 改成你的服务器
$svcName = 'LaptopReverseTunnel'           # NSSM 服务名
$port = 2222                                # 反向隧道在服务器侧绑的端口

function Probe {
  (ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 $server `
     "ss -tln | grep -q ':$port' && echo UP || echo DOWN" 2>$null) -match 'UP'
}

if (Probe) {
  Write-Host "✓ 隧道在线(服务器 127.0.0.1:$port 有监听)" -ForegroundColor Green
} else {
  Write-Host "✗ 隧道不在线,重启服务 $svcName ..." -ForegroundColor Yellow
  try { Restart-Service $svcName -ErrorAction Stop }
  catch {
    Write-Host "  权限不足,以管理员重启..." -ForegroundColor DarkYellow
    Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -Command Restart-Service $svcName" -Wait
  }
  Start-Sleep 6
  if (Probe) { Write-Host "✓ 已恢复" -ForegroundColor Green } else { Write-Host "✗ 仍不通,查 NSSM 日志 ~/.ssh\nssm-tunnel.log" -ForegroundColor Red }
}
Start-Sleep 3
