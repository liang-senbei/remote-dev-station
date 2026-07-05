# cc-launch.ps1 — Wave widget「新会话」:在【当前标签页】新建一个命名的、可恢复的 Claude 会话。
# 会话出生即 `cc-new` 钉死 session-id,并打上"本页 tab"标记(CC_TAB),归「恢复本页」管。
# 依赖:同目录 cc-wave-lib.ps1;服务器侧 cc-new(见 windows/README)。

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8   # ssh/wsh 回传 UTF-8;PS5.1 默认按本地码页(GBK)解码会乱码/坏中文 slug(hotfix,待回写仓库)
$dv = Join-Path $env:USERPROFILE '.ssh\deploy-vars.ps1'   # 个人/客户配置层:提供 $SRV
if (-not (Test-Path $dv)) { Write-Host "缺 $dv —— 先跑 wave\install.ps1 或拷 deploy-vars.ps1.example 填 `$SRV" -ForegroundColor Red; exit 1 }
. $dv
$wsh = Join-Path $env:LOCALAPPDATA 'waveterm\Data\bin\wsh.exe'
$log = Join-Path $env:USERPROFILE '.ssh\cc-restore-tab.log'
. (Join-Path $env:USERPROFILE '.ssh\cc-wave-lib.ps1')

"==== $([DateTime]::Now.ToString('MM-dd HH:mm:ss')) 新会话 ====" | Out-File $log -Append -Encoding utf8
$ctx = Get-WaveTab $wsh $log
$name = Read-Host "本标签页新会话名称(回车=时间戳名)"
if ([string]::IsNullOrWhiteSpace($name)) { $name = 's' + ([DateTime]::Now.ToString('MMddHHmmss')) }
Write-Host "起会话: $name  (归属标签页 $($ctx.tabid))" -ForegroundColor Cyan
ssh -t $SRV "CC_TAB='$($ctx.tabid)' /usr/local/bin/cc-new '$name'"
