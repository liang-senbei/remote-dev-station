# VS Code Remote-SSH:扩展宿主(exthost)反复 OOM 崩窗口

> 现象:VS Code 反复弹「窗口意外终止(原因:"oom",代码 "-536870904")」,点重载又过一阵再犯。
> 根因不是系统内存不够,而是**服务器侧的扩展宿主进程(extension host)膨胀撑爆 Node 堆**。

## 背景:Remote-SSH 下谁在哪跑

你笔记本上是**外壳窗口(renderer)**,真正跑所有插件的**扩展宿主(exthost)在服务器上**。所以
「窗口意外终止(oom)」= 服务器上那个 exthost 进程被撑爆/被杀,笔记本窗口随之断连。

## 两条独立的成因(常同时发生)

### 1. exthost 在大工作区上随时间膨胀,撞 Node V8 堆上限自崩
- 把整个 `~/src/workplace`(十几个 git 仓 + node/python 项目)当**一个多根工作区**打开,exthost
  要监视/索引所有文件。实测**单个 exthost 2 小时涨到 4.6G**,超过 Node old-space 上限后崩,报 oom。
- 与系统内存无关:`journalctl -u earlyoom`/`dmesg` 里**没有** OOM 击杀记录时,就是这类。

### 2. 断线重连留下的僵尸 exthost 堆积
- 笔记本↔服务器网络一抖,VS Code 断线重连时**新起一个 exthost**,但旧的按默认
  `VSCODE_RECONNECTION_GRACE_TIME=10800000ms`(**3 小时**)继续挂着,每个占 0.5~2G。
- 断了又连 → 僵尸越堆越多 → 内存吃光 → 最大那个先崩。日志见反复
  `disconnected, will wait for reconnection 3h before disposing` + 同一工作区被开成 `...-1`、`...-2`。

## 修复(全在服务器侧,三步)

### A. Machine settings:不监视/索引重目录(治膨胀)
把 [`../vscode-server/machine-settings.template.json`](../vscode-server/machine-settings.template.json)
铺到 `~/.vscode-server/data/Machine/settings.json`。核心是 `files.watcherExclude` + `search.exclude`
排除 node_modules/.venv/.git/data/profiles/logs,再关掉自动类型获取、npm/task/tsc autoDetect、
git autofetch、遥测。exthost 从 2G+ 稳到几百 M。

### B. server-env-setup:重连宽限期 3h→8min(治僵尸堆积)
把 [`../vscode-server/server-env-setup`](../vscode-server/server-env-setup) 铺到
`~/.vscode-server/server-env-setup`(VS Code server 启动前会 source 它):
```
export VSCODE_RECONNECTION_GRACE_TIME=480000     # 8min
export VSCODE_RECONNECTION_SHORT_GRACE_TIME=60000
```
断线残留的僵尸 exthost 8 分钟就释放,不再堆到爆。

### C. 让上面两步真正生效:必须**完整重启 vscode-server**
- 这两个配置只在 **server 全新启动**时读取。若 server 已在跑(它持久存活、跨重连复用),配置不生效
  ——日志里 `VSCODE_RECONNECTION_GRACE_TIME=` 仍是 10800000ms 就是没生效。
- 客户端做:`F1 → Kill VS Code Server on Host` 后重连;
- 或服务器侧(注意**别用 `pkill -f vscode-server`,模式会匹配到自己命令行导致自杀 exit 144**,
  用 PID):
  ```bash
  ps -eo pid,args | grep 'vscode-server/bin' | grep -v grep | awk '{print $1}' \
    | while read p; do kill "$p"; done
  ```
  杀 vscode-server **不影响** tmux/claude agent(各自独立进程)。杀完客户端重连即全新起。

## 应急止血(不重启整个 server 也能救一次)

揪出膨胀最大的那个 exthost 单独杀,立即释放几个 G:
```bash
ps -eo pid,rss,args | grep -E 'type=extensionHost|extensionHostProcess' | grep -v grep \
  | sort -k2 -rn | head    # 看谁最肥
kill <那个pid>             # VS Code 会提示重载,重载后是精简的
```

## 治本的使用习惯

exthost 会在超大工作区上慢慢涨。根治两招:
1. **别一次开整个 `~/src/workplace`**,只开当下要弄的那个项目文件夹 → exthost 一直小;
2. 或每隔几小时 `F1 → Developer: Reload Window` 重置 exthost 内存。

## 排查速查

| 检查 | 命令 | 说明 |
|---|---|---|
| 是不是系统 OOM | `journalctl -u earlyoom --since -30min` / `dmesg \| grep -i oom` | 空 = 不是系统内存,是 exthost 自撞堆上限 |
| 哪个 exthost 肥 | `ps -eo pid,rss,etime,args \| grep type=extensionHost \| sort -k2 -rn` | rss 上 G 的就是元凶 |
| 宽限期生效没 | `grep RECONNECTION_GRACE ~/.vscode-server/data/logs/*/remoteagent.log \| tail -1` | 应是 480000ms,还是 10800000 就是 server 没重启 |
| 有几个窗口/僵尸 | 上面 exthost 计数,或 `remoteagent.log` 里 `will wait for reconnection` | 多个 = 僵尸堆积 |

相关:同机内存/OOM 全局硬化见 [`../oom/`](../oom/)(earlyoom + swap + swappiness);
本仓 `docs/deploy-pitfalls.md` 亦有一条速记。
