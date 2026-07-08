#!/bin/bash
# 项目看板门户:只在本机 Tailscale IP 上服务 /root/inbox/dashboards(自动取 IP、tailnet-only)。
# cloud-dashboards.service 的 ExecStart 指向本脚本——去掉写死的作者 IP,任何机器都用自己的。
# 开机时 tailscaled 可能比本服务晚就绪(实测曾晚 1 秒),直接取 IP 会拿到空值退化成 127.0.0.1(外部连不进)。
# 这里等最多 30 秒直到取到真 IP 再起服务;真拿不到才退回 127.0.0.1。
TS_IP=""
for i in $(seq 1 30); do
  TS_IP="$(tailscale ip -4 2>/dev/null | head -1)"
  [ -n "$TS_IP" ] && break
  sleep 1
done
TS_IP="${TS_IP:-127.0.0.1}"
exec /usr/bin/python3 -m http.server 8088 --bind "$TS_IP" --directory /root/inbox/dashboards
