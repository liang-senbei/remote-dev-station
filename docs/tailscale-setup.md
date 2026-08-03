# Tailscale:三设备同 tailnet + 无头授权 · runbook

> 这套体系的**入网命脉**:Claude 跑在美国服务器上,你的电脑、手机要能安全地连进去,全靠 Tailscale
> 把「服务器 + 电脑 + 手机」组进**同一个加密内网(tailnet)**。装好后,三台机器互相能用一个稳定的
> `100.x.y.z` 内网 IP 直连,不暴露公网端口。
>
> `install.sh` **不装 Tailscale**(它是前置命脉,得先自备)——本文只讲 Tailscale 这一层怎么从零配好、
> 无头服务器怎么授权、以及这套仓里谁在用它的 IP。装 Claude 会话层见 [`../README.md`](../README.md),
> 手机 Moshi 见 [`../phone/README.md`](../phone/README.md)。

## 0. 两个概念(先内化)

- **tailnet** = 绑在**一个 Tailscale 账号**下的那张私有网。三台设备**登同一个账号**,就自动进同一个 tailnet,彼此可见、可直连。
- **Tailscale IP** = 每台机器入网后分到的一个 `100.x.y.z`(CGNAT 段 `100.64.0.0/10`),**跨重启不变**,是这套体系里一切内网服务(看板 `:8088`、`cloudconn` 的 mosh)寻址用的地址。(登录桌面 TigerVNC `:5901` 是**公网**口、不走 tailnet —— 客户第一次要用桌面正是为了登录、那时 Tailscale 还没配好。)

> 部署给客户时:**客户用他自己的 Tailscale 账号**组他自己的 tailnet,不是加进别人的。仓里出现的
> `<SERVER_TAILSCALE_IP>` 是占位符(服务器的 Tailscale IP),客户处一律换成**自己服务器**的(见 §3 的「必改清单」)。

## 1. 前置:三台都装客户端

- **服务器(无头 Linux)**:`curl -fsSL https://tailscale.com/install.sh | sh`(官方脚本,认 Ubuntu/Debian),装完 `tailscaled` 守护进程会自动起。
- **电脑(Mac)**:装 Tailscale App(App Store 或 `brew install --cask tailscale`),菜单栏登录。
- **手机**:装 Tailscale App(iOS App Store / Android 应用商店),登录。

**三处登同一个账号 = 自动同一个 tailnet。** 账号本身用 Google / GitHub / Microsoft / 邮箱都行,关键是三台**登的是同一个**。

## 2. ① 无头服务器怎么授权(核心:没有浏览器怎么办)

服务器上跑:

```bash
tailscale up
```

它**不会**在服务器上弹浏览器,而是**打印一条授权链接**,形如:

```
To authenticate, visit:
    https://login.tailscale.com/a/xxxxxxxxxxxx
```

把这条 URL **复制到任意一台有浏览器的设备**(你的电脑或手机)打开 → 用你的 Tailscale 账号登录 → 点批准。
服务器这边 `tailscale up` 就会返回成功,机器入网。**授权只需一次**,之后开机 `tailscaled` 自动重连、不用再点。

### 更省事:用 `--authkey` 非交互入网(脚本化 / 批量)

不想手动点链接(比如 Claude 自动化部署),可以预先生成一把 **auth key** 直接带上:

```bash
tailscale up --authkey tskey-auth-xxxxxxxxxxxxxxxx
```

**auth key 哪来的**:去 Tailscale 管理后台 **Admin console → Settings → Keys → Generate auth key**
(`https://login.tailscale.com/admin/settings/keys`),生成的 key 形如 `tskey-auth-...`。生成时可勾:

- **Reusable**(可复用,多台机器共用一把;否则用一次即失效)
- **Ephemeral**(临时节点,下线自动从 tailnet 清掉——服务器**别勾**)
- **Pre-approved / Tags**(免去后台再手动批准,适合自动化)
- **有效期**(默认最长 90 天,只是"这把 key 能用多久",跟机器入网后的续期是两回事,见 §5)

> ⚠️ auth key = 谁拿到谁能把机器塞进你的 tailnet,**当密码对待**:别写进入库的脚本、别贴群里;
> 部署给客户是**客户在自己后台生成自己的 key**,不用别人的。

## 3. ② + ③ 落到同一 tailnet & 取本机内网 IP

三台都 `up`/登录同一账号后,在**服务器**上验证成员:

```bash
tailscale status        # 列出 tailnet 里所有设备:IP、主机名、在线/直连或中继
tailscale ip -4         # 只打印【本机】的 IPv4(那个 100.x.y.z)—— 最常用
```

`tailscale status` 能看到你的电脑、手机、服务器都在同一张表里 = 三设备同 tailnet 成功。
`tailscale ip -4` 取到的这个 `100.x.y.z`,就是下面所有内网服务寻址用的地址。

### 这套仓里谁在用这个 IP(部署时对照)

**服务器侧——自动适配(不用改)**:
- [`../bin/cloud-dashboards.sh`](../bin/cloud-dashboards.sh) **自己**跑 `tailscale ip -4 | head -1` 取本机 IP,把看板绑到 `${TS_IP}:8088`(取不到回落 `127.0.0.1`)。所以看板层换机**无需手改 IP**;桌面层(TigerVNC 公网 `:5901`)压根不涉及 tailnet IP。

**服务器侧——已全部自动取本机 IP(无需手改)**:
- [`../bin/cloud-dashboards.sh`](../bin/cloud-dashboards.sh)(看板 `:8088`)在脚本内 `tailscale ip -4 | head -1` 自动绑本机 IP;`systemd/cloud-dashboards.service` 的 `ExecStart` 已指向那个 wrapper、不再写死 IP。**服务器侧不用改 IP。**

**电脑(Mac)侧——含服务器 IP 占位符(客户必改,DEPLOY 已列)**:
- [`../cloudconn`](../cloudconn) 与 `../wave-config/cloudconn` 里的 `HOST="root@<SERVER_TAILSCALE_IP>"`(后者还多一个 `HOSTIP=`)——mosh 连服务器用。
- `../wave-config/{waveterm,waveterm-dev}/widgets.json` 里 `:6080`(桌面)和 `:8088`(看板)两处 URL。

> 一句话:**服务器侧(看板 service)自动认本机 IP、无需改;只有 Mac 端的 cloudconn / widgets 是写死的,换机必改成客户自己服务器的 `tailscale ip -4`。**

### 防火墙:为什么绑到内网 IP 就安全

`install.sh` 的防火墙基线是 `ufw allow in on tailscale0`(信任整个 tailnet 网卡)+ `22/tcp` + `60000:61000/udp`(mosh)。
所以 `:6080`/`:8088` 这些服务**只绑 `100.x` 内网 IP、只在 tailnet 内可达**,公网扫不到 = 安全边界。这也是为什么它们不做额外鉴权。

## 4. ④ MagicDNS 名 vs IP —— 客户端一律填 IP

Tailscale 有个 **MagicDNS**:开了之后每台机器还有个域名式的名字,形如 `<主机名>.<tailnet>.ts.net`(或短名 `<主机名>`)。
**但解析这个名字要求客户端本地的 Tailscale DNS 生效**——手机上的 SSH / Moshi 客户端常常用不到这个解析器,填 `*.ts.net` 就报 `DNS resolution failed` / 验证失败。

**实操铁律:客户端配主机地址,填 `100.x.y.z` 这个 IP,别填 MagicDNS 名。**

- **手机 Moshi**:配对后进 App 把主机地址改成服务器的 **Tailscale IP**(手机开着 Tailscale 时,更私密)或**公网 IP**(不开 Tailscale 时,22 端口已放行)。这是「验证失败」头号原因,详见 [`../phone/README.md`](../phone/README.md) §3 第 3 步 + §4 排查第 1 条。
- **Mac `cloudconn`**:`HOST` 直接写 `root@100.x.y.z`,别用域名。

> ⚠️ **中国 Mac 走代理的额外坑**:如果 Mac 挂了 HTTP/SOCKS 代理,要在代理里**绕过 tailnet 段 `100.64.0.0/10`**
> (在你自己的 `~/.zshrc` 里加),否则去往 `100.x` 的流量被塞进代理 → 连不上服务器。见 [`../README.md`](../README.md) §10。

## 5. ⑤ key 过期怎么续

有两种"过期",别混:

1. **auth key 过期**(§2 那把 `tskey-auth-`):只影响"还能不能用这把 key **新入网**机器",最长 90 天。过期了就去后台重新 **Generate auth key**。**已经入网的机器不受它影响。**
2. **机器 node key 过期**(每台设备入网后自己那把):这才是"服务器过一阵突然连不上"的原因。默认有效期约 180 天(以 Admin console 显示为准),到期后该设备在后台标 **Key expired**、掉线,直到重新认证。

**续期两选一**:

- **重新认证**:在那台机器上再跑一次 `tailscale up`(无头服务器 → 又打印授权 URL,浏览器点一下批准,同 §2)。
- **对常开服务器,推荐直接免过期**:Admin console → Machines → 选中这台 → **Disable key expiry**。这台服务器 24×7 常驻,关掉 key 过期省得每半年断一次(这是官方对 always-on 服务器的常规做法)。

> 排查"某天突然全断":先在服务器 `tailscale status`——若本机显示未连或后台标 key expired,就是 node key 到期,按上面续。
> 日常体检:[`../cloud_infra_check.sh`](../cloud_infra_check.sh) 把 `tailscaled.service` 列为**核心必绿项**(挂了提示 `tailscale up` 恢复)。

## 6. 连不上?排查顺序(从高频到低频)

1. **两端不在同一 tailnet** → 两边各 `tailscale status`,确认能互相看到;看不到 = 有一台没登、或登错账号。
2. **客户端填了 MagicDNS 名** → 改成 `100.x` IP(§4)。手机端最常见。
3. **服务器 node key 过期** → `tailscale status` 看本机状态,`tailscale up` 重认证或后台 Disable key expiry(§5)。
4. **IP 写错了地方** → 检查 `cloudconn` 的 `HOST`、`widgets.json` 的 URL,是不是还留着没填的占位符 `<SERVER_TAILSCALE_IP>`(§3 必改清单)。服务器侧看板已自动取本机 IP、不用查。
5. **代理没绕过 tailnet 段** → Mac 代理里放行 `100.64.0.0/10`(§4 坑)。
6. **`tailscaled` 没在跑** → `systemctl is-active tailscaled`,不行 `systemctl restart tailscaled` 再 `tailscale up`。

## 7. 定位:通用核心 vs 私有叠加

- **通用核心(照搬)**:上面整套**流程**——三台装客户端、无头 `up` + 授权 URL / `--authkey`、`tailscale ip -4` 取 IP、客户端填 IP 不填 MagicDNS、key 续期。谁都照着能把自己三台机器组进自己的 tailnet。
- **私有叠加(必换)**:具体的 **Tailscale 账号 / auth key / 各机器 `100.x` IP**——全是个人值。仓里的占位符 `<SERVER_TAILSCALE_IP>`(代表服务器 IP),客户处一律换成自己 `tailscale ip -4` 的结果(§3 必改清单)。
