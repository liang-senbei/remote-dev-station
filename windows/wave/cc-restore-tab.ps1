# cc-restore-tab.ps1 — Wave widget「恢复本页」:一键复活【当前标签页】的所有 Claude 终端。
# 流程:解析当前 tab → 服务器侧 cc-restore 复活所有 tmux → 取本页会话 → 逐个 wsh run 弹终端块。
# 依赖:同目录的 cc-wave-lib.ps1;服务器侧 cc-restore / cc-slugs-by-tab(见仓库 bin/ 与 windows/README)。
# 注意:本脚本须由 Wave widget 启动(块内才有 WAVETERM_SWAPTOKEN);外部 shell 跑不出 wsh 权限。

$ErrorActionPreference = 'SilentlyContinue'
$SRV = 'root@<SERVER_PUBLIC_IP>'   # ← 改成你的服务器(user@host)
$wsh = Join-Path $env:LOCALAPPDATA 'waveterm\Data\bin\wsh.exe'
$log = Join-Path $env:USERPROFILE '.ssh\cc-restore-tab.log'
. (Join-Path $env:USERPROFILE '.ssh\cc-wave-lib.ps1')

"==== $([DateTime]::Now.ToString('MM-dd HH:mm:ss')) 恢复本页 ====" | Out-File $log -Append -Encoding utf8
Get-ChildItem env:WAVETERM* | ForEach-Object { "ENV $($_.Name)=$($_.Value)" | Out-File $log -Append -Encoding utf8 }
$ctx = Get-WaveTab $wsh $log

Write-Host "↻ 服务器侧复活会话..." -ForegroundColor Cyan
(ssh -o BatchMode=yes -o ConnectTimeout=10 $SRV "/usr/local/bin/cc-restore" 2>&1) | Write-Host

if (-not $ctx.tabid) {
  Write-Host "⚠ 没解析到当前标签页 id。看 ~/.ssh/cc-restore-tab.log 排查(WAVETERM 环境 / blocks-json 字段名)。" -ForegroundColor Yellow
  Start-Sleep 8; exit
}
Write-Host "本标签页 = $($ctx.tabid)" -ForegroundColor DarkGray
$rows = ssh -o BatchMode=yes -o ConnectTimeout=10 $SRV "/usr/local/bin/cc-slugs-by-tab '$($ctx.tabid)'" 2>$null
$slugs = @($rows | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() })
if ($slugs.Count -eq 0) {
  Write-Host "本标签页还没有登记会话。点「新会话」在本页建一个(自动归属本页),之后就能一键恢复。" -ForegroundColor Yellow
  Start-Sleep 6; exit
}
Write-Host "→ 本页恢复 $($slugs.Count) 个终端:" -ForegroundColor Cyan
foreach ($s in $slugs) {
  Write-Host "   • cc-$s"
  (& $wsh run -c "ssh -t $SRV /usr/local/bin/cc-new $s" 2>&1) | Out-File $log -Append -Encoding utf8
}
Write-Host "✓ 本页 $($slugs.Count) 个终端已恢复,各自接回内容。" -ForegroundColor Green
Start-Sleep 3
