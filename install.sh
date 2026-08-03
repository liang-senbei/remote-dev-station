#!/bin/bash
# 一键部署：在一台新 Ubuntu/Debian 服务器上重建这套 远程 Claude Code 环境
set -e
cd "$(dirname "$0")"

# 前置护栏:本脚本假定 Debian/Ubuntu 系(apt)+ x86_64/arm64;可重复运行(各步幂等)
command -v apt-get >/dev/null || { echo "❌ 需要 Debian/Ubuntu 系(apt-get);其它发行版请手动改下面的包管理部分。"; exit 1; }
case "$(uname -m)" in x86_64|aarch64|arm64) ;; *) echo "⚠️ 未在 $(uname -m) 上验证过(设计针对 x86_64/arm64),继续风险自负。";; esac
MODEL="${CLOUD_MODEL-}"   # 会话模型。【默认留空 = 不钉死】,交给座舱配置(~/.claude/settings.json 的 ANTHROPIC_MODEL)决定 —— 命令行 --model 优先级高于 settings.json,这里一非空,座舱里怎么配都不生效。只有要把全机会话钉死在某个模型上,才 `CLOUD_MODEL=xxx ./install.sh`。
DESKTOP="${CLOUD_DESKTOP:-0}"   # noVNC(登录用)【必装】;此开关只控【看板/额度 :8088】等非登录 GUI:CLOUD_DESKTOP=1 才装。

echo "== 极简 CLI 版部署 =="
echo "   客户端只需 SSH:装完在本机跑 cli/cloud-connect.sh 即可(生成密钥→推公钥→ssh cloud 直接进 claude)。"
echo "   登录:noVNC 必装;装完在服务器跑 claude-login-url 拿【公网登录页链接】发给客户,客户浏览器打开登录。CLOUD_DESKTOP=1 额外装看板(:8088)。"

echo "[1/7] 安装依赖"
apt-get update -y && apt-get install -y tmux mosh git curl ufw fail2ban python3   # python3:核心自愈(cloud-watchdog/cc-sessions/cc-state/hub)都是 python3,极简镜像可能没有

echo "[2/7] 安装 Claude Code (native)"
command -v claude >/dev/null || curl -fsSL https://claude.ai/install.sh | bash
ln -sf "$HOME/.local/bin/claude" /usr/local/bin/claude 2>/dev/null || true   # 软链到 /usr/local/bin:noVNC 桌面终端/systemd 上下文 PATH 不含 ~/.local/bin,不软链则桌面里敲 claude 报 command not found(exit127)

echo "[3/7] 部署脚本到 ~/.local/bin 和 /usr/local/bin"
mkdir -p ~/.local/bin
mkdir -p /opt/workspace   # 默认工作区根（cloud-enter 默认在此建常驻会话 cc-main）
# 会话系统 + 工具全部装齐（cloud-enter / watchdog 自愈 / 会话恢复都依赖它们）
install -m755 bin/* ~/.local/bin/
install -m755 cc-state ~/.local/bin/
install -m755 bin/cloud-boot.sh /usr/local/bin/   # cloud-sessions.service 的 ExecStart 指这里
install -m755 bin/cloud-enter /usr/local/bin/     # 客户端 ssh 的 RemoteCommand 指它 → `ssh cloud` 直接进 claude;必须在 /usr/local/bin(非交互 PATH 无 ~/.local/bin)
install -m755 bin/cc-new /usr/local/bin/        # 与 cloud-enter 同理:noVNC 桌面终端 / systemd 上下文的 PATH 不含 ~/.local/bin
install -m755 bin/novnc-start.sh bin/cloud-dashboards.sh /usr/local/bin/   # 桌面/看板层 service 的 ExecStart 指这里
install -m755 bin/mosh-server-tmout /usr/local/bin/   # cloudconn 临时 mosh 会话用 --server=/usr/local/bin/mosh-server-tmout(关了自动销毁);极简 SSH 版用不到,留着不碍事
install -m755 bin/gen-dashboard /usr/local/bin/                      # 项目看板首页生成器(gen-dashboard.service/timer 调它)
install -m755 bin/claude-login-url.sh /usr/local/bin/claude-login-url   # 输出临时公网登录页 URL(客户完成 Claude 无头登录用)
install -m755 bin/cc-quota /usr/local/bin/                           # 「5小时额度」看板页生成器(ccusage 算 5h 滚动窗口用量;cc-quota.timer 每分钟刷)
install -m755 hub/hub.sh ~/.local/bin/hub            # 多 cc 会话协同(hub ls/peek/say/iam)
# (极简 CLI 版已移除 Wave「按标签页恢复终端」的服务器助手 windows/server-side/*——纯终端不需要)

echo "[4/7] 部署 tmux 配置 + .bashrc 函数块"
cp tmux.conf ~/.tmux.conf
grep -q "Moshi-CloudCode setup" ~/.bashrc || cat bashrc-cloud-snippet.sh >> ~/.bashrc
mkdir -p ~/.claude
[ -f ~/.claude/settings.json ] || cp claude-config/settings.client.json ~/.claude/settings.json   # 无则铺干净模板(接上 cc-state 自愈钩子,否则会话恢复静默失效);已有则不覆盖
cmp -s claude-config/settings.client.json ~/.claude/settings.json && sed -i "s#/root/\.local/bin/cc-state#$HOME/.local/bin/cc-state#g" ~/.claude/settings.json || true   # 非 root 部署:刚铺的模板里 cc-state 钩子路径写死 /root,换成实际 $HOME(root 下无操作;仅当文件确为我们的模板才动,客户已有配置不碰)
[ -f ~/.claude/CLAUDE.md ] || cp claude-config/CLAUDE.md ~/.claude/CLAUDE.md
mkdir -p ~/.claude/hooks && for h in claude-config/hooks/*; do [ -f "$h" ] && [ ! -f ~/.claude/hooks/"$(basename "$h")" ] && install -m755 "$h" ~/.claude/hooks/; done   # 铺钩子脚本(已有的不覆盖)。注意:只放脚本、【不动 settings.json】——接线是显式动作,hub 闸门跑 `python3 claude-config/enable-hub-gate.py` 才生效(见 DEPLOY.md)   # 让服务器上的 Claude 开工前就知道自己能力(hub 通讯 / 反向操作客户本机文件 / 桌面访问 / 会话管理);无则铺,已有不覆盖

echo "[5/7] 安装 systemd 服务（开机恢复 + 每 15s 自愈守护）"
cp systemd/cloud-sessions.service systemd/cloud-watchdog.service systemd/cloud-watchdog.timer /etc/systemd/system/
cp systemd/cc-autopilot.service systemd/cc-autopilot.timer /etc/systemd/system/   # 任务看板自动督促(空闲提醒/定时继续),空配置=不动作,安全常驻
# (极简 CLI 版不带手机 Moshi:如需再手动 cp systemd/moshi-hook*.service 并按 phone/README.md 配对)
systemctl daemon-reload
systemctl enable --now cloud-sessions.service cloud-watchdog.timer   # --now:装完即起,不必等重启(否则核心体检当场红)
systemctl enable --now cc-autopilot.timer 2>/dev/null || true        # 每5min 跑 cc-autopilot;没在座舱开任何自动驾驶开关时它静默退出、不会乱发
systemctl enable --now fail2ban 2>/dev/null || true                  # SSH 防爆破,cloud_infra_check 的核心项
# 模型只在【显式指定 CLOUD_MODEL】时才钉死进两处关键位置;默认留空 = 两处都保持空,模型由座舱配置(settings.json 的 ANTHROPIC_MODEL)说了算。
# ⚠️ 曾经这里无条件 sed 成 claude-opus-4-8[1m],把 bashrc-cloud-snippet.sh 里的空值又改回写死 —— 座舱配置页因此对新装的机器一律不生效(2026-08-03 在三台现网客户机实测坐实)。
if [ -n "$MODEL" ]; then
  sed -i "s#^CLOUD_MODEL=\"[^\"]*\"#CLOUD_MODEL=\"$MODEL\"#" ~/.bashrc 2>/dev/null || true                                                   # 交互新建会话
  sed -i "s@^#\?Environment=\"CLOUD_MODEL=[^\"]*\"@Environment=\"CLOUD_MODEL=$MODEL\"@" /etc/systemd/system/cloud-watchdog.service 2>/dev/null || true   # 断电自愈 --resume;`#\?` 连注释态那行一起匹配并【取消注释】——否则只改到注释里的字样,watchdog 实际根本没拿到该模型
  echo "  → 会话模型已钉死为 $MODEL(座舱配置页将不生效)"
else
  echo "  → 会话模型未钉死,由座舱配置(~/.claude/settings.json 的 ANTHROPIC_MODEL)决定"
fi
systemctl daemon-reload

echo "[6/7] 防火墙基线（放行必要端口并启用）"
ufw allow 22/tcp; ufw allow 60000:61000/udp; ufw allow in on tailscale0
ufw --force enable

echo "[+] noVNC 图形桌面(【必装】—— Claude 登录要用:客户在自己浏览器里操作服务器桌面登录)"
DEBIAN_FRONTEND=noninteractive apt-get install -y xvfb x11vnc novnc websockify xfce4 xfce4-terminal dbus-x11 fonts-noto-cjk 2>/dev/null || echo "⚠️ 部分桌面包装失败,可 apt 手动补"
command -v google-chrome >/dev/null || { curl -fsSL -o /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb && apt-get install -y /tmp/chrome.deb; } 2>/dev/null || echo "⚠️ chrome 装失败(登录页要用),可手动补"
command -v cloudflared >/dev/null || { curl -fsSL -o /tmp/cf.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb && apt-get install -y /tmp/cf.deb; } 2>/dev/null || echo "⚠️ cloudflared 装失败(登录临时公网URL要用)"
cp systemd/novnc.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now novnc.service 2>/dev/null || echo "⚠️ novnc 服务起失败,可 systemctl restart novnc 单独排查"
if [ "$DESKTOP" = "1" ]; then   # 看板/额度(:8088)非登录必需,仅 CLOUD_DESKTOP=1 装
  echo "  [+] 附加:项目看板 + 额度页(:8088)"
  cp systemd/cloud-dashboards.service systemd/gen-dashboard.service systemd/gen-dashboard.timer systemd/cc-quota.service systemd/cc-quota.timer /etc/systemd/system/
  mkdir -p /root/inbox/dashboards; /usr/local/bin/gen-dashboard 2>/dev/null || true   # 先生成看板首页,避免 :8088 空目录=白屏
  systemctl daemon-reload
  systemctl enable --now cloud-dashboards.service gen-dashboard.timer cc-quota.timer 2>/dev/null || echo "⚠️ 看板服务起失败,可 systemctl restart 单独排查"
fi
echo "  → 让客户完成 Claude 登录:在服务器跑 claude-login-url 拿到【临时公网登录页 URL】,发给客户在自己浏览器打开登录;登录后 pkill cloudflared 拆掉。"

echo "[7/7] OOM 硬化（防单个会话内存暴涨拖垮整机）"
bash oom/harden.sh || echo "⚠️ OOM 硬化部分失败（不影响已装好的核心），可单独重跑：bash oom/harden.sh"

echo "完成。后续:① 服务器跑 claude-login-url 拿公网登录页链接发客户,完成 Claude 登录(登录后 pkill cloudflared);② 在【本机】跑 cli/cloud-connect.sh <服务器IP> 建免密,之后 ssh cloud 直接进 claude(反向加 --reverse);③ git 身份;④(可选)tailscale up。"
if [ "$DESKTOP" = "1" ]; then echo "注:noVNC 登录桌面已装并起(novnc.service/:6080 tailnet-only);看板 :8088 已装。"
else echo "注:noVNC 登录桌面已装并起(novnc.service/:6080 tailnet-only);看板 :8088 未装,CLOUD_DESKTOP=1 可加。"; fi
if [ -n "$MODEL" ]; then echo "⚠️ 会话模型被钉死为 $MODEL —— 座舱配置页改模型将【不生效】(命令行 --model 优先级高于 settings.json)。客户账号若无此模型 → 新建会话/断电自愈启动即死。解开:把 ~/.bashrc 的 CLOUD_MODEL 改回空 + 注释掉 cloud-watchdog.service 里的 Environment=CLOUD_MODEL,然后 systemctl daemon-reload && systemctl restart cloud-watchdog.timer。"
else echo "注:会话模型未钉死 —— 在座舱「配置」页设【默认兜底模型】(写进 ~/.claude/settings.json 的 ANTHROPIC_MODEL)即全局生效,改一处即可。"; fi   # 注意用 if 而非 `[ ] && echo`:后者条件不成立时返回 1,在 set -e 下会让脚本【就此退出】,后面的 shell 增强全装不上

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
