# 无头 VPS 上首次 claude 登录

> 纯 SSH 的远程服务器(没桌面、没浏览器)第一次跑 `claude` 会卡在「登录」——它是 OAuth 网页授权、默认要开浏览器。
> 本文讲**无头环境怎么把这步走通**:为什么卡、具体步骤、凭据落哪、之后怎么免登。
> 对应 [README.md](../README.md)「服务器 0→1」第 ③ 步(那里只写了 `claude`,没展开无头怎么办)。
> 实测环境:Claude Code **v2.1.179**,Linux(无 Keychain)。CLI 有更新时以 `claude auth login --help` 为准。

## 0. 先理解:为什么会卡

`claude` 首次要登录 = 走 OAuth 网页授权,它默认**打开本机浏览器**。无头 VPS 没有桌面浏览器,于是你会看到:

```
· Opening browser to sign in…
```

然后就停在这。**这是正常的,不是死机** —— 往下它会自己提示 `Browser didn't open?` 并打印一条 URL,用那条 URL 手动走即可。

**好消息(无头能登的关键)**:Claude Code 的 OAuth 回调走的是**托管页面**(`https://platform.claude.com/oauth/code/callback`),**不是** `http://localhost:端口` 那种回环回调。所以授权完,网页会**直接显示一段 code(授权码)**给你,你把它**贴回终端**就行:

- 不需要服务器能被浏览器访问,
- 不需要 SSH 端口转发 / 隧道,
- 授权用的浏览器和服务器可以是两台完全不相干的设备。

> 很多 CLI 的 OAuth 回调是 `localhost:端口`,无头就得开隧道才行 —— Claude Code **不是**这种,省这道事。

## 1. 标准流程(推荐,给人用)

在服务器上任选其一触发登录:

```bash
claude                 # 首次没登录会自动进登录流程(= README 第 ③ 步)
# 或显式:
claude auth login      # 想重登 / 换号时用这个
```

屏幕依次出现(节选实测输出):

```
· Opening browser to sign in…
  Browser didn't open? Use the url below to sign in (c to copy)

  https://claude.com/cai/oauth/authorize?code=true&client_id=...&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&scope=...&code_challenge=...&state=...

  Paste code here if prompted >
```

按这几步走:

1. **整段复制那条 URL** —— 从 `https://claude.com/cai/oauth/authorize?` 一直到结尾的 `state=...`。用你终端软件的鼠标选中复制即可。
2. 在**任意有浏览器的设备**(你的 Mac / 手机 / 另一台电脑)打开这条 URL。
3. 登录你的 Claude 账号 → 点 **Authorize(授权)**。
4. 授权后,页面会**显示一段 code**。复制它。
5. 回服务器终端,把 code 粘到 `Paste code here …>` 后面,回车。
6. 成功后凭据落盘,`claude` 直接进对话(或 `auth login` 返回成功)。用 `claude auth status`(下节)复核。

### 选哪个账号 / 登录方式

`claude auth login` 的开关(`claude auth login --help`):

- `--claudeai` —— 用 Claude 订阅(Pro/Max),**默认**,不写也是它。
- `--console` —— 用 Anthropic Console(按 API 用量计费)而非订阅。
- `--email <你的邮箱>` —— 预填登录页邮箱,省得再输。
- `--sso` —— 强制走企业 SSO 流程。

## 2. 备选:`claude setup-token`(长期令牌,给非交互 / CI)

如果你要的是**无人值守**跑 `claude -p ...`(脚本、CI、批处理),而不是坐在终端前交互登录,用:

```bash
claude setup-token     # 需要 Claude 订阅
```

流程和 §1 **一模一样**(打不开浏览器 → 贴 URL 授权 → 把 code 贴回来),区别是它最后**打印一个长期 token**,按屏幕提示保存后用于非交互调用(通常设成环境变量给 `claude -p` 用)。它申请的权限范围较窄(实测 scope 只有 `user:inference`,即「只跑推理」),不等于 §1 的完整登录。

> **一般部署走 §1 就够。** 只有确实要 CI / 无人值守、或不想在每台机器都开浏览器授权时,才用 setup-token。

## 3. 凭据落在哪 · 之后怎么免登

登录成功后写到**两个文件**(Linux 没有 Keychain,一律**明文文件**存储):

- **`~/.claude/.credentials.json`** —— 登录态本体。权限 `0600`(只有属主可读),里面 `claudeAiOauth` = `accessToken` / `refreshToken` / `expiresAt` / `scopes` / `subscriptionType`。
- **`~/.claude.json`** 里的 **`oauthAccount`** 段 —— 账号身份(邮箱 / accountUuid / 组织信息)。

**之后免登**:accessToken 到期会自动拿 refreshToken 续,日常不用再登。会话自愈(cloud-watchdog 跑 `claude --resume`)也直接复用这份凭据,重启/断电拉回会话时不用重新登录。

**查登录态**(随时可用,只读、安全):

```bash
claude auth status --text     # 人话:登录方式 / 组织 / 邮箱
claude auth status --json     # 机读:loggedIn / email / subscriptionType / orgId ...
```

看到 `loggedIn: true` + 你的邮箱 + 订阅类型,就是登好了。

**登出 / 换号**:`claude auth logout` 登出;换号直接再 `claude auth login` 走一遍(在**已经跑着**的会话里也可以用 `/login` 温和换号,不必重启会话)。换号只动上面两个文件的凭据 / `oauthAccount` 段,**对话历史和其它配置不受影响**。

## 4. 常见坑

1. **卡在 `Opening browser to sign in…` 干等** —— 正常,无头没浏览器。别等,往下看 `Browser didn't open? Use the url below…` 那行,用它打印的 URL 手动走。
2. **URL 打印了好几遍 / 中间换行** —— 那是终端重绘 + 长串折行造成的,**不是给了多条**。只需**任意一条完整的**,认准 `https://claude.com/cai/oauth/authorize?...state=...` 首尾即可。
3. **提示的 `c` 复制键没反应** —— `c` 是复制到**服务器本地**剪贴板,纯 SSH 无剪贴板环境下没用。直接用你**终端软件**的鼠标选中复制。
4. **code 贴回去报无效 / 过期** —— 授权码有时效,别拖太久;而且每次跑登录时 URL 里的 `state` / `code_challenge` 是**一次性**的:必须用**这一次**打印的 URL 去授权、拿**这一次**的 code,不能用上一回残留的。搞混了就重跑命令拿新 URL。
5. **贴了 code 但终端没动静** —— 确认光标停在 `Paste code here …>` 之后再粘、粘完按回车;个别终端粘超长串会吞字符,可留意有没有粘全。
6. **`.credentials.json` 权限 / 属主不对** —— 必须 `0600`、属主是跑 claude 的那个用户(本机是 root)。手动迁移凭据后若变成别人可读、或属主错了,claude 可能拒用或每次都要求重登;`chmod 600` + `chown` 修回来。
7. **凭据别入库、别外发** —— `~/.claude/.credentials.json` 是**明文令牌**,绝不 git 提交、绝不截图群发。给客户部署时是**客户用自己账号登录、你不经手他的凭据**(见 [DEPLOY.md](../DEPLOY.md) 红线;登录本身不需要你替客户做)。

## 5. 一句话

无头 VPS 也能正常登:Claude Code 的 OAuth 用**托管回调 + 贴授权码**,不用隧道、不用服务器可被浏览器访问。卡在 README 第 ③ 步 `claude` 时,翻本篇按 §1 走。
