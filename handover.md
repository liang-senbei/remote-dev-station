# remote-dev-station 交接文档（handover）

> 活的交接快照，让新会话 30 秒上手。改动后更新对应段、删过时的，保持当前。

## 1. 基础信息

- **是什么**：一套"远程开发工作站"部署系统——把云服务器变成常驻、断线不丢、多 agent 协同的 Claude Code 开发环境。核心能力：tmux 会话韧性 + watchdog 自愈、hub 多 agent 通讯、反向 SSH 通道操作用户本地设备、TigerVNC 图形桌面、OOM 硬化、cc 座舱(VS Code 扩展)。
- **技术栈**：bash 脚本 + systemd 单元 + Python(cc-agents/statusline) + 少量 Node(cc-cockpit 扩展另仓)。无编译，纯部署配置。
- **这个 agent 负责**：维护这套部署系统本身 + 作为"组长 agent"协调本机其它项目 agent(hub 派活/把关/验收)。
- **部署在哪**：本机 **ser4420027323 / 公网 38.244.50.31 / tailnet 100.126.149.77**(8核16G,CPU 被服务商限流 steal 高)。这是 dev/主控机。客户部署到各自云主机。
- **怎么跑**：`bash install.sh` 铺开(核心层 + TigerVNC 登录桌面必装,见 docs/desktop-layer.md);看板 :8088 才是选装(`CLOUD_DESKTOP=1`)。

## 2. 进度

- **已完成**：会话韧性层(tmux+watchdog)、hub 通讯、反向通道(dfhz/mac/lap)、OOM 硬化(earlyoom+swap+swappiness)、cc 座舱扩展(另仓 cc-cockpit)、TigerVNC 桌面层、cli-deploy 极简版、CLAUDE.md 第5章建档纪律、**任务看板自动督促引擎 `cc-autopilot`(bin/ + systemd,配合座舱 v0.4.19 的开关UI)**、**cloudgo 会话选单入仓**(此前只被文档/验收测试引用、实际不发货的"半迁移"坑:`bashrc-cloud-snippet.sh` 补 9 函数 + `bin/` 补 3 helper(cloud-sessmenu/sesspreview/delmenu);install.sh 原有 `install bin/*` + append snippet 自动接上;验收 A1/A2/H8 现可过。见 TROUBLESHOOTING)。
- **进行中**：无(系统稳定运行)。
- **待办**：无硬待办。**待站长定夺**:install.sh 是否幂等确保 sshd `PubkeyAuthentication yes`(连续多个客户镜像默认 `no`,害得每客户手改)。
  (已了结:桌面层「必装还是可选」的自相矛盾 —— 2026-08-03 随 noVNC→TigerVNC 迁移一并统一为**必装**,CLI-DEPLOY 那行矛盾注释已改。)潜在优化另见 TROUBLESHOOTING.md。

### cc-autopilot（任务看板自动督促）速览
- **引擎**：`bin/cc-autopilot`(Python 守护) + `systemd/cc-autopilot.{service,timer}`(每 5min)。**独立于 VS Code,24h 生效**。
- **配置接口**：`~/.cloud-status/cockpit-autopilot.json`（座舱 UI 写,引擎读）。每 agent `{idleNudge, hourlyContinue, continueSmartSkip}`。空配置=不动作。
- **两个行为**：idleNudge=空闲【且频道有待办】时提醒(每空闲周期1次);hourlyContinue=每 ≥1h 发"继续"(【不依赖待办】,治卡住;continueSmartSkip=在干活则跳过)。
- **发督促**=tmux send-keys(带"[任务看板·…]"前缀,agent 知道是自动督促非真人)。UI 侧在 cc-cockpit 仓 v0.4.19。

## 3. 读写信息在哪

- **本仓文件**(自有可写)：`bin/`(服务器脚本)、`systemd/`(单元)、`oom/`(OOM硬化配置)、`claude-config/`(CLAUDE.md/settings/hooks 部署模板)、`docs/`(专题文档)、`vscode-server/`(VS Code exthost OOM 配置模板)、`install.sh`。
- **部署产物**(install.sh 铺出去,非本仓)：`~/.claude/CLAUDE.md`(现网生效版,比 claude-config/ 模板多 dfhz/tailnet/hub强制规则等私有叠加)、`~/.claude/settings.json`、`/usr/local/bin/*`、`/etc/systemd/system/*`、会话登记 `~/.cloud-sessions/`。
- **组长记忆**(只读参考,非本仓)：`~/.claude/projects/-root-src-workplace-remote-dev-station/memory/`——本机运维事故/决策的持久记录(座舱故障/OOM/BoomAsset迁移/hk14分流等)。

## 4. GitHub 耦合

- **对应仓**：`liang-senbei/remote-dev-station`(本仓)。同名仓在多个账号有分叉(xiaoxihexiaoyu/Eyre921 等),以 liang-senbei 为准。
- **cc-cockpit 是独立仓**(`liang-senbei/cc-cockpit`)——座舱 VS Code 扩展,不在本仓;本仓只在 docs 里引用它。
- **本机其它项目**(各自独立仓,本仓不耦合它们代码,只作为组长 agent 协调)：browser 组(auto_register/gmail_account_saver/omggrow-ai-browser/mail-apppassword)、echoj1-projects(crm-panel/human_register/BoomAsset)、media/tele_automatic 等。跨项目共享资源(会误伤的)见 TROUBLESHOOTING.md。

## 5. 关联机器（本机作组长常打交道的）

- **hk13** `149.88.68.193`(ecs2366442859)：BoomAsset 生产 + human_register/ins-panel。`ssh hk13`。
- **hk14** `154.44.28.208`(ser8096034651,32核空闲)：账号生成重活分流去处,跑第2个 omggrow 浏览器引擎(`/root/omggrow-engine/`)。
- **echo-j1** `38.244.50.74`：旧机,BoomAsset 已从它迁走。`ssh echo-j1`。
