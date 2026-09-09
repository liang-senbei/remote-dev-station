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

## cc 座舱把站长自己 `/root` 下的项目也列出来 —— 它默认调的是**裸 cc-agents**

- **症状**:座舱(cc-cockpit)的 agent 列表 / 频道里冒出**不该给客户看的东西** —— `/root/src` 下站长自己的开发项目、`/root`、`/tmp` 的临时会话、连笔记本信箱 `cc-local` 都在。客户机上这等于把别人的活儿摊给客户看。
- **根因**:`ccCockpit.ccAgentsPath` 默认值是裸 `cc-agents`,而 `cc-agents` 的设计就是**全量**——注册表(`~/.cloud-sessions/*.json`)里没 ended 的 + 活 tmux 里的裸会话,一个不落。座舱本身**没有任何按路径过滤的配置项**(0.8.0 确认:只有 ccAgentsPath / repoRoot / host / pollIntervalMs / notifyOn / local*),所以过滤只能加在**供数这一侧**。
- **修法**:`bin/cc-agents-filtered`(整对象透传 + 重算 summary,只放行 `ROOTS = ["/opt/workspace"]`),`install.sh` 把 `ccCockpit.ccAgentsPath` 指向它并写进 `~/.vscode-server/data/Machine/settings.json`。**Machine settings 优先级高于客户本地(Windows/Mac)的用户设置**,客户那边怎么配都盖不掉。终端 `cc-agents`、`cc-autopilot`、通知**不受影响**,仍是全量——只有座舱这一路被滤。
- **易漏 / 验证**:
  ① **频道不用另外治**:座舱的频道是按当前 agent 的 `dir` 现算分组的(`classifyDir`),列表里没有 `/root/src` 的 agent,频道就不会出现。扩展包里硬编码的 `DIR_ROOTS`(含 `/root/src/workplace/browser` 等)只是个分类表,**不是扫描源**,不用为这事重打 vsix。
  ② **Worktrees 视图是第二个口子**:它走 `ccCockpit.repoRoot`,和 agent 列表**不共用过滤**。repoRoot 留在 `/root/src/...` 就还是会把 /root 下的仓露出来 —— 一并设成 `/opt/workspace`。(默认值 `/opt/workspace/HACKING/...` 不存在时扩展会回落到 `os.homedir()` = `/root`,更要显式设。)
  ③ **过滤脚本必须在仓里**:2026-08-13 前它只以手写脚本的形式躺在机器上、`install.sh` 不发货 —— 重装 = 座舱悄悄恢复成"什么都显示",而且没人会注意到。已入仓,由 `install -m755 bin/*` 带上。
  ④ **别把两台机器的规则搞混**:站长机(ser4420027323)上那份 `cc-agents-filtered` 是**反过来的**(只留 `/root`,给站长自己看开发项目用)。同名脚本、相反规则,改之前先 `head -3` 看清楚是哪台。
  ⑤ **验证**(照 ⑦,要按**注册表**的 dir 验,别按输出里的 dir):
  ```bash
  cc-agents-filtered --json | python3 -c "
  import sys,json,glob
  reg={json.load(open(p))['name']: json.load(open(p)).get('dir','') for p in glob.glob('/root/.cloud-sessions/*.json')}
  d=json.load(sys.stdin)
  for a in d['agents']: print(a['name'], '| 注册表 dir:', reg.get(a['name'],'(裸会话)'))"
  ```
  每行的注册表 dir 都该在 `/opt/workspace` 下;再对比 `cc-agents --json` 仍是全量。座舱侧改完**不用 reload**,下一轮轮询(3s)自动生效。
  ⑥ **`/opt/workspace` 是空的时候座舱就是空的**——这是对的,不是坏了。客户的项目本来就该开在 `/opt/workspace` 下(`cloud-enter`/`cloudgo` 默认落这儿)。
  ⑦ **别按 `cc-agents` 输出里的 `dir` 过滤(第一版就栽在这)**:那个 dir 是**反推**出来的——`realdir = decode_dir(dirname(jsonl_by_uuid(uuid)))`,即"这会话的 jsonl 躺在哪个 project 目录"。而**座舱自己会把同一份 jsonl 软链进别的 project 目录**(`ensureSessionLinks`,「打开」能 resume 全靠它),`jsonl_by_uuid` 用 `glob(...)[0]` 取首个命中,**可能先命中那条软链** → 一个跑在 `/root` 的会话就顶着 `/opt/workspace/xxx` 的 dir **混过过滤**。192.220.36.19 上实测:`cc-root` 注册表写着 `/root`,却因为 `~/.claude/projects/-opt-workspace-Phy-LargeN/<uuid>.jsonl → ../-root/<uuid>.jsonl` 这条软链,被 cc-agents 报成 `/opt/workspace/Phy/LargeN`、堂而皇之进了座舱。**修法**:过滤读 `~/.cloud-sessions/<name>.json` 里的 `dir`(会话创建时写死的启动目录,不受软链影响),没有注册表条目的裸会话才回落到报的 dir(通常为空 → 直接滤掉)。**这个坑会随座舱用得越久越严重**:软链是座舱正常工作的产物,越用越多。

## `sergo` 和 `cloudgo` 看到同一份 tmux 列表 —— 活会话那半从没按 CLOUD_ROOT 过滤过

- **症状**:`cloudgo`(根 `/opt/workspace`)和 `sergo`(根 `/root/src`)本该各管各的工作区,菜单里却**列出一模一样的会话**。
- **根因**:`cloud-sessmenu` 的菜单由两半拼成——**活会话**(`cloud-sesslist`,读 tmux)+ **离线可恢复**(`cc-sessions recoverable`)。只有**后半**按 `$CLOUD_ROOT` 过滤了 dir,`cloud-sesslist` 从头到尾只 `tmux list-sessions` 拿全量、连 CLOUD_ROOT 都没读。而 `cloud-sessmenu` 顶上的注释白纸黑字写着"活的+可恢复的都过滤"——**文档说有、实际只做了一半**。更绕的是 `.bashrc` 里 sergo 的注释又写着"两个入口的会话是互通的",两处自相矛盾,照哪句都说不清该是什么行为。
- **修法**:`cloud-sesslist` 读 `$CLOUD_ROOT`,按会话的启动目录过滤;目录取自**注册表** `~/.cloud-sessions/<name>.json` 的 `dir`(一次 python3 读成 map,不是每会话一次),没登记的裸会话(`cc-tmp-*`/手搓 tmux)回落到 tmux 的 `#{session_path}`。`CLOUD_ROOT` 为空 = 不过滤,保留全量用法。
- **易漏 / 验证**:
  ① **别用 `cc-agents` 报的 dir**(理由同上一条第 ⑦ 点:座舱的软链会把它带偏)。注册表的 dir 才是会话创建时写死的。
  ② **前缀要卡到目录边界**:`[[ "$dir" != "$ROOT"* ]]` 会让 `/root/srcfoo` 混进 `/root/src`。要 `[ "$d" = "$root" ] || [[ "$d" == "$root"/* ]]`。离线那半原本就是宽的前缀匹配,一并收紧了。
  ③ **过滤是"看不见"不是"进不去"**:根之外的会话(比如在 `/tmp` 起的)两个菜单都不列 —— 逃生口是 `tmux ls` 看全量、`cloudattach <名字>` 直接进,都不受过滤影响。
  ④ **验证**:`CLOUD_ROOT=/opt/workspace cloud-sessmenu | cut -f1` 与 `CLOUD_ROOT=/root/src cloud-sessmenu | cut -f1` 两份名单应**无交集**,并集应等于 `tmux ls`(减去根外的)。

## tmux 的 `-t <名字>` 是**前缀匹配**不是精确匹配 —— 会话名互为前缀时全线出错

- **症状**:`cc-atf翻译-r` 明明没在跑,watchdog 却死活不拉它(日志里连尝试都没有);`cloudattach cc-foo` 进去发现是 `cc-foo-2` 的屏幕;`cloud-forget cc-foo` 把还活着的 `cc-foo-2` 杀了。现象各不相同,根子是同一个。
- **根因**:tmux 的 target-session 解析顺序是 **精确 → 前缀 → fnmatch**。所以只要存在 `cc-foo-2`,`tmux has-session -t cc-foo` 就返回 0(命中)。这套部署的会话命名恰恰全是后缀派生(`-2`/`-3`/`-r`/`-r-2`/`-<自定义名>`),**每个正名都是其派生名的前缀** —— 中招是必然的:
  - `cloud-watchdog`:临起前那句 `has-session -t name` 误判"已存在"→ `continue` → **该会话永远拉不回来**(实测 `cc-atf翻译-r` 被 `cc-atf翻译-r-2` 挡住;`cc-atf翻译` 更是被 `-2/-3/-r/-r-2` 任意一个挡住)。
  - `cc-autopilot`:`tmux_alive` 误判已死会话为活着;更糟的是 `send-keys -t name` 会把督促**打进另一个 agent 的输入框**。
  - `cloud-forget`:`kill-session -t name` **杀错会话**(最危险)。
  - `cloud-enter`/`cc-new`/`cloudattach`:误 attach 进别人的会话。
  - `cloudnew`/`cloud_resume` 里"找空闲编号"的 while 循环:白白多跳几个序号。
- **修法**:所有 tmux 目标一律加 `=` 前缀强制精确匹配 —— `-t "=$name"`。已全仓改完(7 个文件 10 处)。
- **易漏 / 验证**:
  ① **`capture-pane` 例外**:它的 `-t` 是【pane 目标】,只写 `-t "=$name"` 会报 `can't find pane`,必须写成 **`-t "=$name:"`**(带冒号)。`has-session`/`attach`/`send-keys`/`kill-session` 写 `=$name` 即可。
  ② **复现只要两条命令**:`tmux new-session -d -s zz-a-2 'sleep 60'; tmux has-session -t zz-a && echo 命中` —— 会打印"命中"。加 `=` 后不命中。
  ③ 这坑**只在有派生名会话时才发作**,单会话机器上永远看不到 —— 所以它能潜伏很久。客户机上一旦同项目开了第二个会话就开始发作。

## `/model` 里看不到新模型(如 Fable 5.1)—— 配置是全局的,但会话跑的是老二进制

- **症状**:`~/.claude/settings.json` 的 `availableModels` 已含 `fable-5-1[1m]`,在某个会话里 `/model` 能选并"保存为默认",但其他 cc-* 会话里 `/model` 列表根本没有 Fable 5.1。
- **根因**:模型清单是**烤在二进制里**的(`fable-5-1` 字符串 2.1.257 才出现,`grep -a -c fable-5-1 ~/.local/share/claude/versions/2.1.252` = 0)。native 装法每次升级只是把 `~/.local/bin/claude` 软链指到新文件,**已在跑的进程还是老版本**——watchdog 开机批量拉起的那一批全停在当时的最新版。看 `readlink /proc/<pid>/exe` 或会话 banner 的 `Claude Code vX.Y.Z` 就能确认,配置文件再对也没用。
- **修法**:重启会话让它加载新二进制。**别用 `/exit`**(SessionEnd 钩子会打 `ended=True`,watchdog 就不复活了),直接 `kill -9 <claude pid>`,tmux 会话随之结束,watchdog 15s 一轮按 `--resume <uuid>` 用**当前** `claude` 拉回,历史不丢。批量做:先按 `tmux capture-pane` 末几行分出空闲/忙碌,只杀空闲的;`cc-sessions resolve <名>` 先确认登记过(未登记的 watchdog 拉不回,得手动 `claude --resume`)。
- **易漏**:
  ① **在 tmux 里的 bash 提示符下手动敲 `claude` 起的会话**,kill 掉 claude 后 bash 壳还在、tmux 会话不消失,watchdog 的 `has-session` 判它活着 → 不拉。这种要 `tmux kill-session -t "=<名>"` 连壳一起收掉。
  ② 恢复后每个会话**保留自己之前选过的模型**(如 "Opus 5"),不会自动改成新全局默认;只有从没选过模型的会话才落到 settings.json 的 `model`。想换就在该会话里 `/model` 重选——这时列表里就有了。
  ③ 输入框里有**未发送的草稿**的会话,kill 会丢草稿,先看一眼 `capture-pane`。
  ④ ⚠️ **别把这条外推到别的 key**。"要重启"只对**少数几个 key**成立,`model` 是其中之一。`env` 是**热重载**的,改了当场生效、不用重启 —— 见下一条。

## 座舱列表点开是空白 Untitled —— 官方插件 `isFile()` 把座舱建的**软链**全跳过了

- **症状**:VS Code 里点 cc 座舱列表中的会话,**面板开出来了但是空白 Untitled**(不是"点了没反应",容易被描述成没反应)。只有座舱管的那批会话中招;直接在 VS Code 里原生开的会话一切正常。终端 `cloudgo`/`cloudattach` 进同一个会话历史完好,所以极易误判成"对话丢了"。客户口径是"好像昨天开始的"——对应官方插件 `anthropic.claude-code` 自动升级的那天(本次 2.1.258,扩展目录 mtime 就是升级时间)。
- **根因**:两边对"文件"的定义对不上。
  - 座舱 `ensureSessionLinks` 把每个 agent 的转录 **`fs.symlinkSync`** 进当前工作区对应的 project 目录(`~/.claude/projects/<encProj(workspaceRoot)>/<uuid>.jsonl`),这是"打开"能 resume 的全部依赖。
  - 官方插件枚举会话用 `readdir(dir,{withFileTypes:true})` 然后 `if(!U.isFile()||!U.name.endsWith(".jsonl")) continue`。**Node 的 Dirent 走 lstat 语义,软链的 `isFile()` 恒为 `false`** → 座舱建的链**一个不剩**全被跳过。
  - 于是 webview 的 `activateSessionFromServer(uuid)` 返回假值 → 走兜底分支 `j(F.initialSession)` 发 `restore_declined`,再 `createSession({isExplicit:false})` 开一个全新空会话 = **Untitled**。
- **定位方法**(比读混淆代码快得多):看 `~/.vscode-server/data/logs/<最新>/exthost*/Anthropic.claude-code/Claude VSCode.log`,`grep restore_declined` —— 每点一次就有一条,`sessionId` 就是点的那个会话。看到 `restore_declined` 基本就锁死是"插件找不到这个 session",不是命令没发出去。
- **修法**:改用**硬链接**,而且**在我们自己的脚本里做,不改厂商的包**。
  - 落点是 `bin/cc-agents-filtered` 的 `link_transcripts()`。它是座舱的供数脚本(`ccCockpit.ccAgentsPath`),**座舱每 3 秒调一次、正好在 `ensureSessionLinks` 之前**,所以我们抢先把硬链摆好,座舱的 `if(!lst) symlinkSync(...)` 就永远不触发;已经是软链的顺手转成硬链(自愈,不必手工清存量)。
  - **一度改过座舱包里的 `symlinkSync` → `linkSync`(全包只此 1 处),已还原。** 别走这条路:改厂商 bundle 装新 VSIX 就没,而且出问题时会被误当成故障源(实测背过一次锅)。
- **易漏 / 验证**:
  ① **一行命令判死活**:`node -e 'const fs=require("fs");for(const e of fs.readdirSync("/root/.claude/projects/-opt-workspace",{withFileTypes:true}))if(e.name.endsWith(".jsonl")&&!e.isFile())console.log("被跳过",e.name)'` —— 有输出就是中招。
  ② **别去追 webview 里的 `PK1`**(`Date.now()-sessionUpdatedAt < 600000` 那个 10 分钟新鲜度门)。它管的是"面板恢复自己上次托管的会话",和座舱显式传 uuid 这条路无关,顺着它查会走进死胡同。
  ③ **座舱不会覆盖已存在的链**:`ensureSessionLinks` 是 `if(!lst) link(...)`,所以先放好的硬链它不动——这正是 `link_transcripts()` 抢跑能生效的前提。
  ⑥ **别硬链到插件自己建的真文件上**:`link_transcripts()` 只在目标是软链、或是指错 inode 的旧硬链时才重建;`nlink==1` 的独立真文件一律不碰(那是官方插件自己的会话)。
  ④ **硬链的前提**:同一文件系统(projects 全在 `~` 下,满足)。若 Claude Code 哪天改成"写临时文件再 rename"来更新转录,硬链会指向旧 inode 而失联——目前转录是 append-only(`appendFileSync`),暂时安全,但这是个要盯的假设。
  ⑤ **顺带发现的另一颗雷(尚未触发)**:座舱自己的 `encProj = (p) => p.replace(/[/_.]/g,"-")` **不处理非 ASCII**,而 Claude Code 会把中文也换成 `-`。工作区开在 `/opt/workspace`(纯 ASCII)时两边一致;一旦把 VS Code 直接开在 `/opt/workspace/诗歌`,座舱会去建 `-opt-workspace-诗歌`,插件却在 `-opt-workspace---` 里找,链建了也白建。另外中文目录名**长度相同就会撞**:`/opt/workspace/{环境,项目,今天,文件,诗歌}` 全部编码成 `-opt-workspace---`,5 个会话的转录挤在一个目录里。

## VS Code 一升级,Claude Code 插件整个起不来、活动栏图标消失(不报任何可见的错)

- **症状**:客户点了标题栏的"更新"后,**官方 Claude Code 插件和 cc 座舱的图标都从活动栏消失**,像是扩展被卸载了。查 `~/.vscode-server/extensions/extensions.json` 两个扩展都还在、版本也对,`ls` 目录也在——**只是加载失败,而且 UI 上没有任何报错**。极易被误判成"上一个改动把插件改坏了"。
- **根因**:新版 VS Code server(本次 `Stable-520fb30b`,替掉 `Stable-08d4889f`)带的 Node 把 `navigator` 变成了全局。VS Code 为了给扩展做迁移过渡,默认在扩展宿主里装了个**一访问 `navigator` 就抛 `PendingMigrationError` 的 getter**:
  ```js
  // server/out/vs/workbench/api/node/extensionHostProcess.js
  qI.supportGlobalNavigator || Object.defineProperty(globalThis, "navigator", {
    get: () => { throw new PendingMigrationError("navigator is now a global in nodejs, ...") }
  });
  ```
  `anthropic.claude-code`(2.1.258 / 2.1.259 都一样,bundle 里 48 处 `navigator`)在**模块加载阶段**(Zod schema 初始化)就会读到它 → `require` 直接抛 → 扩展加载失败 → 图标没了。
- **修法**:开 `extensions.supportNodeGlobalNavigator`(Machine settings,`install.sh` 已自动合并)。server 据此给扩展宿主传 `--supportGlobalNavigator`,那个 getter 就不装:
  ```js
  // server/out/server-main.js
  this._configurationService.getValue("extensions.supportNodeGlobalNavigator") && a.push("--supportGlobalNavigator")
  ```
  改完要 **Reload Window** 才生效(扩展宿主是启动时带参数 fork 的)。
- **易漏 / 验证**:
  ① **错误只在日志里**:`grep -n PendingMigrationError ~/.vscode-server/data/logs/<最新>/exthost1/remoteexthost.log`,堆栈里会直接点名是哪个扩展的 `extension.js`。UI 上什么都不显示,不看日志永远查不出来。
  ② **升级插件没用**:2.1.259 和 2.1.258 的 `navigator` 用法完全一致(都是 48 处),换版本解决不了,得开开关。
  ③ **判断是不是 VS Code 换版本了**:`ls -lt ~/.vscode-server/cli/servers/` 看有没有当天新增的 `Stable-<hash>` 目录;或对比两次连接日志里的 `Stable-` 前缀。**server 版本由客户端 VS Code 决定**,服务器这边只能被动接受。
  ④ **座舱是无辜的**:同一份日志里 `_doActivateExtension echoj3.cc-cockpit` 是正常的、零报错,`PendingMigrationError` 全部来自 `anthropic.claude-code`。座舱图标一起消失是因为窗口在反复重载,不是它自己挂了。

## `settings.json` 的 `env` 是**热重载**的;而且**删 key 不生效、置空才生效**

- **背景**:本仓一度记着"配置只在 claude 启动时读一次"(见上一条 `/model` 那条)。那条对 `model` 成立,**对 `env` 不成立**——是从 `model` 外推出来的错误结论,已订正。发现者是 cc:Yxi_pilot,它拿独立探针目录 + 项目级 `.claude/settings.local.json` 实测出来的。
- **官方文档原文**(code.claude.com/docs/en/settings 的 *When edits take effect*):
  > Claude Code watches your settings files and reloads them when they change, so it applies **most** edits to the running session without a restart, including edits to `permissions`, `hooks`, and credential helpers such as `apiKeyHelper`.

  只读一次、需要重启的是这几个,**`env` 不在其中**:
  - `model` —— 用 `/model` 中途切
  - `effortLevel` / `modelSettings` —— 用 `/effort` 中途改
  - `outputStyle` —— 是 system prompt 的一部分,`/clear` 或重启后才生效
- **实测逐条**(改项目级 `settings.local.json` 的 `env`,会话在跑):
  | 操作 | 结果 |
  |---|---|
  | 往 `env` 加变量 | 运行中的会话**立刻**读到 |
  | `ANTHROPIC_BASE_URL` 改成坏地址 | 下一次请求 `Connection refused` → **换端点不用重启** |
  | 把该 key 从文件里**删掉** | **仍是坏地址**(旧值留在进程环境,删不掉) |
  | 显式改回官方端点 | 恢复正常 |
  | 改成空字符串 `""` | 恢复正常(空串 = 恢复默认,也是热的) |
  | 请求已在飞(重试链里) | 整条链走旧配置,切换落在**下一次**请求上 |
- **修法 / 写脚本的硬约束**:**凡是靠改 `settings.json` 的 `env` 做切换的脚本,必须把所有相关 key 每次全写一遍,不用的写空串 `""`,绝不能靠删 key 来"取消"。** 否则"切回去"会**静默失败**,而 UI 上显示已经切了 —— 这是最难查的一类 bug。
- **易漏 / 验证**:
  ① **热重载有钩子可挂**:每次检测到 settings 文件变化会跑 `ConfigChange` 钩子(MDM / claude.ai console 下发的 managed settings 不触发,那些是按计划轮询到达的,不是存盘即到)。
  ② **确认到底加载了哪些文件**:会话里 `/status` → Status 页的 `Setting sources` 行会列出本次加载的每个 settings 文件。它只说读了哪些文件,**不说哪个 key 是哪个文件给的**。
  ③ **切换端点后第一次请求会全量重读上下文**(每个 model 有自己的 prompt cache),表现为第一次变慢、成本变高,别误判成切换失败。
