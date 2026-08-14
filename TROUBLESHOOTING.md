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
