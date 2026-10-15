<h1 align="center">horizon.setup</h1>

<p align="center">Omarchy 的 Mac 习惯配置面板</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-10b981?style=flat-square" alt="MIT license"></a>
  <a href="https://github.com/Hyprwm/Hyprland"><img src="https://img.shields.io/badge/WM-Hyprland-89b4fa?style=flat-square" alt="Hyprland"></a>
  <a href="https://omarchy.com"><img src="https://img.shields.io/badge/OS-Omarchy-f38ba8?style=flat-square" alt="Omarchy"></a>
  <a href="#快捷键桥接"><img src="https://img.shields.io/badge/Cmd-16%20%E7%BB%84%E6%A1%A5%E6%8E%A5-10b981?style=flat-square" alt="Cmd bridges"></a>
</p>

<p align="center">
  <a href="#快速安装">安装</a> ·
  <a href="#它解决什么问题">功能</a> ·
  <a href="#快捷键桥接">快捷键桥接</a> ·
  <a href="#面板">面板</a> ·
  <a href="#工作原理">原理</a> ·
  <a href="#卸载">卸载</a>
</p>

把 Mac 的肌肉记忆搬到 Omarchy 上的**一键开关面板**：`Cmd` 键直接输出标准 Linux
`Ctrl` 语义（复制粘贴全选即用），在此之上桥接 16 组 Mac 快捷键（行首行尾、
保存、查找、撤销……），外加自然滚动、剪贴板快捷键、npm 国内源、GitHub 代理。
所有开关**可检测、可切换、幂等**——不用再猜「刚才那条命令到底生效没」。

面板是 Omarchy overlay，入口在 **菜单 → 设置**，不占顶栏。

## 快速安装

需要 **Omarchy（Hyprland + Quickshell）**。克隆到插件目录即可：

```bash
git clone https://github.com/CARVIN94/omarchy-horizon-setup.git \
  ~/.config/omarchy/plugins/horizon.setup
```

然后**重启 Omarchy shell**（或注销重登）：

```bash
systemctl --user restart omarchy-launch-shell
```

打开 **菜单 → 设置**，出现 **Horizon Setup** 条目；点开即是面板。

命令行直查/切换（面板之外的等价操作）：

```bash
~/.config/omarchy/plugins/horizon.setup/setup.sh status   # 五开关当前状态
~/.config/omarchy/plugins/horizon.setup/setup.sh toggle keys   # 开/关 Mac 快捷键
```

> 本地开发：改 `Panel.qml` 后 quickshell 热重载即生效；若面板没刷新，
> 重启 omarchy-launch-shell 最稳。

## 它解决什么问题

| 能力 | 说明 |
| --- | --- |
| Cmd = Ctrl | 物理左下角保持 Mac 顺序 `Ctrl \| Option \| Command`；`Command` 键按下时输出标准 Linux `Ctrl`——复制/粘贴/全选在浏览器、编辑器里开箱即用。 |
| 快捷键桥接 | 16 组 `Cmd+…` 桥接到 Linux 目标键：行首行尾、文档首尾、删到行首、保存/查找/撤销等。Omarchy 平铺占用的组合先 `hl.unbind` 接管，关开关自动恢复。 |
| 自然滚动 | 触控板 + 鼠标一起切（macOS 方向），udev 持久化鼠标设置。 |
| 剪贴板快捷键 | `Super+Alt+C` 直接粘贴剪贴板历史首项（Omarchy 原生 `Super+V` 菜单的快捷方式）。 |
| npm 国内源 | 切换 `~/.npmrc` registry 到 npmmirror。 |
| GitHub 代理 | `git config url.insteadOf` 把 `github.com` 克隆透明改写为 `gh-proxy.org`，clone/push 不用改记忆。 |
| 幂等检测 | 每个开关独立检测真实状态（XKB 选项、绑定块标记、npmrc、git config），不是「记着上次点了啥」。 |

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
| `Cmd+W / Q / N / S / O / F` | `Ctrl+W / Q / N / S / O / F` | 关窗 / 退出 / 新建 / 保存 / 打开 / 查找 |
| `Cmd+Z` | `Ctrl+Z` | 撤销 |
| `Cmd+Shift+Z` | `Ctrl+Shift+Z` | 重做 |

> **终端分流**：终端里 `Ctrl+W` 是删词、`Ctrl+S`/`Ctrl+Q` 是 XOFF 冻结/恢复，
> 与 Mac 语义冲突——终端焦点时 `W`/`S`/`Q` 不桥接，保留终端原生行为。
>
> **天花板**：`Option+←/→` 的按词移动无法在 Hyprland 层统一做（Chrome 的
> `Alt+←` 是后退，桥接会打架），升级路径是 per-app 配置，当前不做。
>
> 被接管的组合（如 `Super+F` 全宽、`Super+S` scratchpad）随本开关走：
> 开 = 桥接，关 = Omarchy 默认绑定随 `hyprctl reload` 自动恢复。

## 面板

**菜单 → 设置 → Horizon Setup**，overlay 窗口（`Esc` 或点空白关闭）：

- 头部：标题 + 副标，右侧胶囊徽章显示 `已启用/总数`
- 五个开关：Mac 快捷键、自然滚动、剪贴板快捷键、npm 换源、GitHub 代理
- 底部状态行：空闲时提示关闭方式，写配置时显示进行中
- 开关点击走 `setup.sh toggle <key>`，完成后自动刷新检测状态

## 工作原理

- **检测**：`setup.sh status` 输出 `keys= scroll= clip= npm= ghproxy=` 五态，各自读真实来源
  （`hyprctl getoption input:kb_options`、`~/.config/hypr/bindings.lua` 标记块、`~/.npmrc`、`git config --global`）。
- **切换**：每个开关写入带 `-- horizon.setup:xxx` 标记的幂等块，重复 toggle 只翻转块的存在性，不产生重复条目。
- **快捷键**：Hyprland Lua API（`hl.unbind` + `o.bind` + `hl.dsp.send_key_state`）在
  `~/.config/hypr/bindings.lua` 注册桥接；`send_key_state` 直接注入目标键的 down/up，
  对应用等价于物理按键。
- **面板**：Quickshell overlay（`Panel.qml`），通过 `omarchy-shell shell toggle horizon.setup`
  开关；插件由 `manifest.json` 声明为 `overlay` kind。

## 卸载

```bash
# 1. 先关掉所有开关（恢复默认绑定/配置）
~/.config/omarchy/plugins/horizon.setup/setup.sh toggle keys
~/.config/omarchy/plugins/horizon.setup/setup.sh toggle scroll
# …其余开关同理，或逐个 toggle 至 status 全 0

# 2. 移除插件并重启 shell
rm -rf ~/.config/omarchy/plugins/horizon.setup
systemctl --user restart omarchy-launch-shell
```

## License

[MIT](LICENSE)
