#!/bin/bash
# 打印「让客户完成 Claude 登录」所需的全部信息,直接发给客户即可。
#
# 历史:此脚本原本是用 cloudflared 把 noVNC 的 :6080 网页临时开到公网 —— 因为老方案 noVNC 只绑
# tailscale IP,而客户第一次要用桌面恰恰是为了登录、那时还没配好 tailnet,够不着。
# 2026-08 桌面层换成 TigerVNC 后,:5901 本来就开在公网(靠 VncAuth 密码挡),这个前提消失了;
# 且 cloudflared 隧穿的是 HTTP,裸 VNC 协议走不了。所以这里改成直接输出直连指引。
set -u
echo "=== 让客户完成 Claude 登录 ==="

if ! systemctl is-active --quiet cloud-vnc.service; then
  echo "⚠️ cloud-vnc.service 没在跑,先拉起来:"
  echo "   systemctl start cloud-vnc.service   # 起不来看 ~/.vnc/*.log"
  systemctl start cloud-vnc.service 2>/dev/null && echo "   (已尝试启动)" || true
fi

PUB_IP="$(curl -fsS -m 5 https://api.ipify.org 2>/dev/null || ip -4 route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}')"
PUB_IP="${PUB_IP:-<服务器公网IP>}"

echo
echo "① 客户装任意 VNC 客户端(RealVNC Viewer / TightVNC / macOS 自带「屏幕共享」均可)"
echo "② 连接地址: ${PUB_IP}:5901"
echo "③ 密码:     部署时 install.sh 打印的那串(存在 ~/.vnc/passwd;忘了就 vncpasswd 重设 + systemctl restart cloud-vnc)"
echo "④ 连上后桌面里 Chrome 已停在 claude.com —— 让客户在里面登录自己的 Claude 账号"
echo "   (走的是本服务器的干净 IP,国内 IP 直连 claude.com 登录常被拦;凭据落盘后会话免登)"
echo
echo "状态自检:"
echo "  cloud-vnc.service : $(systemctl is-active cloud-vnc.service 2>&1)"
echo "  5901 监听         : $(ss -ltn 2>/dev/null | grep -c ':5901') 处"
echo "  ~/.vnc/passwd     : $([ -f ~/.vnc/passwd ] && echo '已设置' || echo '❌ 缺失!公网口没密码,先 vncpasswd')"
echo "  ufw 5901          : $(ufw status 2>/dev/null | grep -c '5901')  处放行规则"
echo
echo "⚠️ VNC 画面/键盘是明文过网。登录是一次性动作,登完日常走 SSH;要更稳可让客户走 SSH 隧道"
echo "   (ssh -L 5901:localhost:5901 root@${PUB_IP} 后连 localhost:5901),细节见 docs/desktop-layer.md §3。"
