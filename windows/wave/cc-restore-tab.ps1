# cc-restore-tab.ps1 — Wave widget「恢复本页」:一键复活【当前标签页】的所有 Claude 终端。
# 流程:解析当前 tab → 服务器侧 cc-restore 复活所有 tmux → 取本页会话 → 本块就地 ssh -t 接回(0.14.5 wsh run 不可用)。
# 依赖:同目录的 cc-wave-lib.ps1;服务器侧 cc-restore / cc-slugs-by-tab(见仓库 bin/ 与 windows/README)。
# 注意:本脚本须由 Wave widget 启动(块内才有 WAVETERM_SWAPTOKEN);外部 shell 跑不出 wsh 权限。

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8   # ssh/wsh 回传 UTF-8;PS5.1 默认按本地码页(GBK)解码会乱码/坏中文 slug(hotfix,待回写仓库)
$ErrorActionPreference = 'SilentlyContinue'
$dv = Join-Path $env:USERPROFILE '.ssh\deploy-vars.ps1'   # 个人/客户配置层:提供 $SRV
if (-not (Test-Path $dv)) { Write-Host "缺 $dv —— 先跑 wave\install.ps1 或拷 deploy-vars.ps1.example 填 `$SRV" -ForegroundColor Red; exit 1 }
. $dv
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
# 0.14.5 实测:wsh run 在 cmd 块 JWT 上下文静默失败(rc=1 无输出;与 blocks list 的 no-workspaces 同一路由断点),
# 弹块 API 不可用 → 改为【本块就地接回】第一个会话(与「新会话」同一条已验证的 ssh -t 通路);
# 多会话时其余的点「新会话」输同名即 attach(cc-new 幂等)。
$first = $slugs[0]
if ($slugs.Count -gt 1) {
  Write-Host ("其余 " + ($slugs.Count - 1) + " 个,点「新会话」输同名接回 → " + (($slugs | Select-Object -Skip 1) -join ' / ')) -ForegroundColor Yellow
}
Write-Host "⤷ 本块就地接回 cc-$first(断开后本块结束,再点 widget 即可)" -ForegroundColor Green
ssh -t $SRV "/usr/local/bin/cc-new '$first'"
Start-Sleep 3
