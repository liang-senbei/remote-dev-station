#!/usr/bin/env bash
# =============================================================================
# deploy-test.sh — cloud-setup 部署后验收测试(install.sh 跑完后,用这个证明"真的能用")
#
# 用法:
#   bash tests/deploy-test.sh core                      # A组·核心链路(只读探测,不碰现有会话)
#   bash tests/deploy-test.sh deck                      # B组·deck 服务端(只读:脚本齐/防127 PATH行/账本同源/面板出)
#   bash tests/deploy-test.sh selfheal                  # S组·断电自愈真测(破坏性,只碰 cc-ztest-* 自建会话)
#   bash tests/deploy-test.sh optional                  # O组·可选层(moshi手机审批/noVNC桌面/看板;未装=SKIP)
#   bash tests/deploy-test.sh migrate --projects /opt/workspace/a,/opt/workspace/b   # M组·迁移验收
#   bash tests/deploy-test.sh all [--projects ...]      # 全部(migrate 仅在传了 --projects 时跑)
#
# 输出:每项一行  [PASS|FAIL|SKIP|BLOCKED] <ID> 说明 | 证据
# 退出码:本次所跑各组中任意一项 FAIL → 非零;全 PASS/SKIP/BLOCKED → 0。
#
# 安全边界:S组只创建/杀死/清理名字严格匹配 ^cc-ztest-[0-9]+$ 的自建会话与
# /opt/workspace/ztest-<时间戳> 目录,kill/rm 前都有正则断言;全程 flock 单实例 + trap 兜底清理。
#
# ★★★★★ 红字规则(动这脚本前先读,别删) ★★★★★
# 所有 `claude -p` 探针必须以 `env -u TMUX -u TMUX_PANE` 起跑!
# 原因:探针若继承当前 tmux 的 TMUX_PANE,探针进程自己的 cc-state 生命周期钩子会把
# "探针"认成【你正在用来跑部署的那个会话】→ 覆写 ~/.cloud-sessions/<会话>.json 登记表
# (uuid 被换成探针的一次性对话),探针结束时 SessionEnd 再把登记标 ended=true ——
# 一发探针就把被验收对象打残:断电后 watchdog 不再拉真会话、或拉成错误对话。切记。
# =============================================================================
set -u
export PATH="$HOME/.local/bin:$PATH"   # 部署把工具装在 ~/.local/bin(与 cloud-watchdog.service 的 PATH 同源)
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---- 全局单实例锁(防两份测试并发互踩 ztest 会话/登记表) --------------------
LOCK=/tmp/.deploy-test-selfheal.lock
exec 9>"$LOCK" || { echo "[BLOCKED] LOCK 开不了锁文件 $LOCK"; exit 2; }
flock -n 9 || { echo "[BLOCKED] LOCK 已有另一份 deploy-test 在跑(锁 $LOCK 被持有) | flock -n 失败"; exit 2; }

PASSES=0; FAILS=0; SKIPS=0; BLOCKS=0
pass(){    echo "[PASS] $1 $2 | ${3:-}";    PASSES=$((PASSES+1)); }
fail(){    echo "[FAIL] $1 $2 | ${3:-}";    FAILS=$((FAILS+1)); }
skip(){    echo "[SKIP] $1 $2 | ${3:-}";    SKIPS=$((SKIPS+1)); }
blocked(){ echo "[BLOCKED] $1 $2 | ${3:-}"; BLOCKS=$((BLOCKS+1)); }
one_line(){ tr '\n' ' ' | sed 's/  */ /g; s/ $//' | cut -c1-220; }   # 证据压成一行,防刷屏

usage(){ sed -n '5,13p' "${BASH_SOURCE[0]}"; }

# =========================== A 组 · 核心链路(只读) ===========================
run_core(){
  echo "== A组·核心链路(只读探测) =="
  local out rc ev miss

  # A0 基建体检脚本本身全绿
  out=$(bash "$REPO/cloud_infra_check.sh" 2>&1); rc=$?
  if [ $rc -eq 0 ]; then pass A0 "cloud_infra_check.sh 全绿" "$(printf '%s' "$out" | tail -1 | one_line)"
  else fail A0 "cloud_infra_check.sh 有红项(rc=$rc)" "$(printf '%s' "$out" | grep '❌' | one_line)"; fi

  # A1 bashrc 函数块已进用户 shell。注意:不能用 bash -lc —— Ubuntu 默认 ~/.bashrc 顶部有
  #    非交互守卫([ -z "$PS1" ] && return),函数块追加在守卫之后,-lc(非交互)根本执行不到;
  #    bash -ic 才等价于"用户真实打开终端所得"。
  miss=$(timeout 30 bash -ic 'type cloud >/dev/null 2>&1 || echo cloud' 2>/dev/null | tr '\n' ' ')
  command -v cloud-enter >/dev/null 2>&1 || miss="$miss cloud-enter"
  if [ -z "$miss" ]; then pass A1 "cloud 函数(bash -ic)+ cloud-enter 入口可用(极简版:ssh cloud→cloud-enter→常驻会话)" "命中"
  else fail A1 "会话入口缺失(bashrc-cloud-snippet 没进 ~/.bashrc?或 cloud-enter 没装?)" "缺: $miss"; fi

  # A2 工具链在 PATH + 两个纯输出工具裸跑不报错
  miss=""
  local b
  for b in cc-state cc-sessions cloud-watchdog cloud-forget cloud-sesslist cloud-enter hub; do
    command -v "$b" >/dev/null 2>&1 || miss="$miss $b"
  done
  cloud-sesslist >/dev/null 2>&1; local rc2=$?
  if [ -z "$miss" ] && [ $rc2 -eq 0 ]; then
    pass A2 "会话工具链齐备(含 cloud-enter)且 cloud-sesslist 裸跑 exit 0" "PATH=$HOME/.local/bin"
  else fail A2 "会话工具链不齐/裸跑报错" "缺:${miss:-无} sesslist=$rc2"; fi

  # A3 settings.json 每个 hook 命令首词必须存在且可执行(专抓"写死 /root 路径、换机后失效")
  out=$(python3 - <<'PYEOF' 2>&1
import json, os, shlex, shutil, sys
p = os.path.expanduser("~/.claude/settings.json")
try:
    d = json.load(open(p))
except Exception as e:
    print("settings.json 读不了: %s" % e); sys.exit(1)
bad = []; n = 0
for ev, groups in (d.get("hooks") or {}).items():
    for g in groups or []:
        for h in (g.get("hooks") or []):
            cmd = (h.get("command") or "").strip()
            if not cmd: continue
            n += 1
            try: head = shlex.split(cmd)[0]
            except ValueError: bad.append("%s: 命令解析不了 %r" % (ev, cmd[:60])); continue
            head = os.path.expanduser(os.path.expandvars(head))
            path = head if os.path.isabs(head) else shutil.which(head)
            if not path or not os.access(path, os.X_OK):
                bad.append("%s→%s" % (ev, head))
print("hooks=%d" % n)
for b in bad: print("BAD " + b)
sys.exit(1 if bad else 0)
PYEOF
); rc=$?
  if [ $rc -eq 0 ]; then pass A3 "settings.json 全部 hook 命令首词存在且可执行" "$(printf '%s' "$out" | head -1)"
  else fail A3 "有 hook 命令指向不存在/不可执行的路径(换机后写死路径失效?)" "$(printf '%s' "$out" | grep BAD | one_line)"; fi

  # A4【最要命】bashrc 与 watchdog.service 的 CLOUD_MODEL 一致,且该模型真能出活
  #    (客户账号没有作者专属模型时:新建会话 + 断电自愈会"启动即死",这里当场抓出来)
  # ★红字:下面的 claude -p 探针必须 env -u TMUX -u TMUX_PANE(见文件头)——否则探针自己的
  #   cc-state 钩子会继承 TMUX_PANE,把正在部署/验收的会话登记表覆写、SessionEnd 标 ended=true,
  #   把被验对象打残。绝对不许去掉。
  local BM SVC reply verdict
  CLOUD_MODEL=""
  eval "$(grep -m1 '^CLOUD_MODEL=' "$HOME/.bashrc" 2>/dev/null)"   # install.sh 的 sed 就锚定这行,eval 同源取值
  BM="$CLOUD_MODEL"
  SVC=$(systemctl show cloud-watchdog.service -p Environment --value 2>/dev/null | xargs -n1 2>/dev/null | sed -n 's/^CLOUD_MODEL=//p' | head -1)
  if [ -z "$BM" ]; then
    fail A4 "~/.bashrc 里没有 CLOUD_MODEL= 赋值(函数块没装/被删)" "grep ^CLOUD_MODEL= 无命中"
  else
    out=$(timeout 240 env -u TMUX -u TMUX_PANE claude --model "$BM" --effort max -p "只回复OK" 2>&1); rc=$?
    reply=$(printf '%s' "$out" | one_line)
    # ⚠️ 不能只看 rc/是否非空:实测 claude CLI 对「模型不存在/无权限」返回 rc=0 且把
    #    "There's an issue with the selected model…" 打到 stdout(非空)——naive 判据会把
    #    启动即死的死模型误判成 PASS。必须按输出签名分类:
    #      dead   = 模型压根用不了(不存在/无权限)→ FAIL(这正是 A4 要抓的「启动即死」)
    #      flagged= 模型可达但这条 headless 探针被内容分类器拦(如 Fable5 switchModelsOnFlag=false
    #               下 -p 直接拒答)→ SKIP:模型可达、非账号问题,交互会话/断电自愈另由 S 组端到端证
    #      ok     = 干净短回复 → 真能出活
    if [ -z "${out//[[:space:]]/}" ] \
       || printf '%s' "$out" | grep -qiE "issue with the selected model|may not (exist|have access)|does not exist|not_found|invalid.*model|authentication_error|permission_error"; then
      verdict=dead
    elif printf '%s' "$out" | grep -qiE "API Error|safeguards flagged|flagged this message|can't respond to this request"; then
      verdict=flagged
    else
      verdict=ok
    fi
    if [ "$verdict" = "dead" ]; then
      fail A4 "模型 '$BM' 用不了(不存在/此账号无权限)——新建会话+断电自愈会启动即死(见 DEPLOY 必改·会话模型)" "rc=$rc 回复=${reply:-空}"
    elif [ "$BM" != "$SVC" ]; then
      fail A4 "bashrc 与 cloud-watchdog.service 的 CLOUD_MODEL 不一致(交互能开,断电自愈却用另一个模型)" "bashrc=$BM service=${SVC:-空}"
    elif [ "$verdict" = "flagged" ]; then
      skip A4 "模型 '$BM' 可达但 headless 探针被内容分类器拦(如 Fable5 -p 直接拒答);bashrc==service 一致,交互/自愈另见 S 组" "回复=${reply}"
    else
      pass A4 "会话模型 '$BM' 可用,且 bashrc 与 watchdog.service 一致" "探针回复=${reply}"
    fi
  fi

  # A5 watchdog 定时器真在跳(60s 内触发过)且近 3 分钟无 Python 崩栈
  local lt ep now age tb
  lt=$(systemctl show cloud-watchdog.timer -p LastTriggerUSec --value 2>/dev/null)
  ep=$(date -d "$lt" +%s 2>/dev/null || echo 0); now=$(date +%s); age=$((now-ep))
  tb=$(journalctl -u cloud-watchdog.service --since "-3min" --no-pager 2>/dev/null | grep -c "Traceback")
  if [ "$ep" -gt 0 ] && [ "$age" -lt 60 ] && [ "${tb:-0}" -eq 0 ]; then
    pass A5 "cloud-watchdog.timer 在跳(距上次触发 ${age}s)且近3分钟无 Traceback" "LastTrigger=$lt"
  else
    fail A5 "watchdog 没在跳或在崩(自愈=摆设)" "LastTrigger=${lt:-无} 距今=${age}s Traceback=$tb"
  fi

  # A6 watchdog 手动跑一轮 exit 0(它每 15s 干的活,亲手干一遍)
  out=$(PATH="$HOME/.local/bin:$PATH" cloud-watchdog 2>&1); rc=$?
  if [ $rc -eq 0 ]; then pass A6 "cloud-watchdog 手动对账一轮 exit 0" "$(printf '%s' "${out:-静默(无需恢复)}" | one_line)"
  else fail A6 "cloud-watchdog 手动跑报错(rc=$rc)" "$(printf '%s' "$out" | one_line)"; fi

  # A7 tailscale 内网通(中美加密通道=命脉)
  local ip; ip=$(tailscale ip -4 2>/dev/null | head -1)
  case "$ip" in
    100.*) pass A7 "tailscale 在线,内网 IP $ip" "tailscale ip -4" ;;
    *)     fail A7 "tailscale 不在线/无 100.x 地址(Wave/手机全都连不进来)" "得到:'${ip:-空}',恢复: tailscale up" ;;
  esac

  # A8 防火墙基线:ufw active + 22/tcp + mosh UDP 段 + tailscale0 放行;fail2ban 在防爆破
  local u f2b; u=$(ufw status 2>/dev/null); miss=""
  printf '%s' "$u" | grep -q "Status: active"     || miss="$miss ufw未启用"
  printf '%s' "$u" | grep -q "22/tcp"             || miss="$miss 22/tcp"
  printf '%s' "$u" | grep -q "60000:61000/udp"    || miss="$miss mosh-udp(60000:61000)"
  printf '%s' "$u" | grep -q "tailscale0"         || miss="$miss tailscale0"
  f2b=$(systemctl is-active fail2ban 2>/dev/null); [ "$f2b" = "active" ] || miss="$miss fail2ban=$f2b"
  if [ -z "$miss" ]; then pass A8 "ufw 基线齐(22/tcp+mosh-udp+tailscale0)且 fail2ban 在岗" "ufw active + fail2ban active"
  else fail A8 "防火墙基线缺项" "缺:$miss"; fi

  # A9 OOM 四层硬化落地(oom/harden.sh 承诺的可验状态)
  local eo sw oc smb; miss=""
  eo=$(systemctl is-active earlyoom 2>/dev/null);      [ "$eo" = "active" ] || miss="$miss earlyoom=$eo"
  sw=$(cat /proc/sys/vm/swappiness 2>/dev/null);       [ "${sw:-0}" = "60" ] || miss="$miss swappiness=$sw(应60)"
  oc=$(cat /proc/sys/vm/overcommit_memory 2>/dev/null);[ "${oc:-9}" = "1" ]  || miss="$miss overcommit=$oc(应1)"
  smb=$(free -m | awk '/^Swap:/{print $2}');           [ "${smb:-0}" -ge 8000 ] || miss="$miss swap=${smb}MB(应≥8000)"
  if [ -z "$miss" ]; then pass A9 "OOM 硬化到位(earlyoom+swappiness60+overcommit1+swap≥8G)" "swap=${smb}MB"
  else fail A9 "OOM 硬化没落地(单会话内存暴涨会拖垮整机),重跑 bash oom/harden.sh" "缺:$miss"; fi

  # A10 hub 多会话中控可用
  out=$(hub ls 2>&1); rc=$?
  if [ $rc -eq 0 ]; then pass A10 "hub ls exit 0(多会话协同可用)" "$(printf '%s' "$out" | head -1 | one_line)"
  else fail A10 "hub ls 报错(rc=$rc)" "$(printf '%s' "$out" | one_line)"; fi

  # A11 两个开机自启项确实 enabled(重启后体系自己站起来的前提)
  local e1 e2
  e1=$(systemctl is-enabled cloud-sessions.service 2>/dev/null)
  e2=$(systemctl is-enabled cloud-watchdog.timer 2>/dev/null)
  if [ "$e1" = "enabled" ] && [ "$e2" = "enabled" ]; then
    pass A11 "cloud-sessions.service 与 cloud-watchdog.timer 均已 enabled(重启自动到位)" "enabled/enabled"
  else fail A11 "开机自启缺失(重启后自愈体系起不来)" "cloud-sessions=$e1 watchdog.timer=$e2"; fi

  # A12 tailnet 自动发现能力就绪:tailscale 命令可用(枚举 tailnet 设备的前提)+
  #     claude-config/CLAUDE.md 文档化了「tailnet 自动发现」能力段(够清单外机器:枚举+ssh探活+幂等登记)。
  #     纯只读:一个命令查 + 一次 grep,不枚举真机、不发 ssh 探针、不碰会话。
  local tshave doc
  command -v tailscale >/dev/null 2>&1 && tshave=1 || tshave=""
  grep -q "tailnet 自动发现" "$REPO/claude-config/CLAUDE.md" 2>/dev/null && doc=1 || doc=""
  if [ -n "$tshave" ] && [ -n "$doc" ]; then
    pass A12 "tailnet 自动发现能力就绪(tailscale 命令可用 + CLAUDE.md 文档化)" "grep 命中 'tailnet 自动发现'"
  elif [ -z "$tshave" ]; then
    fail A12 "tailscale 命令不可用(自动发现枚举 tailnet 设备的前提没了)" "command -v tailscale 无;恢复: 装 tailscale + tailscale up"
  else
    fail A12 "claude-config/CLAUDE.md 未文档化'tailnet 自动发现'能力段(够清单外机器的流程没写)" "grep 未命中关键词"
  fi
}

# =========================== B 组 · deck 服务端(只读) ===========================
# 全部只读:不新建/杀会话、不跑 claude 探针,只查 deck 脚本(cc-new/cc-restore/
# cc-slugs-by-tab/cc-agents)是否装齐、防-127 的 PATH 行在不在、账本是否同源、面板能否出。
run_deck(){
  echo "== B组·deck 服务端(只读) =="
  local out rc miss b p

  # B1 四个 deck 脚本存在且可执行(在 PATH 里,通常 /usr/local/bin 或 ~/.local/bin)
  miss=""
  for b in cc-new cc-restore cc-slugs-by-tab cc-agents; do
    command -v "$b" >/dev/null 2>&1 || miss="$miss $b"
  done
  if [ -z "$miss" ]; then pass B1 "deck 四脚本齐备(cc-new/cc-restore/cc-slugs-by-tab/cc-agents 均在 PATH)" "command -v 全命中"
  else fail B1 "deck 脚本缺失" "缺:$miss"; fi

  # B2 防 127:cc-new / cc-restore 脚本头部必须有一行 export PATH= 且含 .local/bin
  #    否则 ssh -t 非交互调用下 sshd 只给极简 PATH → 找不到 claude → 会话秒退 status 127(见 deploy-pitfalls P1)
  miss=""
  for b in cc-new cc-restore; do
    p=$(command -v "$b" 2>/dev/null)
    if [ -z "$p" ]; then miss="$miss $b(脚本不在)"; continue; fi
    grep -m1 'export PATH=.*\.local/bin' "$p" >/dev/null 2>&1 || miss="$miss $b(无 export PATH=…/.local/bin 行)"
  done
  if [ -z "$miss" ]; then pass B2 "cc-new/cc-restore 头部均有 export PATH=…/.local/bin(防 ssh 非交互 127 秒退)" "grep 命中 PATH 行"
  else fail B2 "缺防-127 的 PATH 行:ssh -t 非交互调用下会找不到 claude→会话秒退 status 127(见 deploy-pitfalls P1)" "缺:$miss"; fi

  # B3 账本同源:cc-slugs-by-tab 必须读 ~/.cloud-sessions,且不能还引用旧的 cc-registry.tsv(见 P4)
  p=$(command -v cc-slugs-by-tab 2>/dev/null)
  if [ -z "$p" ]; then
    fail B3 "cc-slugs-by-tab 不在 PATH,无法核账本同源" "command -v 无"
  else
    local hasnew hasold cnnew
    grep -q 'cloud-sessions' "$p" && hasnew=1 || hasnew=""
    grep -q 'cc-registry' "$p" && hasold=1 || hasold=""
    # 顺带核 cc-new 也写 cloud-sessions(bonus,不作判据)
    cnnew=""; b=$(command -v cc-new 2>/dev/null); [ -n "$b" ] && grep -q 'cloud-sessions' "$b" && cnnew=1
    if [ -n "$hasnew" ] && [ -z "$hasold" ]; then
      pass B3 "cc-slugs-by-tab 账本同源(读 ~/.cloud-sessions,无 cc-registry.tsv 旧引用)$([ -n "$cnnew" ] && echo '·cc-new 亦写 cloud-sessions')" "grep cloud-sessions 命中,cc-registry 无"
    elif [ -n "$hasold" ]; then
      fail B3 "cc-slugs-by-tab 仍引用旧 cc-registry.tsv(双账本错位,见 P4)" "grep 命中 cc-registry"
    else
      fail B3 "cc-slugs-by-tab 未读 ~/.cloud-sessions(账本源不对)" "grep cloud-sessions 无命中"
    fi
  fi

  # B4 cc-agents 能出面板:--json 只读秒退,输出须为合法 json 且含 "host" 字段
  if ! command -v cc-agents >/dev/null 2>&1; then
    fail B4 "cc-agents 不在 PATH,出不了面板" "command -v 无"
  else
    out=$(timeout 8 cc-agents --json 2>&1); rc=$?
    local host
    host=$(printf '%s' "$out" | python3 -c 'import json,sys
d=json.load(sys.stdin)
assert "host" in d
print(d["host"])' 2>/dev/null)
    if [ $rc -eq 0 ] && [ -n "$host" ]; then
      pass B4 "cc-agents --json 出合法面板,含 host=$host" "timeout 8 cc-agents --json"
    else
      fail B4 "cc-agents --json 报错/非法 json/缺 host 字段(面板出不来)" "rc=$rc $(printf '%s' "$out" | one_line)"
    fi
  fi
}

# ====================== S 组 · 断电自愈真测(破坏性,串行) ======================
# 只碰自建的 cc-ztest-<时间戳> 会话与 /opt/workspace/ztest-<时间戳> 目录;
# 杀真会话验 watchdog 是否连名带原对话拉回 —— 这是整套体系的核心承诺。
ZTS=""; ZNAME=""; ZDIR=""; ZMARK=""; ZUUID=""

cleanup_ztest(){   # S7 正式步骤 + trap EXIT 兜底共用;幂等,可重复调
  [ -n "${ZNAME:-}" ] || return 0
  [[ "$ZNAME" =~ ^cc-ztest-[0-9]+$ ]] || return 0            # 双保险:只清 ztest
  cc-sessions forget "$ZNAME" >/dev/null 2>&1                # ① 先移出恢复名单(否则 kill 完 watchdog 15s 后又复活成僵尸)
  tmux kill-session -t "$ZNAME" 2>/dev/null                  # ② 再杀会话
  sleep 2                                                    #    给退出钩子落盘窗口,补扫防 SessionEnd 重建登记文件
  rm -f "$HOME/.cloud-sessions/$ZNAME.json" "$HOME/.cloud-status/$ZNAME.json"   # ③ 登记/状态残留
  [ -n "${ZUUID:-}" ] && rm -f "$HOME"/.claude/projects/*/"$ZUUID".jsonl 2>/dev/null   # ④ 对话存档
  local enc="-opt-workspace-ztest-$ZTS"
  case "$enc" in -opt-workspace-ztest-[0-9]*) rm -rf "$HOME/.claude/projects/$enc";; esac   #    及其编码目录
  case "${ZDIR:-}" in /opt/workspace/ztest-[0-9]*) rm -rf "$ZDIR";; esac        # ⑤ 测试工作目录
}

run_selfheal(){
  echo "== S组·断电自愈真测(破坏性,只碰 cc-ztest-*) =="
  local avail; avail=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
  if [ "${avail:-0}" -lt 4500 ]; then
    blocked S0 "空闲内存 ${avail}MB < 4500MB,不起测试会话(watchdog 自身 <4000MB 也按兵不动,测了也白测)" "MemAvailable=${avail}MB"
    return 0
  fi
  command -v claude >/dev/null 2>&1 || { fail S1 "claude 不在 PATH,起不了测试会话" "command -v claude 无"; return 0; }

  ZTS=$(date +%s); ZNAME="cc-ztest-$ZTS"; ZDIR="/opt/workspace/ztest-$ZTS"; ZMARK="ZTEST-$ZTS"; ZUUID=""
  trap cleanup_ztest EXIT                                    # 半途死掉也把 ztest 残留清干净
  mkdir -p "$ZDIR"

  # 预信任测试目录(照抄 cloud-watchdog 的 pretrust:防新会话卡在"信任此文件夹?"弹窗)
  python3 - "$ZDIR" <<'PYEOF'
import json, os, sys
p = os.path.expanduser("~/.claude.json")
if os.path.exists(p):
    try: d = json.load(open(p))
    except Exception: sys.exit(0)          # 读不了就不动用户配置(宁可弹信任框,不覆写)
    if not isinstance(d, dict): sys.exit(0)
else:
    d = {}
d.setdefault("projects", {}).setdefault(sys.argv[1], {})["hasTrustDialogAccepted"] = True
tmp = p + ".ztest-tmp"
with open(tmp, "w") as f: json.dump(d, f)
os.replace(tmp, p)
PYEOF

  # 模型/参数取自 bashrc 赋值行(与 cloud-enter/新建会话同源;install.sh 的 sed 也锚定这两行)
  CLOUD_MODEL=""; CLOUD_OPTS=""
  eval "$(grep -m1 '^CLOUD_MODEL=' "$HOME/.bashrc" 2>/dev/null)"
  eval "$(grep -m1 '^CLOUD_OPTS='  "$HOME/.bashrc" 2>/dev/null)"
  if [ -z "$CLOUD_MODEL" ]; then
    fail S1 "~/.bashrc 无 CLOUD_MODEL(函数块没装),不猜默认值硬跑" "grep ^CLOUD_MODEL= 无命中"
    cleanup_ztest; return 0
  fi

  # S1 起一个真会话(启动命令照抄 bashrc-cloud-snippet 的 cloud():IS_SANDBOX=1 + skip-permissions;
  #    -d 后台 + env -u TMUX 以便本脚本自己在 tmux 里跑时也能建)。判据:cc-state 的「恢复登记」文件
  #    ~/.cloud-sessions/<name>.json ≤60s 出现 = 会话活了且 cc-state 钩子链路通。
  #    ★为什么盯登记文件、不盯 ~/.cloud-status:后者是已下线的 :8722 看板产物,当前部署的 cc-state
  #      多半不再写它(实测确实没写);而登记文件(name/dir/uuid/ended)才是断电自愈真正依赖、新旧 cc-state 都写的。
  env -u TMUX -u TMUX_PANE tmux new-session -d -s "$ZNAME" \
    "cd '$ZDIR' && IS_SANDBOX=1 claude --model '$CLOUD_MODEL' $CLOUD_OPTS --dangerously-skip-permissions"
  local reg="$HOME/.cloud-sessions/$ZNAME.json" t0 okS1=""
  t0=$(date +%s)
  while [ $(( $(date +%s) - t0 )) -le 60 ]; do [ -s "$reg" ] && { okS1=$(( $(date +%s) - t0 )); break; }; sleep 2; done
  if [ -n "$okS1" ]; then pass S1 "测试会话 $ZNAME 启动,${okS1}s 内恢复登记出现(cc-state 钩子链路通)" "$reg"
  else
    fail S1 "60s 无恢复登记文件(会话没起来或 cc-state 钩子没接上)" "屏幕尾行: $(tmux capture-pane -p -t "$ZNAME" 2>/dev/null | tail -3 | one_line)"
    cleanup_ztest; return 0
  fi

  # S2 恢复登记表字段正确(name↔dir↔uuid,ended=false —— 断电自愈全靠这条记录)
  local rdir="" rend="" i
  for i in $(seq 1 15); do
    IFS=$'\t' read -r ZUUID rdir rend < <(python3 - "$reg" <<'PYEOF'
import json, sys
try: r = json.load(open(sys.argv[1]))
except Exception: r = {}
print("%s\t%s\t%s" % (r.get("uuid",""), r.get("dir",""), "true" if r.get("ended") else "false"))
PYEOF
)
    [ -n "$ZUUID" ] && break; sleep 2
  done
  if [ -n "$ZUUID" ] && [ "$rdir" = "$ZDIR" ] && [ "$rend" = "false" ]; then
    pass S2 "登记表就位:uuid 非空 / dir=$ZDIR / ended=false" "uuid=${ZUUID:0:8}…"
  else
    fail S2 "登记表缺失或字段错(watchdog 将无从恢复)" "uuid=${ZUUID:-空} dir=${rdir:-空} ended=${rend:-?}"
    cleanup_ztest; return 0
  fi

  # ── 先让会话产生一次真对话(S3/S4 的前提)────────────────────────────────
  # 实测关键事实:新会话在「提交第一条消息」之前根本不写 ~/.claude/projects/*/<uuid>.jsonl,
  # 而 cc-sessions recoverable 要求 jsonl 存在才算「可恢复」→ 没发过消息的会话 kill 掉 watchdog 也不会拉。
  # 所以必须先发一条消息把对话落盘,S5 才有得测;故把「发消息」放在 S3(存档校验)之前。
  # 提交是否成功一律以「暗号是否进了 jsonl」为准 —— 不看 ~/.cloud-status(已下线)、也不 grep 屏幕:
  #   暗号会先在输入框回显 → capture-pane 假命中;而 jsonl 只记「已提交」的对话轮次,才是真凭据。
  local jl="" submitted="" answered="" tries=0
  sleep 3                                              # 等 TUI 输入框就绪
  tmux send-keys -t "$ZNAME" -l "reply with exactly this token: $ZMARK"
  sleep 1; tmux send-keys -t "$ZNAME" Enter
  t0=$(date +%s)
  while [ $(( $(date +%s) - t0 )) -le 120 ]; do
    jl=$(ls "$HOME"/.claude/projects/*/"$ZUUID".jsonl 2>/dev/null | head -1)
    if [ -n "$jl" ] && grep -qF "$ZMARK" "$jl" 2>/dev/null; then submitted=$(( $(date +%s) - t0 )); break; fi
    tries=$((tries+1)); [ $((tries % 4)) -eq 0 ] && tmux send-keys -t "$ZNAME" Enter   # 首个 Enter 可能被启动横幅吞 → ~每12s 补发一次
    sleep 3
  done
  # 顺带探一下模型是否真回了话(bonus,不作判据):Fable5 等被内容分类器拦时只落用户轮、不落 assistant 轮,
  # 但对话已可 --resume,断电自愈不受影响 —— 所以模型没回话不判 S4 负。
  if [ -n "$submitted" ]; then
    answered=$(python3 - "$jl" "$ZMARK" <<'PYEOF'
import json, sys
f, mark = sys.argv[1], sys.argv[2]; seen = asst = False
try:
    for ln in open(f):
        try: o = json.loads(ln)
        except Exception: continue
        if mark in json.dumps(o, ensure_ascii=False) and o.get("type") == "user": seen = True
        if seen and o.get("type") == "assistant": asst = True
except Exception: pass
print("yes" if asst else "no")
PYEOF
)
  fi

  # S3 对话存档唯一(--resume 的接头暗号恰好一份;由上面这条消息落盘)
  local n; n=$(ls "$HOME"/.claude/projects/*/"$ZUUID".jsonl 2>/dev/null | wc -l)
  if [ "$n" -eq 1 ]; then pass S3 "对话存档 jsonl 恰 1 份" "$jl"
  else fail S3 "对话存档数量异常(=$n,应为 1;=0 多半是消息没提交进去)" "glob ~/.claude/projects/*/$ZUUID.jsonl"; fi

  # S4 消息确已提交进对话(暗号落进 jsonl)= 会话既能收指令、对话也可被 resume 接回
  if [ -n "$submitted" ]; then
    pass S4 "暗号 $ZMARK 已落进对话 jsonl(${submitted}s;以 jsonl 为凭、与屏幕回显无关)$([ "$answered" = yes ] && echo ' + 模型已回话' || echo ' · 模型未回话(可能被内容分类器拦,不影响可恢复性)')" "jsonl 凭据"
  else
    fail S4 "120s 内暗号没进 jsonl(消息没提交成功——TUI 卡弹窗/输入没进去/模型起不来)" "屏幕尾行: $(tmux capture-pane -p -t "$ZNAME" 2>/dev/null | tail -3 | one_line)"
    cleanup_ztest; return 0                            # 没有可恢复对话 → S5 无从测,清理退出
  fi

  # S5【头号测试】模拟断电:kill 掉 tmux 会话。实测 kill-session 不会触发 SessionEnd → 登记 ended 保持
  #    false,忠实模拟「崩溃/断电」(而非「主动 /exit」——那会 ended=true、按设计不该自愈)。
  #    随后看 watchdog 是否 ≤90s 连名带原对话 --resume 拉回。
  if ! [[ "$ZNAME" =~ ^cc-ztest-[0-9]+$ ]]; then
    fail S5 "安全断言失败:会话名 '$ZNAME' 不符 ^cc-ztest-[0-9]+$,拒绝 kill" "防呆护栏"
    cleanup_ztest; return 0
  fi
  tmux kill-session -t "$ZNAME" 2>/dev/null
  sleep 3
  local recov; recov=$(cc-sessions recoverable 2>/dev/null | grep -c "$ZNAME")   # 死后应立即进「可恢复」名单(登记在∧jsonl在∧不在线∧非ended)
  local killt back="" alive="" proc="" markd=""
  killt=$(date +%s)
  while [ $(( $(date +%s) - killt )) -le 90 ]; do
    tmux has-session -t "$ZNAME" 2>/dev/null && { back=$(( $(date +%s) - killt )); break; }
    sleep 3
  done
  if [ -z "$back" ]; then
    fail S5 "kill 后 90s 无同名会话回归——断电自愈不工作" "recoverable列出=$recov watchdog.timer=$(systemctl is-active cloud-watchdog.timer 2>/dev/null) 登记ended=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("ended"))' "$reg" 2>/dev/null)"
  else
    sleep 30                                                       # ② 复查:不是回光返照
    tmux has-session -t "$ZNAME" 2>/dev/null && alive=1
    pgrep -f "resume $ZUUID" >/dev/null 2>&1 && proc=1             #    且进程参数真带 --resume <同一uuid>
    t0=$(date +%s)                                                 # ③ 原对话被 --resume 渲染回来(暗号重现)
    while [ $(( $(date +%s) - t0 )) -le 30 ]; do
      tmux capture-pane -p -t "$ZNAME" -S -300 2>/dev/null | grep -qF "$ZMARK" && { markd=1; break; }
      sleep 3
    done
    if [ -n "$alive" ] && [ -n "$proc" ] && [ -n "$markd" ]; then
      pass S5 "断电自愈全链路:${back}s 同名拉回 + 30s 后仍在 + 进程带 --resume 同uuid + 原对话暗号重现" "revive=${back}s uuid=${ZUUID:0:8}…"
    elif [ -n "$alive" ] && [ -n "$proc" ]; then
      pass S5 "自愈达成(降级判定):${back}s 同名拉回 + 进程带 --resume 同uuid;屏幕未见暗号(TUI 可能折叠历史,进程参数已证接回同一对话)" "revive=${back}s uuid=${ZUUID:0:8}…"
    else
      fail S5 "拉回不完整:30s后存活=${alive:-0} resume进程=${proc:-0} 暗号=${markd:-0}" "屏幕尾行: $(tmux capture-pane -p -t "$ZNAME" 2>/dev/null | tail -3 | one_line)"
    fi
  fi

  # S7 清理并复核零残留(顺序:先 forget 再 kill,防 watchdog 把尸体复活成僵尸)
  cleanup_ztest
  local resid=""
  tmux ls 2>/dev/null | grep -q "^cc-ztest-" && resid="$resid tmux会话"
  cc-sessions recoverable 2>/dev/null | grep -q "cc-ztest-" && resid="$resid recoverable"
  ls "$HOME/.cloud-sessions/" 2>/dev/null | grep -q "^cc-ztest-" && resid="$resid 登记表"
  if [ -z "$resid" ]; then pass S7 "ztest 零残留(tmux/recoverable/登记表都干净)" "forget→kill→rm 顺序清理"
  else fail S7 "清理后仍有 ztest 残留" "残留于:$resid"; fi
}

# ===================== O 组 · 可选层(未装 = SKIP 不判负) =====================
run_optional(){
  echo "== O组·可选层(手机审批/桌面/看板;未装=SKIP) =="
  local ip bad code
  ip=$(tailscale ip -4 2>/dev/null | head -1)

  # O1 moshi-hook(手机远程审批)
  if ! command -v moshi-hook >/dev/null 2>&1; then
    skip O1 "moshi-hook 未装(手机审批层,见 phone/README.md)" "command -v 无"
  else
    bad=""
    timeout 12 moshi-hook status 2>&1 | grep -qi "paired" || bad="$bad 未配对(moshi-hook pair)"
    [ "$(systemctl is-active moshi-hook.service 2>/dev/null)" = "active" ] || bad="$bad service不active"
    journalctl -u moshi-hook.service -n 3000 --no-pager 2>/dev/null | grep -q "ws bridge connected" || bad="$bad 日志无'ws bridge connected'"
    if [ -z "$bad" ]; then pass O1 "moshi 手机审批链路:已配对 + 守护 active + ws bridge 已连云端" "status/systemctl/journalctl 三证"
    else fail O1 "moshi 装了但链路不通(手机收不到审批)" "缺:$bad"; fi
  fi

  # O4 noVNC 图形桌面(:6080,只应绑 tailscale 内网 IP)
  if ! systemctl list-unit-files novnc.service --no-legend 2>/dev/null | grep -q "^novnc\.service"; then
    skip O4 "novnc.service 未装(图形桌面层可选)" "unit 不存在"
  else
    bad=""
    [ "$(systemctl is-active novnc.service 2>/dev/null)" = "active" ] || bad="$bad service不active"
    pgrep -x Xvfb >/dev/null 2>&1        || bad="$bad Xvfb没跑"
    pgrep -x x11vnc >/dev/null 2>&1      || bad="$bad x11vnc没跑"
    pgrep -f websockify >/dev/null 2>&1  || bad="$bad websockify没跑"
    code=$(curl -s -o /dev/null -m 8 -w '%{http_code}' "http://$ip:6080/vnc.html" 2>/dev/null)
    [ "$code" = "200" ] || bad="$bad vnc.html=$code"
    ss -ltn 2>/dev/null | grep -q "$ip:6080" || bad="$bad 6080未绑tailscale-IP($ip)"
    if [ -z "$bad" ]; then pass O4 "noVNC 桌面全链路(service+Xvfb/x11vnc/websockify+HTTP200+只绑内网IP)" "http://$ip:6080/vnc.html=200"
    else fail O4 "noVNC 装了但不健康(打开 :6080 会是空壳/打不开)" "缺:$bad"; fi
  fi

  # O5 项目看板(:8088)
  if ! systemctl list-unit-files cloud-dashboards.service --no-legend 2>/dev/null | grep -q "^cloud-dashboards\.service"; then
    skip O5 "cloud-dashboards.service 未装(看板层可选)" "unit 不存在"
  else
    bad=""
    [ "$(systemctl is-active cloud-dashboards.service 2>/dev/null)" = "active" ] || bad="$bad service不active"
    code=$(curl -s -o /dev/null -m 8 -w '%{http_code}' "http://$ip:8088/" 2>/dev/null)
    [ "$code" = "200" ] || bad="$bad http=$code"
    if [ -z "$bad" ]; then pass O5 "看板门户 active 且 :8088 返回 200" "http://$ip:8088/"
    else fail O5 "看板装了但打不开" "缺:$bad"; fi
  fi
}

# ============== M 组 · 迁移验收(仅在传 --projects 时执行) ==============
run_migrate(){
  echo "== M组·迁移验收(对话历史是否落到服务器路径) =="
  if [ -z "$PROJECTS" ]; then
    skip M1 "未传 --projects,迁移组不适用(用法: migrate --projects /opt/workspace/a,/opt/workspace/b)" ""
    return 0
  fi
  local i=0 p enc arr
  IFS=',' read -ra arr <<< "$PROJECTS"
  for p in "${arr[@]}"; do
    [ -z "$p" ] && continue
    i=$((i+1))
    enc=$(printf '%s' "$p" | sed 's#[/.]#-#g')
    if [ -d "$HOME/.claude/projects/$enc" ]; then
      pass "M1.$i" "项目 $p 的对话历史目录已就位" "~/.claude/projects/$enc"
    else
      fail "M1.$i" "项目 $p 无对话历史目录(历史没迁到/编码路径没改名,--resume 找不回旧对话)" "缺 ~/.claude/projects/$enc"
    fi
  done
  local macn macs
  macn=$(ls "$HOME/.claude/projects/" 2>/dev/null | grep -c '^-Users-')
  macs=$(ls "$HOME/.claude/projects/" 2>/dev/null | grep '^-Users-' | head -3 | tr '\n' ' ')
  if [ "${macn:-0}" -eq 0 ]; then
    pass M2 "无 Mac 旧路径编码目录残留(-Users-*)" "迁移改名完整"
  else
    fail M2 "发现 $macn 个 Mac 旧路径目录(-Users-*)没按服务器路径改名——这些项目的历史对话在服务器上找不回" "如: $macs"
  fi
}

# ================================ 入口 ================================
CMD="${1:-all}"; [ $# -gt 0 ] && shift
PROJECTS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --projects)   PROJECTS="${2:-}"; shift 2 ;;
    --projects=*) PROJECTS="${1#*=}"; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "未知参数: $1"; usage; exit 2 ;;
  esac
done

case "$CMD" in
  core)     run_core ;;
  deck)     run_deck ;;
  selfheal) run_selfheal ;;
  optional) run_optional ;;
  migrate)  run_migrate ;;
  all)      run_core; run_deck; run_selfheal; run_optional
            if [ -n "$PROJECTS" ]; then run_migrate; fi ;;
  -h|--help|help) usage; exit 0 ;;
  *) echo "未知子命令: $CMD"; usage; exit 2 ;;
esac

echo "== 汇总: PASS=$PASSES FAIL=$FAILS SKIP=$SKIPS BLOCKED=$BLOCKS =="
[ "$FAILS" -gt 0 ] && exit 1
exit 0
