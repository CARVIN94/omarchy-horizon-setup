#!/usr/bin/env bash
# horizon.setup — Mac 习惯相关开关：快捷键桥接、自然滚动、剪贴板快捷键。
#
# 检测即真相：不维护状态文件，三态全部从系统/配置实读；配置用带标记的
# 管理块（marker block）幂等管理，toggle 先删旧块再按当前状态重建。
#
# 被 setup.sh source，因此这里只定义函数，不执行动作。

MAC_INPUT="${MAC_INPUT:-$HOME/.config/hypr/input.lua}"
MAC_BIND="${MAC_BIND:-$HOME/.config/hypr/bindings.lua}"
MAC_KEYS_OPT="altwin:swap_alt_win"

# SSH/非图形 shell 下缺会话环境变量，hyprctl 会失败导致误报 0；
# 补上 XDG_RUNTIME_DIR 与 instance signature 即可在任意上下文运行。
mac_ensure_hypr_env() {
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  if ! hyprctl version >/dev/null 2>&1; then
    local inst
    inst=$(ls -dt "$XDG_RUNTIME_DIR"/hypr/*/ 2>/dev/null | head -1 || true)
    if [ -n "$inst" ]; then
      export HYPRLAND_INSTANCE_SIGNATURE
      HYPRLAND_INSTANCE_SIGNATURE=$(basename "$inst")
    fi
  fi
}

# 注意两标记行是彼此的前缀，所有 sed 范围都必须行首/行尾锚定。
MSTART='-- horizon.setup:macos-keys'
MEND='-- horizon.setup:macos-keys-end'
CSTART='-- horizon.setup:clipboard-key'
CEND='-- horizon.setup:clipboard-key-end'
ASTART='-- horizon.setup:selectall-key'
AEND='-- horizon.setup:selectall-key-end'
TSTART='-- horizon.setup:textedit-key'
TEND='-- horizon.setup:textedit-key-end'
# 文本编辑块的内容版本。改块内容（增删任何一行桥接）都要提这个数字，
# 否则老用户手上的旧块仍判「就绪」，永远拿不到新桥接。见 mac_textedit_on。
TREV='-- horizon.setup:textedit-key-rev 4'
VSTART='-- horizon.setup:media-key'
VEND='-- horizon.setup:media-key-end'
SSTART='-- horizon.setup:screenshot-key'
SEND='-- horizon.setup:screenshot-key-end'
# 截图块的内容版本。与 TREV 同一套升级语义：改块内容就提这个数字，
# 老用户判未就绪 ⇒ 面板显示「关」，按一次开关即整块重建。
SREV='-- horizon.setup:screenshot-key-rev 1'

# ---- 检测（直接读系统，不缓存）----------------------------------------

mac_bool_on() { hyprctl getoption "$1" 2>/dev/null | grep -q '^bool: true'; }

mac_selectall_on() { grep -q "^${ASTART}\$" "$MAC_BIND"; }
# 文本编辑块不能只看起始标记：块是用户上次开启时写下的，标记在而内容旧时若判
# 「就绪」，面板会显示「开」，新加的桥接（如 Cmd+Shift+T）永远发不到老用户手里。
# 故块内带一行版本号，判定要求版本号匹配；**改动块内容就必须同步提版本**，
# 老用户于是判未就绪 ⇒ 面板显示「关」，按一次开关即整块重建。
mac_textedit_on() {
  # TREV 本身以 `--` 开头，必须用 `--` 终止选项解析，否则 grep 报 unrecognized option。
  grep -q "^${TSTART}\$" "$MAC_BIND" && grep -qxF -- "${TREV}" "$MAC_BIND"
}
mac_clip_on()      { grep -q "^${CSTART}\$" "$MAC_BIND"; }
mac_media_on()     { grep -q "^${VSTART}\$" "$MAC_BIND"; }
# 截图块同样要求版本号匹配，理由与 textedit 一致：块在而内容旧时不能判就绪。
mac_screenshot_on() {
  grep -q "^${SSTART}\$" "$MAC_BIND" && grep -qxF -- "${SREV}" "$MAC_BIND"
}

# Mac 快捷键：物理 Ctrl|Win|Alt 变 Ctrl|Option|Command（只需 Win↔Alt 交换），
# 且全选、文本编辑 P0 桥接、音量三键、截图键都存在——同属 keys 开关，缺一
# 不算就绪。必须含 media/screenshot：老用户 keys=开 但块是旧内容时就绪判定
# 转假 ⇒ 面板显示「关」，按一次开关即整套重建，自愈而非静默缺功能。
mac_keys_on() {
  local v
  v=$(hyprctl getoption input:kb_options 2>/dev/null | sed -n 's/^str: //p')
  [[ "$v" == *"$MAC_KEYS_OPT"* ]] && mac_selectall_on && mac_textedit_on \
    && mac_media_on && mac_screenshot_on
}

# 自然滚动：顶层管鼠标滚轮 + touchpad 管触控板，两者都要 true。
mac_scroll_on() {
  mac_bool_on input:natural_scroll && mac_bool_on input:touchpad:natural_scroll
}

# ---- input.lua 标记块管理 ----------------------------------------------

mac_del_input_block() {
  # -i.bak 后删备份：GNU/BSD sed 通吃的写法（裸 -i 两者语法不兼容）。
  sed -i.bak "/^${MSTART}\$/,/^${MEND}\$/d" "$MAC_INPUT" && rm -f "$MAC_INPUT.bak"
}

# 按两开关状态重建整块。两开关共享一个块（同一 input 表），块内只写各自
# 开启的字段——未写的字段回落到 Omarchy 默认值，这样 keys 与 scroll 可
# 独立开/关而互不牵连。
mac_render_input_block() { # $1=keys 0/1  $2=scroll 0/1
  local k="$1" s="$2"
  [[ "$k" == 1 || "$s" == 1 ]] || return 0
  {
    echo "$MSTART"
    echo "hl.config({"
    echo "  input = {"
    if [[ "$k" == 1 ]]; then
      echo "    kb_options = \"${MAC_KEYS_OPT}\","
    fi
    if [[ "$s" == 1 ]]; then
      echo "    natural_scroll = true,"
      echo "    touchpad = { natural_scroll = true },"
    fi
    echo "  },"
    echo "})"
    echo "$MEND"
  } >> "$MAC_INPUT"
}

mac_write_input_block() { # $1=keys  $2=scroll
  mac_del_input_block
  mac_render_input_block "$1" "$2"
  hyprctl reload >/dev/null
  sleep 0.3
}

# ---- bindings.lua 标记行管理 -------------------------------------------

mac_reload() { hyprctl reload >/dev/null; sleep 0.3; }

mac_write_clip_binding() {
  if [[ "$1" == 1 ]]; then
    grep -q "^${CSTART}\$" "$MAC_BIND" || {
      printf '\n%s\no.bind("SUPER + ALT + C", "Clipboard manager", "omarchy-shell shell toggle omarchy.clipboard")\n%s\n' \
        "$CSTART" "$CEND" >> "$MAC_BIND"
    }
  else
    sed -i.bak "/^${CSTART}\$/,/^${CEND}\$/d" "$MAC_BIND" && rm -f "$MAC_BIND.bak"
  fi
  mac_reload
}

# 通用全选桥接。复用 Omarchy 自带 send_shortcut_once 思路：down/up 分开发，
# 避免合成键状态卡住（Hyprland send_shortcut 的已知问题）。
# 骨架由 bindings.lua 提供不了（它是独立加载的 chunk），这里自带最小实现。
mac_write_selectall_binding() {
  if [[ "$1" == 1 ]]; then
    grep -q "^${ASTART}\$" "$MAC_BIND" || {
      cat >> "$MAC_BIND" <<'LUAEOF'

-- horizon.setup:selectall-key
-- Super+A → Ctrl+A（Mac Command=Super，Linux 全选=Ctrl+A 的桥接）。
o.bind("SUPER + A", "Universal select all", function()
  hl.dispatch(hl.dsp.send_key_state({ mods = "CTRL", key = "A", state = "down" }))
  hl.timer(function()
    hl.dispatch(hl.dsp.send_key_state({ mods = "CTRL", key = "A", state = "up" }))
  end, { timeout = 50, type = "oneshot" })
end)
-- horizon.setup:selectall-key-end
LUAEOF
    }
  else
    sed -i.bak "/^${ASTART}\$/,/^${AEND}\$/d" "$MAC_BIND" && rm -f "$MAC_BIND.bak"
  fi
  mac_reload
}

# 文本编辑 P0 桥接（Mac Command+方向/退格 的行首尾、行尾删除等）。
# 用 hl.unbind 接管被 Omarchy 平铺占用的 SUPER+方向/退格组合——unbind 只清
# 同一组合的全部绑定，不动其他组合（SUPER+SHIFT+方向仍在）。关闭时删块，
# Omarchy 默认绑定随 reload 自动恢复，脚本不负责重绑。
# 天花板：Option+←/→ 的"按词移动"无法在 Hyprland 层做（Chrome 的 Alt+← 是
# 后退，会打架），升级路径是 per-app 配置，当前不做。
# 同理 Command+[ / ] 的「后退/前进」需要注入 ALT+LEFT/RIGHT，而 send_key_state
# 的 mods 只验证过 "CTRL" / "CTRL+SHIFT"（Omarchy 自身的唯一先例），ALT 未证实，
# 故本批不绑——留作升级路径，验证后再说。
mac_write_textedit_bindings() {
  # 先删旧块再按需重写——不能用「块已存在就跳过」：块是用户上次开启时写下的，
  # 内容可能已过时，跳过会让老用户永远拿不到桥接修复。幂等的正确含义是
  # 「结果恒等于本文件的内容」，不是「写过就不动」。
  sed -i.bak "/^${TSTART}\$/,/^${TEND}\$/d" "$MAC_BIND" 2>/dev/null && rm -f "$MAC_BIND.bak"
  if [[ "$1" == 1 ]]; then
    {
      printf '\n%s\n%s\n' "$TSTART" "$TREV"
      cat <<'LUAEOF'
-- Mac Command 键输出 Super；Linux 文本光标/删除/应用操作用 Ctrl。桥接如下：
--   Command+←/→        → Home/End        行首/行尾
--   Command+Shift+←/→  → Shift+Home/End  选到行首/行尾
--   Command+↑/↓        → Ctrl+Home/End   文档首/尾
--   Command+Backspace  → Ctrl+U          删到行首
--   Command+Slash       → Ctrl+Slash      注释/取消注释
--   Command+W          → Ctrl+W          关标签页/文档
--   Command+Q          → 关闭窗口（WM 动作，见下）
--   Command+R                    → Ctrl+R          重新加载/刷新
--   Command+N/S/O/F/Z            → Ctrl+N/S/O/F/Z（新建/保存/打开/查找/撤销）
--   Command+Shift+Z              → Ctrl+Shift+Z（重做）
--   Command+Shift+T              → Ctrl+Shift+T（恢复刚关闭的标签页/页面）
--   Command+Delete               → Ctrl+K          删到行尾
--   Command+Shift+V              → Ctrl+Shift+V     纯文本粘贴
-- 依赖 hl.unbind 接管 Omarchy 占用的组合（全屏、scratchpad、pop window 等）；
-- 关闭本开关时块被删，默认绑定由 hyprctl reload 自动恢复。
local function send_once(mods, key)
  hl.dispatch(hl.dsp.send_key_state({ mods = mods, key = key, state = "down" }))
  hl.timer(function()
    hl.dispatch(hl.dsp.send_key_state({ mods = mods, key = key, state = "up" }))
  end, { timeout = 50, type = "oneshot" })
end
local function bridge(combo, mods, key)
  hl.unbind(combo)
  o.bind(combo, "macOS text edit", function() send_once(mods, key) end)
end
bridge("SUPER + LEFT", "", "Home")
bridge("SUPER + RIGHT", "", "End")
bridge("SUPER + SHIFT + LEFT", "CTRL+SHIFT", "Home")
bridge("SUPER + SHIFT + RIGHT", "CTRL+SHIFT", "End")
bridge("SUPER + UP", "CTRL", "Home")
bridge("SUPER + DOWN", "CTRL", "End")
bridge("SUPER + BACKSPACE", "CTRL", "U")

-- Command+Delete = 删到行尾。macOS 里 Cmd+Delete 删光标到行尾；Linux/GTK/Qt/
-- VSCode 的对应键是 Ctrl+K（emacs 风格 kill-line），终端 readline 里同样成立，
-- 故无需终端分流。与上面的 Cmd+Backspace（删到行首 → Ctrl+U）成对。
bridge("SUPER + DELETE", "CTRL", "K")

-- Command+Slash = 注释/取消注释。macOS 里 Cmd+/ 是编辑器与 IDE 的通用注释键，
-- Linux 侧对应 Ctrl+/（GTK/VS Code/JetBrains/Neovim 皆然）。
-- hl.unbind 接管 Omarchy 原生的 SUPER+SLASH=显示器缩放放大；平铺 WM 下
-- 调显示器缩放请改用菜单里的显示器面板，或 SUPER+ALT+SLASH（缩小仍在）。
-- 注意 Cmd+Q 已经占了 WM 关窗，本条是发按键而非 WM 动作，与它分工不同。
bridge("SUPER + SLASH", "CTRL", "SLASH")

-- Command+W = 关闭标签页/文档（浏览器关标签、编辑器关文件）。
-- macOS 的 Cmd+W 就是这个语义，对应 Linux 应用的 Ctrl+W，与窗口无关；
-- 因此必须**发 Ctrl+W 给应用**，而不能绑成 WM 的关窗动作（后者会把
-- 「关标签」变成「杀掉整个应用」）。它由下面的 bridge_app 注册。
-- 这会接管 Omarchy 原生的 SUPER+W=关窗：平铺 WM 下关整窗请用 Command+Q。
-- 注意：这正是本插件早期的既有行为（Cmd+W→Ctrl+W），后被误改为
-- 「交还原生关窗」，属误判，已恢复。

-- Command+Q = 退出应用/关闭窗口。macOS 里 Cmd+Q 是退出，这里用 WM 的
-- window.close() 实现——它是应用级动作而非标签级，与焦点应用无关，
-- 终端里同样成立（终端里 Ctrl+Q 是 XOFF 恢复，不能用来发按键）。
o.bind("SUPER + Q", "Close window", hl.dsp.window.close())

-- 应用通用操作（P1）：Command+字母 直通 Ctrl+字母，Linux/GTK 应用原生语义。
-- 终端分流：终端里 Ctrl+W=删词、Ctrl+S=XOFF 冻结，都与保存/关标签语义
-- 冲突，故终端焦点时 W/S 不桥接（保留终端原生行为）——与 Omarchy
-- 剪贴板绑定同法。
-- Q 不在列：它走上面的 window.close()，是 WM 动作，不需要分流。
local function active_is_terminal()
  local w = hl.get_active_window()
  if not w then return false end
  for _, t in ipairs(w.tags or {}) do
    if t:gsub("%*$", "") == "terminal" then return true end
  end
  return false
end
local function bridge_app(combo, mods, key)
  hl.unbind(combo)
  o.bind(combo, "macOS app action", function()
    -- 终端里 Ctrl+W=删词、Ctrl+S=XOFF 冻结，均与 Mac 语义冲突，故跳过。
    -- W/S/R 三个在终端里与 Linux 语义冲突，故焦点是终端时不桥接：
    --  W=删词、S=XOFF 冻结、R=反查历史（reverse-i-search，macOS 同样
    --  是 Ctrl+R，保留它对 Mac 习惯也成立）。
    if active_is_terminal() and (key == "W" or key == "S" or key == "R") then return end
    send_once(mods, key)
  end)
end
bridge_app("SUPER + W", "CTRL", "W")
-- Command+R = 重新加载（macOS 的刷新语义）。Omarchy 未占用 SUPER+R
-- （只有 SUPER+RETURN / SUPER+RIGHT，属不同组合），CTRL+R 在 hyprland 层
-- 也未被占用，故是纯新增，不覆盖任何原生功能。
bridge_app("SUPER + R", "CTRL", "R")
bridge_app("SUPER + N", "CTRL", "N")
bridge_app("SUPER + S", "CTRL", "S")
bridge_app("SUPER + O", "CTRL", "O")
bridge_app("SUPER + F", "CTRL", "F")
bridge_app("SUPER + Z", "CTRL", "Z")
bridge_app("SUPER + SHIFT + Z", "CTRL+SHIFT", "Z")
-- Command+Shift+T = 恢复刚关闭的标签页/页面（macOS 里与 Ctrl+Shift+T 同义）。
-- Ctrl+Shift+T 在 hyprland 层未被占用（Omarchy 的 SUPER+SHIFT+T 也空缺，
-- 已 grep 默认绑定与 hyprctl binds 双向核对），故为纯新增；终端里
-- Ctrl+Shift+T 是终端自己的「新建标签页」，与 Mac 语义同样成立，不参与分流。
bridge_app("SUPER + SHIFT + T", "CTRL+SHIFT", "T")
-- Command+Shift+V = 纯文本粘贴（去掉格式）。macOS 里 Cmd+Shift+V 就是这个语义，
-- Linux/GTK/Qt 的对应键是 Ctrl+Shift+V。终端里 Ctrl+Shift+V 也是「粘贴」，
-- 与 Mac 语义一致，故不参与终端分流。
bridge_app("SUPER + SHIFT + V", "CTRL+SHIFT", "V")
-- horizon.setup:textedit-key-end
LUAEOF
    } >> "$MAC_BIND"
  fi
  mac_reload
}

# 音量三键（macOS 顶排 F10/F11/F12 的语义：静音/减/增）。Super 是 Mac 的
# Command，故绑 Super+F10..F12；动作直接复用 Omarchy 自带音量命令（与
# XF86 媒体键同源，带 OSD 反馈），locked=锁屏可用、repeating=长按连续调。
# 与 textedit 同法：先删旧块再按需重写（升级路径），不依赖「块存在就跳过」。
# 这三个组合在 Omarchy 默认与本机其它配置里均无既有绑定（已 grep 核对），属纯新增。
mac_write_media_bindings() {
  sed -i.bak "/^${VSTART}\$/,/^${VEND}\$/d" "$MAC_BIND" 2>/dev/null && rm -f "$MAC_BIND.bak"
  if [[ "$1" == 1 ]]; then
    {
      cat <<'LUAEOF'

-- horizon.setup:media-key
-- macOS 音量三键的 Linux 对应（Mac 键盘顶排语义）：
--   Super+F10 → 静音开关   Super+F11 → 音量减   Super+F12 → 音量增
-- 复用 Omarchy 音量命令（同 XF86Audio* 键），锁屏可用、支持长按连调。
o.bind("SUPER + F10", "Mute", "omarchy-audio-output-volume mute-toggle", { locked = true })
o.bind("SUPER + F11", "Volume down", "omarchy-audio-output-volume lower", { locked = true, repeating = true })
o.bind("SUPER + F12", "Volume up", "omarchy-audio-output-volume raise", { locked = true, repeating = true })
-- horizon.setup:media-key-end
LUAEOF
    } >> "$MAC_BIND"
  fi
  mac_reload
}

# 截图键：Super+Shift+X 是本插件自选的区域截图组合，**不是** macOS 原生键。
# macOS 的系统截图是 Cmd+Shift+3/4/5；这里没法照搬，因为 Omarchy 把
# SUPER+SHIFT+数字 全给了「移动窗口到工作区 N」（tiling.lua:22-24），
# 抢 3/4/5 会换掉一个常用窗口动作。故退而选空闲的 Super+Shift+X。
# 走 omasnap（Omarchy 原生、带标注/滚动拼接/OCR 的 Wayland 截图器），没装时
# 回落到 Omarchy 自带的 omarchy-capture-screenshot —— 不留一个按了没反应的
# 死键：装了 omasnap 自动升级，没装仍是原来那套 grim+slurp+tensaku。
# 必须 hl.unbind：Omarchy 预装的 webapp 绑定占了 SUPER+SHIFT+X（打开 x.com），
# 不先解绑会两条同键并存，谁生效取决于注册顺序。
mac_write_screenshot_binding() {
  sed -i.bak "/^${SSTART}\$/,/^${SEND}\$/d" "$MAC_BIND" 2>/dev/null && rm -f "$MAC_BIND.bak"
  if [[ "$1" == 1 ]]; then
    {
      printf '\n%s\n%s\n' "$SSTART" "$SREV"
      cat <<'LUAEOF'
-- 区域截图并进入标注（自选组合，非 macOS 原生：macOS 用 Cmd+Shift+3/4/5，
-- 但那几个数字键被 Omarchy 的「移动窗口到工作区」占了）。omasnap 缺失时回落原生流程。
-- 接管了 Omarchy 预装的 Super+Shift+X（打开 X webapp）；关闭本开关后由 reload 恢复。
hl.unbind("SUPER + SHIFT + X")
o.bind("SUPER + SHIFT + X", "Screenshot", "if command -v omasnap >/dev/null 2>&1; then exec omasnap; else exec omarchy-capture-screenshot; fi")
-- horizon.setup:screenshot-key-end
LUAEOF
    } >> "$MAC_BIND"
  fi
  mac_reload
}
