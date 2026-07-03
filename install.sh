#!/bin/bash
# 一键部署：在一台新 Ubuntu/Debian 服务器上重建这套 远程 Claude Code 环境
set -e
cd "$(dirname "$0")"

# 前置护栏:本脚本假定 Debian/Ubuntu 系(apt)+ x86_64/arm64;可重复运行(各步幂等)
command -v apt-get >/dev/null || { echo "❌ 需要 Debian/Ubuntu 系(apt-get);其它发行版请手动改下面的包管理部分。"; exit 1; }
case "$(uname -m)" in x86_64|aarch64|arm64) ;; *) echo "⚠️ 未在 $(uname -m) 上验证过(设计针对 x86_64/arm64),继续风险自负。";; esac
MODEL="${CLOUD_MODEL:-claude-fable-5[1m]}"   # 会话默认模型。客户跑 `CLOUD_MODEL=claude-opus-4-8[1m] ./install.sh` 即全局用该模型(默认 fable-5=作者账号专属,客户多半没有)

echo "[1/6] 安装依赖"
apt-get update -y && apt-get install -y tmux mosh git curl ufw fail2ban python3   # python3:核心自愈(cloud-watchdog/cc-sessions/cc-state/hub)都是 python3,极简镜像可能没有

echo "[2/6] 安装 Claude Code (native)"
command -v claude >/dev/null || curl -fsSL https://claude.ai/install.sh | bash

echo "[3/6] 部署脚本到 ~/.local/bin 和 /usr/local/bin"
mkdir -p ~/.local/bin
mkdir -p /opt/workspace   # 默认工作区根（cloudgo/cloudnewat/cloudtmp 默认在此新建会话）
# 会话系统 + Mac 桥接 + 工具全部装齐（cloudgo / watchdog 自愈 / 会话恢复都依赖它们）
install -m755 bin/* ~/.local/bin/
install -m755 cc-state ~/.local/bin/
install -m755 bin/cloud-boot.sh /usr/local/bin/   # cloud-sessions.service 的 ExecStart 指这里
install -m755 bin/novnc-start.sh bin/cloud-dashboards.sh /usr/local/bin/   # 可选桌面/看板层 service 的 ExecStart 指这里
install -m755 hub/hub.sh ~/.local/bin/hub            # 多 cc 会话协同(hub ls/peek/say/iam)
install -m755 windows/server-side/* /usr/local/bin/  # Windows PS 层按 /usr/local/bin 绝对路径 ssh 调用（「按标签页恢复终端」）

echo "[4/6] 部署 tmux 配置 + .bashrc 函数块"
cp tmux.conf ~/.tmux.conf
grep -q "Moshi-CloudCode setup" ~/.bashrc || cat bashrc-cloud-snippet.sh >> ~/.bashrc
mkdir -p ~/.claude
[ -f ~/.claude/settings.json ] || cp claude-config/settings.client.json ~/.claude/settings.json   # 无则铺干净模板(接上 cc-state 自愈钩子,否则会话恢复静默失效);已有则不覆盖

echo "[5/6] 安装 systemd 服务（开机恢复 + 每 15s 自愈守护）"
cp systemd/cloud-sessions.service systemd/cloud-watchdog.service systemd/cloud-watchdog.timer /etc/systemd/system/
# 手机 Moshi 单元一并放好；二进制由 moshi-hook update 装、配对后再 enable（见 phone/README.md）
cp systemd/moshi-hook.service systemd/moshi-hook-healthcheck.service systemd/moshi-hook-healthcheck.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now cloud-sessions.service cloud-watchdog.timer   # --now:装完即起,不必等重启(否则核心体检当场红)
systemctl enable --now fail2ban 2>/dev/null || true                  # SSH 防爆破,cloud_infra_check 的核心项
# 把会话模型写进两处关键位置(默认 fable-5=作者专属;客户 CLOUD_MODEL=... 重跑即换成自己账号可用的)
sed -i "s#^CLOUD_MODEL=\"[^\"]*\"#CLOUD_MODEL=\"$MODEL\"#" ~/.bashrc 2>/dev/null || true                                                   # 交互新建会话
sed -i "s#Environment=\"CLOUD_MODEL=[^\"]*\"#Environment=\"CLOUD_MODEL=$MODEL\"#" /etc/systemd/system/cloud-watchdog.service 2>/dev/null || true   # 断电自愈 --resume
systemctl daemon-reload

echo "[6/6] 防火墙基线（放行必要端口并启用）"
ufw allow 22/tcp; ufw allow 60000:61000/udp; ufw allow in on tailscale0
ufw --force enable

echo "完成。后续手动项：① 配 ~/.ssh 密钥与 ~/.ssh/config 的 'mac' 别名；② git 身份；③ tailscale up"
echo "注：图形桌面层(noVNC/xfce/Chrome) 与 moshi-hook 二进制未在此安装——按需分别见后续桌面层文档与 phone/README.md。"
[ "$MODEL" = "claude-fable-5[1m]" ] && echo "⚠️ 会话模型仍是默认 claude-fable-5[1m]（作者账号专属）。客户账号若无此模型 → 新建会话/断电自愈会启动即死。改法:CLOUD_MODEL=claude-opus-4-8[1m] ./install.sh 重跑,或手改后 systemctl daemon-reload && systemctl restart cloud-watchdog.timer。"

set +e   # 以下 shell 增强尽力而为,弱网失败也不影响已装好的核心(避免 set -e 让整脚本非零退出)
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
