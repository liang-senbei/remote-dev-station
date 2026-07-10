#!/usr/bin/env python3
"""轻量服务器状态面板:纯标准库、零依赖。GET /api/status 返回一次快照 JSON
(其中 history 字段是后台线程独立按 HISTORY_INTERVAL 采样、存在内存里的最近一段趋势,
不落盘、服务重启即清空);GET / 返回自带轮询的静态页面。"""
import collections
import http.server
import json
import os
import subprocess
import threading
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

# 同一份代码在所有机器上跑,靠这个环境变量分角色——只有 echo-j2 是"hub"(轮询
# 其它几台拼成一份);HK13/HK14/Air/mini 默认(未设置时)是"agent",/api/status
# 只报自己。踩过的坑:曾经把这份带 PEERS 逻辑的脚本原样部署到 HK13/HK14,导致它们
# 也去跑 hub_snapshot()——不仅把自己的数据错标成"echo-j2",还会去拉全部 4 台
# (包括拉自己),/api/status 吐出来的是 {machines:[...]} 这个"整份聚合"形状,
# 而不是单机形状,真正的 hub(echo-j2)读到这种畸形数据就渲染报错——这正是
# "HK13/HK14 连不上"的根因。SYSMON_ROLE=hub 只应该出现在 echo-j2 自己的 systemd
# 配置里(sysmon-hub.service),别的机器一律用不带这个变量的通用模板(sysmon.service)。
ROLE = os.environ.get('SYSMON_ROLE', 'agent')

# 多机聚合:echo-j2 自己(url=None,本地直接算)+ 另外几台各自跑同一套 agent、
# 暴露自己的 /api/status,这里并行拉一遍拼成一份。改机器/加机器改这张表就行。
PEERS = [
    {'id': 'echo-j2', 'label': 'echo-j2(本机)', 'url': None},
    {'id': 'air',     'label': 'MacBook Air',   'url': 'http://100.101.160.72:19998/api/status'},
    {'id': 'mini',    'label': 'Mac mini',      'url': 'http://100.76.20.101:19998/api/status'},
    {'id': 'hk13',    'label': 'HK13',          'url': 'http://100.115.171.117:19998/api/status'},
    {'id': 'hk14',    'label': 'HK14',          'url': 'http://100.100.232.33:19998/api/status'},
]

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


# 之前"卡爆三次"排查完全靠事后翻日志——面板该能在真正卡死前就露出"内存正在往上爬"。
# 后台线程按固定节奏独立采样(不依赖有没有人开着页面在轮询),存最近一小时、内存环形
# 缓冲区、服务重启即清空,不落盘。
HISTORY_INTERVAL = 10   # 秒
HISTORY_LEN = 360        # 10s×360 = 1 小时
_history = collections.deque(maxlen=HISTORY_LEN)
_history_lock = threading.Lock()


def _history_sampler():
    while True:
        try:
            point = {
                't': int(time.time()),
                'cpu': cpu_snapshot()['total'],
                'mem': mem_snapshot()['pct'],
                **net_snapshot(),
            }
            with _history_lock:
                _history.append(point)
        except Exception:
            pass  # 单次采样失败不影响下一次,静默跳过
        time.sleep(HISTORY_INTERVAL)


def claude_session_map():
    # pid → 会话名,用来把进程榜里光秃秃的 "claude" 标注成"是哪个会话"(今天排查证明很有用)。
    # 失败/超时不影响整个面板,静默返回空表。
    try:
        r = subprocess.run(['/root/.local/bin/claude', 'agents', '--json'],
                            capture_output=True, text=True, timeout=3)
        data = json.loads(r.stdout)
        return {str(x['pid']): x.get('name', '?') for x in data if 'pid' in x}
    except Exception:
        return {}


def top_processes(n=12):
    # etimes(存活秒数)一起拿:ps 的 %CPU = 用掉的CPU时间/自身存活时间,活不到1秒的
    # 进程(ps自己/临时起的sshd/一次性脚本...)分母趋零,算出来会飙到100%——不是真负载,
    # 是自我测量假象。按存活时间过滤这整类噪音,不是照名字一个个排除(排不完)。
    sessmap = claude_session_map()
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
        label = f"{name} ({sessmap[pid]})" if name == 'claude' and pid in sessmap else name
        procs.append({'pid': pid, 'name': label, 'cpu': float(cpu), 'mem': float(mem)})
        if len(procs) >= n:
            break
    return procs


# 今天真实经历过一次 OOM+重启,面板该在第一眼就告诉我"最近有没有再犯"。
# 全量扫24h日志要10秒,每3秒刷新一次的面板扛不住——启动时全量查一次打底(唯一慢的
# 一次),之后每次只查"上次查到现在"这一小段增量,快且不丢事件。全局态只留内存里,
# 服务重启会重新打底,符合"不做持久历史"的设计。
_oom_cache = {'last_checked': None, 'last_oom_ts': None, 'count_since_start': 0}

def oom_status():
    now = time.time()
    try:
        if _oom_cache['last_checked'] is None:
            since_arg = '24 hours ago'
        else:
            since_arg = time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(_oom_cache['last_checked']))
        r = subprocess.run(
            ['journalctl', '--since', since_arg, '--no-pager', '-o', 'short-unix'],
            capture_output=True, text=True, timeout=12)
        lines = [l for l in r.stdout.splitlines() if 'invoked oom-killer' in l]
        if lines:
            _oom_cache['last_oom_ts'] = float(lines[-1].split()[0])
            _oom_cache['count_since_start'] += len(lines)
        _oom_cache['last_checked'] = now
    except Exception:
        pass  # 这次查询失败就沿用上次结果,不让整个面板挂掉
    if _oom_cache['last_oom_ts'] is None:
        return {'count_recent': _oom_cache['count_since_start'], 'hours_since': None}
    hours_since = round((now - _oom_cache['last_oom_ts']) / 3600, 1)
    return {'count_recent': _oom_cache['count_since_start'], 'hours_since': hours_since}


def docker_snapshot():
    # 只用 docker ps(~60ms),不用 docker stats(要采样~1.1s,拖慢整个接口不划算)。
    try:
        r = subprocess.run(['docker', 'ps', '-a', '--format', '{{.Names}}|{{.Status}}|{{.Image}}'],
                            capture_output=True, text=True, timeout=3)
    except Exception:
        return []  # docker 没装(FileNotFoundError)/超时,静默返回空,不报错——多机部署后不是每台都有 docker
    if r.returncode != 0:
        return []  # docker 装了但没起,静默返回空,不报错
    out = []
    for line in r.stdout.splitlines():
        parts = line.split('|')
        if len(parts) != 3:
            continue
        name, status, image = parts
        out.append({'name': name, 'status': status, 'image': image, 'up': status.startswith('Up')})
    return out


def security_snapshot():
    # 今天排查 echo2 那个埋了十天没人发现的账号才想起来加:谁登着、fail2ban 挡了多少——
    # 一眼扫过,不用再临时手敲命令查。
    who = []
    try:
        out = subprocess.run(['who'], capture_output=True, text=True, timeout=2).stdout
        for line in out.splitlines():
            parts = line.split()
            if not parts:
                continue
            src = next((p.strip('()') for p in parts if p.startswith('(')), '-')
            who.append({'user': parts[0], 'tty': parts[1] if len(parts) > 1 else '?', 'from': src})
    except Exception:
        pass
    banned = failed = None
    try:
        out = subprocess.run(['fail2ban-client', 'status', 'sshd'],
                              capture_output=True, text=True, timeout=2).stdout
        for line in out.splitlines():
            if 'Currently banned' in line:
                banned = int(line.rsplit(':', 1)[-1].strip())
            elif 'Total failed' in line:
                failed = int(line.rsplit(':', 1)[-1].strip())
    except Exception:
        pass
    return {'who': who, 'fail2ban_banned': banned, 'fail2ban_failed_total': failed}


def tmux_session_count():
    try:
        r = subprocess.run(['tmux', 'list-sessions'], capture_output=True, text=True, timeout=2)
        return r.stdout.count('\n') if r.returncode == 0 else 0
    except Exception:
        return 0  # tmux 没装/没有会话,多机部署后不是每台都有 tmux


def _safe(fn, default):
    # 单项指标(ps/df/journalctl 输出)偶发格式异常不该拖垮整台机器的状态——
    # 之前 echo-j2 自己就因为某个子采集瞬时抛错,被 hub 判成"离线",具备误导性
    # (面板运行在 echo-j2 上,它本身'离线'这个结论基本不可能成立)。逐项兜底。
    try:
        return fn()
    except Exception:
        return default


def local_snapshot():
    with _history_lock:
        history = list(_history)
    return {
        'time': time.strftime('%H:%M:%S'),
        'cpu': _safe(cpu_snapshot, {'total': 0.0, 'per_core': []}),
        'mem': _safe(mem_snapshot, {'total_mb': 0, 'used_mb': 0, 'pct': 0, 'swap_total_mb': 0, 'swap_used_mb': 0}),
        'disk': _safe(disk_snapshot, []),
        'net': _safe(net_snapshot, {'rx_kbps': 0.0, 'tx_kbps': 0.0}),
        **_safe(load_uptime, {'load': [0.0, 0.0, 0.0], 'uptime_h': 0.0}),
        'top': _safe(top_processes, []),
        'docker': _safe(docker_snapshot, []),
        'oom': _safe(oom_status, {'count_recent': None, 'hours_since': None}),
        'security': _safe(security_snapshot, {'who': [], 'fail2ban_banned': None, 'fail2ban_failed_total': None}),
        'history': history,
        'sessions': _safe(tmux_session_count, 0),
    }


def collect_machine(machine_id, url):
    if url is None:
        try:
            return machine_id, {'online': True, 'data': local_snapshot(), 'error': None}
        except Exception as e:
            return machine_id, {'online': False, 'data': None, 'error': type(e).__name__}
    try:
        # macOS agent 实测单次 2.1~2.3s 打底,偶发抖动到 6s+(top 采样间隔+机器
        # 自身其它常驻任务瞬时抢资源),超时给够余量,别把慢当离线。
        with urllib.request.urlopen(url, timeout=8) as resp:
            data = json.loads(resp.read().decode())
        return machine_id, {'online': True, 'data': data, 'error': None}
    except Exception as e:
        # 对方机器关机/tailscale断了/agent没起——都归为"离线",面板不能因为
        # 一台连不上就整体挂掉,这是多机聚合的核心容错点。
        return machine_id, {'online': False, 'data': None, 'error': type(e).__name__}


def hub_snapshot():
    # 并行拉,总耗时约等于最慢那一台的超时时间,不是几台超时时间相加。
    with ThreadPoolExecutor(max_workers=len(PEERS)) as ex:
        futures = [ex.submit(collect_machine, p['id'], p['url']) for p in PEERS]
        results = dict(f.result() for f in as_completed(futures))
    machines = [{'id': p['id'], 'label': p['label'], **results.get(
        p['id'], {'online': False, 'data': None, 'error': 'no-result'})} for p in PEERS]
    return {'time': time.strftime('%H:%M:%S'), 'machines': machines}


# 拉 4 台远程机器最慢能到 8 秒超时——如果每次开面板/每次前端轮询都现拉一遍,
# 打开面板就得等好几秒。改成后台线程独立按 HUB_INTERVAL 刷新、存一份缓存,
# HTTP 请求只读缓存,响应从"秒级"降到"毫秒级"。新鲜度上限就是 HUB_INTERVAL,
# 反正前端本来就是按这个节奏轮询,不算额外变旧。
HUB_INTERVAL = 10
_hub_cache = {'data': {'time': '-', 'machines': []}}
_hub_cache_lock = threading.Lock()


def _hub_sampler():
    while True:
        try:
            snap = hub_snapshot()
            with _hub_cache_lock:
                _hub_cache['data'] = snap
        except Exception:
            pass  # 保留上一次的缓存,不让整个后台采样线程死掉
        time.sleep(HUB_INTERVAL)


PAGE = """<!doctype html><html><head><meta charset="utf-8">
<title>全机状态总览</title>
<style>
:root{color-scheme:light}
body{font:14px/1.5 -apple-system,"PingFang SC",system-ui,sans-serif;background:#f3f5f9;color:#1e293b;margin:0;padding:20px}
h1{font-size:16px;margin:0 0 4px;color:#0f172a}
.sub{color:#94a3b8;font-size:12px;margin-bottom:18px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:14px;margin-bottom:18px}
.card{background:#ffffff;border:1px solid #e2e8f0;border-radius:10px;padding:14px;box-shadow:0 1px 3px rgba(15,23,42,.05)}
.card h2{font-size:12px;color:#94a3b8;margin:0 0 10px;font-weight:700;text-transform:uppercase;letter-spacing:.05em}
.bar{background:#eef1f6;border-radius:5px;height:16px;overflow:hidden;margin:3px 0}
.bar>div{height:100%;background:linear-gradient(90deg,#3b82f6,#60a5fa);transition:width .3s}
.bar.warn>div{background:linear-gradient(90deg,#d97706,#fbbf24)}
.bar.crit>div{background:linear-gradient(90deg,#dc2626,#f87171)}
.row{display:flex;justify-content:space-between;font-size:12px;color:#475569;margin-top:2px}
.cores{display:grid;grid-template-columns:repeat(4,1fr);gap:6px}
.cores .bar{height:10px}
table{width:100%;border-collapse:collapse;font-size:12.5px}
td{padding:3px 4px;border-bottom:1px solid #f1f5f9}
td:nth-child(3),td:nth-child(4){text-align:right;color:#64748b}
.big{font-size:24px;font-weight:700;color:#0f172a}
.dot{display:inline-block;width:7px;height:7px;border-radius:50%;margin-right:6px;flex-shrink:0}
.dot.up{background:#16a34a}
.dot.down{background:#dc2626}
.mut{color:#94a3b8}
.spark{width:100%;height:36px;display:block;margin-top:8px}
.spark polyline{opacity:.95}
.spark polygon{opacity:.12}
.legend{font-size:11px;color:#94a3b8;margin-top:2px}
.legend span{margin-right:12px}
.legend i{display:inline-block;width:8px;height:2px;margin-right:4px;vertical-align:middle}
.overview{display:flex;flex-direction:column;gap:6px;margin-bottom:28px}
.ov-row{display:flex;align-items:center;gap:16px;background:#ffffff;border:1px solid #e2e8f0;border-radius:8px;padding:9px 14px;font-size:12.5px;flex-wrap:wrap;box-shadow:0 1px 3px rgba(15,23,42,.04)}
.ov-row.offline{opacity:.55}
.ov-name{font-weight:700;min-width:110px;color:#0f172a}
.ov-row .mut{font-size:12.5px}
.ov-metric{display:inline-flex;align-items:center;gap:6px;color:#475569}
.mini-bar{display:inline-block;width:42px;height:6px;background:#eef1f6;border-radius:3px;overflow:hidden;vertical-align:middle}
.mini-bar>span{display:block;height:100%;background:#3b82f6}
.mini-bar>span.warn{background:#f59e0b}
.mini-bar>span.crit{background:#dc2626}
.machine-header{display:flex;align-items:center;gap:8px;margin:8px 0 10px;font-size:15px;font-weight:700;color:#0f172a;padding-top:18px;border-top:1px solid #e2e8f0}
.machine-header:first-child{border-top:none;padding-top:0}
.offline-card{background:#ffffff;border:1px dashed #cbd5e1;border-radius:10px;padding:16px;color:#94a3b8;font-size:13px;margin-bottom:18px}
</style></head><body>
<h1>📊 全机状态总览</h1>
<div class="sub" id="meta">加载中…</div>
<div class="overview" id="overview"></div>
<div id="sections"></div>
<script>
function barClass(p){return p>=90?'bar crit':p>=70?'bar warn':'bar'}
function miniBarClass(p){return p>=90?'crit':p>=70?'warn':''}
function miniBar(p){
  return `<span class="mini-bar"><span class="${miniBarClass(p)}" style="width:${Math.min(p,100)}%"></span></span>`;
}
function multiSpark(id, series, fixedMax){
  const w = 240, h = 36;
  const el = document.getElementById(id);
  if (!el) return;
  const n = Math.max(0, ...series.map(s=>s.values.length));
  if (!n) { el.innerHTML = ''; return; }
  const max = fixedMax || Math.max(1, ...series.flatMap(s=>s.values));
  const parts = series.map(s=>{
    const step = s.values.length > 1 ? w/(s.values.length-1) : w;
    const pts = s.values.map((v,i)=>[(i*step).toFixed(1), (h-Math.min(v/max,1)*h).toFixed(1)]);
    const line = pts.map(p=>p.join(',')).join(' ');
    const area = `0,${h} ${line} ${w},${h}`;
    return `<polygon points="${area}" fill="${s.color}"/><polyline points="${line}" fill="none" stroke="${s.color}" stroke-width="1.6"/>`;
  }).join('');
  el.innerHTML = `<svg viewBox="0 0 ${w} ${h}" preserveAspectRatio="none" class="spark">${parts}</svg>`;
}
function renderOverviewRow(m){
  if (!m.online) {
    return `<div class="ov-row offline"><span class="dot down"></span><span class="ov-name">${m.label}</span>
      <span class="mut">离线 / 连不上${m.error ? '('+m.error+')' : ''}</span></div>`;
  }
  const d = m.data, disk0 = d.disk[0] || {pct:0,mount:'-'};
  return `<div class="ov-row"><span class="dot up"></span><span class="ov-name">${m.label}</span>
    <span class="ov-metric">CPU ${d.cpu.total}% ${miniBar(d.cpu.total)}</span>
    <span class="ov-metric">内存 ${d.mem.pct}% ${miniBar(d.mem.pct)}</span>
    <span class="ov-metric">磁盘(${disk0.mount}) ${disk0.pct}% ${miniBar(disk0.pct)}</span>
    <span>负载 ${d.load.join('/')}</span>
    <span>${d.uptime_h}h</span><span>${d.sessions} 会话</span></div>`;
}
function renderMachineSection(m){
  if (!m.online) {
    return `<div class="machine-header"><span class="dot down"></span>${m.label}</div>
      <div class="offline-card">连不上这台机器${m.error ? '('+m.error+')' : ''}——可能关机、tailscale 断了,或者这台机器上的监控 agent 没起来。</div>`;
  }
  const d = m.data, id = m.id;
  const swapPct = d.mem.swap_total_mb ? Math.round(100*d.mem.swap_used_mb/d.mem.swap_total_mb) : 0;
  const oomTxt = d.oom.count_recent == null ? '—'
    : (d.oom.count_recent === 0 ? '无' : `${d.oom.count_recent}次·最近${d.oom.hours_since}h前`);
  const oomDot = d.oom.count_recent == null ? '' : (d.oom.count_recent === 0 ? 'up' : 'down');
  return `<div class="machine-header"><span class="dot up"></span>${m.label}<span class="sub" style="margin:0 0 0 4px">更新于 ${d.time}</span></div>
  <div class="grid">
    <div class="card"><h2>CPU</h2><div class="big">${d.cpu.total}%</div>
      <div class="cores">${d.cpu.per_core.map((p,i)=>`<div class="${barClass(p)}" title="core${i} ${p}%"><div style="width:${p}%"></div></div>`).join('')}</div>
      <div id="spark-cpu-${id}"></div><div class="legend">近1小时</div></div>
    <div class="card"><h2>内存 / Swap</h2>
      <div class="${barClass(d.mem.pct)}"><div style="width:${d.mem.pct}%"></div></div>
      <div class="row"><span>${d.mem.used_mb}MB / ${d.mem.total_mb}MB</span><span>${d.mem.pct}%</span></div>
      <div class="${barClass(swapPct)}" style="margin-top:10px"><div style="width:${swapPct}%"></div></div>
      <div class="row"><span>Swap ${d.mem.swap_used_mb}MB / ${d.mem.swap_total_mb}MB</span><span>${swapPct}%</span></div>
      <div id="spark-mem-${id}"></div><div class="legend">近1小时</div></div>
    <div class="card"><h2>磁盘</h2><div>${d.disk.map(x=>
      `<div class="row" style="margin-bottom:2px"><span>${x.mount}</span><span>${(x.used_mb/1024).toFixed(1)}G / ${(x.total_mb/1024).toFixed(1)}G(${x.pct}%)</span></div>
       <div class="${barClass(x.pct)}"><div style="width:${x.pct}%"></div></div>`).join('') || '<div class="mut">(无数据)</div>'}</div></div>
    <div class="card"><h2>网络 / 负载 / 会话</h2>
      <div class="row"><span>↓ 下行</span><span>${d.net.rx_kbps.toFixed(0)} KB/s</span></div>
      <div class="row"><span>↑ 上行</span><span>${d.net.tx_kbps.toFixed(0)} KB/s</span></div>
      <div id="spark-net-${id}"></div>
      <div class="legend"><span><i style="background:#5fd97a"></i>下行</span><span><i style="background:#f0c060"></i>上行</span></div>
      <div class="row" style="margin-top:8px"><span>负载(1/5/15分)</span><span>${d.load.join(' / ')}</span></div>
      <div class="row"><span>运行时长</span><span>${d.uptime_h} 小时</span></div>
      <div class="row"><span>会话数</span><span>${d.sessions}</span></div>
      <div class="row"><span><span class="dot ${oomDot}"></span>近24h OOM</span><span>${oomTxt}</span></div></div>
  </div>
  <div class="grid">
    <div class="card"><h2>进程 Top 12(按 CPU)</h2><table><tbody>${d.top.map(p=>
      `<tr><td>${p.pid}</td><td>${p.name}</td><td>${p.cpu}%</td><td>${p.mem}%</td></tr>`).join('') || '<tr><td class="mut">(无数据)</td></tr>'}</tbody></table></div>
    <div class="card"><h2>Docker 容器</h2><table><tbody>${d.docker.length
      ? d.docker.map(c=>`<tr><td><span class="dot ${c.up?'up':'down'}"></span>${c.name}</td><td class="mut">${c.image}</td><td colspan="2" class="mut">${c.status}</td></tr>`).join('')
      : '<tr><td class="mut">(无容器 / 未安装 docker)</td></tr>'}</tbody></table></div>
    <div class="card"><h2>安全</h2><div>${d.security.who.length
      ? d.security.who.map(w=>`<div class="row"><span>${w.user} · ${w.tty}</span><span>${w.from}</span></div>`).join('')
      : '<div class="row mut"><span>(无活跃会话)</span></div>'}</div>
      <div class="row" style="margin-top:8px"><span>fail2ban 累计失败</span><span>${d.security.fail2ban_failed_total ?? '—'}</span></div>
      <div class="row"><span>fail2ban 当前封禁</span><span>${d.security.fail2ban_banned ?? '—'}</span></div></div>
  </div>`;
}
let tickFails = 0;
async function tick(){
  let d;
  try {
    const r = await fetch('/api/status');
    if (!r.ok) throw new Error('HTTP '+r.status);
    d = await r.json();
  } catch (e) {
    // 取数据这步本身失败(服务重启瞬间/网络抖动)—— 显式说清楚,而不是悄悄留着上一屏
    // 不动,让人误以为"卡住了/坏了"。已渲染过的内容保留,只在顶部提示。
    tickFails++;
    document.getElementById('meta').textContent = '刷新失败(' + e.message + '),' + tickFails + ' 次重试中…上次成功的数据仍在下方';
    return;
  }
  tickFails = 0;
  try {
    document.getElementById('meta').textContent = '更新于 ' + d.time + '(每 10 秒自动刷新,共 ' + d.machines.length + ' 台)';
    document.getElementById('overview').innerHTML = d.machines.map(renderOverviewRow).join('');
    document.getElementById('sections').innerHTML = d.machines.map(renderMachineSection).join('');
    d.machines.forEach(m=>{
      if (!m.online) return;
      const h = m.data.history || [];
      multiSpark('spark-cpu-'+m.id, [{values: h.map(x=>x.cpu), color:'#4f8cff'}], 100);
      multiSpark('spark-mem-'+m.id, [{values: h.map(x=>x.mem), color:'#7db2ff'}], 100);
      multiSpark('spark-net-'+m.id, [
        {values: h.map(x=>x.rx_kbps), color:'#5fd97a'},
        {values: h.map(x=>x.tx_kbps), color:'#f0c060'},
      ]);
    });
  } catch (e) {
    // 渲染这步本身抛错(某台机器数据形状异常)——同样不要悄悄空白,报出来方便定位。
    document.getElementById('meta').textContent = '渲染出错: ' + e.message + '(数据已取到,是显示逻辑的问题)';
  }
}
tick(); setInterval(tick, 10000);
</script></body></html>"""


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        # Wave 网页块会缓存 GET 响应(踩过一次坑,见 cloud-session-tooling 记忆里旧看板那次)——
        # 这个面板改动频繁,强制 no-store 防止浏览器/Wave 拿着改之前的旧版 HTML/JS 硬跑。
        if self.path.startswith('/api/status'):
            if ROLE == 'hub':
                with _hub_cache_lock:
                    payload = _hub_cache['data']
            else:
                payload = local_snapshot()   # agent 模式:只报自己,单机形状,不碰 PEERS
            body = json.dumps(payload).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            self.wfile.write(body)
        else:
            body = PAGE.encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            self.wfile.write(body)


if __name__ == '__main__':
    threading.Thread(target=_history_sampler, daemon=True).start()
    if ROLE == 'hub':
        threading.Thread(target=_hub_sampler, daemon=True).start()
    server = http.server.ThreadingHTTPServer((TS_IP, PORT), Handler)
    print(f'sysmon serving on {TS_IP}:{PORT} (role={ROLE})')
    server.serve_forever()
