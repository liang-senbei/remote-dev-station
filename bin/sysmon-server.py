#!/usr/bin/env python3
"""轻量服务器状态面板:纯标准库、零依赖、按请求现算(不常驻采集/不存历史)。
GET /api/status 返回一次快照 JSON;GET / 返回自带轮询的静态页面。"""
import http.server
import json
import subprocess
import time

def resolve_ts_ip():
    # 开机时 tailscaled 可能比本服务晚就绪,直接取会拿到空值——等最多 30 秒。
    for _ in range(30):
        ip = subprocess.run(['tailscale', 'ip', '-4'], capture_output=True, text=True).stdout.strip()
        if ip:
            return ip
        time.sleep(1)
    return '127.0.0.1'


TS_IP = resolve_ts_ip()
PORT = 19998


def read_cpu_times():
    with open('/proc/stat') as f:
        cores = {}
        total = None
        for line in f:
            if not line.startswith('cpu'):
                break
            parts = line.split()
            label, nums = parts[0], list(map(int, parts[1:]))
            idle = nums[3] + nums[4]
            busy = sum(nums) - idle
            entry = (busy, busy + idle)
            if label == 'cpu':
                total = entry
            else:
                cores[label] = entry
        return total, cores


def cpu_snapshot():
    t1, c1 = read_cpu_times()
    time.sleep(0.15)
    t2, c2 = read_cpu_times()

    def pct(a, b):
        db, dt = b[0] - a[0], b[1] - a[1]
        return round(100 * db / dt, 1) if dt > 0 else 0.0

    per_core = [pct(c1[k], c2[k]) for k in sorted(c1, key=lambda x: int(x[3:]))]
    return {'total': pct(t1, t2), 'per_core': per_core}


def mem_snapshot():
    kv = {}
    with open('/proc/meminfo') as f:
        for line in f:
            k, v = line.split(':')
            kv[k.strip()] = int(v.strip().split()[0])  # kB
    total = kv.get('MemTotal', 0)
    avail = kv.get('MemAvailable', 0)
    used = total - avail
    swap_total = kv.get('SwapTotal', 0)
    swap_free = kv.get('SwapFree', 0)
    return {
        'total_mb': total // 1024, 'used_mb': used // 1024,
        'pct': round(100 * used / total, 1) if total else 0,
        'swap_total_mb': swap_total // 1024, 'swap_used_mb': (swap_total - swap_free) // 1024,
    }


def disk_snapshot():
    out = subprocess.run(['df', '-BM', '-x', 'tmpfs', '-x', 'devtmpfs', '-x', 'overlay'],
                          capture_output=True, text=True).stdout
    disks = []
    for line in out.splitlines()[1:]:
        parts = line.split()
        if len(parts) < 6:
            continue
        disks.append({
            'mount': parts[5], 'total_mb': int(parts[1].rstrip('M')),
            'used_mb': int(parts[2].rstrip('M')), 'pct': int(parts[4].rstrip('%')),
        })
    return disks[:8]


def net_snapshot():
    def is_real_iface(name):
        # 排除 docker0/网桥/veth 这些容器内部虚拟网卡——它们和物理网卡/tailscale0
        # 会把同一份流量重复计一遍,只算真正对外的接口。
        return name != 'lo' and not name.startswith(('docker', 'br-', 'veth'))

    def read():
        rx = tx = 0
        with open('/proc/net/dev') as f:
            for line in f.readlines()[2:]:
                iface, rest = line.split(':')
                iface = iface.strip()
                if not is_real_iface(iface):
                    continue
                nums = rest.split()
                rx += int(nums[0]); tx += int(nums[8])
        return rx, tx
    rx1, tx1 = read()
    time.sleep(0.15)
    rx2, tx2 = read()
    return {'rx_kbps': round((rx2 - rx1) / 1024 / 0.15, 1), 'tx_kbps': round((tx2 - tx1) / 1024 / 0.15, 1)}


def load_uptime():
    load = open('/proc/loadavg').read().split()[:3]
    uptime_s = float(open('/proc/uptime').read().split()[0])
    return {'load': [float(x) for x in load], 'uptime_h': round(uptime_s / 3600, 1)}


def top_processes(n=12):
    # etimes(存活秒数)一起拿:ps 的 %CPU = 用掉的CPU时间/自身存活时间,活不到1秒的
    # 进程(ps自己/临时起的sshd/一次性脚本...)分母趋零,算出来会飙到100%——不是真负载,
    # 是自我测量假象。按存活时间过滤这整类噪音,不是照名字一个个排除(排不完)。
    out = subprocess.run(['ps', '-eo', 'pid,comm,pcpu,pmem,etimes', '--sort=-pcpu', '--no-headers'],
                          capture_output=True, text=True).stdout
    procs = []
    for line in out.splitlines():
        parts = line.split(None, 4)
        if len(parts) < 5:
            continue
        pid, name, cpu, mem, etimes = parts
        if int(etimes) < 2:
            continue
        procs.append({'pid': pid, 'name': name, 'cpu': float(cpu), 'mem': float(mem)})
        if len(procs) >= n:
            break
    return procs


def docker_snapshot():
    # 只用 docker ps(~60ms),不用 docker stats(要采样~1.1s,拖慢整个接口不划算)。
    r = subprocess.run(['docker', 'ps', '-a', '--format', '{{.Names}}|{{.Status}}|{{.Image}}'],
                        capture_output=True, text=True)
    if r.returncode != 0:
        return []  # docker 未装/未运行,静默返回空,不报错
    out = []
    for line in r.stdout.splitlines():
        parts = line.split('|')
        if len(parts) != 3:
            continue
        name, status, image = parts
        out.append({'name': name, 'status': status, 'image': image, 'up': status.startswith('Up')})
    return out


def snapshot():
    return {
        'time': time.strftime('%H:%M:%S'),
        'cpu': cpu_snapshot(),
        'mem': mem_snapshot(),
        'disk': disk_snapshot(),
        'net': net_snapshot(),
        **load_uptime(),
        'top': top_processes(),
        'docker': docker_snapshot(),
        'sessions': subprocess.run(['tmux', 'list-sessions'], capture_output=True, text=True)
                    .stdout.count('\n'),
    }


PAGE = """<!doctype html><html><head><meta charset="utf-8">
<title>echo-j2 服务器状态</title>
<style>
:root{color-scheme:dark light}
body{font:14px/1.5 -apple-system,"PingFang SC",system-ui,sans-serif;background:#11161f;color:#e6ecf5;margin:0;padding:20px}
h1{font-size:16px;margin:0 0 4px}
.sub{color:#8a97ab;font-size:12px;margin-bottom:18px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:14px;margin-bottom:18px}
.card{background:#1a2332;border:1px solid #2b3850;border-radius:10px;padding:14px}
.card h2{font-size:12px;color:#8a97ab;margin:0 0 10px;font-weight:600;text-transform:uppercase;letter-spacing:.05em}
.bar{background:#0d1219;border-radius:5px;height:16px;overflow:hidden;margin:3px 0}
.bar>div{height:100%;background:linear-gradient(90deg,#4f8cff,#7db2ff);transition:width .3s}
.bar.warn>div{background:linear-gradient(90deg,#e0a030,#f0c060)}
.bar.crit>div{background:linear-gradient(90deg,#e05050,#f08080)}
.row{display:flex;justify-content:space-between;font-size:12px;color:#aab8cc;margin-top:2px}
.cores{display:grid;grid-template-columns:repeat(4,1fr);gap:6px}
.cores .bar{height:10px}
table{width:100%;border-collapse:collapse;font-size:12.5px}
td{padding:3px 4px;border-bottom:1px solid #232e42}
td:nth-child(3),td:nth-child(4){text-align:right;color:#aab8cc}
.big{font-size:22px;font-weight:600}
.dot{display:inline-block;width:7px;height:7px;border-radius:50%;margin-right:6px}
.dot.up{background:#5fd97a}
.dot.down{background:#e05050}
.mut{color:#8a97ab}
</style></head><body>
<h1>📊 echo-j2 服务器状态</h1>
<div class="sub" id="meta">加载中…</div>
<div class="grid">
  <div class="card"><h2>CPU</h2><div class="big" id="cpu-total">—</div>
    <div class="cores" id="cpu-cores"></div></div>
  <div class="card"><h2>内存 / Swap</h2>
    <div class="bar" id="mem-bar"><div></div></div><div class="row" id="mem-txt"></div>
    <div class="bar" id="swap-bar" style="margin-top:10px"><div></div></div><div class="row" id="swap-txt"></div></div>
  <div class="card"><h2>磁盘</h2><div id="disks"></div></div>
  <div class="card"><h2>网络 / 负载 / 会话</h2>
    <div class="row"><span>↓ 下行</span><span id="net-rx">—</span></div>
    <div class="row"><span>↑ 上行</span><span id="net-tx">—</span></div>
    <div class="row"><span>负载(1/5/15分)</span><span id="load">—</span></div>
    <div class="row"><span>运行时长</span><span id="uptime">—</span></div>
    <div class="row"><span>tmux 会话数</span><span id="sessions">—</span></div></div>
</div>
<div class="grid">
  <div class="card"><h2>进程 Top 12(按 CPU)</h2><table><tbody id="procs"></tbody></table></div>
  <div class="card"><h2>Docker 容器</h2><table><tbody id="docker"></tbody></table></div>
</div>
<script>
function barClass(p){return p>=90?'bar crit':p>=70?'bar warn':'bar'}
async function tick(){
  const r = await fetch('/api/status'); const d = await r.json();
  document.getElementById('meta').textContent = '更新于 ' + d.time + '(每 3 秒自动刷新)';
  document.getElementById('cpu-total').textContent = d.cpu.total + '%';
  document.getElementById('cpu-cores').innerHTML = d.cpu.per_core.map((p,i)=>
    `<div class="${barClass(p)}" title="core${i} ${p}%"><div style="width:${p}%"></div></div>`).join('');
  document.getElementById('mem-bar').className = barClass(d.mem.pct);
  document.getElementById('mem-bar').firstElementChild.style.width = d.mem.pct+'%';
  document.getElementById('mem-txt').innerHTML = `<span>${d.mem.used_mb}MB / ${d.mem.total_mb}MB</span><span>${d.mem.pct}%</span>`;
  const swapPct = d.mem.swap_total_mb ? Math.round(100*d.mem.swap_used_mb/d.mem.swap_total_mb) : 0;
  document.getElementById('swap-bar').className = barClass(swapPct);
  document.getElementById('swap-bar').firstElementChild.style.width = swapPct+'%';
  document.getElementById('swap-txt').innerHTML = `<span>Swap ${d.mem.swap_used_mb}MB / ${d.mem.swap_total_mb}MB</span><span>${swapPct}%</span>`;
  document.getElementById('disks').innerHTML = d.disk.map(x=>
    `<div class="row" style="margin-bottom:2px"><span>${x.mount}</span><span>${(x.used_mb/1024).toFixed(1)}G / ${(x.total_mb/1024).toFixed(1)}G(${x.pct}%)</span></div>
     <div class="${barClass(x.pct)}"><div style="width:${x.pct}%"></div></div>`).join('');
  document.getElementById('net-rx').textContent = d.net.rx_kbps.toFixed(0)+' KB/s';
  document.getElementById('net-tx').textContent = d.net.tx_kbps.toFixed(0)+' KB/s';
  document.getElementById('load').textContent = d.load.join(' / ');
  document.getElementById('uptime').textContent = d.uptime_h+' 小时';
  document.getElementById('sessions').textContent = d.sessions;
  document.getElementById('procs').innerHTML = d.top.map(p=>
    `<tr><td>${p.pid}</td><td>${p.name}</td><td>${p.cpu}%</td><td>${p.mem}%</td></tr>`).join('');
  document.getElementById('docker').innerHTML = d.docker.length
    ? d.docker.map(c=>
        `<tr><td><span class="dot ${c.up?'up':'down'}"></span>${c.name}</td><td class="mut">${c.image}</td><td colspan="2" class="mut">${c.status}</td></tr>`).join('')
    : '<tr><td class="mut">(无容器 / docker 未运行)</td></tr>';
}
tick(); setInterval(tick, 3000);
</script></body></html>"""


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        if self.path.startswith('/api/status'):
            body = json.dumps(snapshot()).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            body = PAGE.encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)


if __name__ == '__main__':
    server = http.server.ThreadingHTTPServer((TS_IP, PORT), Handler)
    print(f'sysmon serving on {TS_IP}:{PORT}')
    server.serve_forever()
