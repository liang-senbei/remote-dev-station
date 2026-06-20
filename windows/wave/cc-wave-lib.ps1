# cc-wave-lib.ps1 — 在 Wave 「块内」解析当前上下文(blockid / tabid),并把一次性
# WAVETERM_SWAPTOKEN 换成 WAVETERM_JWT,让随后的 wsh 命令有权限。
#
# 背景:Wave 的 controller:cmd 块(我们用来跑 PowerShell 脚本的那种)不会走 Wave 的
#       shell 集成,所以拿不到换好的 WAVETERM_JWT,只有一次性的 WAVETERM_SWAPTOKEN。
#       官方换法 = `wsh token <swaptoken> <shell>` 返回一段 shell 初始化脚本(里面含 JWT)。
#       SWAPTOKEN 只能换一次,所以这里只调用一次、用正则把 JWT 值抠出来(值与 shell 无关)。
#
# 用法:在脚本里 dot-source 后调用
#   . (Join-Path $env:USERPROFILE '.ssh\cc-wave-lib.ps1')
#   $ctx = Get-WaveTab $wshExe $logPath   # -> .blockid / .tabid,并已 set $env:WAVETERM_JWT

function Get-WaveTab {
  param([string]$wsh, [string]$log)
  function LL($m) { if ($log) { "$([DateTime]::Now.ToString('HH:mm:ss')) [lib] $m" | Out-File $log -Append -Encoding utf8 } }
  $r = [pscustomobject]@{ blockid = ''; tabid = '' }
  $swap = $env:WAVETERM_SWAPTOKEN
  if (-not $swap) { LL 'no WAVETERM_SWAPTOKEN (不在 Wave 块内?)'; return $r }
  # 1) blockid 直接从 SWAPTOKEN 解(base64 -> json.rpccontext.blockid),不依赖 wsh
  try {
    $ctx = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($swap)) | ConvertFrom-Json
    $r.blockid = $ctx.rpccontext.blockid
    $env:WAVETERM_BLOCKID = $r.blockid
  } catch { LL "decode swaptoken 失败 $_" }
  LL "blockid=$($r.blockid)"
  # 2) 一次性换 JWT(bash 格式输出最稳;只抠值)
  if (-not $env:WAVETERM_JWT) {
    try {
      $init = & $wsh token $swap bash 2>&1 | Out-String
      LL "token-init-len=$($init.Length)"
      if ($init -match 'WAVETERM_JWT["\s:=]+([A-Za-z0-9_.\-]+)') {
        $env:WAVETERM_JWT = $matches[1]; LL "JWT set len=$($env:WAVETERM_JWT.Length)"
      } else { LL "JWT 不在 init 输出里 >>> $init" }
    } catch { LL "wsh token 失败 $_" }
  }
  # 3) 用 blocks list 找到自己那条 -> tabid
  try {
    $bl = & $wsh blocks list --json 2>&1 | Out-String
    LL "blocks-json=$bl"
    $arr = $bl | ConvertFrom-Json
    foreach ($b in $arr) {
      $bid = $b.blockid; if (-not $bid) { $bid = $b.oid }; if (-not $bid) { $bid = $b.id }
      if ($bid -eq $r.blockid) { $r.tabid = $b.tabid; if (-not $r.tabid) { $r.tabid = $b.tab }; break }
    }
  } catch { LL "blocks list 失败 $_" }
  LL "tabid=$($r.tabid)"
  return $r
}
