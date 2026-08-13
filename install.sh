#!/bin/bash
# 一键部署：在一台新 Ubuntu/Debian 服务器上重建这套 远程 Claude Code 环境
set -e
cd "$(dirname "$0")"

# 前置护栏:本脚本假定 Debian/Ubuntu 系(apt)+ x86_64/arm64;可重复运行(各步幂等)
command -v apt-get >/dev/null || { echo "❌ 需要 Debian/Ubuntu 系(apt-get);其它发行版请手动改下面的包管理部分。"; exit 1; }
case "$(uname -m)" in x86_64|aarch64|arm64) ;; *) echo "⚠️ 未在 $(uname -m) 上验证过(设计针对 x86_64/arm64),继续风险自负。";; esac
MODEL="${CLOUD_MODEL-}"   # 会话模型。【默认留空 = 不钉死】,交给座舱配置(~/.claude/settings.json 的 ANTHROPIC_MODEL)决定 —— 命令行 --model 优先级高于 settings.json,这里一非空,座舱里怎么配都不生效。只有要把全机会话钉死在某个模型上,才 `CLOUD_MODEL=xxx ./install.sh`。
DESKTOP="${CLOUD_DESKTOP:-0}"   # TigerVNC 登录桌面【必装】,不受此开关控;此开关只控【看板/额度 :8088】等非登录 GUI:CLOUD_DESKTOP=1 才装。

echo "== 极简 CLI 版部署 =="
echo "   客户端只需 SSH:装完在本机跑 cli/cloud-connect.sh 即可(生成密钥→推公钥→ssh cloud 直接进 claude)。"
echo "   登录:TigerVNC 桌面必装;客户连 <公网IP>:5901 在服务器桌面的 Chrome 里登录,或跑 claude-login-url 拿【临时公网登录页链接】发给客户。CLOUD_DESKTOP=1 额外装看板(:8088)。"

echo "[1/7] 安装依赖"
apt-get update -y && apt-get install -y tmux mosh git curl ufw fail2ban python3   # python3:核心自愈(cloud-watchdog/cc-sessions/cc-state/hub)都是 python3,极简镜像可能没有

echo "[2/7] 安装 Claude Code (native)"
command -v claude >/dev/null || curl -fsSL https://claude.ai/install.sh | bash
ln -sf "$HOME/.local/bin/claude" /usr/local/bin/claude 2>/dev/null || true   # 软链到 /usr/local/bin:VNC 桌面终端/systemd 上下文 PATH 不含 ~/.local/bin,不软链则桌面里敲 claude 报 command not found(exit127)

echo "[3/7] 部署脚本到 ~/.local/bin 和 /usr/local/bin"
mkdir -p ~/.local/bin
mkdir -p /opt/workspace   # 默认工作区根（cloud-enter 默认在此建常驻会话 cc-main）
# 会话系统 + 工具全部装齐（cloud-enter / watchdog 自愈 / 会话恢复都依赖它们）
install -m755 bin/* ~/.local/bin/
install -m755 cc-state ~/.local/bin/
install -m755 bin/cloud-boot.sh /usr/local/bin/   # cloud-sessions.service 的 ExecStart 指这里
install -m755 bin/cloud-enter /usr/local/bin/     # 客户端 ssh 的 RemoteCommand 指它 → `ssh cloud` 直接进 claude;必须在 /usr/local/bin(非交互 PATH 无 ~/.local/bin)
install -m755 bin/cc-new /usr/local/bin/        # 与 cloud-enter 同理:VNC 桌面终端 / systemd 上下文的 PATH 不含 ~/.local/bin
install -m755 bin/cloud-dashboards.sh /usr/local/bin/   # 看板层 service 的 ExecStart 指这里(桌面层已改用 TigerVNC,由 vncserver 自己拉起,不再需要启动脚本)
install -m755 bin/mosh-server-tmout /usr/local/bin/   # cloudconn 临时 mosh 会话用 --server=/usr/local/bin/mosh-server-tmout(关了自动销毁);极简 SSH 版用不到,留着不碍事
install -m755 bin/gen-dashboard /usr/local/bin/                      # 项目看板首页生成器(gen-dashboard.service/timer 调它)
install -m755 bin/claude-login-url.sh /usr/local/bin/claude-login-url   # 输出临时公网登录页 URL(客户完成 Claude 无头登录用)
install -m755 bin/cc-quota /usr/local/bin/                           # 「5小时额度」看板页生成器(ccusage 算 5h 滚动窗口用量;cc-quota.timer 每分钟刷)
install -m755 hub/hub.sh ~/.local/bin/hub            # 多 cc 会话协同(hub ls/peek/say/iam)
# (极简 CLI 版已移除 Wave「按标签页恢复终端」的服务器助手 windows/server-side/*——纯终端不需要)

# ---- cc 座舱:只让它看见 /opt/workspace ----------------------------------
# 座舱默认调裸 cc-agents = 机器上【所有】会话都进座舱,包括 /root 下站长自己的项目。
# 客户机上这等于把非客户的东西摊给客户看。改由 cc-agents-filtered 供数(上面 bin/* 已装),
# 并把路径写进 Machine settings —— 它优先级【高于】客户本地(Windows/Mac)的用户设置,
# 客户那边怎么配都盖不掉。终端里的 cc-agents / cc-autopilot / 通知不受影响,仍是全量。
echo "[+] cc 座舱:写 Machine settings(座舱只扫 /opt/workspace)"
mkdir -p ~/.vscode-server/data/Machine
python3 - "$HOME/.vscode-server/data/Machine/settings.json" "$HOME/.local/bin/cc-agents-filtered" "$(hostname)" <<'PY' || echo "  → 跳过:现有 settings.json 解析不了(可能带注释/手改过),没敢覆盖 —— 手动加 ccCockpit.ccAgentsPath 即可"
import json, os, sys
p, binpath, host = sys.argv[1], sys.argv[2], sys.argv[3]
cfg = json.load(open(p, encoding="utf-8")) if os.path.exists(p) else {}   # 解析失败=抛异常,走上面的 || 分支,绝不覆盖客户已有配置
cfg.update({"ccCockpit.ccAgentsPath": binpath,
            "ccCockpit.repoRoot": "/opt/workspace",   # Worktrees 视图的根,别让它伸进 /root
            "ccCockpit.host": host})
json.dump(cfg, open(p, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY

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

echo "[+] sshd 幂等确保公钥认证开着"
# ⚠️ 连续多个客户镜像出厂就是 PubkeyAuthentication no(2026-08-03 第四个客户实测:sshd -T 明确吐 no)。
# 后果很隐蔽:部署方把公钥推进 ~/.ssh/authorized_keys、权限内容全对,登录却照样跳过公钥直接要密码,
# 报的还是 "Permission denied (password)" —— 看着像密码错,实则是公钥认证被服务端禁用。
# 只开 Pubkey,【不动 PasswordAuthentication】:改坏了还能用密码进,锁不死自己。
if [ "$(sshd -T 2>/dev/null | awk '/^pubkeyauthentication /{print $2}')" = "no" ]; then
  cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak-$(date +%Y%m%d%H%M%S)"
  sed -i 's/^[[:space:]]*#\?[[:space:]]*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
  grep -qi '^PubkeyAuthentication' /etc/ssh/sshd_config || echo 'PubkeyAuthentication yes' >> /etc/ssh/sshd_config
  # sshd_config.d/ 里的云镜像配置会覆盖主文件(OpenSSH 首次匹配生效,Include 通常在主文件开头),一并清掉
  grep -rlie '^[[:space:]]*PubkeyAuthentication[[:space:]]\+no' /etc/ssh/sshd_config.d/ 2>/dev/null | while read -r f; do
    sed -i 's/^[[:space:]]*PubkeyAuthentication[[:space:]]\+no/PubkeyAuthentication yes/I' "$f"; echo "  → 同时改了 $f"
  done
  if sshd -t 2>/dev/null; then
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
    echo "  → sshd 公钥认证已开启(实际生效值:$(sshd -T 2>/dev/null | awk '/^pubkeyauthentication /{print $2}'))"
  else
    echo "  ⚠️ sshd 配置语法检查未过,【未重启】,原配置仍在跑;请手动看 sshd -t 的报错"
  fi
else
  echo "  → sshd 公钥认证本就是开的,跳过"
fi

echo "[6/7] 防火墙基线（放行必要端口并启用）"
ufw allow 22/tcp; ufw allow 60000:61000/udp; ufw allow in on tailscale0
ufw allow 5901/tcp comment 'tigervnc public'   # 登录桌面走公网:客户 Tailscale 还没配好时也够得着(靠 ~/.vnc/passwd 的 VncAuth 挡)
ufw --force enable

echo "[+] TigerVNC 图形桌面(【必装】—— Claude 登录要用:客户在自己浏览器里操作服务器桌面登录)"
DEBIAN_FRONTEND=noninteractive apt-get install -y tigervnc-standalone-server tigervnc-common tigervnc-tools xfce4 xfce4-terminal dbus-x11 fonts-noto-cjk 2>/dev/null || echo "⚠️ 部分桌面包装失败,可 apt 手动补"
command -v google-chrome >/dev/null || { curl -fsSL -o /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb && apt-get install -y /tmp/chrome.deb; } 2>/dev/null || echo "⚠️ chrome 装失败(登录页要用),可手动补"
command -v cloudflared >/dev/null || { curl -fsSL -o /tmp/cf.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb && apt-get install -y /tmp/cf.deb; } 2>/dev/null || echo "⚠️ cloudflared 装失败(登录临时公网URL要用)"
# ~/.vnc/:几何/安全类型 + 会话脚本(开 xfce 并把 Chrome 停在 claude.com)。已有则不覆盖,免踩客户自己调过的设置。
mkdir -p ~/.vnc
[ -f ~/.vnc/config ]   || cp vnc/config ~/.vnc/config
[ -f ~/.vnc/xstartup ] || install -m755 vnc/xstartup ~/.vnc/xstartup
# VncAuth 密码::5901 走公网,【必须】有密码。无则随机生成一个并打印(客户连桌面时要用);已有不动。
if [ ! -f ~/.vnc/passwd ]; then
  VNCPW="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 8)"
  printf '%s\n' "$VNCPW" | vncpasswd -f > ~/.vnc/passwd && chmod 600 ~/.vnc/passwd
  echo "  ★ VNC 密码(连 <公网IP>:5901 用,请记下并发给客户): $VNCPW"
else
  echo "  → ~/.vnc/passwd 已存在,沿用原密码(忘了就 vncpasswd 重设)"
fi
cp systemd/cloud-vnc.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now cloud-vnc.service 2>/dev/null || echo "⚠️ cloud-vnc 服务起失败,可 systemctl restart cloud-vnc 单独排查(日志在 ~/.vnc/*.log)"
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
if [ "$DESKTOP" = "1" ]; then echo "注:TigerVNC 登录桌面已装并起(cloud-vnc.service/公网 :5901,VncAuth 密码见上);看板 :8088 已装。"
else echo "注:TigerVNC 登录桌面已装并起(cloud-vnc.service/公网 :5901,VncAuth 密码见上);看板 :8088 未装,CLOUD_DESKTOP=1 可加。"; fi
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
