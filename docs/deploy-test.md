# 部署后功能验收(deploy-test)

> 🔴 **先记死这条再往下读:所有 `claude` 探针(`claude -p 只回复OK` 之类的一次性调用)一律加
> `env -u TMUX -u TMUX_PANE` 前缀。** 验收的人(或 AI)自己往往就坐在被验机器的某个 cc-* tmux
> 会话里;cc-state 钩子按 `TMUX_PANE` 反查"当前 tmux 会话名"写恢复登记——裸跑探针 = 把**探针
> 自己的 uuid/目录覆盖进你所在会话的登记**,watchdog 之后按错的 uuid 拉、对话错乱,而且**不报错**。
> `tests/deploy-test.sh` 内部已全部这么做(A4 模型探针、S1 建会话都带);你手敲复测时也必须。
> (唯一例外:测试自己新建的 `cc-ztest-*` 会话,它们本来就该登记自己。)

照 [DEPLOY.md](../DEPLOY.md) 五阶段走完,只能说"装完了";本文回答**"怎么证明跑通了"**——先定义
"跑通"(五个闭环),再给全量测试点(A 核心 / S 破坏性自愈 / O 可选层 / M 迁移 / H 人工·补充)和
逐项判据。编号与 `tests/deploy-test.sh` 的输出一一对应(**脚本是权威**,本文跟它走)。链路最长、
最容易挂的 S5 单独给一张失败定位表(§3)。对应 DEPLOY.md 阶段五「收尾验证」——那里的一行
"`cloud_infra_check.sh` + 各项体检"展开成可执行清单就是本文。

## 0. 怎么跑(裸脚本)

机器能判的测试点都在 `tests/deploy-test.sh` 里(H 类人工项不进脚本):

```bash
bash tests/deploy-test.sh core      # 只 A 组:核心链路(只读探测,不碰现有会话)
bash tests/deploy-test.sh selfheal  # 只 S 组:断电自愈真测(破坏性,只碰 cc-ztest-* 自建会话;独占跑)
bash tests/deploy-test.sh optional  # 只 O 组:可选层(没装的层记 SKIP,不判负)
bash tests/deploy-test.sh migrate --projects /opt/workspace/a,/opt/workspace/b   # 只 M 组:迁移验收
bash tests/deploy-test.sh all [--projects ...]   # 全量:core → selfheal → optional(migrate 仅在传了 --projects 时跑)
```

输出约定:每项一行 `[PASS|FAIL|SKIP|BLOCKED] <ID> 说明 | 证据`,结尾一行汇总统计;**所跑各组中
任一 FAIL → 退出码 1;全 PASS/SKIP/BLOCKED → 0**。BLOCKED 有两种:已有另一份 deploy-test 在跑
(**全脚本 flock 单实例锁** `/tmp/.deploy-test-selfheal.lock`——core/optional 也不能与 selfheal
并发,后来者直接退出码 2),或空闲内存不足(S0,整组不测)。BLOCKED 不判负,但也**没测成**——
等锁/腾内存后重跑才算数。

注意:`all` **不看 core 结果、无条件按序接着跑 selfheal**(只有内存不足才整组 BLOCKED)。想要
"地基全绿才做破坏性真测",就分两步手跑:先 `core`,全绿了再 `selfheal`。

也可以让机器上的 Claude 来编排:先跑 `core`/`optional`、对每个 FAIL 下钻根因,`core` 全绿再串行
跑 `selfheal`,最后用 AskUserQuestion 走人工项、汇总一页验收报告(注意裸脚本有单实例锁,同刻只有
一份真在跑,撞锁的 BLOCKED 后错峰重跑即可)。

时长预估:core ≈ 1–3 分钟(大头是 A4 真发一次模型探针,上限 240s),optional/migrate 秒级,
selfheal ≈ 3–6 分钟(S1 等登记 ≤60s、发暗号 ≤120s、S5 等拉回 ≤90s 再复查 30s);全量 10 分钟内。

## 1. "跑通"的定义:五个闭环

五个都闭上才算跑通,缺一个都是"看着装好了、一出事就露馅":

1. **建会话 + 模型真可用**——`CLOUD_MODEL` 指的模型在这台机、这个账号上真能出活(不是启动即死)。
   对应 A4(模型探针 + bashrc/service 两处一致)+ S1(真会话起得来)。
   最高频翻车点:仓里默认 `CLOUD_MODEL` 可能是特殊模型,普通账号没有(DEPLOY 阶段一)。
2. **cc-state 登记**——会话一有动静,`~/.cloud-sessions/<名>.json` 就有 name/dir/uuid。对应
   A3(钩子接线可执行)+ S1/S2(登记真出现、字段对)。这是一切自愈的地基:登记表恒空 =
   watchdog 无从拉起,还**不报错**。
3. **杀会话 → watchdog 按 uuid 拉回**——tmux 会话被杀(≈断电/崩溃)后,15s 级 watchdog 连名带对话
   原样接回。对应 S5(正向金标准);反向(主动 `/exit` 的不纠缠)脚本不自动测 → H4 人工补测。
4. **OOM 硬化在位**——swap / swappiness / overcommit / earlyoom 四层脚本真测(A9),user.slice
   软顶一层脚本不查、人工核对(H7);单个会话内存暴涨拖不垮整机。
5. **tailscale·ufw·可选层就位**——入网命脉 + 防火墙基线 + 装了的可选层(Moshi/桌面/看板)都活着。
   对应 A7/A8 + O 组。

## 2. 全量测试点清单

### 2.1 A · 核心(必须全 PASS;A4 有一种合法 SKIP)

全部只读探测:不建会话、不碰现有会话(真会话闭环在 S 组测)。下表 `$M` 指从 `~/.bashrc` 读出的
`CLOUD_MODEL` 值:`M=$(grep -m1 '^CLOUD_MODEL=' ~/.bashrc | cut -d'"' -f2)`(脚本内部用 `eval`
同源取值;install.sh 的 sed 也锚定这一行)。

| 编号·测什么 | 怎么测 | 期望(PASS 判据) | FAIL 怎么判 / 去哪修 |
|---|---|---|---|
| **A0** 基建体检全绿 | `bash cloud_infra_check.sh; echo $?` | 退出码 0(可选层显示 ⏭ 不算失败) | 按它打印的「恢复:」逐项修完重跑 |
| **A1** shell 函数块进了用户 shell | `timeout 30 bash -ic 'type cloudgo cloudattach cloudnew cloud_resume cloudtmp'` 五函数全命中。**必须 `bash -ic`、不能 `-lc`**:Ubuntu 默认 `~/.bashrc` 顶部有非交互守卫(`[ -z "$PS1" ] && return`),函数块追加在守卫之后,`-lc`(非交互)根本执行不到,`-ic` 才等价于"用户真实打开终端所得" | 五个都 `type` 得到 | 缺 = bashrc-cloud-snippet 没进 `~/.bashrc`(或被守卫挡在后面没装对位置)→ 重跑 `./install.sh` |
| **A2** 会话工具链齐备 | `command -v cc-state cc-sessions cloud-watchdog cloud-forget cloud-sessmenu cloud-sesslist hub`(七个,装在 `~/.local/bin`);再把纯输出的 `cloud-sessmenu`、`cloud-sesslist` 裸跑一遍 | 七个全在 PATH,两个裸跑 exit 0 | 缺啥都别单补,重跑 `./install.sh`(幂等) |
| **A3** settings.json 钩子接线可执行 | python 遍历 `~/.claude/settings.json` 的 hooks,每条命令**首词**(展开 `~`/`$VAR` 后)必须存在且可执行——专抓"写死旧机绝对路径(`/root/...`、`/Users/...`),换机后失效" | 无 BAD 项 | 逐条把 BAD 的命令改指到本机真实路径,或重铺/合并 `claude-config/settings.client.json`(DEPLOY 阶段一)。注意它只查**已配置**的 hook;cc-state 钩子压根没配时这里不报,由 S1(登记不出现)兜出来 |
| **A4** 模型真可用 + 两处一致【最要命】 | `timeout 240 env -u TMUX -u TMUX_PANE claude --model "$M" --effort max -p "只回复OK"`;再比对 systemd unit 的 `Environment="CLOUD_MODEL=…"`。**不能只看退出码/输出非空**:实测 CLI 对「模型不存在/无权限」返回 rc=0 且把报错打到 stdout,naive 判据会把死模型误判成 PASS——必须按输出签名分三类:`dead`(含 "issue with the selected model" / "may not exist" / not_found / invalid model / authentication_error / permission_error,或输出全空)、`flagged`(含 "API Error" / "safeguards flagged" / "can't respond")、`ok`(干净短回复) | `ok` 且 bashrc == service → PASS;`flagged` 且两处一致 → **SKIP**(模型可达、非账号问题,headless 探针被内容分类器拦,交互/自愈由 S 组端到端另证) | `dead` → 模型用不了,新建会话+断电自愈会**启动即死** → DEPLOY 阶段一「必改·会话模型」(最高频坑);报未登录 → [headless-login.md](headless-login.md);两处不一致 → "新建会话正常、断电自愈全死"(或反过来),两处都改后 `systemctl daemon-reload && systemctl restart cloud-watchdog.timer` |
| **A5** watchdog 定时器真在跳 | `systemctl show cloud-watchdog.timer -p LastTriggerUSec` 距今 <60s;`journalctl -u cloud-watchdog.service --since -3min` 无 Traceback | 在跳且没崩 | 没在跳/在崩 = 自愈是摆设:`systemctl enable --now cloud-watchdog.timer`;有 Traceback 读 journal 修根因 |
| **A6** watchdog 手动跑一轮 | `cloud-watchdog`(PATH 带 `~/.local/bin`)——它每 15s 干的活,亲手干一遍 | exit 0(静默 = 无需恢复,正常) | 报错读输出定位(登记表损坏/依赖缺失等) |
| **A7** tailscale 内网通 | `tailscale ip -4` | 有 `100.x.y.z`(中美加密通道 = 命脉) | 不在线 = Wave/手机全都连不进来 → `tailscale up`;→ [tailscale-setup.md](tailscale-setup.md) |
| **A8** 防火墙基线 | `ufw status`;`systemctl is-active fail2ban` | `Status: active`,含 `22/tcp`、`60000:61000/udp`(mosh)、`tailscale0` 放行;fail2ban active | 缺哪条照 install.sh 第 [6/7] 步补 `ufw allow …` 再 `ufw --force enable`;fail2ban `systemctl enable --now fail2ban` |
| **A9** OOM 硬化在位 | `systemctl is-active earlyoom`;`cat /proc/sys/vm/swappiness`;`cat /proc/sys/vm/overcommit_memory`;`free -m` 看 Swap | earlyoom active、swappiness=60、overcommit=1、swap ≥ 8000MB | 任一缺 = 单会话内存暴涨会拖垮整机 → 重跑 `bash oom/harden.sh`(幂等)。user.slice 软顶那层脚本不查 → H7 |
| **A10** hub 多会话中控 | `hub ls` | exit 0 | 报错读输出;装坏了重跑 `./install.sh` |
| **A11** 开机自启 enabled | `systemctl is-enabled cloud-sessions.service cloud-watchdog.timer` | 都 enabled(重启后体系自己站起来的前提) | `systemctl enable` 补上,否则重启后自愈体系起不来;boot 线演练见 H5/H3 |

### 2.2 S · 破坏性自愈(串行独占)

- 全部动作只碰**自建的 `cc-ztest-<时间戳>` 会话**和 `/opt/workspace/ztest-<时间戳>` 目录,不碰
  客户已有会话;kill/rm 前都有 `^cc-ztest-[0-9]+$` 正则断言(防呆护栏),全程 flock 单实例 +
  `trap EXIT` 兜底清理。
- **必须串行独占**:flock 只防第二份测试脚本,防不了人——S 组跑的时候别的人/agent 不得建、杀
  会话,watchdog 观察窗里混进别的动作,结果没法判(见 §3 第 8 行)。
- 万一测试中途断掉:trap 兜底通常已清干净;真有残留照 §5 手动清。
- 流程顺序:S0 守卫 → S1 → S2 → **发暗号消息**(见下)→ S3 → S4 → S5 → S7。**没有 S6**(编号
  跳过,保持与脚本输出一一对应)。
- **发暗号这一步为什么卡在 S2 和 S3 之间**(它是 S3/S4 的前提):实测新会话在提交第一条消息之前
  **根本不写** `~/.claude/projects/*/<uuid>.jsonl`,而 `cc-sessions recoverable` 要求 jsonl 存在才算
  "可恢复"——没发过消息的会话 kill 掉 watchdog 也不会拉,S5 就无从测。脚本用 `tmux send-keys`
  发一句 `reply with exactly this token: ZTEST-<时间戳>`,≤120s 轮询暗号进 jsonl;首个 Enter 可能
  被启动横幅吞,约每 12s 补发一次。**提交成败一律以「暗号进了 jsonl」为准**——不看
  `~/.cloud-status`(已下线的 :8722 看板产物),也不 grep 屏幕(暗号会先在输入框回显,
  capture-pane 假命中;jsonl 只记已提交的对话轮次,才是真凭据)。

| 编号·测什么 | 怎么测 | 期望(PASS 判据) | FAIL 怎么判 / 去哪修 |
|---|---|---|---|
| **S0** 内存前置守卫 | 读 `/proc/meminfo` 的 MemAvailable | ≥ 4500MB 才开测;不足 → 整组 **BLOCKED**(watchdog 自身 <4000MB 也按兵不动,测了也白测) | BLOCKED 不是 FAIL:关几个闲会话腾出内存再跑 |
| **S1** 起真会话 → 恢复登记出现 | 预信任测试目录(照抄 watchdog 的 pretrust,防卡"信任此文件夹?"弹窗)后:`env -u TMUX -u TMUX_PANE tmux new-session -d -s cc-ztest-<ts> "cd /opt/workspace/ztest-<ts> && IS_SANDBOX=1 claude --model $CLOUD_MODEL $CLOUD_OPTS --dangerously-skip-permissions"`(启动命令照抄 bashrc-cloud-snippet 的 `cloud()`,模型/参数与 cloudgo 同源取自 bashrc);轮询 ≤60s | `~/.cloud-sessions/<名>.json` 60s 内非空出现 = 会话活了且 cc-state 钩子链路通。**盯登记文件、不盯 `~/.cloud-status`**:后者是已下线 :8722 看板的产物,当前 cc-state 多半不写;登记文件才是断电自愈真正依赖的 | 前置直接 FAIL 的两种:claude 不在 PATH;`~/.bashrc` 无 `CLOUD_MODEL=`(不猜默认值硬跑)。60s 无登记 → 看 tmux 屏幕尾行:claude 秒退回 A4,没秒退则钩子没接上回 A3 |
| **S2** 登记表字段正确 | 读登记 json 的 uuid/dir/ended | uuid 非空、dir = 测试目录、ended=false(断电自愈全靠这条记录) | 字段缺/错 = watchdog 将无从恢复 → 打开 `~/.cloud-sessions/<名>.json` 看哪个字段不对,回修 A3/S1 |
| **S3** 对话存档唯一 | `ls ~/.claude/projects/*/<uuid>.jsonl` 计数(由发暗号那步落盘) | 恰 1 份(`--resume` 的接头暗号恰好一份) | =0 多半是消息没提交进去(看上面发暗号说明);≠1 异常,查 glob 命中了什么 |
| **S4** 消息真提交(暗号进 jsonl) | 发暗号步骤的轮询结果 | ≤120s 暗号落进 jsonl = 会话既能收指令、对话也可被 resume 接回。"模型已回话"只是加分注记、**不作判据**——被内容分类器拦时(如 Fable5 headless 拒答)只落 user 轮、不落 assistant 轮,但对话已可 `--resume`,自愈不受影响 | 120s 没进 = 消息没提交成功(TUI 卡弹窗/输入没进去/模型起不来)→ 看屏幕尾行。此项 FAIL 则 S5 无从测,脚本清理退出 |
| **S5**【头号测试】杀会话 → 按 uuid 拉回 | 正则断言会话名后 `tmux kill-session -t cc-ztest-<ts>`(实测 kill-session **不触发** SessionEnd → 登记 ended 保持 false,忠实模拟「崩溃/断电」而非「主动 /exit」)→ 轮询 ≤90s `tmux has-session` 同名回归 → 再等 30s 复查不是回光返照 + `pgrep -f "resume <uuid>"` 证进程参数真带 `--resume <同一uuid>` + ≤30s capture-pane 看原对话暗号重现 | 三证齐(仍在 + resume 同 uuid + 暗号重现)= PASS;存活 + resume 同 uuid 而屏幕未见暗号 = **降级 PASS**(TUI 可能折叠历史,进程参数已证接回同一段对话) | 90s 无同名回归,或拉回不完整 → **照 §3 定位表从上往下排**。脚本顺带打印 `cc-sessions recoverable` 是否列出它、timer 是否 active、登记 ended 值,都是 §3 的第一手线索 |
| **S7** 清理并复核零残留 | 顺序必须 **先 forget 再 kill 再 rm**(否则 kill 完 watchdog 15s 后又把尸体复活成僵尸):`cc-sessions forget` → `tmux kill-session` → 删登记/状态 json、对话 jsonl 及编码目录、`/opt/workspace/ztest-*` 工作目录 → 复核 | tmux / `cc-sessions recoverable` / `~/.cloud-sessions/` 三处都无 `cc-ztest-*` | 有残留 → 照 §5 手动清 |

> S5 为什么给到 90s:timer 每 15s 一轮、每轮最多温和拉 1 个,内存紧张还会整轮暂缓。判 FAIL 前
> 先看 `journalctl -u cloud-watchdog` 有没有"暂缓/退避"——那是守卫在干活,不是坏了。

### 2.3 O · 可选层(装了才测;没装 SKIP 不判负)

脚本只自动测下面三个(O 编号有跳空、没有 O2/O3,是沿革保留,为的是和脚本输出一一对应)。旧版
编在 O 组的 moshi 兜底 timer、shell 增强、反向通道、cloudflared 见 §2.5 与文末小注。

| 编号·测什么 | 怎么测 | 期望(PASS 判据) | FAIL 怎么判 / 去哪修 |
|---|---|---|---|
| **O1** moshi-hook 手机审批链路 | `command -v moshi-hook` 没有 → SKIP;有 → 三证:`timeout 12 moshi-hook status` 显示 paired + `systemctl is-active moshi-hook.service` + `journalctl -u moshi-hook.service -n 3000` 里有 `ws bridge connected` | 已配对 + 守护 active + ws bridge 已连云端 | 装了但链路不通 = 手机收不到审批,照 [phone/README.md](../phone/README.md) §2、§4 排(未配对先 `moshi-hook pair`);自愈兜底 timer 是 H11 |
| **O4** noVNC 图形桌面(:6080) | `novnc.service` unit 不存在 → SKIP;存在 → service active + `Xvfb`/`x11vnc`/`websockify` 三进程都在 + `curl http://<tailscale-IP>:6080/vnc.html` 返回 200 + `ss -ltn` 确认 6080 **只绑 tailscale 内网 IP**(不对公网) | 全链路健康 | 装了但不健康 = 打开 :6080 是空壳/打不开 → [desktop-layer.md](desktop-layer.md);"空壳无桌面"老毛病已由 wait-在-Xvfb 修掉,再犯 → `systemctl restart novnc` |
| **O5** 项目看板(:8088) | `cloud-dashboards.service` unit 不存在 → SKIP;存在 → service active + `curl http://<tailscale-IP>:8088/` 返回 200 | active + 200 | `systemctl restart cloud-dashboards.service` |

### 2.4 M · 迁移(传了 `--projects` 才真跑;没传 M1 记 SKIP)

做没做迁移:部署参数表里记了 / 直接问客户(可顺带探 `~/.claude/skills`、
`~/.claude/commands` 有无非模板内容、`/tmp/claude-migrate.tgz` 痕迹)。裸脚本不猜——做过就把
点名项目传进来:`bash tests/deploy-test.sh migrate --projects /opt/workspace/a,/opt/workspace/b`。
skills/MCP 清单、红线自查、迁移垃圾密钥这些扩展检查脚本不自动测 → H13–H16。

| 编号·测什么 | 怎么测 | 期望(PASS 判据) | FAIL 怎么判 / 去哪修 |
|---|---|---|---|
| **M1.\<i\>** 点名项目的对话历史目录 | 每个 `--projects` 路径按 `sed 's#[/.]#-#g'` 编码(如 `/opt/workspace/a` → `-opt-workspace-a`),查 `~/.claude/projects/<编码>` 目录存在;每个项目出一条 M1.1、M1.2、… | 逐条 PASS | 缺 = 历史没迁到/编码路径没改名,`--resume` 找不回旧对话 → DEPLOY 阶段四「记忆·编码路径改名」 |
| **M2** 无 Mac 旧路径编码残留 | `ls ~/.claude/projects/ \| grep -c '^-Users-'` | 计数 0(迁移改名完整) | 有 = 这几个项目的历史对话在服务器上找不回、记忆**静默不加载**(不报错、就是不生效)→ 逐个按服务器新路径重命名 |

### 2.5 H · 人工/补充(脚本不覆盖;人工或让机器上的 Claude 用 AskUserQuestion 走)

先是三个必走的人工闭环(H1–H3),然后是 H4 起的**补充点**——都是"脚本不自动测,需人工或作为
补充手测"的:多数旧版曾编在 A/S/O/M 组,脚本收敛范围后移到这里,**别当成已被自动覆盖**。

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
  `journalctl -k --since -15min | grep -i 'out of memory'` 无新 OOM。H5 只是它的缩水版,真重启这一遍
  最能压实闭环 3+4。

补充手测点(每条都是**脚本不自动测**;括号里是旧版编号,方便对老报告):

| 编号·测什么 | 怎么测 | 期望 | 挂了去哪修 |
|---|---|---|---|
| **H4**(旧 S2)`/exit` 主动退出不被复活 | 照 S 组方式建个牺牲会话(命名用 `cc-ztest-<时间戳>`,吃进正则防护和 §5 清场)→ `tmux send-keys '/exit' Enter` → 轮询 ≤30s:tmux 会话消失、登记 `.ended==true` → 再观察 45s(≥3 个 watchdog 周期) | **不被复活**(脚本只测了 kill→拉回的正向,这条反向属人工) | `ended` 没置 true → SessionEnd 钩子没跑(回 A3);被复活了 → `cc-sessions recoverable` 过滤失效,`diff ~/.local/bin/cc-sessions bin/cc-sessions` 对照仓版 |
| **H5**(旧 S4)boot 线缩水演练 | `systemctl restart cloud-sessions.service && systemctl is-active cloud-sessions.service cloud-watchdog.timer` | 都 active(boot 脚本只起 timer、不猛拉,重启后靠 watchdog 每轮 1 个逐个回) | restart 失败看 `journalctl -u cloud-sessions`;真重启全链路 = H3 |
| **H6**(旧 S3)watchdog 守卫与退避在位 | `grep -cE 'MIN_FREE_MB\|MAX_PER_CYCLE\|BACKOFF' ~/.local/bin/cloud-watchdog` ≥ 3;`journalctl -u cloud-watchdog --since -30min` 无反复"拉起…仍死"(手跑一轮 exit 0 已由 A6 自动测) | 常量在、无雪崩迹象 | 版本不对 → 重跑 `./install.sh`。真 OOM 行为**不在此演练**(风险不可控),线上靠 A9+H7 那几层兜 |
| **H7**(旧 A8 的第五层)user.slice 内存软顶 | `[ -f /etc/systemd/system/user.slice.d/50-memoryhigh.conf ]` | conf 在(A9 只自动测另外四层) | 缺 → 重跑 `bash oom/harden.sh`(幂等) |
| **H8**(旧 A1/A7 溢出)安装外围小件 + 登记可解析 | `command -v cloud-sesspreview cloud-delmenu`;`[ -x /usr/local/bin/cloud-boot.sh ]`;`[ -f ~/.tmux.conf ]`;有活会话时 `cc-sessions list` 含它、`cc-sessions resolve <名>` 给出 dir+uuid(主力工具链已由 A2 自动测) | 全在、resolve 命中 | 缺啥别单补,重跑 `./install.sh`;resolve 失败 = 登记 json 损坏/缺字段 → 直接看 `~/.cloud-sessions/<名>.json` |
| **H9**(旧 O5)shell 增强 | `command -v fzf`;`command -v starship`;`[ -d ~/.local/share/blesh ]` | **fzf 必须有**;starship/blesh 缺只提示 | fzf 缺按 **FAIL 对待、不是 SKIP**——cloudgo 选择器/新建/分级删除菜单全靠它,没它入口哑火:`apt-get install -y fzf`;其余重跑 install.sh 尾段 |
| **H10**(旧 O6)反向通道 mac/laptop | `grep -q '^Host mac' ~/.ssh/config` 没配 → 不适用;配了 → `ssh -o BatchMode=yes -o ConnectTimeout=8 mac true`(`laptop` 同理) | 退出 0 | [mac-reverse-channel.md](mac-reverse-channel.md) / [windows-reverse-channel.md](windows-reverse-channel.md) |
| **H11**(旧 O2)moshi 自愈兜底 | (O1 装了才查)`systemctl is-active moshi-hook-healthcheck.timer` | active | `systemctl enable --now moshi-hook-healthcheck.timer`(A0 基建体检把它列为可选项,会顺带显示) |
| **H12**(旧 O3/O4 的人工增量)桌面/看板真实打开 | 脚本 O4/O5 已自动做 service/进程/HTTP 探活;人工补充 = 浏览器实开 `http://<tailscale-IP>:6080/vnc.html` 操作一下桌面、`:8088` 看板内容对不对 | 真可用,不止 HTTP 200 | 打不开先回看 O4/O5 的 FAIL 明细;curl 通、浏览器不通多半是客户端没进 tailnet(回 H1) |
| **H13**(旧 M2)settings 合并完整 | `grep -q cc-state ~/.claude/settings.json` 且 `grep -o '"/Users/[^"]*"' ~/.claude/settings.json` 为空 | 自愈钩子还在、无旧机死路径 | 钩子被旧 settings 盖掉 → 重新合并 `settings.client.json` 的 hooks;死路径逐条改/删(DEPLOY 阶段四「settings 别整份覆盖」)。A3 只验"已配置 hook 首词可执行"、S1 端到端验钩子链路,整份 settings 的死路径扫描属这里 |
| **H14**(旧 M3)skills/commands/MCP 到位 | 对着客户点名清单查 `~/.claude/skills/`、`~/.claude/commands/`;`mcpServers.json` 里每个 `command` 都 `command -v` 得到 | 清单齐、MCP 命令可执行 | 缺的:能从市场重装的重装,客户私有的手动迁(DEPLOY 阶段四) |
| **H15**(旧 M4)红线自查 | 抽查 `~/.claude/CLAUDE.md` 不含**别人的**私有业务规则 / 机器名 / 记忆引用;`git -C <仓目录> remote get-url origin` | CLAUDE.md 是客户自己的;origin 是客户自己的仓 | 命中别人的私有内容 = 违 DEPLOY §7 红线 1/3 → 换成客户自己的 CLAUDE.md / origin |
| **H16**(旧 M5)迁移垃圾与密钥 | `ls /tmp/claude-migrate.tgz` 及解包临时目录 | 已删;若包还在,`tar tzf` 里**不得**含 `.credentials.json` | 包里有密钥 = 高危 → 立删,并让客户重新登录换凭据(红线 2:不经手明文密钥) |

> 旧 O7(cloudflared 对外隧道)不再列验收点:特定环境专属、通用客户机无判据;A0 基建体检的可选项
> 一栏会顺带显示它,未装/SKIP 即正常。

## 3. S5 失败定位表(从高频到低频)

S5 是全链路(登记 → recoverable 过滤 → timer → 内存守卫 → resume → 模型 → trust),挂了别瞎猜,
按现象对号:

| # | 现象 | 第一查 | 根因 | 修法 |
|---|---|---|---|---|
| 1 | 90s 没动静,journal 里连提都没提这会话 | `systemctl is-active cloud-watchdog.timer`;`cc-sessions recoverable` 里有没有它 | timer 没跑;或被 recoverable 滤掉:登记 `ended=true` / `uuid` 空 / 对话 jsonl 不在 / 登记的 dir 已不存在 | timer:`systemctl enable --now cloud-watchdog.timer`;其余打开 `~/.cloud-sessions/<名>.json` 看哪个字段不对,分别回修 A3/S1/S2;jsonl 不在多半是迁移路径编码错(M1/M2) |
| 2 | journal 有"拉回 …",但会话起了又死、反复,最后打"退避" | `journalctl -u cloud-watchdog --since -10min`;把 unit 那条 resume 命令手跑一遍看真实报错 | **watchdog 用的是 unit 里 `Environment=CLOUD_MODEL`,不是 `~/.bashrc`**——只改了 bashrc 一处,自愈还在用那个不可用的模型,启动即死 | DEPLOY 阶段一「必改·会话模型」**两处都改** → `systemctl daemon-reload && systemctl restart cloud-watchdog.timer`;然后等退避冷却(600s)或删 `~/.cloud-status/_watchdog.json` 立即重试 |
| 3 | journal 打"内存仅 xxxMB(<4000),暂缓恢复" | `free -m` | 不是 bug:内存守卫在防 OOM 雪崩,空闲 <4G 整轮不拉 | 关几个闲会话后自动继续;真要激进,调 watchdog 里 `MIN_FREE_MB`(自担 OOM 风险) |
| 4 | journal 打"退避 <名>: 180s 内拉起 3 次仍死,冷却 600s" | 手动跑一遍 resume 命令,看它到底怎么死的 | 会话本身起不来(模型/登录/目录没了),watchdog 按设计退避防狂拉 | 先修死因(多半就是第 2 行),再等冷却或删 `~/.cloud-status/_watchdog.json` |
| 5 | 会话回来了,但登记 uuid 变了 / 对话是全新的 | `ls ~/.claude/projects/<目录编码>/ \| grep <旧uuid>`;手跑 `env -u TMUX -u TMUX_PANE claude --resume <旧uuid>` 看报错 | 旧 jsonl 没了(被删 / 路径编码不对),resume 失败落成新对话 | 找回/修正 jsonl 位置(M1/M2);实在找不回就接受新对话、让登记随之更新 |
| 6 | tmux 会话在,里面却是个 bash 壳、没 claude | `ps --forest -o pid,cmd -g $(tmux list-panes -t <名> -F '#{pane_pid}')`;`diff ~/.local/bin/cloud-watchdog bin/cloud-watchdog` | 旧版 watchdog 的 `\|\| exec bash` 残留:claude 崩了剩壳冒充存活,watchdog 以为成功不再补救 | 重跑 `./install.sh` 装仓版(新版故意让失败会话彻底死 → 下轮重试 + 退避兜底) |
| 7 | 拉起后卡在"信任此目录?"对话框 | `~/.claude.json` 里 `projects.<dir>.hasTrustDialogAccepted` | pretrust 没写成:`~/.claude.json` 损坏/只读(S1 建会话前那步 pretrust 同理) | 修 `~/.claude.json` 权限/格式;应急可进会话手动点一次信任 |
| 8 | "回来了"但 uuid 对不上,journal 也没拉过 | journal + 登记文件的 `src`/`ts` | 竞态:观察窗里有人/别的 agent 手动建了同名会话,watchdog 临起前查到同名已在就跳过了 | 保证 S 段独占重测——这正是"selfheal 必须串行独占"的原因(flock 挡得住第二份脚本,挡不住人) |

## 4. 判定标准

- **验收通过**:A 全 PASS(A4 因内容分类器拦截记 SKIP 的,以 S 组全绿为准)+ S 全 PASS(S0
  BLOCKED = 内存不足**没测成**,不算过,腾内存重跑)+ 已装的 O 全 PASS +(做过迁移则)M 全 PASS
  且 H13–H16 人工过 + H1 通过(装了 Moshi 则 H2 也要过)+ H9 里 **fzf 必须在**(缺了按 FAIL 对待,
  cloudgo 全家入口哑火)。H3 推荐、不强制。
- **有条件通过**:A/S 全绿,只有 O/M/H 补充项里非关键项没修 → 列明"什么条件、谁负责、多久修完"
  再交付。
- **不通过**:A 或 S 任一 FAIL。别交付,按对应行修完整段重跑。

## 5. 收尾清场

脚本正常跑完(乃至半途死掉)都会自己清:S7 正式清一遍,`trap EXIT` 兜底再扫一遍(先 forget 再
kill 再 rm,含登记/状态 json、测试对话 jsonl 及其编码目录、`/opt/workspace/ztest-*` 工作目录)。
下面是手动兜底,不给客户留尾巴:

```bash
# 1) 移出恢复名单并杀掉所有测试会话(先 forget 再杀,防 watchdog 15s 后复活僵尸)
tmux ls -F '#{session_name}' 2>/dev/null | grep '^cc-ztest-' | xargs -rn1 cloud-forget
# 2) 登记表不应再有残留(有就逐个 cc-sessions forget)
ls ~/.cloud-sessions/ | grep ztest || echo clean
# 3) 测试工作目录与对话编码目录(脚本的 trap 正常会删掉;残留才需要这步)
rm -rf /opt/workspace/ztest-* ~/.claude/projects/-opt-workspace-ztest-*
# 4) 收尾后再体检一遍,确认核心仍全绿
bash cloud_infra_check.sh
```

`~/.cloud-status/_watchdog.json` 里的退避残留会在会话不再"该活没活"后自动清,不用管。
