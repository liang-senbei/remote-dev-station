# 部署后功能验收(deploy-test)

> 🔴 **先记死这条再往下读:所有 `claude` 探针(`claude -p ok` 之类的一次性调用)一律加
> `env -u TMUX -u TMUX_PANE` 前缀。** 验收的人(或 AI)自己往往就坐在被验机器的某个 cc-* tmux
> 会话里;cc-state 钩子按 `TMUX_PANE` 反查"当前 tmux 会话名"写恢复登记——裸跑探针 = 把**探针
> 自己的 uuid/目录覆盖进你所在会话的登记**,watchdog 之后按错的 uuid 拉、对话错乱,而且**不报错**。
> `tests/deploy-test.sh` 内部已全部这么做;你手敲复测时也必须。
> (唯一例外:测试自己新建的 `cc-deploytest-*` 会话,它们本来就该登记自己。)

照 [DEPLOY.md](../DEPLOY.md) 五阶段走完,只能说"装完了";本文回答**"怎么证明跑通了"**——先定义
"跑通"(五个闭环),再给全量测试点(A 核心 / S 破坏性自愈 / O 可选层 / M 迁移 / H 人工)和逐项判据。
链路最长、最容易挂的 S5 单独给一张失败定位表(§3)。对应 DEPLOY.md 阶段五「收尾验证」——那里的一行
"`cloud_infra_check.sh` + 各项体检"展开成可执行清单就是本文。

## 0. 两种跑法

**① 裸脚本**(机器判的都在这;H 类人工项不进脚本):

```bash
bash tests/deploy-test.sh all        # 全量:core → optional → migrate → selfheal
bash tests/deploy-test.sh core      # 只 A 段
bash tests/deploy-test.sh optional  # 只 O 段(没装的层记 SKIP,不判负)
bash tests/deploy-test.sh migrate   # 只 M 段(没做过迁移就全 SKIP)
bash tests/deploy-test.sh selfheal  # 只 S 段(破坏性,独占跑,别和别的并行)
```

输出约定:每项一行 `[PASS|FAIL|SKIP] <编号> <一句证据>`,结尾统计;**任一 FAIL → 退出码非 0**。
`all` 里若 core 有 FAIL,selfheal 整段自动标 SKIP(破坏性测试不在坏地基上跑)。

**② `/deploy-accept` 命令**(推荐,AI 编排):对刚部署完那台机器上的 Claude 说一句 `/deploy-accept`,
它会预检 → 并行跑 core/optional/migrate 并对每个 FAIL 下钻根因 → core 全绿才串行跑 selfheal →
AskUserQuestion 走人工项 → 汇总一页验收报告。命令文件在
[`claude-config/commands/deploy-accept.md`](../claude-config/commands/deploy-accept.md),客户机没有就拷一次:
`cp claude-config/commands/deploy-accept.md ~/.claude/commands/`。

时长预估:core ≈ 3 分钟(要真建会话等登记),optional/migrate 秒级,selfheal ≈ 5 分钟(S2 观察 45s、
S5 最长等 120s);全量 10 分钟内。

## 1. "跑通"的定义:五个闭环

五个都闭上才算跑通,缺一个都是"看着装好了、一出事就露馅":

1. **建会话 + 模型真可用**——新建 cc-* 会话里 claude 真起来(不是启动即死)。对应 A2/A3/A6。
   最高频翻车点:仓里默认模型 `claude-fable-5[1m]` 是作者账号专属,客户账号没有(DEPLOY 阶段一)。
2. **cc-state 登记**——会话一有动静,`~/.cloud-sessions/<名>.json` 就有 name/dir/uuid。对应 A5/A6/A7。
   这是一切自愈的地基:登记表恒空 = watchdog 无从拉起,还**不报错**。
3. **杀会话 → watchdog 按 uuid 拉回**——tmux 会话被杀(≈断电/崩溃)后,15s 级 watchdog 连名带对话
   原样接回。对应 S5(正向)+ S2(反向:主动 `/exit` 的不纠缠)。
4. **OOM 硬化在位**——swap / swappiness / overcommit / earlyoom / user.slice 软顶 四层都在,
   单个会话内存暴涨拖不垮整机。对应 A8。
5. **tailscale·ufw·可选层就位**——入网命脉 + 防火墙基线 + 装了的可选层(Moshi/桌面/看板)都活着。
   对应 A4/A9 + O 段。

## 2. 全量测试点清单

### 2.1 A · 核心(必须全 PASS)

只读探针 + 一个真会话闭环(A6),可与 O/M 段并行。下表 `$M` 指从 `~/.bashrc` 读出的
`CLOUD_MODEL` 值:`M=$(grep -m1 '^CLOUD_MODEL=' ~/.bashrc | cut -d'"' -f2)`。

| 编号·测什么 | 怎么测 | 期望(PASS 判据) | FAIL 怎么判 / 去哪修 |
|---|---|---|---|
| **A1** 脚本与接线就位 | `~/.local/bin/` 下 `cc-state cc-sessions cloud-watchdog cloud-forget cloud-sessmenu cloud-sesslist cloud-sesspreview cloud-delmenu hub` 全部可执行;`/usr/local/bin/cloud-boot.sh` 在;`grep -q 'Moshi-CloudCode setup' ~/.bashrc`;`[ -f ~/.tmux.conf ]` | 全在 | 缺啥都别单补,重跑 `./install.sh`(幂等) |
| **A2** 登录 + 模型真可用 | `timeout 90 env -u TMUX -u TMUX_PANE claude --model "$M" -p ok` | 退出码 0 且有非空回复 | 报未登录 → [headless-login.md](headless-login.md);报模型不存在/无权限 → **DEPLOY 阶段一「必改·会话模型」**(最高频坑) |
| **A3** 模型两处一致 | 比对 `~/.bashrc` 的 `CLOUD_MODEL="…"` 与 `/etc/systemd/system/cloud-watchdog.service` 的 `Environment="CLOUD_MODEL=…"` | 两值相同,且客户机上**不是** `claude-fable-5[1m]` | 只改一处 = "新建会话正常、断电自愈全死"(或反过来);两处都改后 `systemctl daemon-reload && systemctl restart cloud-watchdog.timer` |
| **A4** systemd 核心 + 入网 | `systemctl is-active cloud-watchdog.timer cloud-sessions.service tailscaled fail2ban`;`systemctl is-enabled cloud-watchdog.timer cloud-sessions.service`;`tailscale ip -4` | 全 active 且 enabled;有 `100.x.y.z` | 不 active 的按 `cloud_infra_check.sh` 打印的「恢复:」提示;tailscale 起不来 → [tailscale-setup.md](tailscale-setup.md) |
| **A5** cc-state 钩子接线 | `grep -q cc-state ~/.claude/settings.json` | 命中 | 没命中 = 登记表恒空、自愈静默哑火 → 铺/合并 `claude-config/settings.client.json`(DEPLOY 阶段一) |
| **A6** 建会话→登记闭环 | 建 `n=cc-deploytest-$RANDOM`:`tmux new-session -d -s $n "cd /opt/workspace && IS_SANDBOX=1 claude --model \"$M\" --effort max -n deploytest --dangerously-skip-permissions"`;10s 后 pane 进程树里仍有 claude;`tmux send-keys -t $n '只回复 ok' Enter`;轮询 ≤60s `~/.cloud-sessions/$n.json` 出现且 `.uuid` 非空 | 会话活着 + 登记齐 | claude 秒退 → 回看 A2/A3;登记文件不出现 → A5;uuid 恒空 → 看 `~/.claude/projects/-opt-workspace/` 有没有新 jsonl |
| **A7** 登记可解析 | (A6 会话还活着时)`cc-sessions list` 含 `$n`;`cc-sessions resolve $n` 给出 dir+uuid;测完 `cloud-forget $n` 清场 | 都命中,清场成功 | resolve 失败 = 登记 json 损坏/缺字段 → 直接看 `~/.cloud-sessions/$n.json` 内容 |
| **A8** OOM 硬化在位 | `free -m` 看 Swap;`cat /proc/sys/vm/swappiness`;`cat /proc/sys/vm/overcommit_memory`;`systemctl is-active earlyoom`;`[ -f /etc/systemd/system/user.slice.d/50-memoryhigh.conf ]` | swap ≥ 8G(或原有更大)、swappiness=60、overcommit=1、earlyoom active、conf 在 | 任一缺 → 重跑 `bash oom/harden.sh`(幂等);earlyoom 装不上的极简镜像按脚本自己的提示处理 |
| **A9** 防火墙基线 | `ufw status` | `Status: active`,含 `22/tcp`、`60000:61000/udp`(mosh)、`Anywhere on tailscale0` | 缺哪条照 install.sh 第 [6/7] 步补 `ufw allow …`,再 `ufw --force enable` |
| **A10** 基建体检全绿 | `bash cloud_infra_check.sh; echo $?` | 退出码 0(可选层显示 ⏭ 不算失败) | 按它打印的「恢复:」逐项修完重跑 |

### 2.2 S · 破坏性自愈(串行独占;core 全 PASS 才跑)

- 全部动作只碰**专用牺牲会话 `cc-deploytest-heal-*`**,不碰客户已有会话。
- **必须串行独占**:S 段跑的时候别的人/agent 不得建、杀会话——watchdog 观察窗里混进别的动作,
  结果没法判(见 §3 第 8 行)。
- 万一测试中途断掉,先清场:`cloud-forget` 掉所有 `cc-deploytest-*`(见 §5)。

| 编号·测什么 | 怎么测 | 期望(PASS 判据) | FAIL 怎么判 / 去哪修 |
|---|---|---|---|
| **S1** 牺牲会话就绪 | 照 A6 流程建 `h=cc-deploytest-heal-$RANDOM`,发一句带标记的话(如"应答 S5MARK"),等登记 `.uuid` 非空、对话 jsonl 落盘 | 登记齐 | 不过 = core 其实没绿,回去修 A 段再来 |
| **S2** 主动退出不纠缠 | `tmux send-keys -t $h '/exit' Enter` → 轮询 ≤30s:tmux 会话消失、登记 `.ended==true` → 再观察 45s(≥3 个 watchdog 周期) | **不被复活** | `ended` 没置 true → SessionEnd 钩子没跑(回 A5);被复活了 → `cc-sessions recoverable` 过滤失效,`diff ~/.local/bin/cc-sessions bin/cc-sessions` 对照仓版 |
| **S3** 守卫与退避在位 | `grep -cE 'MIN_FREE_MB\|MAX_PER_CYCLE\|BACKOFF' ~/.local/bin/cloud-watchdog` ≥ 3;手跑 `~/.local/bin/cloud-watchdog` 退出 0;`journalctl -u cloud-watchdog --since -30min` 无反复"拉起…仍死" | 常量在、空转正常、无雪崩迹象 | 版本不对 → 重跑 `./install.sh`。真 OOM 行为**不在此演练**(风险不可控),线上靠 A8 那五层兜 |
| **S4** boot 线缩水演练 | `systemctl restart cloud-sessions.service && systemctl is-active cloud-sessions.service cloud-watchdog.timer` | 都 active(boot 脚本只起 timer、不猛拉,重启后靠 watchdog 每轮 1 个逐个回) | restart 失败看 `journalctl -u cloud-sessions`;真重启全链路 = H3 |
| **S5** 杀会话→按 uuid 拉回(金标准) | 重建牺牲会话(同 S1),记 `U=登记里的 uuid` → `tmux kill-session -t $h`(模拟崩溃/断电)→ 轮询 ≤120s `tmux has-session -t $h` | ≤120s 同名回来;pane 里是 **claude 进程**(不是 bash 空壳);登记 `.uuid` 仍 = `U`(同一段对话接回) | **照 §3 定位表从上往下排**。测完 `cloud-forget $h` |

> S5 为什么给到 120s:timer 每 15s 一轮、每轮最多温和拉 1 个,内存紧张还会整轮暂缓。判 FAIL 前
> 先看 `journalctl -u cloud-watchdog` 有没有"暂缓/退避"——那是守卫在干活,不是坏了。

### 2.3 O · 可选层(装了才测;没装 SKIP 不判负)

| 编号·测什么 | 怎么测 | 期望(PASS 判据) | FAIL 怎么判 / 去哪修 |
|---|---|---|---|
| **O1** moshi-hook 守护+配对 | `command -v moshi-hook` 没有 → SKIP;有 → `systemctl is-active moshi-hook.service` + `timeout 12 moshi-hook status` 显示 paired + `journalctl -u moshi-hook --since -10min \| grep -i 'ws bridge connected'` | active + paired + bridge 通 | 配对/换账号/连不上,照 [phone/README.md](../phone/README.md) §2、§4 |
| **O2** moshi 自愈兜底 | (O1 装了才查)`systemctl is-active moshi-hook-healthcheck.timer` | active | `systemctl enable --now moshi-hook-healthcheck.timer` |
| **O3** 桌面层 noVNC | `systemctl is-active novnc.service` 未装 → SKIP;装了再 `curl -fsS -m5 -o /dev/null http://127.0.0.1:6080/vnc.html` | active + HTTP 可达 | [desktop-layer.md](desktop-layer.md);"空壳无桌面"老毛病已由 wait-在-Xvfb 修掉,再犯 → `systemctl restart novnc` |
| **O4** 项目看板 | `systemctl is-active cloud-dashboards.service` 未装 → SKIP;装了再 `curl -fsS -m5 -o /dev/null http://127.0.0.1:8088/` | active + 响应 | `systemctl restart cloud-dashboards.service` |
| **O5** shell 增强 | `command -v fzf`;`command -v starship`;`[ -d ~/.local/share/blesh ]` | **fzf 必须有**;starship/blesh 缺只提示 | fzf 缺判 **FAIL 不是 SKIP**——cloudgo 选择器/新建/分级删除菜单全靠它,没它入口哑火:`apt-get install -y fzf`;其余重跑 install.sh 尾段 |
| **O6** 反向通道 mac/laptop | `grep -q '^Host mac' ~/.ssh/config` 没配 → SKIP;配了 → `ssh -o BatchMode=yes -o ConnectTimeout=8 mac true`(`laptop` 同理) | 退出 0 | [mac-reverse-channel.md](mac-reverse-channel.md) / [windows-reverse-channel.md](windows-reverse-channel.md) |
| **O7** cloudflared 对外隧道 | `systemctl is-active cloudflared.service` | 作者环境专属;客户机 SKIP 即正常 | — |

### 2.4 M · 迁移(做过 DEPLOY 阶段四才测;没做全段 SKIP)

判"做没做迁移":部署参数表里记了 / 直接问客户;脚本侧探 `~/.claude/skills`、`~/.claude/commands`
有非模板内容或 `/tmp/claude-migrate.tgz` 痕迹。

| 编号·测什么 | 怎么测 | 期望(PASS 判据) | FAIL 怎么判 / 去哪修 |
|---|---|---|---|
| **M1** 记忆目录路径编码 | 快筛 `ls ~/.claude/projects/ \| grep '^-Users-'`;再逐个目录名反解回路径查本机 `[ -d ]` | 无 `-Users-*` 等旧机编码;点名要迁的项目记忆目录按**新路径**编码存在(如 `-opt-workspace-<项目>`) | 有残留 = 记忆**静默不加载**(不报错、就是不生效)→ 按 DEPLOY 阶段四「记忆·编码路径改名」重命名 |
| **M2** settings 合并完整 | `grep -q cc-state ~/.claude/settings.json` 且 `grep -o '"/Users/[^"]*"' ~/.claude/settings.json` 为空 | 自愈钩子还在、无旧机死路径 | 钩子被旧 settings 盖掉 → 重新合并 `settings.client.json` 的 hooks;死路径逐条改/删(DEPLOY 阶段四「settings 别整份覆盖」) |
| **M3** skills/commands/MCP 到位 | 对着客户点名清单查 `~/.claude/skills/`、`~/.claude/commands/`;`mcpServers.json` 里每个 `command` 都 `command -v` 得到 | 清单齐、MCP 命令可执行 | 缺的:能从市场重装的重装,客户私有的手动迁(DEPLOY 阶段四) |
| **M4** 红线自查 | `grep -il 'xiaoxihexiaoyu' ~/.claude/CLAUDE.md`;`git -C <仓目录> remote get-url origin` | CLAUDE.md 是客户自己的(不含作者业务规则);origin ≠ 作者仓 | 命中 = 违 DEPLOY §7 红线 1/3 → 换客户自己的 CLAUDE.md / fork |
| **M5** 迁移垃圾与密钥 | `ls /tmp/claude-migrate.tgz` 及解包临时目录 | 已删;若包还在,`tar tzf` 里**不得**含 `.credentials.json` | 包里有密钥 = 高危 → 立删,并让客户重新登录换凭据(红线 2:不经手明文密钥) |

### 2.5 H · 人工(不进脚本;/deploy-accept 用 AskUserQuestion 走)

- **H1 电脑端遥控闭环(必做)**:客户从**自己电脑**(Mac:Wave + cloudconn;Windows:照
  [windows/README.md](../windows/README.md))连上、进会话、对话一来一回。判据:现场演示或客户确认。
  挂了先查 README「常见卡点」:两端同 tailnet?`cloudconn` 的 HOST 改成客户 IP 了没?
- **H2 手机审批闭环(装了 Moshi 才要求)**:开一个**不带** `--dangerously-skip-permissions` 的临时
  探针会话(`env -u TMUX -u TMUX_PANE claude --model "$M"`),让它跑条命令触发权限请求 → 手机 Moshi
  弹批准、批完命令真执行。判据:手机上真批到。挂了照 [phone/README.md](../phone/README.md) §4
  从高频到低频排。
- **H3 真重启演练(推荐,客户点头才做)**:`reboot` → 开机后
  `systemctl is-active cloud-sessions.service cloud-watchdog.timer` 都 active → 几分钟内登记的非
  ended 会话**逐个**回齐(watchdog 每轮最多 1 个,别急)→ 客户端重连接回。判据:回齐,且
  `journalctl -k --since -15min | grep -i 'out of memory'` 无新 OOM。S4 只是它的缩水版,真重启这一遍
  最能压实闭环 3+4。

## 3. S5 失败定位表(从高频到低频)

S5 是全链路(登记 → recoverable 过滤 → timer → 内存守卫 → resume → 模型 → trust),挂了别瞎猜,
按现象对号:

| # | 现象 | 第一查 | 根因 | 修法 |
|---|---|---|---|---|
| 1 | 120s 没动静,journal 里连提都没提这会话 | `systemctl is-active cloud-watchdog.timer`;`cc-sessions recoverable` 里有没有它 | timer 没跑;或被 recoverable 滤掉:登记 `ended=true` / `uuid` 空 / 对话 jsonl 不在 / 登记的 dir 已不存在 | timer:`systemctl enable --now cloud-watchdog.timer`;其余打开 `~/.cloud-sessions/<名>.json` 看哪个字段不对,分别回修 A5/A6;jsonl 不在多半是迁移路径编码错(M1) |
| 2 | journal 有"拉回 …",但会话起了又死、反复,最后打"退避" | `journalctl -u cloud-watchdog --since -10min`;把 unit 那条 resume 命令手跑一遍看真实报错 | **watchdog 用的是 unit 里 `Environment=CLOUD_MODEL`,不是 `~/.bashrc`**——只改了 bashrc 一处,自愈还在用作者专属模型,启动即死 | DEPLOY 阶段一「必改·会话模型」**两处都改** → `systemctl daemon-reload && systemctl restart cloud-watchdog.timer`;然后等退避冷却(600s)或删 `~/.cloud-status/_watchdog.json` 立即重试 |
| 3 | journal 打"内存仅 xxxMB(<4000),暂缓恢复" | `free -m` | 不是 bug:内存守卫在防 OOM 雪崩,空闲 <4G 整轮不拉 | 关几个闲会话后自动继续;真要激进,调 watchdog 里 `MIN_FREE_MB`(自担 OOM 风险) |
| 4 | journal 打"退避 <名>: 180s 内拉起 3 次仍死,冷却 600s" | 手动跑一遍 resume 命令,看它到底怎么死的 | 会话本身起不来(模型/登录/目录没了),watchdog 按设计退避防狂拉 | 先修死因(多半就是第 2 行),再等冷却或删 `~/.cloud-status/_watchdog.json` |
| 5 | 会话回来了,但登记 uuid 变了 / 对话是全新的 | `ls ~/.claude/projects/<目录编码>/ \| grep <旧uuid>`;手跑 `env -u TMUX -u TMUX_PANE claude --resume <旧uuid>` 看报错 | 旧 jsonl 没了(被删 / 路径编码不对),resume 失败落成新对话 | 找回/修正 jsonl 位置(M1);实在找不回就接受新对话、让登记随之更新 |
| 6 | tmux 会话在,里面却是个 bash 壳、没 claude | `ps --forest -o pid,cmd -g $(tmux list-panes -t <名> -F '#{pane_pid}')`;`diff ~/.local/bin/cloud-watchdog bin/cloud-watchdog` | 旧版 watchdog 的 `\|\| exec bash` 残留:claude 崩了剩壳冒充存活,watchdog 以为成功不再补救 | 重跑 `./install.sh` 装仓版(新版故意让失败会话彻底死 → 下轮重试 + 退避兜底) |
| 7 | 拉起后卡在"信任此目录?"对话框 | `~/.claude.json` 里 `projects.<dir>.hasTrustDialogAccepted` | pretrust 没写成:`~/.claude.json` 损坏/只读 | 修 `~/.claude.json` 权限/格式;应急可进会话手动点一次信任 |
| 8 | "回来了"但 uuid 对不上,journal 也没拉过 | journal + 登记文件的 `src`/`ts` | 竞态:观察窗里有人/别的 agent 手动建了同名会话,watchdog 临起前查到同名已在就跳过了 | 保证 S 段独占重测——这正是"selfheal 必须串行"的原因 |

## 4. 判定标准

- **验收通过**:A 全 PASS + S 全 PASS + 已装的 O 全 PASS(fzf 缺按 FAIL 算)+(做过迁移则)M 全
  PASS + H1 通过(装了 Moshi 则 H2 也要过)。H3 推荐、不强制。
- **有条件通过**:A/S 全绿,只有 O/M 里非关键项没修 → 列明"什么条件、谁负责、多久修完"再交付。
- **不通过**:A 或 S 任一 FAIL。别交付,按对应行修完整段重跑。

## 5. 收尾清场

测试自己造的东西自己收干净,不给客户留尾巴:

```bash
# 1) 移出恢复名单并杀掉所有测试会话(对话存档保留,不删)
tmux ls -F '#{session_name}' 2>/dev/null | grep '^cc-deploytest-' | xargs -rn1 cloud-forget
# 2) 登记表不应再有残留(有就逐个 cc-sessions forget)
ls ~/.cloud-sessions/ | grep deploytest || echo clean
# 3) 收尾后再体检一遍,确认核心仍全绿
bash cloud_infra_check.sh
```

测试对话的 jsonl(在 `~/.claude/projects/-opt-workspace/` 下)留着无害;要洁癖可按 uuid 删。
`~/.cloud-status/_watchdog.json` 里的退避残留会在会话不再"该活没活"后自动清,不用管。
