# 远程 Claude 会话体系 · 交接文档

> 一套"在美国服务器上跑 Claude Code,从中国的 Mac(Wave 自建中文版)和手机(Moshi)远程操作"的体系。
> 读完应能理解每层、会话怎么管/恢复/退出/删除,以及出问题去哪查。

---

## 0. 一句话总览

Claude **不在你设备上**,跑在 **美国服务器 echo-j2** 的 **tmux** 里。

- **Mac**:Wave(自建中文版打包 App)→ `cloudconn` → **mosh + Tailscale** → 服务器
- **手机**:Moshi App → SSH/mosh → 服务器
- 两者是**两个遥控器,操作同一批 tmux 会话**。
- 每个会话靠「**会话名 `cc-<名>` + 对话 `<uuid>.jsonl`**」登记;断电/崩溃后 **watchdog** 按 uuid 自动连名带对话接回。
- 每个 **Wave 标签会"自学习"**它常进的会话:重开/意外退出 → **直接进,不弹菜单**。

---

## 1. 全景图

```
   ┌───────────────────────┐            ┌───────────────────────┐
   │ Mac · Wave(中文版App) │            │ 手机 · Moshi App       │
   └───────────┬───────────┘            └───────────┬───────────┘
       cloudconn│(mosh+断线重连+传块ID)        SSH/mosh│(自带密钥)
               ▼                                      ▼
   ╔══════════════ Tailscale/WireGuard 中美加密直连 ══════════════════╗
   ║              Mac 100.101.160.72 ⇄ 服务器 100.109.254.125          ║
   ╚════════════════════════════════╤═════════════════════════════════╝
                                     ▼
   ╔══════════════════ 美国服务器 echo-j2 (root) ═════════════════════╗
   ║  tmux ─┬─ cc-中控 ─ claude ─ <uuid>.jsonl                        ║
   ║        └─ cc-…  ─ claude ─ <uuid>.jsonl                          ║
   ║  后台:cc-state(登记) · cloud-watchdog(15s自愈) · 完成铃铛       ║
   ║  桌面:noVNC :6080(Xvfb+xfce,给 AdsPower 等 GUI)               ║
   ╚══════════════════════════════════════════════════════════════════╝
```

---

## 2. 会话入口:自学习 + 选择器(★日常你只碰这个)

侧栏点 **「会话」**(= `cloudconn cloudgo`):
- **标签学过会话** → 直接进(自学习,按 Wave 的 `WAVETERM_BLOCKID` 记在 `~/.cloud-blockbind/`)。
- **没学过 / 绑的会话没了** → 弹**选择器**:
  - 选一个会话 → 进入 **并记住**(下次这个标签自动进)
  - `➕` 新建会话(选目录)
  - `⟳` 原生选择器恢复(找回未登记的老对话)
  - `🔓` 忘记本标签绑定(改绑/重选)
  - `⏱` 临时会话(用完即弃,不进恢复体系)
  - `Ctrl-X` 对某会话 → **分级删除**(见 §5)

> 自学习 = 你选一次,以后这个标签永久自动进。新标签/改绑才会再用到选择器。

---

## 3. Mac → 会话:逐层

```
① Wave 标签        = 一条存好的命令(像书签);Wave 重开会恢复标签布局并重跑命令
② cloudconn        ~/bin/cloudconn:拉 mosh、传 WAVETERM_BLOCKID、真断线才5秒重连、干净退出不重连
③ mosh             UDP;先 SSH 握手一次再切 UDP;抗丢包/漫游/本地预测
④ Tailscale        加密内网,把 mosh 的包安全送到服务器
⑤ cloudgo          自学习→直接进;否则选择器(见 §2)
⑥ tmux 会话 cc-<名> 会话"活躯体":断开继续跑;被杀由 watchdog 重建
⑦ claude           对话存 ~/.claude/projects/<目录>/<uuid>.jsonl
```

## 4. 手机 → 会话(Moshi)

```
Moshi App(配对 ~/.config/moshi/host-pairings.json,root SSH 进服务器)
  → SSH/mosh → Moshi 内置 tmux 选择器 → 同一批 cc-* 会话(与 Mac 共享)
```
手机独有:**远程批准权限**(allow/deny);Mac 端只显示"等待输入"。**Moshi 是下阶段优化重心。**

---

## 5. 退出 / 分级删除(会话有多层,按需动)

| 你想要 | 怎么做 | 杀tmux | 删登记 | 删对话.jsonl | 能找回 |
|---|---|:--:|:--:|:--:|---|
| 暂离(等下回来) | `Ctrl-b d` / 关标签 | ✕ | ✕ | ✕ | 会话还在跑 |
| 停掉这次运行 | claude 里 `/exit` | ✓ | 标ended | ✕ | ✓ `⟳` |
| 移出体系(留对话) | 选择器 `Ctrl-X`→① | ✓ | ✓ | ✕ | ✓ `⟳` |
| 彻底删除 | 选择器 `Ctrl-X`→②(打 yes) | ✓ | ✓ | ✓ | ✗ |
| 改/重选标签的会话 | 选择器 `🔓` | (不动会话) | — | — | 解绑→重选 |

- `Ctrl-X` 弹引导菜单(`cloud-delmenu`)选 ①移出 / ②彻底 / ③取消;彻底删要打 `yes`。
- **关标签 ≠ 退出**(只是断开,会话还活、自动回);要"别再自动回"用 `/exit` 或 `Ctrl-X`。

## 6. 临时会话(`⏱`)
名字 `cc-tmp-*`:**关标签即销毁**(`destroy-unattached`)、**不登记/不恢复**(`cc-state` 跳过),但 **claude 对话 jsonl 仍保留**(日后 `⟳` 找回)。

---

## 7. 恢复机制

| 机制 | 触发 | 做什么 | 文件 |
|---|---|---|---|
| `cc-state` 钩子 | 每个 Claude 事件 | 写恢复登记表 名↔目录↔uuid;`/exit`→ended=true(不自动复活) | `~/.local/bin/cc-state` → `~/.cloud-sessions/` |
| `cloud-watchdog` | 每 15s | "该活却没在跑"的会话按 uuid 连名带对话 resume;**内存守卫防 OOM** | `~/.local/bin/cloud-watchdog` + systemd timer |
| `cloud-boot.sh` | 开机 | 只启 watchdog 定时器(不一次猛拉) | `/usr/local/bin/cloud-boot.sh` |
| `cloudconn` 重连 | mosh 真断线 | 5s 重连;**干净退出(码0)不重连** | `~/bin/cloudconn` |
| Wave 布局恢复 | 重开 Wave | 读本地 db 重建标签 + 重跑命令 | Mac `waveterm.db` |

> 核心:`.jsonl`(对话)+ 登记表 是"不死的"(硬盘文件);tmux 是可重建的躯体。

---

## 8. 侧栏 widgets(6 个,图标随主题变色 + 同色标签)
默认 terminal/files/web/sysinfo 已隐藏(`display:hidden`);6 个自定义,各取当前主题调色板里一种色(`--wicon-1..6`):
- 🔵 **会话**(`cloudgo`):核心入口(自学习/新建/恢复/改绑/临时/分级删除)。
- 🟣 **主题**(`wavetheme` → 本机 `:8799` 色卡网页):点色卡**一键换整套主题**(终端+画框+边栏+文字+图标联动,13 套:8 浅 5 深,浅色在前)。
- 🩵 **项目看板**(`:8088/` 门户):列各项目自己的看板(读 `/root/inbox/dashboards/registry.json`;`cloud-dashboards.service` 只服务该目录)。
- 🟢 **服务器桌面**(noVNC `:6080`):服务器 GUI(AdsPower 等)。见 §9。
- 🟡 **服务器文件**:浏览服务器 `/opt/workspace`。
- 🔴 **临时会话**(`cloudtmp` → `cc-tmp-*`):关标签 ~60s 自动清(`mosh-server-tmout` 超时 → `destroy-unattached`);不进恢复体系,对话 jsonl 仍留。
> 终端配色含 13 主题的 **cursor 光标色**(每主题对比背景,浅色=深光标),靠 `termthemes/*.json` 的 `cursor` 字段。

## 9. 服务器桌面(noVNC)
- `novnc.service` → `novnc-start.sh`:`Xvfb:1` + xfce + `x11vnc` + `websockify :6080`。
- **健壮版**:全程 `wait` 在 Xvfb 上,它一死脚本退出 → systemd 自动重启(不再出现"空壳无桌面")。
- 用途:在服务器开图形界面(如 **AdsPower**)。点侧栏「服务器桌面」打开 `:6080/vnc.html`。
- 注意:① 跨太平洋链路看图形桌面**会卡**(物理限制);② `:6080` 在自己 tailnet 内**不鉴权**;③ 另有个 `Xvfb:99` 是给 `chrome-devtools-mcp` 的**独立显示**,与本桌面无关、勿混。

---

## 10. 关键文件 / 命令地图

**服务器 `~/.local/bin/`**:`cc-state`(登记钩子)· `cc-sessions`(解析:list/resolve/recoverable/resumable/forget/prune)· `cloud-watchdog`(自愈)· `cloud-forget`(删)· `cloud-delmenu`(分级删除)· `cloud-sessmenu`/`cloud-sesslist`/`cloud-sesspreview`(选择器)
**服务器 `~/.bashrc` 函数**:`cloudgo`(入口+自学习)· `cloudattach`(进会话)· `cloudtmp`(临时)· `cloudunbind`(解绑)· `_cloudbind`(记绑)· `cloudnewat`/`cloudnew`/`cloud_resume`(新建/恢复)
**服务器其它**:`/usr/local/bin/{cloud-boot.sh, novnc-start.sh}` · systemd:`cloud-watchdog.timer/.service`、`cloud-sessions.service`、`novnc.service`、`cloud-dashboards.service`(:8088 项目看板) · 登记 `~/.cloud-sessions/` · 绑定 `~/.cloud-blockbind/` · 对话 `~/.claude/projects/.../<uuid>.jsonl` · 钩子 `~/.claude/settings.json`(cc-state + moshi-hook)· 铃铛 `~/.claude/hooks/{stop,notification}.sh`
**Mac**:`~/bin/cloudconn` · `~/.zshrc`(proxy 开关;Tailscale 网段 `100.64.0.0/10` 已加代理绕过)· `~/.config/waveterm`(打包版读)/`waveterm-dev`(dev 重建读)· `~/build/waveterm-zh`(自建源码)

---

## 11. 底层原理速记
- **mosh**:先 SSH 握手一次(启 mosh-server+换密钥)再切 UDP。UDP 无队头阻塞 + 本地预测 = 高丢包下打字跟手。
- **Tailscale**:WireGuard 点对点加密;优先 NAT 打洞直连,打不通回落香港中继。
- **tmux**:扛"断开"(会话后台继续跑);不扛"杀掉"(靠 watchdog 重建)。
- **标签稳定 ID(自学习的键)**:`cmd` 控制器的块(跑 cloudconn 的标签)**拿不到 `WAVETERM_BLOCKID`**(它走 shell 集成的 swap-token,只 shell 块注入)→ `cloudconn` 改从 **`WAVETERM_SWAPTOKEN`**(base64 JSON 的 `.rpccontext.blockid`)解出 blockid 当键,带到服务器,cloudgo 据此记"标签↔会话"。blockid 跨 **Cmd+Q 重启不变**(但关标签开新的 = 新 id,要重选一次)。
- **wsh / JWT**:wsh 只在 Wave 自己的块里能用(mosh 会话里没有);所以恢复/绑定全在 cloudgo/cloudconn 这层做。

## 12. 已知坑 / 注意
1. **中美链路阵发丢包**:打字(mosh)扛得住;网页类(VNC桌面/内置浏览器/git https)天生卡——物理限制,非 bug。
2. **`cc-` 前缀是硬约定**:别手动 `tmux rename` 去掉,否则会话从工具里"消失"且不报错。
3. **内存上限 ~10 个活跃会话**(15G);加 RAM 须关机改实例规格。
4. **两套 Wave 配置**(`waveterm`/`waveterm-dev`)改配置需同步;只要还 dev 重建就得留两套。
5. **GLM key**:Mac 本地轮换代理 `127.0.0.1:8718`,密钥池 `~/.config/glm-proxy/keys.txt`(明文勿外传);失效报"身份验证失败 type:1000",换新 key 填进去即可。
6. **最大长期成本 = 维护自建 Wave 分叉**(跟上游需重新合并+编译+打包)。兜底永远是回官方版(丢中文+自定义画框,但零维护)。

---

## 附:仓库部署 / 备份 / 还原

**仓库结构**:`bin/`(服务器脚本)· `systemd/`(服务单元:watchdog/sessions/novnc/cloud-dashboards)· `cloudconn`/`mosh-server-tmout`(Mac/服务器辅助)· `cc-state` · `bashrc-cloud-snippet.sh` · `wave-config/`(Mac Wave 客户端配置)· `README.md`

**Wave 客户端配置 `wave-config/`**:
- `wave-config/{waveterm,waveterm-dev}/` = Mac `~/.config/waveterm{,-dev}` 整套:`settings.json`(term:theme/waveai)· `widgets.json`(6 widget + 颜色)· `termthemes/*.json`(13 主题配色 + **cursor 光标色**)· `waveai.json`(GLM 走本地代理,无真 key)· backgrounds/presets/connections。
- **还原**:`cp -r wave-config/waveterm/* ~/.config/waveterm/ && cp -r wave-config/waveterm-dev/* ~/.config/waveterm-dev/` → 重开 Wave 即生效(termtheme/widgets 是运行时配置,不用重编译)。
- 主题/图标/标签的**源码**(`theme.scss`/`app.tsx`/`widgets.tsx`,需 `build:prod`+`electron-builder --dir` 编进 .app)在自建分叉 `~/build/waveterm-zh`,不在本仓库。
- ⚠️ **不含**:Wave 数据库(`~/Library/Application Support/waveterm`,标签/块布局/历史 = 每机状态,别备份)+ GLM 密钥(`~/.config/glm-proxy/keys.txt`,**勿入库**)。

**其它**:新服务器一键重建 `./install.sh`;本仓库 push 到**私有** GitHub(含内网IP/路径);另定期备份 `~/.claude/projects/`(对话历史 = 会话的"灵魂",见 §7)。

---

## 附二:通用骨架 vs 个人配置(复用 / 分享须知)

本仓 = **一套可复用的「远程 Claude 工作站」骨架** + **我(Echo)的个人配置**。换人复用时:**🟢 通用层照搬,🔴 个人层替换成自己的**。

**🟢 通用层(换谁都能用,是这套系统本体)**
- 会话系统:`cloudconn` · `cc-state` · `bin/cloud-*`(watchdog/sessions/delmenu/sesslist…)· `tmux.conf` · `systemd/cloud-*`+`novnc` · `install.sh` · `bashrc-*.sh`
- 多 agent:`hub/`
- Mac 桥接:`bin/{macget,macput,macls,pullimg}`
- Wave 工具:`wavetheme` · `wavetheme-server` · `statusline.py` · `com.wavetheme.ui.plist`

**🔴 个人层(我特定的,复用必换)**
- `claude-config/CLAUDE.md` —— 我的业务规则(Echo 前缀、raas/公司、机器分工)。
- `claude-config/{settings.json, hooks/, mcpServers.json, installed_plugins.json, known_marketplaces.json}` —— **我选的 6 MCP / 9 插件 / 7 市场** + 钩子接线(含 moshi/hub)。⚠️ 工具本身大多通用、可从市场重装,**但"选了哪些"这套组合是个人配置**。
- Skills(34)+ `hello2cc-local`(我的本地市场 = `github.com/hellowind777/hello2cc`)—— **个人技能组合**(内容不入库,清单在上面 records 里;还原见 `claude-config/RESTORE.md`)。
- `wave-config/`(我的主题/部件审美)· `hammerspoon-init.lua`(我的 Mac)· `bin/wechat-cli`(业务)· `systemd/moshi-hook.service` + moshi 配对(我的手机审批)。

> 一句话:**`bin/` + `systemd/`(cloud/novnc 部分) + `hub/` + `cloudconn` + Wave 工具 = 通用骨架;`claude-config/` 整目录 + `wave-config/` + 几个 Mac/业务脚本 = 个人配置。**
