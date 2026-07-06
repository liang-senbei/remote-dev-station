# cc-agents-ssh.ps1 — Wave widget「指挥中心(ssh)」:一屏看全部 agent 会话状态,走普通 ssh、不依赖 WSL mosh。
# 服务器侧需有 cc-agents(/usr/local/bin)。面板末尾可输序号跳进某会话。
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$dv = Join-Path $env:USERPROFILE '.ssh\deploy-vars.ps1'
if (-not (Test-Path $dv)) { Write-Host "缺 $dv —— 先跑 wave\install.ps1 或拷 deploy-vars.ps1.example 填 `$SRV" -ForegroundColor Red; exit 1 }
. $dv
ssh -t $SRV "cc-agents"
