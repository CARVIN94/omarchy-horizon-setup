<h1 align="center">Horizon Setup</h1>

<p align="center">Omarchy 的输入习惯、工具链、防火墙与插件汉化配置面板</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-10b981?style=flat-square" alt="MIT license"></a>
  <a href="https://github.com/Hyprwm/Hyprland"><img src="https://img.shields.io/badge/WM-Hyprland-89b4fa?style=flat-square" alt="Hyprland"></a>
  <a href="https://omarchy.com"><img src="https://img.shields.io/badge/OS-Omarchy-f38ba8?style=flat-square" alt="Omarchy"></a>
  <a href="#快捷键桥接"><img src="https://img.shields.io/badge/Cmd-17%20%E7%BB%84%E6%A1%A5%E6%8E%A5-10b981?style=flat-square" alt="Cmd bridges"></a>
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

需要 **Omarchy（Hyprland + Quickshell）**。克隆到插件目录即可：

```bash
git clone https://github.com/CARVIN94/omarchy-horizon-setup.git \
  ~/.config/omarchy/plugins/horizon.setup
```

然后重启 Omarchy shell：

```bash
omarchy-restart-shell
```

打开 **菜单 → 设置 → Horizon Setup**；点开即是面板。

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
| **开发环境** | npm 换源、GitHub 加速 | 包管理与网络。 |
| **防火墙** | ufw 规则列表 + 增删 | 读写分离：读免权限，写走一次授权。 |
| **插件汉化** | 第三方插件中文文案的汉化/还原 | 只改界面文案，写插件目录，免授权。 |

头部显示 `已启用/总数` 胶囊徽章；底部在写配置时显示进行中。

### GitHub 代理（git fetch 镜像）

面板开关只做一件事：`git config url.insteadOf` 把 `github.com` 改写到 `gh-proxy.org`。
免密、即时、必成 —— **开关的成败只由它决定**。push 仍直连 GitHub（镜像是只读的）。

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

`Command` 键输出 `Super`，以下桥接把 `Super+…` 转发为 Linux 侧等价键：

**文本编辑（P0）**

| Mac | → Linux | 语义 |
| --- | --- | --- |
| `Cmd+←/→` | `Home` / `End` | 行首 / 行尾 |
| `Cmd+Shift+←/→` | `Shift+Home` / `Shift+End` | 选到行首 / 行尾 |
| `Cmd+↑/↓` | `Ctrl+Home` / `Ctrl+End` | 文档首 / 尾 |
| `Cmd+Backspace` | `Ctrl+U` | 删到行首 |
| `Cmd+A` | `Ctrl+A` | 全选 |

**应用操作（P1）**

| Mac | → Linux | 语义 |
| --- | --- | --- |
| `Cmd+W` | `Ctrl+W` | **关闭标签页/文档**（浏览器关标签、编辑器关文件） |
| `Cmd+Q` | **关闭窗口** | WM 动作（`window.close`），与焦点应用无关；终端里同样成立 |
| `Cmd+R` | `Ctrl+R` | **重新加载/刷新**（浏览器、编辑器、IM 通用） |
| `Cmd+N / S / O / F` | `Ctrl+N / S / O / F` | 新建 / 保存 / 打开 / 查找 |
| `Cmd+Z` | `Ctrl+Z` | 撤销 |
| `Cmd+Shift+Z` | `Ctrl+Shift+Z` | 重做 |

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
> `Cmd+Q` 是 WM 动作，不参与分流。
>
> **接管了 Omarchy 原生的 `Super+W`（关窗）**：为符合 Mac 习惯，`Super+W`
> 被改绑为关标签。平铺 WM 下关整窗请用 `Cmd+Q`。本开关关闭时该原生绑定
> 随 `hyprctl reload` 自动恢复。
>
> **天花板**：`Option+←/→` 的按词移动无法在 Hyprland 层统一做（Chrome 的
> `Alt+←` 是后退，桥接会打架），升级路径是 per-app 配置，当前不做。
>
> 被接管的组合（如 `Super+F` 全宽、`Super+S` scratchpad）随本开关走：
> 开 = 桥接，关 = Omarchy 默认绑定随 `hyprctl reload` 自动恢复。

## 插件汉化

给第三方 Omarchy 插件（如 `evindor.keystroke`、`stappmus.activity-monitor`）
的**显示文案**一键汉化。只改界面文案：命令触发词、示例命令、存档枚举值、
关键词与标识符一律保持原样，功能零变化。

- **映射表驱动**：文案以「精确片段 + 期望次数」存放在
  `~/.local/share/omarchy-zh-cn/maps/*.json`，应用器
  `~/.local/share/omarchy-zh-cn/apply-zh.py` 幂等执行；
  任何一条失配则**整体拒绝**，绝不半应用。
- **检测即真相**：状态每次实读映射表与插件源码——`未汉化 / 已汉化 / 已失配`。
  上游 `git pull` 把英文带回来即转「未汉化」，重新点汉化即可；
  上游改动了文案字面量则转「已失配」，此时按钮禁用、先更新映射表。
- **免授权**：写的是插件目录（用户自己的文件），不碰系统配置。

命令行等价操作（映射表 id 见 `$P zhcn` 首列）：

```bash
P=~/.config/omarchy/plugins/horizon.setup/setup.sh
$P zhcn                                  # 各映射表状态（TAB 分隔）
$P zhcn-apply stappmus.activity-monitor  # 应用汉化
$P zhcn-revert stappmus.activity-monitor # 还原英文
```

## 配套推荐

本插件只负责「输入习惯 / 工具链 / 防火墙 / 插件汉化」。下面两个项目补齐
**中文体验**，都是实测在用的：

| 项目 | 说明 | Star |
| --- | --- | --- |
| [iDvel/rime-ice](https://github.com/iDvel/rime-ice) | **雾凇拼音** — 长期维护的简体词库，中文输入的首选方案。装完即可打字，`F4` 切换方案与开关功能 | 19.7k |
| [QueedWen/omarchy-zh-cn](https://github.com/QueedWen/omarchy-zh-cn) | **Omarchy 简体中文界面** — 菜单、通知、天气、快捷键面板中文化，与本插件的中文面板互补 | 31 |

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

### Omarchy 简体中文界面（omarchy-zh-cn）

```bash
git clone https://github.com/QueedWen/omarchy-zh-cn.git
cd omarchy-zh-cn
./install.sh --dry-run      # 先预览，看它会改哪些文件
./install.sh                # 正式安装
omarchy-zh-sync             # 之后与 Omarchy 更新同步
./uninstall.sh              # 卸载
```

它从**本机已安装的 Omarchy 源文件**生成**用户级插件克隆**，不改动
`/usr/share/omarchy`，也不在仓库里重新分发 Omarchy 的源码 —— 卸载干净、
上游升级不冲突。

## 工作原理

代码分层，每层只负责一类配置：

| 文件 | 职责 |
| --- | --- |
| `setup.sh` | 命令入口与状态汇总，只做调度 |
| `lib/macos.sh` | 快捷键、自然滚动、剪贴板（读 `hyprctl` / `bindings.lua`） |
| `lib/devtools.sh` | npm registry、git `insteadOf` |
| `lib/firewall.sh` | ufw 规则的解析、校验、增删 |
| `lib/zhcn.sh` | 插件汉化映射表的状态检测与重放（调 `apply-zh.py`） |
| `Panel.qml` | overlay 容器、Tab 栏、状态徽章 |
| `ToggleList.qml` | 一组开关的展示壳 |
| `FirewallTab.qml` | 防火墙 Tab（表单 + 规则列表） |
| `ZhcnTab.qml` | 插件汉化 Tab（映射表列表 + 应用/还原） |
| `RuleList.qml` | 规则列表展示（纯展示，不自带滚动） |

- **检测即真相**：不维护任何状态文件，状态全部从系统/配置实读
  （`hyprctl getoption`、标记块、`~/.npmrc`、`git config`、`/etc/ufw/user*.rules`）。
- **幂等写入**：每个开关写带 `-- horizon.setup:xxx` 标记的块，重复 toggle
  只翻转块的存在性，不产生重复条目。
- **凭据安全**：提权只针对 root 所有的 `/usr/bin/ufw`，插件自身永不提权；
  所有参数（端口/协议/来源/备注）在无权限侧按白名单校验后才下发。

## 开发

```bash
bash tests/firewall_test.sh    # 防火墙层 82 项断言，用 fixture + 桩件，不碰真机
```

`tests/fixtures/` 是真实机器规则的快照；`tests/fake/` 是 `pkexec`/`ufw` 桩件，
因此测试**不触发任何授权框、不修改真实防火墙**。

改 `Panel.qml` 等 QML 后 quickshell 会自动重载本地插件；若没生效：

```bash
omarchy-restart-shell
```

## 卸载

```bash
# 1. 先关掉所有开关（恢复默认绑定/配置）
P=~/.config/omarchy/plugins/horizon.setup/setup.sh
for t in keys scroll clip npm ghproxy; do $P toggle $t; done
# 防火墙规则请先在面板里逐条删除（或 $P fw-del …）

# 2. 移除插件并重启 shell
rm -rf ~/.config/omarchy/plugins/horizon.setup
omarchy-restart-shell
```

## License

[MIT](LICENSE)
