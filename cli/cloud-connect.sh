#!/usr/bin/env bash
# cloud-connect —— 客户端一条命令接入远程 Claude Code(极简 CLI 版,无需 Wave)
#
#   在你【本机】(Mac / Linux / WSL)跑一次即可:
#     ./cloud-connect.sh <服务器IP> [用户=root] [--reverse]
#
#   它做三件事,全部幂等(重复跑安全):
#     ① 本机没有 SSH 密钥就生成一把(~/.ssh/id_ed25519)
#     ② 把【本机公钥】推到【服务器】authorized_keys → 以后免密登录       ← 登录靠这个方向
#     ③ 写 ~/.ssh/config 的 'cloud' 别名(带 RemoteCommand)→ 之后 `ssh cloud` 直接进 claude
#
#   --reverse 额外做【反向隧穿】的密钥:把【服务器公钥】取回放进【本机】
#     authorized_keys,并尽量把本机 SSH(远程登录)打开 → 服务器能反向操作你本机。 ← 反向靠这个方向(与①相反)
#
#   之后每次进 Claude:直接  ssh cloud   (无需子命令,claude 自动打开;断线重连接回同一会话)
set -euo pipefail

SERVER="${1:-}"; USER_="${2:-root}"; REVERSE=0
for a in "$@"; do [ "$a" = "--reverse" ] && REVERSE=1; done
case "${USER_}" in --*) USER_=root;; esac   # 第2位若是 --reverse 而非用户名,回落 root
[ -n "$SERVER" ] || { echo "用法: $0 <服务器IP> [用户=root] [--reverse]"; exit 1; }

KEY="$HOME/.ssh/id_ed25519"
ALIAS="cloud"

echo "① 本机 SSH 密钥"
if [ ! -f "$KEY" ]; then
  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
  ssh-keygen -t ed25519 -N "" -f "$KEY" -C "cloud-connect@$(hostname 2>/dev/null || echo local)"
  echo "  → 新生成 $KEY"
else
  echo "  → 已有 $KEY,复用"
fi

echo "② 把本机公钥推到服务器(首次会让你输一次服务器密码)"
# 优先 ssh-copy-id;没有就手动 append(两者都幂等,不会重复写同一把钥匙)
if command -v ssh-copy-id >/dev/null 2>&1; then
  ssh-copy-id -i "${KEY}.pub" "${USER_}@${SERVER}"
else
  PUB="$(cat "${KEY}.pub")"
  ssh "${USER_}@${SERVER}" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && grep -qxF '$PUB' ~/.ssh/authorized_keys || echo '$PUB' >> ~/.ssh/authorized_keys"
fi
echo "  → 完成,以后免密"

echo "③ 写 ~/.ssh/config 的 '${ALIAS}' 别名"
CFG="$HOME/.ssh/config"; touch "$CFG"; chmod 600 "$CFG"
if grep -qE "^Host[[:space:]]+${ALIAS}\$" "$CFG"; then
  echo "  → 已有 Host ${ALIAS},不动(如需改指向请手动编辑 $CFG)"
else
  {
    echo ""
    echo "Host ${ALIAS}   # remote-dev-station · cloud-connect 自动写入"
    echo "    HostName ${SERVER}"
    echo "    User ${USER_}"
    echo "    IdentityFile ${KEY}"
    echo "    IdentitiesOnly yes"
    echo "    ServerAliveInterval 30"
    echo "    RequestTTY yes"
    echo "    RemoteCommand cloud-enter"
  } >> "$CFG"
  echo "  → 已写入(RemoteCommand cloud-enter → 以后 ssh ${ALIAS} 直接进 claude)"
  echo "     管理员要裸 shell:  ssh ${ALIAS} -o RemoteCommand=none -t bash"
fi

if [ "$REVERSE" = "1" ]; then
  echo "④ 反向隧穿:取服务器公钥 → 放进本机 authorized_keys"
  SRV_PUB="$(ssh "${ALIAS}" 'cat ~/.ssh/id_ed25519.pub 2>/dev/null || (ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519 >/dev/null 2>&1; cat ~/.ssh/id_ed25519.pub)')"
  if [ -n "$SRV_PUB" ]; then
    mkdir -p "$HOME/.ssh"; touch "$HOME/.ssh/authorized_keys"; chmod 600 "$HOME/.ssh/authorized_keys"
    grep -qxF "$SRV_PUB" "$HOME/.ssh/authorized_keys" || echo "$SRV_PUB" >> "$HOME/.ssh/authorized_keys"
    echo "  → 服务器公钥已加入本机 authorized_keys"
  else
    echo "  ⚠️ 没取到服务器公钥,反向先跳过(可稍后手动)"
  fi
  # 尽量打开本机 SSH(远程登录),各平台不同,失败只提示不中断
  case "$(uname -s)" in
    Darwin) echo "  → Mac:请到「系统设置 → 通用 → 共享 → 远程登录」打开(需你手动授权,脚本不代改系统设置)";;
    Linux)  sudo systemctl enable --now ssh 2>/dev/null || sudo systemctl enable --now sshd 2>/dev/null || echo "  → Linux:请确保本机 sshd 已开(systemctl enable --now ssh)";;
    *)      echo "  → 本机 SSH 服务请按平台手动开启";;
  esac
  echo "  → 反向连通还需服务器侧知道你本机地址:在服务器 ~/.ssh/config 建一个指向本机 IP 的别名(见 CLI-DEPLOY.md『反向隧穿』)"
fi

echo ""
echo "✅ 完成。进 Claude:  ssh ${ALIAS}   (claude 自动打开;断线重连接回同一会话)"
echo "   现在就进 → 回车;不进 → Ctrl-C"
read -r _ || exit 0
exec ssh "${ALIAS}"
