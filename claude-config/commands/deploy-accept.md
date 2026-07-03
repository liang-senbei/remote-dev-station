---
description: 部署完一句话启动全量功能验收:预检 → 并行 core/optional/migrate → 串行破坏性自愈 → 人工项问询 → 一页验收报告
argument-hint: 可选,如 "core"(只验某段)、"跳过人工项";默认全量
---

你是 remote-dev-station 的**部署验收编排员(lead)**。这台机器刚照 DEPLOY.md 部署完,现在按
`docs/deploy-test.md` 定义的「五闭环 + A/S/O/M/H 测试点」做全量功能验收。**开工前先把
`docs/deploy-test.md` 完整读一遍**——判据、命令、S5 失败定位全以它为准;执行体是
`tests/deploy-test.sh`。用户带了参数($ARGUMENTS)就按参数收窄范围;没带 = 全量。

**两条铁律(违者验收结果作废):**

1. **所有 `claude` 探针必须 `env -u TMUX -u TMUX_PANE claude …`**。你自己就跑在被验机器的 tmux
   会话里,裸跑探针会把探针的 uuid 写进你所在会话的恢复登记,污染被验会话(watchdog 之后按错
   uuid 拉、对话错乱且不报错)。派出去的 agent 也要在指令里带上这条。
2. **派 agent(Task/subagent/workflow 的 `agent()`)一律不写 `model` 参数,让它继承会话模型。**
   显式写死型号 = 复刻「仓里默认 fable-5 是作者专属、客户账号没有、全线启动即死」的坑
   (DEPLOY 阶段一)。这套体系本身就栽过,别在验收工具里再栽一次。

## 阶段 0 · lead 预检(自己做,不派 agent)

1. **读两处模型**:`grep -m1 '^CLOUD_MODEL=' ~/.bashrc` 和
   `grep CLOUD_MODEL /etc/systemd/system/cloud-watchdog.service`。记下两值;不一致先记一笔
   (= A3 预期 FAIL),不终止。
2. **探明装了哪些可选层**(决定阶段 1 的 optional 范围、阶段 3 问不问 H2):
   - `command -v moshi-hook` + `systemctl is-active moshi-hook.service moshi-hook-healthcheck.timer`
   - `systemctl is-active novnc.service cloud-dashboards.service cloudflared.service`
   - `command -v fzf`;`grep -q '^Host mac' ~/.ssh/config`(反向通道,laptop 同理)
   列一张「装了 / 没装」小清单,后面带给 agent。
3. **探迁移痕迹**(决定 migrate 段跑不跑):`~/.claude/skills`、`~/.claude/commands` 有非模板内容,
   或有 `/tmp/claude-migrate.tgz` 痕迹。拿不准就 AskUserQuestion 问一句「做过 DEPLOY 阶段四的
   资料迁移吗」。
4. **快速闸**:`timeout 90 env -u TMUX -u TMUX_PANE claude -p ok`。无输出或非零退出 →
   **就地终止整个验收**,只报一句:「Claude 未登录或不可用——先照 docs/headless-login.md 登录,
   再来 /deploy-accept」。别带病往下跑,下面每一段都会假性全红,浪费所有人时间。

## 阶段 1 · 并行 3 个 agent(只读 / 低扰动段)

同时派 3 个 agent(**都不写 model 参数**),各自跑一段并对结果下钻:

- **agent-core**:`bash tests/deploy-test.sh core`
- **agent-optional**:`bash tests/deploy-test.sh optional`,把预检的「装了/没装」清单塞进指令;
  没装的层 SKIP 不判负,fzf 缺按 FAIL 算(docs/deploy-test.md §2.3)
- **agent-migrate**:`bash tests/deploy-test.sh migrate`;预检确认没做过迁移 → 这个 agent 不派,
  整段直接记 SKIP

给每个 agent 的指令里写明:对每个 FAIL,**先重跑一遍该项探针**排除偶发,再按
`docs/deploy-test.md` 对应表行下钻根因,返回
`编号 / FAIL / 一行证据 / 根因 / 修法(DEPLOY.md 锚点,如「阶段一·必改会话模型」)`;
PASS/SKIP 每项一行带一句证据即可。也把铁律 1 原样抄给它们。

## 阶段 2 · 破坏性自愈(串行、独占;门槛 = core 全 PASS)

- core 有任一 FAIL → **跳过本阶段**,报告里写明「selfheal 未跑:core 未全绿,先修再来」。
  破坏性测试不在坏地基上跑。
- core 全 PASS → 派**单个** agent 串行跑 `bash tests/deploy-test.sh selfheal`。期间**不得**并行
  任何其它 agent、不得建/杀任何会话——S 段要独占 watchdog 的观察窗,混进别的动作结果没法判。
- S5 FAIL 时,按 `docs/deploy-test.md` §3「S5 失败定位表」**从上往下逐行对号**,把命中那行的
  现象→根因→修法写进报告,别自由发挥。
- 无论成败都要清场:`tmux ls -F '#{session_name}' | grep '^cc-ztest-' | xargs -rn1 cloud-forget`,
  并确认 `ls ~/.cloud-sessions/ | grep ztest` 为空(测试脚本用 `cc-ztest-<时间戳>` 命名)。agent 中途死了 lead 补做。

## 阶段 3 · 人工项(AskUserQuestion,能合的一次问齐)

照 `docs/deploy-test.md` §2.5,用 AskUserQuestion 给客户出选择题(装了 Moshi 才问 H2):

- **H1 电脑端**:从你自己的电脑连上、进会话、对话一来一回,通过了吗?
  (已通过 / 现在去试,等我回来 / 跳过)
- **H2 手机端**:手机 Moshi 真批到一次权限了吗?(已通过 / 现在去试 / 跳过)
  客户要现场试就按 §2.5 H2 的探针会话操作法带他走。
- **H3 真重启演练**:现在 reboot 演练一次开机自愈吗?(推荐做 / 这次跳过)
  客户点头才做;做就指导 `reboot`,回来后核对登记会话逐个回齐、无新 OOM(判据在 §2.5 H3)。

## 阶段 4 · 汇总一页报告

所有结果收口到**最后一条**消息,按这个骨架:

1. **结论**(放最前):验收通过 / 有条件通过(列条件、责任人、期限) / 不通过(列阻塞项)。
   判定标准照 `docs/deploy-test.md` §4,别自创。
2. **五闭环**逐个一句话:绿/红 + 证据。
3. **A/S/O/M/H 计数**(PASS/FAIL/SKIP)+ FAIL 明细:每条给 根因 + DEPLOY.md 修法锚点 +
   修完的复测命令(如 `bash tests/deploy-test.sh core`)。
4. **交接提醒**:会话默认 `--dangerously-skip-permissions`,唯一人工闸是 Moshi 审批且是选装——
   未装 = 无人工闸,要客户知情接受(DEPLOY 阶段五)。

$ARGUMENTS
