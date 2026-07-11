一键部署 · 客户机反向隧道 setup
===============================

作用:在【客户电脑】上跑一条,自动完成——
  ① 开 SSH 服务端(开机自启)
  ② 生成本机 SSH 密钥
  ③ (给了服务器公钥的话)授权服务器回连读文件
  ④ 反向隧道设为开机/登录自启 + 断线自动重连
  ⑤ 打印【本机公钥】(也存到客户桌面 client-pubkey.txt)

用法
----
Windows(管理员 PowerShell,在 windows\ 目录里):
  powershell -NoProfile -ExecutionPolicy Bypass -File .\win-setup-tunnel.ps1 -Server <服务器IP> -ServerPubKey "ssh-ed25519 AAAA... srv"

Mac(终端,在 mac/ 目录里):
  bash mac-setup-tunnel.sh <服务器IP> "ssh-ed25519 AAAA... srv"

参数
----
  <服务器IP>       必填。远程服务器的公网 IP(默认用 root 登录)。
  ServerPubKey    可选但建议。服务器的公钥,用来授权服务器反向读客户文件;
                  没有先不填,拿到后重跑一次带上即可。

跑完要做什么
----------
  把脚本打印的【本机公钥】(client-pubkey.txt)发给部署方 → 部署方加到服务器
  ~/.ssh/authorized_keys。之后隧道自动接通,服务器就能 ssh 进这台客户机 + 取送文件。

具体实例(拿自己笔电连开发服务器 echo-j1 测)
------------------------------------------------
Windows(管理员 PowerShell,在 windows\ 目录):
  powershell -NoProfile -ExecutionPolicy Bypass -File .\win-setup-tunnel.ps1 -Server 38.244.50.74 -ServerPubKey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDmao7a7oisquLnn2b2Z/1FXJiZX8T2nFwXD1bT2zY+U us4-server@echo-j1"

Mac(终端,在 mac/ 目录):
  bash mac-setup-tunnel.sh 38.244.50.74 "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDmao7a7oisquLnn2b2Z/1FXJiZX8T2nFwXD1bT2zY+U us4-server@echo-j1"

  · 38.244.50.74 = 服务器公网 IP;后面那串 = 服务器公钥(填进去脚本自动授权服务器回连)。
  · 真客户部署时:IP 换成客户服务器的、公钥换成那台服务器自己的(每台不同)。

说明
----
  · 隧道用同一把 ~/.ssh/id_ed25519(既登录、又建隧道),不另生成隧道钥匙。
  · Windows 以"当前用户登录时"自启(个人电脑够用);要"没登录也在线"另说。
  · Mac 若没装 autossh,脚本用纯 ssh + launchd KeepAlive 兜底;brew install autossh 更稳。
