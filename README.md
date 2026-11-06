<h1 align="center">Horizon Setup</h1>

<p align="center">Omarchy 的输入习惯、工具链、防火墙与插件汉化配置面板</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-10b981?style=flat-square" alt="MIT license"></a>
  <a href="https://github.com/Hyprwm/Hyprland"><img src="https://img.shields.io/badge/WM-Hyprland-89b4fa?style=flat-square" alt="Hyprland"></a>
  <a href="https://omarchy.com"><img src="https://img.shields.io/badge/OS-Omarchy-f38ba8?style=flat-square" alt="Omarchy"></a>
  <a href="#快捷键桥接"><img src="https://img.shields.io/badge/Cmd-21%20%E7%BB%84%E6%A1%A5%E6%8E%A5-10b981?style=flat-square" alt="Cmd bridges"></a>
</p>

<p align="center">
  <a href="#快速安装">安装</a> ·
  <a href="#面板">面板</a> ·
  <a href="#快捷键桥接">快捷键桥接</a> ·
  <a href="#插件汉化">插件汉化</a> ·
  <a href="#防火墙ufw">防火墙</a> ·
  <a href="#配套推荐">配套推荐</a> ·
  <a href="#工作原理">原理</a> ·
  <a href="#开发">开发</a> ·
  <a href="#卸载">卸载</a>
</p>

把输入习惯调成 Mac 手感，并顺手管好包管理、网络代理、**ufw 防火墙**与
**第三方插件汉化**的一键面板。
所有开关**可检测、可切换、幂等**——不用再猜「刚才那条命令到底生效没」。

面板是 Omarchy overlay，入口在 **菜单 → 设置**，不占顶栏；内部按用途分四个 Tab。

## 快速安装

需要 **Omarchy（Hyprland + Quickshell）**。克隆到插件目录：

```bash
git clone https://github.com/CARVIN94/omarchy-horizon-setup.git \
  ~/.config/omarchy/plugins/horizon.setup
```

**然后必须启用它** —— 第三方插件不会自动启用：判定是「`shell.json` 里有引用」
（`shell/services/PluginRegistry.qml:135-163`，`plugins[]` 或 `bar.layout.*` 任一处；
只有 first-party 才默认启用）。不启用的话 `omarchy plugin list` 显示 `disabled`，
`omarchy-shell shell summon` 只回 `unknown`，面板点不开：

```bash
omarchy plugin enable horizon.setup     # 往 ~/.config/omarchy/shell.json 的 plugins[] 里登记
omarchy plugin list | grep horizon      # 应显示 enabled
omarchy-restart-shell
```

> 没有 `omarchy plugin enable` 子命令（老版本）时，等价做法是手工登记：
>
> ```bash
> jq '.plugins = ((.plugins // []) + ["horizon.setup"] | unique)' \
>   ~/.config/omarchy/shell.json > /tmp/shell.json \
>   && mv /tmp/shell.json ~/.config/omarchy/shell.json
> omarchy-restart-shell
> ```

### 加菜单入口（一次性）

面板装好后还需要一个点得开的入口。Omarchy 的菜单是 `jsonc`，用户扩展文件
`~/.config/omarchy/extensions/omarchy-menu.jsonc` 默认不存在——自己建一个，
把下面这条加进去（已有别的条目就以同样格式追加，别覆盖掉你原有的）：

```jsonc
{
  "setup.horizon": {
    "icon": "⚙️",
    "label": "Horizon Setup",
    "aliases": ["horizon", "mackeys", "mac"],
    "action": "omarchy-shell shell toggle horizon.setup"
  }
}
```

> **加一次，永久有效**：这个条目属于「用户自加」，1.3.x → 1.4.0 的迁移脚本
> 精简该文件时**会显式保留它**（保留清单里第一条就是 `setup.horizon`）。所以
> 先跑迁移再加菜单、或者先加菜单再跑迁移，结果一样，不冲突。
>
> 不想动菜单也行，命令行等价：
> `omarchy-shell shell toggle horizon.setup`（或 `omarchy-shell shell summon horizon.setup '{}'`）。

装好后打开 **菜单 → 设置 → Horizon Setup**；点开即是面板。

> **从 1.3.x 升级的老用户**：1.4.0 不再依赖 omarchy-zh-cn（第三方汉化项目），
> 而 Omarchy 0.4.5 自带多语言。升级后跑一次迁移脚本，把旧项目写进用户态的东西
> 一次清干净 —— bar 挂件切回 `omarchy.*`、删 `carvin.*` 插件目录、把旧中文菜单
> 副本**精简**成只留你自己加的条目（`setup.horizon` 面板入口等，其余交给 0.4.5
> 原生中文菜单）、删 `bindings.lua` 里的 zh 块（SUPER+K 恢复原生）、删三个
> `omarchy-zh-*` 脚本与 post-update hook、删它的 state 目录。脚本**幂等**，
> 跑几次都一样，无事可做时只打印「已是干净状态」：
>
> ```bash
> bash ~/.config/omarchy/plugins/horizon.setup/lib/migrate-drop-omarchy-zh-cn.sh --dry-run
> bash ~/.config/omarchy/plugins/horizon.setup/lib/migrate-drop-omarchy-zh-cn.sh
> ```

命令行直查/切换（面板之外的等价操作）：

```bash
P=~/.config/omarchy/plugins/horizon.setup/setup.sh
$P status                     # 全部开关状态（含 ufw 与规则条数）
$P rules                      # 当前 ufw 规则（TAB 分隔）
$P toggle keys                # 开/关 Mac 快捷键
$P fw-add 3082 tcp 192.168.0.0/24 'DSH web'   # 新增放行（会弹一次授权）
$P fw-del 3082 tcp 192.168.0.0/24 'DSH web'   # 精确删除（同样授权）
```

## 面板

**菜单 → 设置 → Horizon Setup**，overlay 窗口（`Esc` 或点空白关闭）。
四个 Tab 按「这块配置属于谁」分组：

| Tab | 内容 | 说明 |
| --- | --- | --- |
| **Mac 习惯** | Mac 快捷键、自然滚动、剪贴板快捷键 | 键位、滚动与剪贴板。 |
| **开发环境** | npm 换源、GitHub 加速、Google 翻译修复 | 包管理与网络。 |
| **防火墙** | ufw 规则列表 + 增删 | 读写分离：读免权限，写走一次授权。 |
| **插件汉化** | 第三方插件中文文案与 Omasnap 界面的汉化/还原 | 映射表组改文案 + Omasnap 改源码重编译，都免授权。 |

头部显示 `已启用/总数` 胶囊徽章；底部在写配置时显示进行中。

### GitHub 代理（git fetch 镜像）

面板开关只做一件事：`git config url.insteadOf` 把 `github.com` 改写到 `gh-proxy.org`。
免密、即时、必成 —— **开关的成败只由它决定**。push 仍直连 GitHub（镜像是只读的）。

注意它只改写 `git` 自己的流量。`raw.githubusercontent.com` 上的文件
（脚本 `curl`、包管理器、编辑器插件）**不经这条规则**，整段 IP 挂掉时需手写镜像
URL —— 详见下面「已知天花板」。

### GitHub hosts 加速（一次性安装，非开关）

把 `github.com` 等域名指向**当天探活通过的多个 IP**，每天 04:00 自动刷新。

**为什么做成一次性安装而不是开关**：写 `/etc/hosts` 必须 root，而 root 授权
（pkexec/polkit）并不总是可靠 —— 实测本机 polkit 对 `org.freedesktop.policykit.exec`
反复 `FAILED to authenticate`。若把它塞进面板开关，授权一失败开关就「点不动」
（这是真 bug，已修）。故：开关只管 git；hosts 走一次性的 root 安装，装完后
每日刷新**零密码、零干预**。

安装（粘贴到终端，sudo 缓存 5 分钟故只输一次密码）：

```bash
bash /tmp/horizon-hosts-install.sh     # 先 cat 看一眼内容再执行
```

装了什么：

| 路径 | 内容 |
| --- | --- |
| `/usr/local/bin/horizon-setup-hosts-refresh` | root 所有的刷新器（root:root 0755） |
| `/etc/systemd/system/horizon-setup-hosts.service` | oneshot 服务 |
| `/etc/systemd/system/horizon-setup-hosts.timer` | 每日 04:00，`Persistent=true` |

> **为什么每天探活而不是信上游快照**：国内访问 GitHub 是**按 SNI 的概率性阻断**
> （DNS 干净、TCP 常通、TLS 阶段丢包），且各 IP 状态**小时级翻转**。实测：
>
> - 上游 `hosts.gitcdn.top` 是**静态快照**，`github.com` 长期钉在单个
>   `20.205.243.166` 上 —— 该 IP 一死，整块 hosts 全废。
> - 公共 DNS（1.1.1.1 / 8.8.8.8 / 223.5.5.5 / 119.29.29.29）对 `github.com`
>   **也只返回这一个 A 记录**。所以「删掉 hosts 让它自然解析」同样不通。
> - 只写单条映射：`0/10` 成功；写 5 条存活 IP：`9/10`。
> - 探活成功那个 IP 立刻复用：仅 `3/10` —— 因为 TLS 层还会概率性丢。
>
> ⇒ 刷新器抓完上游后，对 `github.com` / `api` / `codeload` /
> `raw.githubusercontent.com` / `objects` / `gist` 六个域名，
> **并行探测候选 IP 池**（`curl --resolve`，判据 HTTP 200/301/302/403/404，
> 见 403/404 也算「TCP+TLS 已成立」），把**所有存活的 IP 写成多行**。
> 全并行约 4 秒。某域名一个都没探活成功时保留上游原行（宁可赌一次，也不留空）。
> 逃生阀：`HORIZON_HOSTS_PROBE=0` 关闭探活，退回纯上游快照。
>
> **「通」不等于「是 GitHub」——探活必须验指纹**：`20.205.243.169` 的
> TCP/TLS/HTTP 全通、回 `200`，但任何 git 请求都只拿到 `text/plain "OK"`，
> git 报 `info/refs not valid: is this a git repository?`；而浏览器、`gh auth`、
> `curl https://github.com/` 全都正常，从表面完全看不出问题。只判状态码的探活
> 会把它当活 IP 写进 hosts，于是每天刷新后 push 随机失败。故判据是**两层**：
> 状态码成立 **且** 应答带 GitHub 指纹（`strict-transport-security` /
> `etag` / `server: github.com` 之一）；只会回 `OK` 的中转/劫持节点三个都没有。
>
> **这套方案管不到的地方（已知天花板）**：实测有三种互不相同的失效方式，
> hosts 只对第一种有效。
>
> | 失效方式 | 实测证据 | hosts 有用吗 |
> |---|---|---|
> | **A. 单 IP 死、池中有活** | `github.com` 的 `.166` 死时，`140.82.113.3`/`.114.3`/`.112.3` 均 200 | ✅ 写多条就稳 |
> | **B. 整段 IP 同时死** | `raw`/`objects` 共用的 `185.199.108-111.133` 四个 IP 同时全 `000`（10:26、10:36 两轮） | ❌ 写几条都是同一段的死 IP |
> | **C. 按域名 SNI 阻断** | `gist.github.com` 换 7 个 IP 全 `000`；`curl -v` 显示 ClientHello 发出后 `Recv failure: Connection reset`。**同一批 IP 打 `github.com` 却 200** | ❌ 阻断判据是域名不是 IP |
>
> 所以：`github.com` / `api` / `codeload` 靠探活能稳（都属 A）；
> `raw` / `objects`（B）和 `gist`（C）**换任何 IP、写多少条都没用**。
> 探活对它们的价值只剩「别把死 IP 写进去浪费超时」，失败时保留上游原行兜底。
>
> 这几处只能靠镜像绕过。`git` 侧已由上面的 `insteadOf` 兜住；要直接抓
> `raw` 内容的场景（脚本 `curl`、包管理器、编辑器插件）请自行改走镜像：
>
> ```bash
> # gh-proxy.org 实测最稳（同一 raw 文件 3/3 全 200，直连 0/3）
> curl -fsSL https://gh-proxy.org/https://raw.githubusercontent.com/<owner>/<repo>/<ref>/<path>
> ```


>
> **安全模型（红线）**：root 侧只执行 **root 所有的二进制**（`install` / `tee` /
> `systemctl`），**绝不执行用户可写的插件脚本** —— 插件目录用户可写，提权它等于
> 把「改写本文件」变成 root 执行。刷新器装为 root:root，与插件目录无引用关系
> （测试里有专门断言「runner 未引用插件目录」）。
>
> **输入校验**：抓到的 hosts 内容逐行白名单校验（`IP 主机名`，字段数恰好为 2，
> IP 在合法范围、主机名只含 `[A-Za-z0-9._-]`），任一非法行**整体拒绝**写入。
>
> **接管遗留块**：`/etc/hosts` 里若已有外部工具（maxiaof/github-hosts 等）写的块，
> 写入时会一并清掉。注意 glibc 对同名多行是**全部返回**而非取首个，所以遗留块
> 不会「遮蔽」本插件 —— 但它会把自己的**过期 IP** 混进候选集，且每天追加会让
> 文件无限增长。清掉是为了让候选集只由探活结果决定。

面板底部的 `ghhosts` / `ghtimer` 两个状态位分别表示「hosts 块已写入」和
「每日定时已启用」，装完安装块后两者都会变 1。

### Google 翻译修复（一次性安装，非开关）

把 `translate.googleapis.com` 指到**当前真能返回译文**的 IP，恢复 Chromium /
Chrome 的网页翻译。与上面的 GitHub hosts 加速同构，但完全独立的单元名、独立的
标记块与独立的 timer，两者互不覆盖。

**为什么需要它**：Chrome 系浏览器的网页翻译只调 `translate.googleapis.com`。
该域名在国内被解析到不可用的国外地址（实测 `74.125.x` / `173.194.x` / `192.179.x`
全部 TCP 超时），于是翻译整体失效 —— 表现为点了翻译没反应，或在
`chrome://translate-internals` 里一直 pending。

**网上流传的做法今天已失效**（都是本机实测）：

| 流传说法 | 实测结果 |
| --- | --- |
| 「ping `google.cn` 拿 IP 写进 hosts」 | `113.108.239.x` 整个 /24 **没有一个** IP 带翻译后端 |
| 「用 `120.253.255.98`」 | 对 `/translate_a/*` 一律 404，证书是 `upload.video.google.com`，该 GFE 无翻译后端 |
| 「加一行 hosts 就行」 | 命中节点会漂移：实测同一 IP 十分钟前可用、之后 429/超时 |

真正可用的是少数国家 GFE 节点，且**与 DNS 答案不在同一主机地址**：实测某个
/24 里 DNS 给的 `.95` 是死的，而 `.101/.138/.139/.148` 可用。命中率极低——
扫描 `108.177.0.0/16` 约 2800 个地址只出 9 个（约 0.3%）。

**判据是功能级的，不是连通性的**：绝大多数 IP 对 `translate.googleapis.com`
会回 **200 或 404 但内容是 Google 错误页**（该 GFE 上没有翻译后端）。只看状态码
会把它们当活节点写进 hosts，翻译依旧坏。故探活要求应答**严格等于**那句译文：

```bash
curl -s --resolve translate.googleapis.com:443:<ip> \
  "https://translate.googleapis.com/translate_a/t?client=chrome&sl=en&tl=zh-CN&q=hello"
# 只有恰好返回 ["你好"] 才算活
```

这也是本项目在 GitHub 那边学到的同一条教训（「通」不等于「是它」），只是判据
从响应头指纹换成了真实译文。

**两阶段探活，避免每次刷新都慢**：

1. 快路径 —— 只探**已有线索**（缓存里的上轮命中 + DNS 答案）。常态下它们还活着，
   实测 **2.6 秒**收工。
2. 慢路径 —— 线索凑不够 3 个才展开种子段与线索所在 /24 的全部邻居（约 1200 个
   地址，实测 **100 秒**）。冷启动走这条。

种子段（`108.177.96/98/104/122`、`74.125.20`）是实测扫出来的、反复有节点的
/24；它们会漂移，但缓存里记的是**上一轮真命中**的 IP，其 /24 会自动进入下一轮
候选，于是种子失效也能被自动替换，不必改代码。覆盖方式：`HORIZON_GT_SEED`。

**全灭时不写块**（与 GitHub 那套刻意不同）：GitHub 那边上游快照本身常是好 IP，
留一行兜底有意义；这里兜底只能取 DNS 答案，而 DNS 答案实测就是不可用的
（`173.194.43.95` 连测三次全 DEAD）。写进去的后果是「块存在 ⇒ 状态位为真 ⇒
面板显示已开启」，但翻译依旧坏 —— 那是假绿。所以探活全灭时**保持关闭态并报错**。

安装（一次密码，装完每日 04:20 自动刷新）：

```bash
P=~/.config/omarchy/plugins/horizon.setup/setup.sh
$P gtranslate-install-block > /tmp/gt-install.sh
cat /tmp/gt-install.sh     # 先看一眼
bash /tmp/gt-install.sh
```

命令行等价操作：

```bash
$P status                   # 末尾的 gtranslate= 字段
$P toggle gtranslate        # 开/关
$P update-gtranslate        # 手动刷新一次
```

> **已知天花板**：这套只管 `translate.googleapis.com`。整页翻译时浏览器还会请求
> `translate.google.com`，实测在可用 IP 上该域名能回 200 但**响应不结束**
> （挂到超时），故不在本模块的 hosts 里写它 —— 写了反而拖慢。若将来上游把整页
> 翻译改成必须经该域名，本模块需要跟着调整判据。

### 防火墙（ufw）

面板里直接列出防火墙规则，并可增删。设计要点：

- **读取不需要 root**：`/etc/ufw/user.rules` 与 `user6.rules` 是 `644`，
  直接解析 ufw 自己的 `### tuple ###` 行，呼出面板**不会弹授权框**。
- **写入才提权**：只 `pkexec /usr/bin/ufw …`，且参数全部在无权限侧校验。
  **绝不 pkexec 本插件脚本**——插件目录用户可写，提权它等于把「改写本文件」
  变成 root 执行，这是 Omarchy 自己在 `omarchy-windows-vm` 里明令避免的做法。
- **v4/v6 合并展示**：同一条逻辑规则的 v4/v6 落盘条目在列表里显示为一条，
  带 `[v4+v6]` 标记。
- **外部规则只读**：带接口名的规则（如 ufw-docker 装的 `in_docker0`）灰显，
  不提供删除按钮。
- **删除必须带备注**：见下节。

#### 为什么删除强制要备注

ufw 的删除匹配有两档行为（源码 + 真机 dry-run 双向确认）：

| 命令形态 | 匹配强度 | 风险 |
| --- | --- | --- |
| `delete … comment '<备注>'` | 备注也须相等 | 只删目标那一条 |
| `delete …`（不带备注） | 仅五元组 | **会连带删掉同端口的他人规则** |

实测：对同一端口建两条备注不同的规则，不带备注删除会**两条全删**。
因此本插件：

- `fw-del` 拒绝备注为空的删除；
- 面板对无备注的规则不给删除按钮，并说明原因；
- 新增规则时备注为必填（1–60 字符，不可首尾空白）。

> 删除用的 `action` 取自规则自身（`allow`/`limit`/…）。用 `allow` 去删一条
> `limit` 规则会静默失败——这是 ufw 的行为，插件已按规则自身动作下发。

## 快捷键桥接

`Command` 键输出 `Super`，以下桥接把 `Super+…` 转发为 Linux 侧等价键。
**共 21 组 Cmd 类桥接** = 文本编辑 10 组（`bridge()` 9 条 + `Cmd+A` 全选）
+ 应用操作 11 组（`bridge_app()` 10 条 + `Cmd+Q` 关窗）；另加 3 条音量键与
1 条截图键——**全部随「Mac 快捷键」这一个开关走**，关掉一起消失。
数法可复现：在 `lib/macos.sh` 的 `mac_write_textedit_bindings()` 块内数
`^bridge(`（9）+ `^bridge_app(`（10）+ `^o\.bind(` 直接绑（1，`SUPER+Q`），
再加 `mac_write_selectall_binding()` 里的 `SUPER+A`（1）。

**文本编辑（P0）**

| Mac | → Linux | 语义 |
| --- | --- | --- |
| `Cmd+←/→` | `Home` / `End` | 行首 / 行尾 |
| `Cmd+Shift+←/→` | `Shift+Home` / `Shift+End` | 选到行首 / 行尾 |
| `Cmd+↑/↓` | `Ctrl+Home` / `Ctrl+End` | 文档首 / 尾 |
| `Cmd+Backspace` | `Ctrl+U` | 删到行首 |
| `Cmd+Delete` | `Ctrl+K` | 删到行尾（与上行成对） |
| `Cmd+/` | `Ctrl+/` | **注释 / 取消注释**（编辑器与 IDE 通用） |
| `Cmd+A` | `Ctrl+A` | 全选 |

**应用操作（P1）**

| Mac | → Linux | 语义 |
| --- | --- | --- |
| `Cmd+W` | `Ctrl+W` | **关闭标签页/文档**（浏览器关标签、编辑器关文件） |
| `Cmd+Q` | **关闭窗口** | WM 动作（`window.close`），与焦点应用无关；终端里同样成立 |
| `Cmd+R` | `Ctrl+R` | **重新加载/刷新**（浏览器、编辑器、IM 通用） |
| `Cmd+Shift+T` | `Ctrl+Shift+T` | **恢复刚关闭的标签页/页面**（等价于原来的 `Ctrl+Shift+T`） |
| `Cmd+Shift+V` | `Ctrl+Shift+V` | **纯文本粘贴**（去掉格式） |
| `Cmd+N / S / O / F` | `Ctrl+N / S / O / F` | 新建 / 保存 / 打开 / 查找 |
| `Cmd+Z` | `Ctrl+Z` | 撤销 |
| `Cmd+Shift+Z` | `Ctrl+Shift+Z` | 重做 |
| `Cmd+Shift+X` | **截图并标注** | 呼出 `omasnap`（Omarchy 的截图就是它） |

> **`Cmd+Shift+X` 是本插件自选的组合，不是 macOS 原生键**。macOS 的系统截图是
> `Cmd+Shift+3/4/5`，但那三个数字键被 Omarchy 的「移动窗口到工作区 N」占着
> （`tiling.lua:22-24`），抢过来会换掉一个常用窗口动作，故改选空闲的
> `Super+Shift+X`——它接管了 Omarchy 预装的 `Super+Shift+X`（打开 x.com），
> `Super+Shift+Alt+X`（发帖）不受影响。落地就是 [Omasnap](#截图omasnap) 的
> 标注/滚动拼接/OCR：**Omarchy 0.4.5 默认就装 omasnap，`omarchy-capture-screenshot`
> 现在本身就是 `exec omasnap`**（`bin/omarchy-capture-screenshot:27`）——旧那套
> grim/slurp/tensaku 已被 `migrations/1788129995.sh` 取代。所以这个键不会
> 出现「按了没反应」。

**音量三键（Mac 顶排语义）**

| 快捷键 | 语义 |
| --- | --- |
| `Super+F10` | **静音开关**（`mute-toggle`） |
| `Super+F11` | **音量减**（长按连续调） |
| `Super+F12` | **音量增**（长按连续调） |

> 动作复用 Omarchy 自带的音量命令（与 `XF86Audio*` 媒体键同源，带 OSD 反馈），
> 锁屏下同样可用。三个组合在 Omarchy 默认绑定里原本是空的，属**纯新增**；
> 随「Mac 快捷键」开关走：关 = 媒体块被删，绑定随之消失。

> **`Cmd+W` 与 `Cmd+Q` 的分工**（对应 macOS 语义）：
> `Cmd+W` 关**标签页/文档**，发 `Ctrl+W` 给应用；`Cmd+Q` 关**窗口/退出应用**，
> 走 WM 的 `window.close()`。二者不可互换——把 `Cmd+W` 绑成 WM 关窗会变成
> 「关标签却杀掉整个应用」。
>
> **终端分流**：终端里 `Ctrl+W`=删词、`Ctrl+S`=XOFF 冻结、`Ctrl+R`=反查历史
> （reverse-i-search，macOS 同样是 Ctrl+R）——三者与各自的 Mac 语义冲突或更有价值，
> 终端焦点时 `W`/`S`/`R` 不桥接，保留终端原生行为。
> `Cmd+Q` 是 WM 动作，不参与分流。`Cmd+Shift+T` 也不分流——终端里
> `Ctrl+Shift+T` 本就是「新建标签页」，与浏览器里「恢复关闭的页面」同属
> 应用自身的标签语义，原样透传即可。
>
> **接管了 Omarchy 原生的 `Super+W`（关窗）**：为符合 Mac 习惯，`Super+W`
> 被改绑为关标签。平铺 WM 下关整窗请用 `Cmd+Q`。本开关关闭时该原生绑定
> 随 `hyprctl reload` 自动恢复。
>
> **接管了 Omarchy 原生的 `Super+/`（显示器缩放放大）**：macOS 的 `Cmd+/`
> 是注释，故该组合改发 `Ctrl+/`。缩放**缩小**仍在 `Super+Alt+/`，放大可改用
> 菜单里的显示器面板调整。关闭本开关时 `Super+/` 恢复为缩放。
>
> **天花板**：`Option+←/→` 的按词移动无法在 Hyprland 层统一做（Chrome 的
> `Alt+←` 是后退，桥接会打架），升级路径是 per-app 配置，当前不做。
>
> 同理 `Cmd+[` / `Cmd+]`（后退 / 前进）需要向应用注入 `Alt+←/→`，而
> `send_key_state` 的 `mods` 只验证过 `CTRL` 与 `CTRL+SHIFT`（Omarchy 自身的
> 唯一先例），`ALT` 未证实——故本轮不绑，验证后再加。
>
> 被接管的组合（如 `Super+F` 全宽、`Super+S` scratchpad）随本开关走：
> 开 = 桥接，关 = Omarchy 默认绑定随 `hyprctl reload` 自动恢复。
>
> **升级老配置**：绑定块写进 `~/.config/hypr/bindings.lua` 后不会再自动更新，
> 所以块里带版本戳（`-- horizon.setup:textedit-key-rev N`）。往块里加/删桥接
> 就提这个版本号；老用户的块版本对不上 ⇒ 开关判定为「关」，面板点一次即整块
> 重建，新桥接才真正到手。只改块内容却不提版本号，老用户永远拿不到。

## 插件汉化

面板「插件汉化」Tab 里有两层，机制完全不同，所以分开说：

| 层 | 目标 | 做法 |
| --- | --- | --- |
| **映射表组** | `evindor.keystroke`、`stappmus.activity-monitor` | 改插件源码里的显示文案字面量 |
| **Omasnap** | `omacom/omasnap` | 改 C++ 源码 + 重新编译 |

> **为什么还要自己汉化第三方插件**：Omarchy 0.4.5 的 i18n 只覆盖**第一方 shell**
> （`/usr/share/omarchy/default/i18n/<code>/{shell,menu,keybindings,cli}.json`）。
> 第三方插件不在其列：`evindor.keystroke` 与 `stappmus.activity-monitor` 上游
> 零 i18n 设施（无 `.ts/.qm`、无 `tr()`），中文只能改源码。本插件自带映射表，
> **fail-closed**——任何一条失配就整体拒绝，绝不半应用；上游更新把英文带回来，
> 重新点一次即可。

Omarchy 自身的界面语言不用本插件管：**菜单 → 设置 → 语言**（详见
[下面那节](#omarchy-界面中文已自带无需装)）。

### 映射表组（keystroke / activity-monitor）

只改界面文案：命令触发词、示例命令、存档枚举值、关键词与标识符一律保持原样，
功能零变化。

- **资产随插件分发**：映射表在 `lib/zh-maps/*.json`（精确片段 + 期望次数），
  应用器 `lib/apply-zh.py` 幂等执行（`check` / `apply` / `revert`）。
  **不读** `~/.local/share/omarchy-zh-cn/` —— 那是旧的第三方项目，与本插件无关。
- **检测即真相**：状态每次实读映射表与插件源码——`未汉化 / 已汉化 / 已失配`。
  上游 `git pull` 把英文带回来即转「未汉化」，重新点汉化即可；
  上游改动了文案字面量则转「已失配」，此时按钮禁用、先更新映射表。
- **免授权**：写的是插件目录（用户自己的文件），不碰系统配置。

### Omasnap 界面汉化（需编译）

给 [Omasnap](#截图omasnap) 截图器换中文界面。**改源码 + 重新编译**，约 1 分钟，
不要 root，也不碰系统配置。

> **为什么不能像普通插件那样改文案文件**：Omasnap 上游没有任何 i18n 设施 ——
> 0 处 `tr()`、无 `.ts/.qm` 文件，383 条 UI 文案全是硬编码的 C++ 字符串字面量。
> 所以汉化只能是**改源码 + 重新编译**。

这一层做的事：下载固定 tag 的源码 → 用 `lib/omasnap-zh.json` 词表按**词法位置**
替换 → `cmake` 编译 → 装到 `~/.local`。

设计要点：

- **词表按字面量整串替换，不打 patch**：patch 的行号一碰上游更新就废，而且
  多行拼接的 C++ 字面量（`"…" "…"`）会被 reflow 打断。词表按词法位置把相邻
  字面量拼成一个逻辑串再替换，上游怎样折行都不影响。
- **fail-closed**：任何一条词表没命中（上游改了该文案）就**整条中止**，绝不
  编出一个半汉化的程序。`stale` 状态就是这么来的——pin 的上游版本变了。
- **不改二进制、不要 root**：汉化版与上游原版都放在 `~/.local/libexec/omasnap/`，
  `~/.local/bin/omasnap` 是启动器，用软链切换。缺的系统库
  （`libLayerShellQtInterface.so.6`）由启动器注入路径，两个版本共用。
- **翻译边界**：只译「显示用」的字面量。三类明确不译——参与逻辑比较的
  （`"Screen capture failed:"` 是 `startsWith` 的判据）、协议/键值
  （`"ShowItems"` 是 D-Bus 方法）、路径与字体名（`"Screenshots"` 是目录名）。
  上游把显示名（`backgroundName`）与序列化名（`backgroundStyleName`）分成
  两套函数，正是这条边界成立的前提。
- **编译依赖**：`cmake` `ninja` `g++` `wayland-scanner` 与 `layer-shell-qt` 的
  开发文件。没有 root 时，把 Arch 官方 `layer-shell-qt` 包的
  `include/LayerShellQt/`（**含无扩展名的 `Window`/`Shell` 转发头**，漏了这两个
  就会 `fatal error: LayerShellQt/Window: No such file`）与
  `lib/cmake/LayerShellQt/` 放到 `~/.local` 即可，构建会自动找到。

### 命令

```bash
P=~/.config/omarchy/plugins/horizon.setup/setup.sh
$P zhcn                                  # 两层状态（TAB 分隔；映射表组 id 在首列）
$P zhcn-apply keystroke                  # 应用 keystroke 的汉化
$P zhcn-apply activity-monitor           # 应用活动监视器的汉化
$P zhcn-revert keystroke                 # 还原英文
$P omasnap-zh                            # Omasnap 状态：missing / stock / zh / stale
$P omasnap-zh-install                    # 编译安装汉化版
$P omasnap-zh-revert                     # 装回上游原版（汉化版保留，再开不必重编）
```

## 配套推荐

本插件只负责「输入习惯 / 工具链 / 防火墙 / 插件汉化」。下面几个项目补齐
**中文输入**与**截图体验**，都是实测在用的：

| 项目 | 说明 | Star |
| --- | --- | --- |
| [iDvel/rime-ice](https://github.com/iDvel/rime-ice) | **雾凇拼音** — 长期维护的简体词库，中文输入的首选方案。装完即可打字，`F4` 切换方案与开关功能 | 19.7k |
| [omacom/omasnap](https://github.com/omacom/omasnap) | **Omasnap** — Omarchy 原生截图+标注一体（layer-shell 覆盖层）：智能选区、滚动拼接、OCR、贴图预览，MIT | 571 |

### 截图：Omasnap

Linux 上没有 macshot（那是个 macOS 应用）。功能最接近的是 **Omasnap**：
Omarchy 作者维护的原生 Wayland 截图器，MIT 许可、C++/Qt6 + layer-shell。

Omarchy 0.4.5 已经用它替换了旧的 grim+slurp+tensaku（`migrations/1788129995.sh`
里 `omarchy-pkg-drop satty tensaku`），所以它**就是** Omarchy 现在的截图流程，
不再是二选一。与 macOS macshot 相比，差的正是那部分**截完之后的流**：

| 能力 | Omasnap | Omarchy 0.4.5 之前（tensaku，已移除） |
| --- | --- | --- |
| 智能选区（拖=区域 / 点=窗口 / 点空白=整屏） | ✅ 同一浮层里 | 分三个命令 |
| 截完自动复制 + 10 秒浮动预览（可钉住、可拖进别的应用） | ✅ | ❌ 只有通知 |
| 滚动长截图 | ✅ 手动/自动滚动拼接 | 仅 `--scroll-capture`（要手拼） |
| OCR | ✅ 整图或框选 | 独立命令 `omarchy-capture-text` |
| 标注（箭头/形状/文字/马赛克/高光/序号） | ✅ 矢量图层，可改可移 | ✅ 更细（16 种工具、图层） |
| 美化（渐变底/阴影/圆角） | ✅ | ❌ |
| 录屏 | ❌ 用 `omarchy screenrecord` | ❌ 用同一个 |
| 界面汉化 | ✅ 面板一键（改源码重编译） | ❌ 上游无 i18n |

**Omarchy 已自带，无需 AUR**：`omasnap` 就在 Omarchy 官方仓库里
（`pacman -Si omasnap` → `Repository: omarchy`），Omarchy 0.4.5 起默认装好，
`omarchy-capture-screenshot` 本身就是它（见下）。只差中文 OCR 的话补一个词库：

```bash
sudo pacman -S tesseract-data-chi_sim   # 需要中文 OCR 才装
```

> 万一被卸掉了，装回来也只有一条：`sudo pacman -S omasnap`
> （依赖 `hyprland layer-shell-qt qt6-base tesseract wayland wl-clipboard`
> 由 pacman 一次带齐，不用 AUR）。

> **保存位置**：设 `OMARCHY_SCREENSHOT_DIR` 即可，Omarchy 会替你转译成
> omasnap 认识的 `OMASNAP_SCREENSHOT_DIR`（`bin/omarchy-capture-screenshot:9-10`
> 就是这么写的），**不用**改 `~/.config/omasnap/omasnap.conf`。
> 没设时 omasnap 默认存 `~/Pictures/Screenshots`。

装完按 `Super+Shift+X` 即可用——本插件的 Mac 快捷键开关会**自动检测**：
`omasnap` 在 `PATH` 里就直接调它，否则调 `omarchy-capture-screenshot`——而那
命令现在转手也是 `exec omasnap`，两条路落到同一个程序。

> **已知天花板**：omasnap 用 `hyprctl` 做显示器/窗口发现，只在 Hyprland 上成立；
> 它的更新比 Omarchy 本体快（一周两版），面板不跟踪它的版本——升级跟系统走
> （`omarchy update` 或 `sudo pacman -Syu`）。`Print` 键仍是 Omarchy 默认的
> 截图入口（`default/hypr/bindings/utilities.lua:40`），与本插件的 `Cmd+Shift+X`
> 互不干扰——两个键落到同一个 omasnap。

### 雾凇拼音（rime-ice）

先装输入法引擎，再装词库：

```bash
# 1) 引擎（Arch/Omarchy）
sudo pacman -S fcitx5-rime        # 连带 librime + librime-data

# 2a) 方式 A：图形安装（最简单）
#     下载 full.zip → 清空 rime 用户目录 → 解压进去 → 重新部署
#     大陆镜像（GitHub 直连慢时）：
#     https://mirror.nju.edu.cn/github-release/iDvel/rime-ice/LatestRelease/full.zip

# 2b) 方式 B：命令行（plum，自动打补丁，可选双拼/语法模型）
cd ~ && git clone https://github.com/rime/plum.git plum && cd ~/plum
rime_dir="$HOME/.local/share/fcitx5/rime" bash rime-install iDvel/rime-ice

# 3) 重新部署（改完配置必跑）
cd "$HOME/.local/share/fcitx5/rime" && rime_deployer --build .
```

> ⚠️ **`rime_dir` 必须显式指定**：fcitx5 的 rime 用户目录在
> `~/.local/share/fcitx5/rime`，而 rime-ice 官方示例写的是
> `~/.config/fcitx5/rime`（iBus / Weasel 那套路径）—— 在 **fcitx5 + Arch**
> 上照抄会装进一个不存在的目录，然后「装了但打不出字」。

### Omarchy 界面中文（已自带，无需装）

Omarchy 0.4.5 起**自带多语言**（`/usr/share/omarchy/default/i18n/<code>/`），
菜单、通知、快捷键面板、CLI 都在内，不再需要第三方汉化项目（`omarchy-zh-cn`
那套已作废）。切换：**菜单 → 设置 → 语言**（底层是 `omarchy-language <code>`，
选择存在 `~/.config/omarchy/language`）。

这一层**不由本插件代劳**；本插件只管**第三方插件**的文案（见[插件汉化](#插件汉化)）。

## 工作原理

代码分层，每层只负责一类配置：

| 文件 | 职责 |
| --- | --- |
| `setup.sh` | 命令入口与状态汇总，只做调度 |
| `lib/macos.sh` | 快捷键、自然滚动、剪贴板（读 `hyprctl` / `bindings.lua`） |
| `lib/devtools.sh` | npm registry、git `insteadOf` |
| `lib/firewall.sh` | ufw 规则的解析、校验、增删 |
| `lib/zhcn.sh` | 映射表组的状态检测与重放（keystroke / activity-monitor） |
| `lib/apply-zh.py` | 映射表应用器：`check` / `apply` / `revert`，失配整体拒绝 |
| `lib/zh-maps/*.json` | 映射表资产：精确片段 + 期望次数 + group 归属（随插件分发） |
| `lib/omasnapzh.sh` | Omasnap 汉化：状态检测、改源码重编译、装回上游原版 |
| `Panel.qml` | overlay 容器、Tab 栏、状态徽章 |
| `ToggleList.qml` | 一组开关的展示壳 |
| `FirewallTab.qml` | 防火墙 Tab（表单 + 规则列表） |
| `ZhcnTab.qml` | 插件汉化 Tab（两层列表 + 应用/还原） |
| `RuleList.qml` | 规则列表展示（纯展示，不自带滚动） |

- **检测即真相**：不维护任何状态文件，状态全部从系统/配置实读
  （`hyprctl getoption`、标记块、`~/.npmrc`、`git config`、`/etc/ufw/user*.rules`）。
- **幂等写入**：每个开关写带 `-- horizon.setup:xxx` 标记的块，重复 toggle
  只翻转块的存在性，不产生重复条目。
- **凭据安全**：提权只针对 root 所有的 `/usr/bin/ufw`，插件自身永不提权；
  所有参数（端口/协议/来源/备注）在无权限侧按白名单校验后才下发。

## 开发

```bash
bash tests/firewall_test.sh     # 防火墙层，用 fixture + 桩件，不碰真机
bash tests/hosts_test.sh        # GitHub hosts 层
bash tests/gtranslate_test.sh   # Google 翻译 hosts 层
bash tests/zhcn_test.sh         # 插件汉化映射表组（幂等、fail-closed、分组聚合）
bash tests/omasnap_zh_test.sh   # Omasnap 汉化层（词表 fail-closed、状态四态）
```

`tests/fixtures/` 是真实机器规则的快照；`tests/fake/` 是 `pkexec`/`ufw` 桩件，
因此测试**不触发任何授权框、不修改真实防火墙**。`hosts_test.sh` 与
`gtranslate_test.sh` 同理：`curl`/`getent` 全部用桩件接管，
**不联网、不写真实 `/etc/hosts`、不跑安装块**。`zhcn_test.sh` 用临时 fixture
映射表与假插件目录，不碰真实插件、也不读 `~/.local/share/omarchy-zh-cn/`。
`omasnap_zh_test.sh` 也不编译（真编译靠人跑一次），只验证词法的拼接与
fail-closed、以及状态四态。

改 `Panel.qml` 等 QML 后 quickshell 会自动重载本地插件；若没生效：

```bash
omarchy-restart-shell
```

## 卸载

```bash
# 1. 先关掉所有开关（恢复默认绑定/配置）
P=~/.config/omarchy/plugins/horizon.setup/setup.sh
for t in keys scroll clip npm ghproxy; do $P toggle $t; done
$P toggle gtranslate      # 需要已安装才能关；未安装时它只报错、不动 hosts
# 防火墙规则请先在面板里逐条删除（或 $P fw-del …）

# 2. hosts 的两套 root 安装物（如果装过）需要手动清掉
sudo systemctl disable --now horizon-setup-hosts.timer horizon-setup-gtranslate.timer
sudo rm -f /usr/local/bin/horizon-setup-hosts-refresh \
           /usr/local/bin/horizon-setup-gtranslate-refresh \
           /etc/systemd/system/horizon-setup-hosts@.service \
           /etc/systemd/system/horizon-setup-hosts.timer \
           /etc/systemd/system/horizon-setup-gtranslate@.service \
           /etc/systemd/system/horizon-setup-gtranslate.timer \
           /etc/polkit-1/rules.d/99-horizon-setup-hosts.rules \
           /etc/polkit-1/rules.d/99-horizon-setup-gtranslate.rules
sudo rm -rf /var/lib/horizon-setup
sudo systemctl daemon-reload

# 3. 若装过 Omasnap 汉化：先还原上游原版，再清编译缓存
$P omasnap-zh-revert
rm -rf ~/.local/share/omasnap-zh

# 3b. 若这台机器从 1.3.x 升上来（装过 omarchy-zh-cn）：跑一次迁移脚本。
#     它清 8 类残留：shell.json 的 carvin.* 挂件、plugins/carvin.*、旧映射表目录、
#     旧中文菜单副本（精简为只留用户自加条目，面板入口 setup.horizon 保住）、
#     bindings.lua 的 zh 块（SUPER+K 回原生）、三个 omarchy-zh-* 脚本、
#     post-update hook、~/.local/state/omarchy-zh。改文件前都先备份。
M=~/.config/omarchy/plugins/horizon.setup/lib/migrate-drop-omarchy-zh-cn.sh
bash "$M" --dry-run   # 先看它要删什么
bash "$M"

# 4. 先注销插件登记（否则 shell.json 里留着指向已删目录的引用）
omarchy plugin disable horizon.setup
# 顺带撤掉菜单入口：从 ~/.config/omarchy/extensions/omarchy-menu.jsonc 里
# 删掉 "setup.horizon" 那一条（或整份文件，若里面只剩这一条）
omarchy plugin list | grep horizon        # 应无输出

# 5. 移除插件并重启 shell
rm -rf ~/.config/omarchy/plugins/horizon.setup
omarchy-restart-shell
```

## License

[MIT](LICENSE)
