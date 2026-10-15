#!/usr/bin/env bash
# horizon.setup — Mac 习惯配置的检测与切换。
#
# 设计原则：检测即真相。不维护任何状态文件，三态全部从系统/配置实读；
# 配置用带标记的管理块（marker block）幂等管理，toggle 先删旧块再按
# 两开关当前状态重建，reload 后复读校验。
#
# 用法: setup.sh status | toggle keys|scroll|clip|npm
set -euo pipefail

INPUT="$HOME/.config/hypr/input.lua"
BIND="$HOME/.config/hypr/bindings.lua"
NPMRC="$HOME/.npmrc"
KEYS_OPT="altwin:swap_alt_win"
NPM_MIRROR="https://registry.npmmirror.com"
# GitHub 镜像前缀：git 的 insteadOf 会把 https://github.com/ 自动改写走代理。
# 只影响 https clone/fetch；push 仍走真实 origin（镜像是只读的，push 会失败）。
GHPROXY_KEY='url.https://gh-proxy.org/https://github.com/.insteadOf'

# SSH/非图形 shell 下缺会话环境变量，hyprctl 会失败导致误报 0；
# 这里补上 XDG_RUNTIME_DIR 与 instance signature 即可在任意上下文运行。
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
if ! hyprctl version >/dev/null 2>&1; then
  # 优先当前图形会话的 instance；多会话时取最新的（mtime 倒序）。
  inst=$(ls -dt "$XDG_RUNTIME_DIR"/hypr/*/ 2>/dev/null | head -1 || true)
  if [ -n "$inst" ]; then
    export HYPRLAND_INSTANCE_SIGNATURE
    HYPRLAND_INSTANCE_SIGNATURE=$(basename "$inst")
  fi
fi
# 注意两标记行是彼此的前缀，所有 sed 范围都必须行首/行尾锚定。
MSTART='-- horizon.setup:macos-keys'
MEND='-- horizon.setup:macos-keys-end'
CSTART='-- horizon.setup:clipboard-key'
CEND='-- horizon.setup:clipboard-key-end'
ASTART='-- horizon.setup:selectall-key'
AEND='-- horizon.setup:selectall-key-end'
TSTART='-- horizon.setup:textedit-key'
TEND='-- horizon.setup:textedit-key-end'

# ---- 检测（直接读系统，不缓存）----------------------------------------

bool_on() { hyprctl getoption "$1" 2>/dev/null | grep -q '^bool: true'; }

# Mac 快捷键：物理 Ctrl|Win|Alt 变 Ctrl|Option|Command（只需 Win↔Alt 交换），
# 且全选、文本编辑 P0 桥接都存在——同属 keys 开关，缺一不算就绪。
keys_on() {
  local v
  v=$(hyprctl getoption input:kb_options 2>/dev/null | sed -n 's/^str: //p')
  [[ "$v" == *altwin:swap_alt_win* ]] && selectall_on && textedit_on
}

# 自然滚动：顶层管鼠标滚轮 + touchpad 管触控板，两者都要 true。
scroll_on() {
  bool_on input:natural_scroll && bool_on input:touchpad:natural_scroll
}

clip_on() { grep -q "^${CSTART}\$" "$BIND"; }

# 通用全选（Super+A → Ctrl+A）：Command 键输出 Super，而 Linux 应用的全选
# 是 Ctrl+A，故需像 Omarchy 的 Super+C/V 一样桥接。属 keys 开关的一部分。
selectall_on() { grep -q "^${ASTART}\$" "$BIND"; }

# 文本编辑 P0 桥接块：同属 keys 开关。
textedit_on() { grep -q "^${TSTART}\$" "$BIND"; }

# npm 换源：~/.npmrc 的 registry 指向 npmmirror（官方源则为关闭态）。
npm_on() { [[ -f "$NPMRC" ]] && grep -q "^registry=${NPM_MIRROR}\$" "$NPMRC"; }

# GitHub 代理：git config --global insteadOf 把 github.com 改写到镜像。
ghproxy_on() {
  [[ "$(git config --global --get "$GHPROXY_KEY" 2>/dev/null)" == "https://github.com/" ]]
}

b() { if "$1"; then echo 1; else echo 0; fi; }

status() {
  echo "keys=$(b keys_on) scroll=$(b scroll_on) clip=$(b clip_on) npm=$(b npm_on) ghproxy=$(b ghproxy_on)"
}

# ---- input.lua 标记块管理 ------------------------------------------------

del_input_block() {
  # -i.bak 后删备份：GNU/BSD sed 通吃的写法（裸 -i 两者语法不兼容）。
  sed -i.bak "/^${MSTART}\$/,/^${MEND}\$/d" "$INPUT" && rm -f "$INPUT.bak"
}

# 按两开关状态重建整块。两开关共享一个块（同一 input 表），
# 块内只写各自开启的字段——未写的字段回落到 Omarchy 默认值，
# 这样 keys 与 scroll 可独立开/关而互不牵连。
render_input_block() { # $1=keys_on 0/1  $2=scroll_on 0/1
  local k="$1" s="$2"
  [[ "$k" == 1 || "$s" == 1 ]] || return 0
  {
    echo "$MSTART"
    echo "hl.config({"
    echo "  input = {"
    if [[ "$k" == 1 ]]; then
      echo "    kb_options = \"${KEYS_OPT}\","
    fi
    if [[ "$s" == 1 ]]; then
      echo "    natural_scroll = true,"
      echo "    touchpad = { natural_scroll = true },"
    fi
    echo "  },"
    echo "})"
    echo "$MEND"
  } >> "$INPUT"
}

write_input_block() { # $1=keys  $2=scroll
  del_input_block
  render_input_block "$1" "$2"
  hyprctl reload >/dev/null
  sleep 0.3
}

# ---- bindings.lua 标记行管理 ---------------------------------------------

write_clip_binding() {
  if [[ "$1" == 1 ]]; then
    grep -q "^${CSTART}\$" "$BIND" || {
      printf '\n%s\no.bind("SUPER + ALT + C", "Clipboard manager", "omarchy-shell shell toggle omarchy.clipboard")\n%s\n' \
        "$CSTART" "$CEND" >> "$BIND"
    }
  else
    sed -i.bak "/^${CSTART}\$/,/^${CEND}\$/d" "$BIND" && rm -f "$BIND.bak"
  fi
  hyprctl reload >/dev/null
  sleep 0.3
}

# 通用全选桥接。复用 Omarchy 自带 send_shortcut_once 思路：down/up 分开发，
# 避免合成键状态卡住（Hyprland send_shortcut 的已知问题）。
# 骨架由 bindings.lua 提供不了（它是独立加载的 chunk），这里自带最小实现。
write_selectall_binding() {
  if [[ "$1" == 1 ]]; then
    grep -q "^${ASTART}\$" "$BIND" || {
      cat >> "$BIND" <<'LUAEOF'

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
    sed -i.bak "/^${ASTART}\$/,/^${AEND}\$/d" "$BIND" && rm -f "$BIND.bak"
  fi
  hyprctl reload >/dev/null
  sleep 0.3
}

# 文本编辑 P0 桥接（Mac Command+方向/退格 的行首尾、行尾删除等）。
# 用 hl.unbind 接管被 Omarchy 平铺占用的 SUPER+方向/退格组合——unbind 只清
# 同一组合的全部绑定，不动其他组合（SUPER+SHIFT+方向仍在）。关闭时删块，
# Omarchy 默认绑定随 reload 自动恢复，脚本不负责重绑。
# 天花板：Option+←/→ 的"按词移动"无法在 Hyprland 层做（Chrome 的 Alt+← 是
# 后退，会打架），升级路径是 per-app 配置，当前不做。
write_textedit_bindings() {
  if [[ "$1" == 1 ]]; then
    grep -q "^${TSTART}\$" "$BIND" || {
      cat >> "$BIND" <<'LUAEOF'

-- horizon.setup:textedit-key
-- Mac Command 键输出 Super；Linux 文本光标/删除/应用操作用 Ctrl。桥接如下：
--   Command+←/→        → Home/End        行首/行尾
--   Command+Shift+←/→  → Shift+Home/End  选到行首/行尾
--   Command+↑/↓        → Ctrl+Home/End   文档首/尾
--   Command+Backspace  → Ctrl+U          删到行首
--   Command+W/Q/N/S/O/F/Z            → Ctrl+W/Q/N/S/O/F/Z（关窗/退出/新建/保存/打开/查找/撤销）
--   Command+Shift+Z                  → Ctrl+Shift+Z（重做）
-- 依赖 hl.unbind 接管 Omarchy 占用的组合（全宽 FULLSCREEN 等）；关闭本开关
-- 时块被删，默认绑定由 hyprctl reload 自动恢复。
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

-- 应用通用操作（P1）：Command+字母 直通 Ctrl+字母，Linux/GTK 应用原生语义。
-- 终端里 Ctrl+W=删词、Ctrl+S=XOFF 冻结、Ctrl+Q=XOFF 恢复，与 Mac 语义冲突，
-- 终端焦点时 W/S/Q 不桥接（保留终端原生行为）——与 Omarchy 剪贴板绑定同法。
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
    if active_is_terminal() and (key == "W" or key == "S" or key == "Q") then return end
    send_once(mods, key)
  end)
end
bridge_app("SUPER + W", "CTRL", "W")
bridge_app("SUPER + Q", "CTRL", "Q")
bridge_app("SUPER + N", "CTRL", "N")
bridge_app("SUPER + S", "CTRL", "S")
bridge_app("SUPER + O", "CTRL", "O")
bridge_app("SUPER + F", "CTRL", "F")
bridge_app("SUPER + Z", "CTRL", "Z")
bridge_app("SUPER + SHIFT + Z", "CTRL+SHIFT", "Z")
-- horizon.setup:textedit-key-end
LUAEOF
    }
  else
    sed -i.bak "/^${TSTART}\$/,/^${TEND}\$/d" "$BIND" && rm -f "$BIND.bak"
  fi
  hyprctl reload >/dev/null
  sleep 0.3
}

# ---- npm 换源 -------------------------------------------------------------

write_npm_registry() {
  if [[ "$1" == 1 ]]; then
    touch "$NPMRC"
    if grep -q '^registry=' "$NPMRC"; then
      sed -i.bak "s|^registry=.*|registry=${NPM_MIRROR}|" "$NPMRC" && rm -f "$NPMRC.bak"
    else
      echo "registry=${NPM_MIRROR}" >> "$NPMRC"
    fi
  else
    # 关闭 = 移除本插件写入的镜像行（不留默认值，让 npm 回落官方源）。
    # sed 表达式用 | 分隔符（镜像 URL 含 /）。
    sed -i.bak "\|^registry=${NPM_MIRROR}\$|d" "$NPMRC" && rm -f "$NPMRC.bak"
    [ -s "$NPMRC" ] || rm -f "$NPMRC"
  fi
}

# ---- GitHub 代理 -------------------------------------------------------------

write_ghproxy() {
  if [[ "$1" == 1 ]]; then
    git config --global "$GHPROXY_KEY" "https://github.com/"
  else
    git config --global --unset "$GHPROXY_KEY" 2>/dev/null || true
  fi
}

# ---- 入口 -----------------------------------------------------------------

main() {
  case "${1:-}" in
    status)
      status
      ;;
    toggle)
      case "${2:-}" in
        keys)
          local k s
          if keys_on; then k=0; else k=1; fi
          s=$(b scroll_on)
          write_input_block "$k" "$s"
          write_selectall_binding "$k"
          write_textedit_bindings "$k"
          ;;
        scroll)
          local k s
          k=$(b keys_on)
          if scroll_on; then s=0; else s=1; fi
          write_input_block "$k" "$s"
          ;;
        clip)
          local c
          if clip_on; then c=0; else c=1; fi
          write_clip_binding "$c"
          ;;
        npm)
          local n
          if npm_on; then n=0; else n=1; fi
          write_npm_registry "$n"
          ;;
        ghproxy)
          local g
          if ghproxy_on; then g=0; else g=1; fi
          write_ghproxy "$g"
          ;;
        *)
          echo "unknown toggle target: ${2:-}" >&2; exit 2
          ;;
      esac
      status
      ;;
    *)
      echo "usage: $0 status|toggle keys|scroll|clip|npm|ghproxy" >&2
      exit 2
      ;;
  esac
}

main "$@"
