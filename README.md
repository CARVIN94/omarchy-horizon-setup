<h1 align="center">Horizon Setup</h1>

<p align="center">Omarchy 的输入习惯、工具链与防火墙配置面板</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-10b981?style=flat-square" alt="MIT license"></a>
  <a href="https://github.com/Hyprwm/Hyprland"><img src="https://img.shields.io/badge/WM-Hyprland-89b4fa?style=flat-square" alt="Hyprland"></a>
  <a href="https://omarchy.com"><img src="https://img.shields.io/badge/OS-Omarchy-f38ba8?style=flat-square" alt="Omarchy"></a>
  <a href="#快捷键桥接"><img src="https://img.shields.io/badge/Cmd-15%20%E7%BB%84%E6%A1%A5%E6%8E%A5-10b981?style=flat-square" alt="Cmd bridges"></a>
</p>

<p align="center">
  <a href="#快速安装">安装</a> ·
  <a href="#面板">面板</a> ·
  <a href="#快捷键桥接">快捷键桥接</a> ·
  <a href="#防火墙ufw">防火墙</a> ·
  <a href="#工作原理">原理</a> ·
  <a href="#开发">开发</a> ·
  <a href="#卸载">卸载</a>
</p>

把输入习惯调成 Mac 手感，并顺手管好包管理、网络代理与 **ufw 防火墙** 的一键面板。
所有开关**可检测、可切换、幂等**——不用再猜「刚才那条命令到底生效没」。

面板是 Omarchy overlay，入口在 **菜单 → 设置**，不占顶栏；内部按用途分三个 Tab。

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
三个 Tab 按「这块配置属于谁」分组：

| Tab | 内容 | 说明 |
| --- | --- | --- |
| **Mac 习惯** | Mac 快捷键、自然滚动、剪贴板快捷键 | 键位、滚动与剪贴板。 |
| **开发环境** | npm 换源、GitHub 代理 | 包管理与网络。 |
| **防火墙** | ufw 规则列表 + 增删 | 读写分离：读免权限，写走一次授权。 |

头部显示 `已启用/总数` 胶囊徽章；底部在写配置时显示进行中。

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
| `Cmd+Q` | **关闭窗口** | WM 动作（`window.close`），与焦点应用无关；终端里同样关窗 |
| `Cmd+N / S / O / F` | `Ctrl+N / S / O / F` | 新建 / 保存 / 打开 / 查找 |
| `Cmd+Z` | `Ctrl+Z` | 撤销 |
| `Cmd+Shift+Z` | `Ctrl+Shift+Z` | 重做 |

> **终端分流**：终端里 `Ctrl+S` 是 XOFF 冻结，与保存语义冲突——终端焦点时
> `S` 不桥接，保留终端原生行为。`Cmd+Q` 是 WM 关窗动作，不参与分流。
>
> **`Super+W` 保持 Omarchy 原生**：它本来就是「关闭窗口」，本插件不再接管它
> （早期版本把它 unbind 成发 `Ctrl+W`，反而弄坏了原生关窗）。
>
> **天花板**：`Option+←/→` 的按词移动无法在 Hyprland 层统一做（Chrome 的
> `Alt+←` 是后退，桥接会打架），升级路径是 per-app 配置，当前不做。
>
> 被接管的组合（如 `Super+F` 全宽、`Super+S` scratchpad）随本开关走：
> 开 = 桥接，关 = Omarchy 默认绑定随 `hyprctl reload` 自动恢复。

## 工作原理

代码分层，每层只负责一类配置：

| 文件 | 职责 |
| --- | --- |
| `setup.sh` | 命令入口与状态汇总，只做调度 |
| `lib/macos.sh` | 快捷键、自然滚动、剪贴板（读 `hyprctl` / `bindings.lua`） |
| `lib/devtools.sh` | npm registry、git `insteadOf` |
| `lib/firewall.sh` | ufw 规则的解析、校验、增删 |
| `Panel.qml` | overlay 容器、Tab 栏、状态徽章 |
| `ToggleList.qml` | 一组开关的展示壳 |
| `FirewallTab.qml` | 防火墙 Tab（表单 + 规则列表） |
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
