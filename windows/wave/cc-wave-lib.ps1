# cc-wave-lib.ps1 — 在 Wave 「块内」解析当前上下文(blockid / tabid),并把一次性
# WAVETERM_SWAPTOKEN 换成 WAVETERM_JWT,让随后的 wsh 命令有权限。
#
# 背景:Wave 的 controller:cmd 块不会走 shell 集成,只有一次性 WAVETERM_SWAPTOKEN;
#       官方换法 = `wsh token <swaptoken> <shell>`,SWAPTOKEN 只能换一次,只调一次、正则抠 JWT。
#
# 2026-07-06 hotfix(BoomAsset,待回写仓库):Wave 0.14.5 上 `wsh blocks list` 报
#   "no workspaces found",swaptoken rpccontext 也无 tabid(仅 sockname/routeid/procroute/blockid)
#   → 原生 tabid 取不到。改为三层:
#   ①(主路)tab 级持久变量 CC_TABID(wsh getvar/setvar -b tab):同页所有块共享、跨 Wave 重启
#     稳定;首次使用生成 uuid 写入。账本侧 tab 本就是不透明字符串,服务器零改动。
#   ②(兜底)旧 blocks list 匹配(兼容老 Wave)。
#   ③ 全程 LL 日志,失败可从 ~/.ssh/cc-restore-tab.log 直接定位。
#
# 用法(不变):
#   . (Join-Path $env:USERPROFILE '.ssh\cc-wave-lib.ps1')
#   $ctx = Get-WaveTab $wshExe $logPath   # -> .blockid / .tabid,并已 set $env:WAVETERM_JWT

function Get-WaveTab {
  param([string]$wsh, [string]$log)
  function LL($m) { if ($log) { "$([DateTime]::Now.ToString('HH:mm:ss')) [lib] $m" | Out-File $log -Append -Encoding utf8 } }
  $r = [pscustomobject]@{ blockid = ''; tabid = '' }
  $swap = $env:WAVETERM_SWAPTOKEN
  if (-not $swap -and -not $env:WAVETERM_JWT) { LL 'no WAVETERM_SWAPTOKEN/JWT (不在 Wave 块内?)'; return $r }
  # 1) blockid 直接从 SWAPTOKEN 解(base64 -> json.rpccontext.blockid),不依赖 wsh
  if ($swap) {
    try {
      $ctx = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($swap)) | ConvertFrom-Json
      $r.blockid = $ctx.rpccontext.blockid
      $env:WAVETERM_BLOCKID = $r.blockid
      LL ("rpccontext-keys=" + (($ctx.rpccontext.PSObject.Properties.Name) -join ','))
    } catch { LL "decode swaptoken 失败 $_" }
  }
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
  # 3)【主路】tab 级持久变量 CC_TABID 当"本页身份"
  try {
    $tv = (& $wsh getvar -b tab 'CC_TABID' 2>&1 | Out-String).Trim()
    LL "getvar[tab]CC_TABID=<$tv>"
    if ($tv -match '^[0-9a-f\-]{36}$') { $r.tabid = $tv }
    elseif ($tv -notmatch 'rror|sage:') {
      $new = [guid]::NewGuid().ToString()
      $so = (& $wsh setvar -b tab "CC_TABID=$new" 2>&1 | Out-String).Trim()
      LL "setvar[tab]CC_TABID=$new -> <$so>"
      $chk = (& $wsh getvar -b tab 'CC_TABID' 2>&1 | Out-String).Trim()
      if ($chk -eq $new) { $r.tabid = $new } else { LL "setvar 回读不一致 <$chk>" }
    }
  } catch { LL "tab 变量路失败 $_" }
  # 4)【兜底】旧 blocks list 匹配 blockid -> tabid(0.14.5 已知报 no workspaces,保留兼容老版本)
  if (-not $r.tabid) {
    try {
      $bl = & $wsh blocks list --json 2>&1 | Out-String
      LL "blocks-json=$bl"
      $arr = $bl | ConvertFrom-Json
      foreach ($b in $arr) {
        $bid = $b.blockid; if (-not $bid) { $bid = $b.oid }; if (-not $bid) { $bid = $b.id }
        if ($bid -eq $r.blockid) { $r.tabid = $b.tabid; if (-not $r.tabid) { $r.tabid = $b.tab }; break }
      }
    } catch { LL "blocks list 失败 $_" }
  }
  LL "tabid=$($r.tabid)"
  return $r
}
