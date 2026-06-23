# install.ps1 — 在 Windows 笔电上安装 Wave「新会话/恢复本页」一键恢复层。
# 干两件事(都遵守编码铁律):
#   1) 把同目录三个 .ps1 复制到 %USERPROFILE%\.ssh\,写成 UTF-8【带 BOM】(PS5.1 才认中文)。
#   2) 把两个 widget 合并进 Wave widgets.json,写成 UTF-8【无 BOM】(Wave 带 BOM 会解析失败 → widget 全空)。
# 幂等:widgets.json 已有 cc-restore-tab 就跳过插入。改前自动备份。
# 用法(在本目录下):  powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1

$ErrorActionPreference = 'Stop'
$bom    = New-Object System.Text.UTF8Encoding($true)    # 带 BOM
$noBom  = New-Object System.Text.UTF8Encoding($false)   # 无 BOM
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$sshDir = Join-Path $env:USERPROFILE '.ssh'
New-Item -ItemType Directory -Force -Path $sshDir | Out-Null

# 1) 三个脚本 → ~/.ssh\,带 BOM
foreach ($f in 'cc-wave-lib.ps1','cc-restore-tab.ps1','cc-launch.ps1') {
  $src = Join-Path $here $f
  $dst = Join-Path $sshDir $f
  $txt = [IO.File]::ReadAllText($src, [Text.Encoding]::UTF8)
  [IO.File]::WriteAllText($dst, $txt, $bom)
  Write-Host "✓ 安装 $dst (UTF-8 BOM)" -ForegroundColor Green
}

# 2) 合并 widgets.json,无 BOM
$wp = Join-Path $env:USERPROFILE '.config\waveterm\widgets.json'
if (-not (Test-Path $wp)) { Write-Host "找不到 $wp —— 先装/开一次 Wave Terminal。" -ForegroundColor Yellow; exit 1 }
$raw = [IO.File]::ReadAllText($wp, [Text.Encoding]::UTF8)
if ($raw -match '"cc-restore-tab"') {
  Write-Host "= widgets.json 已含 cc-restore-tab,跳过(幂等)" -ForegroundColor DarkGray
} else {
  Copy-Item $wp ("$wp.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
  $up = ($env:USERPROFILE).Replace('\','\\')
  $ins = @"
  "cc-launch": {
    "display:order": -3,
    "icon": "plus",
    "label": "新会话",
    "color": "#9ece6a",
    "description": "在本标签页新建命名的可恢复 Claude 会话",
    "blockdef": { "meta": {
      "view": "term", "controller": "cmd",
      "cmd": "powershell -NoProfile -ExecutionPolicy Bypass -File ${up}\\.ssh\\cc-launch.ps1",
      "cmd:interactive": true
    } }
  },
  "cc-restore-tab": {
    "display:order": -2,
    "icon": "rotate",
    "label": "恢复本页",
    "color": "#ea9a97",
    "description": "一键复活并在本标签页弹出属于本页的全部 Claude 终端",
    "blockdef": { "meta": {
      "view": "term", "controller": "cmd",
      "cmd": "powershell -NoProfile -ExecutionPolicy Bypass -File ${up}\\.ssh\\cc-restore-tab.ps1",
      "cmd:interactive": true
    } }
  },
"@
  $idx = $raw.IndexOf('{')
  $new = $raw.Substring(0, $idx + 1) + "`r`n" + $ins + $raw.Substring($idx + 1)
  $null = $new | ConvertFrom-Json   # 校验合法再写
  [IO.File]::WriteAllText($wp, $new, $noBom)
  $b = [IO.File]::ReadAllBytes($wp)[0..2]
  Write-Host "✓ widgets.json 已插入 新会话+恢复本页(首字节 $($b -join ',') 应非 239,187,191)" -ForegroundColor Green
}
Write-Host "完成。改服务器地址:编辑 ~/.ssh\cc-restore-tab.ps1 与 cc-launch.ps1 顶部的 `$SRV。" -ForegroundColor Cyan
