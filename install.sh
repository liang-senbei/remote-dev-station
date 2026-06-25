#!/bin/bash
# 一键部署：在一台新 Ubuntu 服务器上重建这套 远程 Claude Code 环境
set -e
echo "[1/6] 安装依赖"
apt-get update -y && apt-get install -y tmux mosh git curl ufw fail2ban
echo "[2/6] 安装 Claude Code (native)"
command -v claude >/dev/null || curl -fsSL https://claude.ai/install.sh | bash
echo "[3/6] 部署辅助脚本到 ~/.local/bin 和 /usr/local/bin"
mkdir -p ~/.local/bin
install -m755 bin/pullimg bin/macget bin/macput bin/macls ~/.local/bin/
install -m755 bin/cloud-boot.sh /usr/local/bin/
echo "[4/6] 部署 tmux 配置 + .bashrc 函数块"
cp tmux.conf ~/.tmux.conf
grep -q "Moshi-CloudCode setup" ~/.bashrc || cat bashrc-cloud-snippet.sh >> ~/.bashrc
echo "[5/6] 安装 systemd 服务（开机自动恢复 Claude 会话）"
cp systemd/cloud-sessions.service /etc/systemd/system/
cp systemd/cloud-outbox.service /etc/systemd/system/
systemctl daemon-reload && systemctl enable cloud-sessions.service cloud-outbox.service
echo "[6/6] 防火墙基线（仅放行必要端口）"
ufw allow 22/tcp; ufw allow 60000:61000/udp; ufw allow in on tailscale0
echo "完成。记得：① 配 ~/.ssh 密钥与 ~/.ssh/config 的 'mac' 别名；② git 身份；③ tailscale up"

# ---- Shell 增强 (fzf + starship + ble.sh) ----
echo "[+] 安装 shell 增强"
add-apt-repository -y universe 2>/dev/null || true
apt-get update -y && apt-get install -y fzf || true
command -v starship >/dev/null || curl -fsSL https://starship.rs/install.sh | sh -s -- -y
if [ ! -d ~/.local/share/blesh ]; then
  curl -fL --retry 5 -o /tmp/blesh.tar.xz https://github.com/akinomyoga/ble.sh/releases/download/nightly/ble-nightly.tar.xz \
    && tar xJf /tmp/blesh.tar.xz -C /tmp && mv /tmp/ble-nightly ~/.local/share/blesh
fi
grep -q "Shell 增强" ~/.bashrc || cat bashrc-shell-enhance.sh >> ~/.bashrc
