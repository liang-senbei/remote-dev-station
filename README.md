# 远程 Claude 会话体系 · 完整交接文档

> 维护对象:一套"在美国服务器上跑 Claude Code,从中国的 Mac 和手机远程操作"的体系。
> 阅读对象:接手维护的同事。读完应能理解每一层、会话怎么管、断了怎么回来、出问题去哪查。

---

## 0. 一句话总览

我们(Mac / 手机)**都不直接跑 Claude**。Claude 跑在 **美国服务器 echo-j2** 上、装在 **tmux** 里持久化。

- **Mac**:用 **Wave 终端** → `cloudconn` → **mosh + Tailscale** → 服务器
- **手机**:用 **Moshi App** → SSH/mosh → 服务器
- **Windows 笔电**:用 **Wave 终端** →(**反向 SSH 隧道 / WSL2-mosh**)→ 服务器,见 [`windows/`](windows/README.md)(含 Wave**「按标签页一键恢复终端」**)
- 三者是**三个遥控器,操作同一批服务器上的 tmux 会话**。
- 每个会话靠「**会话名 `cc-<名>` + 对话文件 `<uuid>.jsonl`**」绑定;断电/崩溃后 **watchdog** 守护进程按 uuid 把对话**原样自动接回**。

---

## 1. 全景图

```
   ┌──────────────────────────┐          ┌──────────────────────────┐
   │  你的 Mac(中国)         │          │  你的手机(Moshi App)    │
   │  Wave Terminal           │          │  getmoshi.app            │
   └───────────┬──────────────┘          └───────────┬──────────────┘
               │ cloudconn(拉起 mosh+断线重连)        │ SSH/mosh(自带配对密钥)
               ▼                                      ▼
   ╔══════════════════════════════════════════════════════════════════╗
   ║         Tailscale / WireGuard 加密虚拟网络                        ║
   ║   Mac 100.101.160.72  ⇄  服务器 100.109.254.125                  ║
   ║   (跨太平洋 NAT 打洞直连,~180ms,阵发丢包)                     ║
   ╚════════════════════════════════╤═════════════════════════════════╝
                                     ▼
   ╔══════════════════════════════════════════════════════════════════╗
   ║                  美国服务器 echo-j2  (root)                       ║
   ║                                                                  ║
   ║   tmux ─┬─ cc-项目A   ─ claude ─ 对话 a3f9…​.jsonl                 ║
   ║         ├─ cc-项目B   ─ claude ─ 对话 b1c2…​.jsonl                 ║
   ║         └─ cc-…​      ─ claude ─ 对话 …​.jsonl                     ║
   ║                                                                  ║
   ║   后台守护(你不用碰):                                          ║
   ║     • cc-state     每个事件把 名↔目录↔uuid 写进登记表           ║
   ║     • cloud-watchdog  每 15s 把"该活却没在跑"的会话拉回         ║
   ║     • cloudstatus  状态看板 :8722    • 完成铃铛                  ║
   ╚══════════════════════════════════════════════════════════════════╝
```

**核心心智模型**:服务器是"真身电脑",Mac 和手机只是"显示器+键盘"。关掉显示器,真身照跑。

---

## 2. 为什么是这套架构(底层动机)

| 约束 | 导出的设计 |
|---|---|
| Claude 不能在本地 Mac 跑(封号风险) | → Claude 必须放**服务器** |
| 人在中国、服务器在美国,跨太平洋高延迟+丢包 | → 用 **mosh**(抗丢包、本地预测打字)而非普通 SSH |
| 关电脑 / 断网,会话不能丢 | → **tmux** 在服务器保活(扛"断开") |
| 断电 / 崩溃 / OOM 后还要回来 | → **登记表 + watchdog 自愈**(扛"杀掉") |
| 手机也要能看进度、远程批准权限 | → **Moshi** 独立通道,接同一批会话 |

> 记住:**这几层不是冗余,每一层都对应上面一条硬约束。**

---

## 3. Mac → 会话:逐层拆解

```
① Wave 标签            你点开的标签 = 一个"存好的命令"(像浏览器书签)
     │  标签里存的命令,决定它连去哪
     ▼
② cloudconn            ~/bin/cloudconn:拉起 mosh,并 while-true 断线 5s 重连
     │
     ▼
③ mosh                 UDP 协议。先用 SSH 登一次服务器握手(启动 mosh-server+
     │                 换密钥),立刻切到 UDP。抗丢包、断网漫游、打字本地预测
     ▼
④ Tailscale/WireGuard  加密虚拟网,让 mosh 的包安全跨太平洋到达服务器
     │
     ▼
⑤ 服务器上的入口命令    两种:
     │                 • cloudgo      → 弹会话选择器,你手选一个
     │                 • cloudattach cc-X → 直奔某个会话(绑定标签用)
     ▼
⑥ tmux 会话 cc-<名>    会话的"活躯体":断开它继续跑;被杀会被 watchdog 重建
     │
     ▼
⑦ claude               真正跟你对话的进程。对话内容存在 <uuid>.jsonl
```

**每层职责 + 对应文件:**

| 层 | 作用 | 文件 / 命令 |
|---|---|---|
| ① Wave 标签 | UI;标签=存好的命令 | Mac 上 Wave,布局存 `~/Library/Application Support/waveterm/db/waveterm.db` |
| ② cloudconn | 拉 mosh + 断线重连 | `~/bin/cloudconn` |
| ③ mosh | 抗丢包传输 | `/opt/homebrew/bin/mosh`(两端都装) |
| ④ Tailscale | 加密内网 | `tailscale`;服务器 IP `100.109.254.125` |
| ⑤ 入口 | 选/进会话 | `~/.bashrc` 的 `cloudgo` / `cloudattach` |
| ⑥ tmux | 会话保活 | tmux 会话名 `cc-<名>` |
| ⑦ claude | AI 本体 | 对话 `~/.claude/projects/<目录>/<uuid>.jsonl` |

> **界面恢复**走另一条线:Wave 的标签/分屏布局存在 Mac 本地 `waveterm.db`,重开 Wave 自动摆回布局 + 自动重跑每个标签的命令 → 顺着 ①→⑦ 再连回去。

---

## 4. 手机 → 会话:逐层拆解

```
① Moshi App(手机)     getmoshi.app。配对信息: 服务器 ~/.config/moshi/host-pairings.json
     │                 两条通道:(a) 出站 WebSocket→Moshi云(推送/远程批准/用量)
     │                          (b) SSH/mosh 直连服务器 22 端口(真正进终端)
     ▼ (走 b)
② SSH / mosh 进服务器   按配对的密钥直连,不经过 Mac
     ▼
③ Moshi 内置 tmux 选择器  列出 tmux 会话并 attach
     ▼
④ tmux 会话 cc-<名>     ← 和 Mac 接的是【同一组会话,无隔离】
```

**Mac 和手机的关系:两个遥控器,一台电视。**

| | Mac (Wave) | 手机 (Moshi) |
|---|---|---|
| 入口 App | Wave(独立) | Moshi(独立) |
| 传输 | mosh + Tailscale | SSH/mosh(自带密钥,不过 Mac) |
| 进会话菜单 | cloudgo | Moshi 内置选择器 |
| **底层会话** | **同一组 tmux `cc-*`(完全共享)** | **同一组** |
| **对话存档** | **同一批 `<uuid>.jsonl`** | **同一批** |
| 远程批准权限 | ❌ 只显示"等待输入" | ✅ 手机点 allow/deny(独有) |

> ⚠️ 安全须知:Moshi 是**第三方 App,被授权以 root SSH 进服务器**,并维持出站 WebSocket 到第三方云上报用量。接受这套=信任 Moshi 链路。

---

## 5. 会话是什么 + 命名机制

**一个"会话" = 服务器上 [一个 tmux] 里 [一个 claude 进程] 在跑 [一个对话文件]。**

一个会话同时有几个"名",但 **你只需要管一个**:

```
你起的名:    项目A                    ← 你唯一要管的
  ├─ Wave 标签名:   项目A             (自动 = 你起的名,纯显示)
  ├─ claude 界面名: 项目A             (claude 的 -n 参数,自动去掉 cc-,纯显示)
  ├─ tmux 把手:     cc-项目A          (自动加 cc- 前缀)★功能性:attach/恢复/筛选靠它
  ├─ 对话 uuid:     a3f9d2c1…​.jsonl  (Claude 自己生成)★功能性:认对话靠它
  └─ Claude 摘要:   "调试项目A…​"      (Claude 自动写,只在原生恢复菜单里出现,可忽略)
```

- **真正干活的只有 2 个**:`cc-项目A`(人能读的把手)+ `uuid`(机器认对话)。
- 登记表把这两个**绑在一起**——这就是"你说项目A,系统就能找回对话"的原理。
- `cc-` 前缀是**给工具识别的暗号**(hub / cloudgo / watchdog 靠它认"这是我们的 claude 会话")。**严禁手动 `tmux rename` 去掉 `cc-`,否则会话会从所有工具里"消失"且不报错。**

---

## 6. 状态与恢复机制(底层原理)★最重要

### 6.1 关键区分:tmux 扛"断开",不扛"杀掉"

```
断开(关 Wave / 断网 / 合盖)  →  tmux 让会话在后台继续跑,claude 不掉   ✅ tmux 的本职
杀掉(服务器重启 / OOM / kill) →  tmux 没了                            ❌ tmux 不抗,但能重建
```

### 6.2 真正"不死"的是文件,不是 tmux

| | 是什么 | 抗杀吗 |
|---|---|---|
| **对话 `.jsonl`(uuid)** | 你和 claude 的每句话,会话的"**灵魂**" | ✅ 硬盘文件 |
| **登记表** `~/.cloud-sessions/<名>.json` | 一张便条:名↔目录↔uuid,"这个要保持活着" | ✅ 硬盘文件 |
| **tmux 会话** | 会话的"**活躯体**" | ❌ 杀掉就没,但可重建 |

**恢复 = 拿灵魂(uuid)重新造个躯体(tmux)**:
`cloud-watchdog` 每 15s 查"登记表说该活、但 tmux 没了"的会话 → 新建 tmux 跑 `claude --resume <uuid>` → 从 `.jsonl` 把对话原样读回。

### 6.3 所有恢复机制一览

| 机制 | 何时触发 | 做什么 | 文件 |
|---|---|---|---|
| **cc-state** | 每个 Claude 事件 | 写状态看板 + 写登记表(名↔目录↔uuid) | `~/.local/bin/cc-state` |
| **cloud-watchdog** | 每 15s(systemd timer) | 死掉的会话按 uuid 连名带对话拉回;**带内存守卫**(空闲<4G 暂缓、每轮最多拉1个,防 OOM 雪崩);崩溃退避 | `~/.local/bin/cloud-watchdog` |
| **cloud-boot.sh** | 服务器开机 | 只启 watchdog 定时器,由它温和恢复(不一次猛拉) | `/usr/local/bin/cloud-boot.sh` |
| **cloudattach 离线分支** | 进一个已死会话 | 查 uuid,连名带对话 resume | `~/.bashrc` |
| **cloud-forget / Ctrl-X** | 你主动删会话 | 停恢复 + 杀 tmux,**保留 `.jsonl`** | `~/.local/bin/cloud-forget` |
| **cloudconn 5s 重连** | mosh 断 | 自动重连 | `~/bin/cloudconn` |
| **mosh UDP 漫游** | 丢包/换网 | 不重连即穿过抖动 | mosh 两端 |
| **Wave 布局恢复** | 重开 Wave/Mac | 读 db 重建标签+重跑命令 | `waveterm.db` |
| **Moshi 远程批准** | claude 要权限 | 阻塞≤300s 等手机点 | `~/.claude/settings.json` |

> **教训(2026-06):** 本机仅 15G 内存,Opus 会话每个 ~1G+。14 个并发曾把整组 OOM 杀光。所以 watchdog 必须有内存守卫,绝不能 OOM 后猛拉一堆。容量上限约 **10 个活跃会话**;要更多得加 RAM(关机改实例规格,光重启不加)。

---

## 7. 日常操作手册(所有场景)

| 场景 | 怎么操作 | 谁来做 |
|---|---|---|
| 进会话 | 点侧栏「会话」widget → 菜单选 / 或点"绑定标签"直接进 | 你 |
| 换会话 | 回「会话」重选 / 或点另一个绑定标签 | 你 |
| 新开会话 | 「会话」→ `➕ 新建会话(选目录)` → 起名 | 你 |
| 关会话 | 「会话」里 `Ctrl-X`(留对话存档)/ 终端 `cloud-forget cc-名` | 你 |
| 找回老对话 | 「会话」→ `⟳ 原生选择器恢复` | 你 |
| 服务器挂/重启 | **啥也不做**,watchdog 15s 自动全拉回 | 🤖 自动 |
| Mac 挂/重启 | 开 Wave,标签自动重连 | 🤖 自动 |
| 断网/换WiFi | **啥也不做**,mosh 漫游 | 🤖 自动 |
| 会话自己崩 | **啥也不做**,watchdog 自动 resume | 🤖 自动 |

**进阶:把标签绑死到某会话(标签=会话,开标签直进、不过菜单)**
在 Wave 里 Cmd+T 新开本地标签,跑:`wbind <会话名>`(如 `wbind 项目A`),改标签名,重开 Wave 生效。
原理:把该标签的命令从 `cloudconn cloudgo`(菜单)改写成 `cloudconn cloudattach cc-项目A`(直奔)。

---

## 8. 关键文件 / 命令地图(给接手人)

**服务器 `~/.local/bin/`:**
- `cc-state` — Claude 钩子,写状态+登记表
- `cc-sessions` — 登记表解析层(list/resolve/recoverable/resumable/forget/prune)
- `cloud-watchdog` — 自愈守护(systemd timer 每 15s)
- `cloud-forget` — 删会话(留存档)
- `cloud-sessmenu` / `cloud-sesslist` / `cloud-sesspreview` — cloudgo 的菜单/列表/预览

**服务器 `~/.bashrc` 函数:** `cloudgo`(入口选择器)· `cloudattach`(进会话:活则attach/死则resume)· `cloud`/`cloudnew`/`cloudnewat`(新建)· `cloud_resume`(原生恢复)· `cloudforget`

**服务器其它:**
- `/usr/local/bin/cloud-boot.sh` — 开机引导
- systemd:`cloud-watchdog.timer/.service`、`cloud-sessions.service`、`cloudstatus.service`
- 登记表 `~/.cloud-sessions/`;状态 `~/.cloud-status/`;对话 `~/.claude/projects/<目录>/<uuid>.jsonl`
- 钩子配置 `~/.claude/settings.json`(挂 cc-state + moshi-hook);铃铛 `~/.claude/hooks/{stop,notification}.sh`
- 所有脚本备份在 git 仓库 `~/cloud-setup`(私有)

**Mac:**
- `~/bin/cloudconn`(mosh 连接器)、`~/bin/wbind`(标签绑定助手)
- `~/.zshrc`(proxy 开关函数 + PATH;Tailscale 网段 `100.64.0.0/10` 已加入代理绕过)
- `~/.config/waveterm/`(settings.json / widgets.json / waveai.json / termthemes)
- wsh:`~/Library/Application Support/waveterm/bin/wsh`

---

## 9. 底层原理速记

- **mosh**:先用 SSH 登一次握手(启动 mosh-server + 换密钥),再切 UDP。所以你会看到 SSH——它只是**点火**,之后是纯 UDP。UDP 无队头阻塞 + 本地预测 = 高丢包下打字仍跟手。
- **Tailscale**:基于 WireGuard 的点对点加密网。优先 NAT 打洞**直连**,打不通才回落香港 DERP 中继。给服务器一个稳定内网 IP,不必裸暴露公网。
- **tmux**:终端复用器。它的全部价值=**断开后会话继续在后台跑**;不抗进程被杀(靠 watchdog 重建)。
- **wsh / WAVETERM_JWT**:wsh 是 Wave 的 CLI,**只在 Wave 自己的终端块里能用**(每块有一次性令牌 JWT)。从服务器 ssh 进来的普通 shell 没有 JWT,用不了 wsh——所以无法从服务器侧远程改 Wave 界面。
- **代理绕过**:Mac 系统代理的例外表已加 `100.64.0.0/10`(Tailscale 网段),否则 Wave 的网页块(看板/VNC)会把内网请求也走代理→偶发 -1001 超时。

---

## 10. 已知坑 / 注意事项

1. **中美链路阵发丢包**:打字(mosh)扛得住;但任何走 HTTP 多次往返的(网页看板、VNC、内置浏览器、git over https)在丢包高峰会卡/超时。**这是链路本质,不是 bug。**
2. **`cc-` 前缀是硬约定**:别手动 `tmux rename` 去掉它,否则会话从 hub/看板/自愈里"消失"且不报错。
3. **内存上限 ~10 个活跃会话**:超了会 OOM。加 RAM 必须关机改实例规格。
4. **两个 Wave 并存**:Mac 上有官方版(日常)+ 自建中文版(未打包,dev 态)。配置分 `~/.config/waveterm` 和 `~/.config/waveterm-dev` 两套,改一处需同步。若要省内存,二选一。
5. **Wave AI(GLM)密钥**:走 Mac 本地轮换代理 `127.0.0.1:8718`(launchd `com.glm.rotateproxy`),密钥池 `~/.config/glm-proxy/keys.txt`(明文,**勿外传**)。智谱 key 失效会报"身份验证失败 type:1000",换新 key 填进 keys.txt 即可(实时读、不用重启)。
6. **多端同看一个会话**:Mac 和手机可同时 attach 同一个 tmux(镜像显示),正常。

---

*最后更新:2026-06。维护脚本见 git `~/cloud-setup`。*

---

## 附:仓库部署 / 备份

- **新服务器一键重建**:`./install.sh`(重建脚本 / systemd 服务 / bashrc 片段)。
- **备份建议**:
  - 本仓库 push 到**私有** GitHub(含内网 IP/路径,**务必保持私有**)。
  - 另定期备份 `~/.claude/projects/`(全部对话历史 = 会话的"灵魂",见 §6)。
- 本仓库内容:`bin/`(各脚本)、`cc-state`、`bashrc-cloud-snippet.sh` / `bashrc-shell-enhance.sh`、`claude-config/`(CLAUDE.md + hooks + 命令)、`systemd/`、`install.sh`。
