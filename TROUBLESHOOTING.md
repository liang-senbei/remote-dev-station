# remote-dev-station 踩坑账（TROUBLESHOOTING）

> 每条 = 症状 → 根因 → 修法/怎么避开。只增不删。遇到似曾相识的现象先翻这里。
> 更宽的部署坑另见 [docs/deploy-pitfalls.md](docs/deploy-pitfalls.md)（这份记本机运维/协调踩的坑）。

## `pkill -f <模式>` 会自杀（exit 144/255）

- **症状**：`pkill -f "chrome"` / `pgrep -f "vscode-server"` 之类,命令莫名以 144 或 255 退出、没杀干净。
- **根因**：`-f` 匹配整条命令行,而**你的 pkill/pgrep 命令行本身就含那个模式**,于是匹配到自己、把自己(所在 shell)也杀了。
- **修法**：先 `ps -eo pid,args | grep <模式> | grep -v grep | awk '{print $1}' > /tmp/x` 拿 PID 写文件,再 `xargs -a /tmp/x kill`。命令行里不出现待杀模式就不会自杀。

## VS Code Remote-SSH 反复"窗口意外终止(oom)",但系统没真 OOM

- **症状**：反复弹 oom 崩窗口,点重载又犯;但 `journalctl -u earlyoom`/`dmesg` 没有击杀记录。
- **根因**：①exthost 在超大工作区(一次开整个 /root/src/workplace 十几个仓)上随时间膨胀,实测单 exthost 2h 涨到 4.6G 撞 Node 堆上限自崩;②断线重连留下的僵尸 exthost 按默认 3h 宽限期继续挂着堆积。
- **修法**：见 [docs/vscode-remote-oom.md](docs/vscode-remote-oom.md)——watcherExclude 排除重目录 + server-env-setup 把宽限期改 8min + 完整重启 vscode-server(配置才生效)。治本:别一次开整个工作区,只开当下项目文件夹。

## 机器很卡但 CPU 利用率不高 → 看 steal（服务商限流）

- **症状**：打字/操作卡顿,但 top 里用户进程 CPU 不算高;`vmstat` 的 `st`(steal)列却 60-80%。
- **根因**：这是**突发型 VPS 的 CPU 配额限流**——平时能冲高,重活(44个浏览器/全局 ripgrep 等)把突发配额烧光后,宿主把超出基准的 CPU"偷"走,steal 飙高、load 虚高(进程排队等被偷走的 CPU)。
- **修法**：①减自己的负载(停空闲 agent、别全局搜索、把重活分流到闲机如 hk14);②闲置一段时间配额自愈;③长期 steal 都高=套餐超卖,换独享 CPU 机。**这不是代码能修的**,别在 VM 内瞎折腾。

## 指纹浏览器引擎泄漏，几十个 chromium 空转压垮整机

- **症状**：load 飙到 40+、打字卡死;一查 40+ 个 cloakbrowser chromium 空转吃几百% CPU,而 agent 是空闲的。
- **根因**：多个 agent 并行调 `/v1/ephemeral`,引擎旧的**账面并发闸崩溃后计数不清零**→ 无限开;且 closeBrowser 异常路径漏关 tracked 浏览器 → 成孤儿无人清。
- **修法**：引擎(omggrow-ai-browser 仓)加了四道防线:**硬闸(数真实 /proc 进程,崩溃安全)+ 孤儿清扫(杀非引擎子孙)+ ephemeral TTL(关引擎自己超时的)+ 用完即关(finally 兜底)**。每台机器独立闸值(本机紧=4,hk14 闲=8)。**别退回账面计数**(那是 44 孤儿的根)。

## `ps` 一瞬把孤儿进程误判成某 agent 的子进程

- **症状**：`ps`/pstree 显示某引擎进程挂在 cc-boomassets 名下,以为是它起的。
- **根因**：孤儿进程(父进程死了)被内核 **reparent** 到别的进程树下,某一瞬 `ps` 抓到会误归属。
- **修法**：别只信一瞬 ps;用 `pstree -ps <PID>` 看完整祖先链,或核对进程 PPID 是不是 1(孤儿)。归属存疑时 hub 找相关 agent 对齐,别贸然认定/误杀。

## 给仓库建 handover/文档时，账号数据/密码/截图差点推上 GitHub

- **症状**：给 auto_register/gmail_account_saver 建仓时,`git add -A` 把 322 账号+app_password 的 json、邮箱列表 txt、几百张注册截图、网络抓包都暂存了。
- **根因**：这些项目**代码和数据混在一个目录**,裸 `git add` 全进;.gitignore 模式没覆盖全(如 `registered-*.json` 挡了但 `registered-*.txt` 没挡)。
- **修法**：推前**必验**:`git diff --cached --name-only` 逐个看 + grep 敏感模式(@gmail/apppassword/\.png/accounts)。数据/凭据/截图全 gitignore,只留代码+文档。改 .gitignore 后 `rm .git/index && git add -A` 重来(单纯 `git rm --cached` 有时不干净),`git check-ignore -v <文件>` 确认真被忽略。仓建私有。

## earlyoom 默认"优先杀 claude"→ agent 反复被杀

- **症状**：内存一紧张,agent(claude 会话)就掉线,像随机掉。
- **根因**：`oom/earlyoom.default` 里 `--prefer ^claude$`——内存紧张时 earlyoom **专挑 claude 杀**(为保住机器,拿 agent 当牺牲品)。掉线不是随机是被主动杀的。
- **修法**：配合"闲 agent 睡 swap"策略:swappiness 调 80 + swap 够大 + earlyoom `-s` 从 100 降到 5(只在 RAM 和 swap 都见底才动手,让内核先把闲 agent 换页进 swap)。被杀的会话 watchdog 会 `--resume` 拉回,uuid 在 `~/.cloud-sessions/<name>.json`。

## cc 座舱点「打开」开成 untitled / 不 resume —— cc-agents 没输出 jsonl（**头号老坑**）

- **症状**：cc-cockpit 里点某 agent 的「打开」,官方 Claude 插件开出**空白 / untitled**,不 resume 那个 agent 的会话。反复出现、修了好几版都没根治。
- **根因**：官方插件 `editor.open(uuid)` 只在**当前窗口 root 的 project 目录**(`~/.claude/projects/<编码路径>/`)里按 uuid 找会话;cc-cockpit 靠 `ensureSessionLinks` 把会话文件软链进那个目录来补救。但建软链要 agent 的真 `jsonl` 路径(代码读 `a.jsonl`),而 **`cc-agents --json` 从来不输出 `jsonl` 字段** → `a.jsonl` 恒为 undefined → `ensureSessionLinks` 对每个 agent 都 `continue`、**一个软链都不建** → `editor.open` 找不到 → untitled。cc-cockpit v0.4.17 只在**接收端**补了 `jsonl` 透传(`model.ts`),**源头 cc-agents 不产出 → 管子里没水**,自上线起从没真正工作过(全靠手动链)。
- **修法**：`bin/cc-agents` 输出 dict 加一行 `"jsonl": jl` —— `jl = jsonl_by_uuid(uuid)` 早就算出来了(拿去读 task/cost),只是没塞进 JSON。改完 `install -m755 bin/cc-agents ~/.local/bin/`。cc-cockpit ≥0.4.17 本就消费它 → 座舱下一轮轮询(3s)自动建软链,「打开」即 resume,**不用重打 .vsix / 不用 reload**。`cc-agents-filtered` 是整对象透传,自动带上。
- **易漏 / 验证**：① **只改接收端(cc-cockpit)不改源头(cc-agents)是空修** —— 两头字段必须都在。② `encProj`(cc-cockpit 把 root 路径的 `/ _ .` 都换 `-`)必须和官方 project 目录编码**一致**(实测一致:`auto_register`→`-…-auto-register`);编码错则软链进错目录、照样 untitled。③ 验证:`cc-agents --json | grep -c jsonl` >0 且路径文件存在;座舱活跃后 `find ~/.claude/projects -maxdepth 2 -type l -name '*.jsonl'` 应出现软链(修复前恒为 0)。④ 无 uuid 的裸会话没有可 resume 的 jsonl,「打开」仍无效属正常(只能 Attach 终端)。

## cloudgo「文档/验收测试要求装，install.sh 却不发货」——半迁移留下的空引用

- **症状**:干净跑 `install.sh` 的极简客户,终端里敲 `cloudgo`/`cloudnew`/`cloudattach` 全 `command not found`;`bin/` 里也没有 `cloud-sessmenu`/`cloud-sesspreview`/`cloud-delmenu`。可仓库到处把 cloudgo 当核心:验收 A1(`type cloudgo cloudattach cloudnew cloud_resume cloudtmp`)、A2(`command -v cloud-sessmenu cloud-sesslist`)、H8(`cloud-sesspreview cloud-delmenu`)全查它,CLI-DEPLOY 正文也写「装…+cloudgo」——照测试根本过不了,照文档又名不副实。
- **根因**:cli-deploy 分支从全功能版**半迁移**:测试和 CLI-DEPLOY 正文按"cloudgo 是核心"写好了,但 ① 那 9 个函数从没进 `bashrc-cloud-snippet.sh`(它只有 `claude()`/`cloud()`);② 3 个 helper 脚本从没进 `bin/`(`install -m755 bin/*` 只能装已存在的);③ 同时 README 头、CLI-DEPLOY intro、`claude-config/CLAUDE.md` 还留着"本版无 cloudgo"的旧话,和 ①② 互相打架。典型"文档说有、实际没有 + 文档自相矛盾"。
- **修法**:把 cloudgo 收进仓库当核心发货件——`bashrc-cloud-snippet.sh` 补全 9 函数(去掉站长机专用的 `sergo`、`claude`→`command claude`、新增 `export CLOUD_ROOT`),`bin/` 补 3 个 helper。**install.sh 无需改**(`install -m755 bin/*` + `cat bashrc-cloud-snippet.sh >> ~/.bashrc` 原本就会带上,fzf 尾段也早装好)。再把 6 处"无/移除 cloudgo"的矛盾文档改成"保留·服务器侧·两版都有"。
- **怎么避开**:验收测试(deploy-test.md)是"契约"——**测试查的工具/函数必须有对应发货件**。加/删一条能力要三头对齐:发货件(bin//bashrc 片段)+ install 接线 + 测试,别只动一头留下空引用。纯 SSH 下 cloudgo 靠 `WAVETERM_BLOCKID` 为空自动降级成"每次弹菜单",极简版照样能用,不必担心"只能 Wave 用"。
