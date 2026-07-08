#!/bin/bash
# 一键部署：在一台新 Ubuntu/Debian 服务器上重建这套 远程 Claude Code 环境
set -e
cd "$(dirname "$0")"

# 前置护栏:本脚本假定 Debian/Ubuntu 系(apt)+ x86_64/arm64;可重复运行(各步幂等)
command -v apt-get >/dev/null || { echo "❌ 需要 Debian/Ubuntu 系(apt-get);其它发行版请手动改下面的包管理部分。"; exit 1; }
case "$(uname -m)" in x86_64|aarch64|arm64) ;; *) echo "⚠️ 未在 $(uname -m) 上验证过(设计针对 x86_64/arm64),继续风险自负。";; esac
MODEL="${CLOUD_MODEL:-claude-opus-4-8[1m]}"   # 会话默认模型。客户跑 `CLOUD_MODEL=claude-opus-4-8[1m] ./install.sh` 即全局用该模型(默认 claude-opus-4-8[1m]，通用；特殊模型如 fable-5 普通账号未必有)

echo "[1/7] 安装依赖"
apt-get update -y && apt-get install -y tmux mosh git curl ufw fail2ban python3   # python3:核心自愈(cloud-watchdog/cc-sessions/cc-state/hub)都是 python3,极简镜像可能没有

echo "[2/7] 安装 Claude Code (native)"
command -v claude >/dev/null || curl -fsSL https://claude.ai/install.sh | bash

echo "[3/7] 部署脚本到 ~/.local/bin 和 /usr/local/bin"
mkdir -p ~/.local/bin
mkdir -p /opt/workspace   # 默认工作区根（cloudgo/cloudnewat/cloudtmp 默认在此新建会话）
# 会话系统 + Mac 桥接 + 工具全部装齐（cloudgo / watchdog 自愈 / 会话恢复都依赖它们）
install -m755 bin/* ~/.local/bin/
install -m755 cc-state ~/.local/bin/
install -m755 bin/cloud-boot.sh /usr/local/bin/   # cloud-sessions.service 的 ExecStart 指这里
install -m755 bin/novnc-start.sh bin/cloud-dashboards.sh /usr/local/bin/   # 桌面/看板层 service 的 ExecStart 指这里
install -m755 bin/mosh-server-tmout /usr/local/bin/   # 临时会话(cloudtmp/cloudconn 用 --server=/usr/local/bin/mosh-server-tmout,关了自动销毁)
install -m755 bin/gen-dashboard /usr/local/bin/                      # 项目看板首页生成器(gen-dashboard.service/timer 调它)
install -m755 bin/claude-login-url.sh /usr/local/bin/claude-login-url   # 输出临时公网登录页 URL(客户完成 Claude 无头登录用)
install -m755 hub/hub.sh ~/.local/bin/hub            # 多 cc 会话协同(hub ls/peek/say/iam)
install -m755 windows/server-side/* /usr/local/bin/  # Windows PS 层按 /usr/local/bin 绝对路径 ssh 调用（「按标签页恢复终端」）

echo "[4/7] 部署 tmux 配置 + .bashrc 函数块"
cp tmux.conf ~/.tmux.conf
grep -q "Moshi-CloudCode setup" ~/.bashrc || cat bashrc-cloud-snippet.sh >> ~/.bashrc
mkdir -p ~/.claude
[ -f ~/.claude/settings.json ] || cp claude-config/settings.client.json ~/.claude/settings.json   # 无则铺干净模板(接上 cc-state 自愈钩子,否则会话恢复静默失效);已有则不覆盖
cmp -s claude-config/settings.client.json ~/.claude/settings.json && sed -i "s#/root/\.local/bin/cc-state#$HOME/.local/bin/cc-state#g" ~/.claude/settings.json || true   # 非 root 部署:刚铺的模板里 cc-state 钩子路径写死 /root,换成实际 $HOME(root 下无操作;仅当文件确为我们的模板才动,客户已有配置不碰)
[ -f ~/.claude/CLAUDE.md ] || cp claude-config/CLAUDE.md ~/.claude/CLAUDE.md   # 让服务器上的 Claude 开工前就知道自己能力(hub 通讯 / 反向操作客户本机文件 / 桌面访问 / 会话管理);无则铺,已有不覆盖

echo "[5/7] 安装 systemd 服务（开机恢复 + 每 15s 自愈守护）"
cp systemd/cloud-sessions.service systemd/cloud-watchdog.service systemd/cloud-watchdog.timer /etc/systemd/system/
# 手机 Moshi 单元一并放好；二进制由 moshi-hook update 装、配对后再 enable（见 phone/README.md）
cp systemd/moshi-hook.service systemd/moshi-hook-healthcheck.service systemd/moshi-hook-healthcheck.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now cloud-sessions.service cloud-watchdog.timer   # --now:装完即起,不必等重启(否则核心体检当场红)
systemctl enable --now fail2ban 2>/dev/null || true                  # SSH 防爆破,cloud_infra_check 的核心项
# 把会话模型写进两处关键位置(默认 claude-opus-4-8[1m];客户 CLOUD_MODEL=... 重跑即换成自己账号可用的)
sed -i "s#^CLOUD_MODEL=\"[^\"]*\"#CLOUD_MODEL=\"$MODEL\"#" ~/.bashrc 2>/dev/null || true                                                   # 交互新建会话
sed -i "s#Environment=\"CLOUD_MODEL=[^\"]*\"#Environment=\"CLOUD_MODEL=$MODEL\"#" /etc/systemd/system/cloud-watchdog.service 2>/dev/null || true   # 断电自愈 --resume
systemctl daemon-reload

echo "[6/7] 防火墙基线（放行必要端口并启用）"
ufw allow 22/tcp; ufw allow 60000:61000/udp; ufw allow in on tailscale0
ufw --force enable

echo "[+] noVNC 图形桌面(必装 —— Claude 无头登录 + 服务器桌面 widget 都要用)"
DEBIAN_FRONTEND=noninteractive apt-get install -y xvfb x11vnc novnc websockify xfce4 xfce4-terminal dbus-x11 fonts-noto-cjk 2>/dev/null || echo "⚠️ 部分桌面包装失败,可 apt 手动补"
command -v google-chrome >/dev/null || { curl -fsSL -o /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb && apt-get install -y /tmp/chrome.deb; } 2>/dev/null || echo "⚠️ chrome 装失败(登录页要用),可手动补"
command -v cloudflared >/dev/null || { curl -fsSL -o /tmp/cf.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb && apt-get install -y /tmp/cf.deb; } 2>/dev/null || echo "⚠️ cloudflared 装失败(登录临时公网URL要用)"
cp systemd/novnc.service systemd/cloud-dashboards.service systemd/gen-dashboard.service systemd/gen-dashboard.timer /etc/systemd/system/
mkdir -p /root/inbox/dashboards; /usr/local/bin/gen-dashboard 2>/dev/null || true   # 先生成看板首页,避免 :8088 空目录=白屏
systemctl daemon-reload
systemctl enable --now novnc.service cloud-dashboards.service gen-dashboard.timer 2>/dev/null || echo "⚠️ novnc/dashboards 服务起失败,可 systemctl restart 单独排查"
echo "  → 让客户完成 Claude 登录:跑 claude-login-url 拿到临时公网登录页 URL(登录后 pkill cloudflared 拆掉)。"

echo "[7/7] OOM 硬化（防单个会话内存暴涨拖垮整机）"
bash oom/harden.sh || echo "⚠️ OOM 硬化部分失败（不影响已装好的核心），可单独重跑：bash oom/harden.sh"

echo "完成。后续手动项：① 配 ~/.ssh 密钥与 ~/.ssh/config 的 'mac'（Mac 客户端）/'laptop'（Windows 客户端）别名；② git 身份；③ tailscale up"
echo "注：noVNC 图形桌面层已随本脚本必装并起(novnc.service/:6080 tailnet-only + 项目看板 cloud-dashboards/:8088)。仅 moshi-hook 二进制未装——见 phone/README.md。"
[ "$MODEL" = "claude-opus-4-8[1m]" ] && echo "⚠️ 会话模型仍是默认 claude-opus-4-8[1m]（特殊模型、普通账号未必有）。客户账号若无此模型 → 新建会话/断电自愈会启动即死。改法:CLOUD_MODEL=claude-opus-4-8[1m] ./install.sh 重跑,或手改后 systemctl daemon-reload && systemctl restart cloud-watchdog.timer。"

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
