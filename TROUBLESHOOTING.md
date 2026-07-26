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
