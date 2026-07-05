#!/bin/bash
# 项目看板门户:只在本机 Tailscale IP 上服务 /root/inbox/dashboards(自动取 IP、tailnet-only)。
# cloud-dashboards.service 的 ExecStart 指向本脚本——去掉写死的 IP,任何机器都用自己的。
TS_IP="$(tailscale ip -4 2>/dev/null | head -1)"; TS_IP="${TS_IP:-127.0.0.1}"
exec /usr/bin/python3 -m http.server 8088 --bind "$TS_IP" --directory /root/inbox/dashboards
