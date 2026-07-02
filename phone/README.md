# 手机端(Moshi)· 从零配置 runbook

> 让手机当"第三个遥控器":远程**批准** Claude 的权限请求 + 远程**开终端**操作服务器会话。
> Moshi App 有 iOS / Android(作者用 Vivo)。服务器侧的 moshi-hook **systemd 单元**由 `install.sh` 放好
> (见 [`../systemd/moshi-hook.service`](../systemd/) 和 `moshi-hook-healthcheck.*`),但**二进制要
> `moshi-hook update` 自己装、配对后再 `enable`**(§1、§2 讲);本文只讲**手机怎么接上**这半。

## 0. 先搞清:Moshi 有两条独立配对

- **① Agent 钩子配对** —— 让服务器守护连上你的 Moshi 账号,把权限请求/通知推到手机上批。命令 `moshi-hook pair`。断了 = 手机收不到审批推送。
- **② SSH/Mosh 主机配对** —— 让手机能 SSH / 开终端进这台机。命令 `moshi-hook host setup`。断了 = 手机上开不了终端。

两条各配一次、互不影响。**只想在手机上批权限,配 ① 就够;想在手机上开终端,再配 ②。**

## 1. 前置

- 服务器已装 `moshi-hook`(`~/.local/bin/moshi-hook`;没有或要升级就 `moshi-hook update`)。
- 手机装 **Moshi App**(iOS App Store / Android 应用商店),注册并登录你的 Moshi 账号。
- 建议服务器和手机在**同一 Tailscale tailnet**(手机开 Tailscale)——后面能用稳定内网 IP。

## 2. ① Agent 钩子配对(手机批权限)

1. 手机 Moshi App → **Settings → Integrations**(部分版本叫 **Hooks**),拿到 **pairing token**(一串设备令牌)。
   > ⚠️ App 里可能同时给一个 **License key**(形如 `MOSHI-XXXX-XXXX-XXXX`)——那是 App 订阅用的,**主机配对不需要它**,别把两者搞混。
2. 服务器上执行(Linux 无 Keychain,固定用 `--store file`):
   ```bash
   moshi-hook pair --token <你的-pairing-token> --store file --name <主机名，如 echo-j2>
   moshi-hook status                              # 看到 status: paired + host id = 成了
   sudo systemctl restart moshi-hook.service      # 让守护用新配对重连云端
   ```
3. 验证审批通道真的通了:
   ```bash
   journalctl -u moshi-hook.service --since -2min | grep -i 'ws bridge connected'
   ```
   看到 `ws bridge connected` 就对了。此后 Claude 要权限时,手机会弹出批准。

### 换账号 / 报"此主机已与另一个 Moshi 账户配对"

主机之前绑过别的账号时会这样。**先解绑再重配**:
```bash
moshi-hook unpair
moshi-hook pair --token <新账号的-token> --store file --name <主机名>
sudo systemctl restart moshi-hook.service
```

## 3. ② SSH/Mosh 主机配对(手机开终端)

1. 服务器上生成配对码:
   ```bash
   moshi-hook host setup --name <主机名>
   ```
   它打印一个 `moshi://host/setup...` 链接 + 二维码,**约 5 分钟内有效**(过期就重跑)。
2. 手机 Moshi App 扫这个码 → 它把手机的 SSH 公钥装进服务器 `~/.ssh/authorized_keys`。
   > 🖥️ 纯 SSH 进来的**无图形服务器**拿不到图片二维码?两招:① 直接扫终端里打印的 ASCII 二维码;
   > ② 用 `qrencode` 把链接转成 PNG,挂到**只绑 tailnet IP** 的小 http(如 `:8088`)上扫,**扫完立即删**(这码 = 谁扫谁拿到本机 SSH 权限,别外泄/别截图群发)。
3. **扫完必做**:在 App 里把这台主机的地址改成 **IP** —— 开 Tailscale 填 `100.x.y.z`,没开填公网 IP。
   > 默认可能是一串 MagicDNS 名(`xxx.ts.net`),**手机解析不了 → 连不上**,这是"验证失败"最常见的原因。
4. 管理已配对的手机:
   ```bash
   moshi-hook host list        # 看已装了哪些手机 SSH key
   moshi-hook host revoke ...   # 撤掉某一个
   ```

## 4. "验证失败 / 连不上" 排查(从高频到低频)

1. **主机地址是 MagicDNS 名、手机解析不了** → 改成 Tailscale / 公网 **IP**(§3 第 3 步)。最常见。
2. **服务器 SSH host key 变过**(重装系统 / 重生成)→ 手机存的指纹对不上 → 在 App 里删掉这台主机、重新 `host setup`。
3. **账号不匹配**:守护绑账号 A、手机 App 登账号 B → `host setup` 会报"已与另一个账户配对"。用 §2 的换账号流程把守护 `unpair → pair` 到手机那个账号。
4. **守护没在跑**:`systemctl is-active moshi-hook.service` 应为 `active`;不行就 `systemctl restart moshi-hook.service`,再 `moshi-hook logs -f` 看日志。

## 5. 服务器侧守护(已在本仓,供参考)

- 单元:[`../systemd/moshi-hook.service`](../systemd/)(本仓已加 `Restart=always` 兜底,退出即拉起)+ `moshi-hook-healthcheck.timer/.service`(定时体检)。
- 配对信息存在 **file secret store**(`--store file`);在 `unpair` 之前一直有效,**重启守护不丢**。

## 6. 定位:通用核心 vs 你的私有叠加

- **通用核心(可给客户)**:上面整套**流程**——两条配对、命令、排查。谁都照着能把自己的手机接到自己的服务器。
- **你的私有叠加(别入库)**:具体的 pairing token / License key / 主机名 / IP / Moshi 账号——都是个人值,配的时候现填。
- **给客户部署时**:是**客户用他自己的 Moshi 账号**配他自己的服务器,不是套用你的。
