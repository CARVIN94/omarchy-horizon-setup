#!/usr/bin/env bash
# horizon.setup — 一次性迁移：把 1.3.x 留下的 omarchy-zh-cn 现场擦干净。
#
# 本脚本只在 1.3.x → 1.4.0 迁移时用一次，用完可删。
#
# 为什么要有它：1.3.x 里那套 omarchy-zh-cn（第三方汉化项目）会往用户态写一堆
# 东西，1.4.0 不再用它，但现场还在，不清就会污染 0.4.5：
#   ① ~/.config/omarchy/shell.json 的 bar layout 里 carvin.* 挂件 id（中文版克隆）
#   ② ~/.config/omarchy/plugins/ 下的 carvin.* 插件目录
#   ③ ~/.local/share/omarchy-zh-cn/（映射表 + 应用器）
#   ④ ~/.config/omarchy/extensions/omarchy-menu.jsonc（旧版全量中文菜单克隆，
#      实测遮住 130 个 0.4.5 新条目：旧名 style.* 顶掉新名 appearance.*）。
#      **不整删** —— 本插件唯一的面板入口 setup.horizon 只存在于此。改为按保留
#      清单重建：只留用户自加的那几条，其余交给 0.4.5 原生中文菜单。
#   ⑤ ~/.config/hypr/bindings.lua 里 `-- >>> omarchy-zh-cn` … `-- <<< omarchy-zh-cn`
#      的块（把 SUPER+K 换成中文快捷键面板）
#   ⑥ ~/.local/bin/ 的 omarchy-zh-sync / omarchy-update-zh /
#      omarchy-menu-keybindings-zh
#   ⑦ ~/.config/omarchy/hooks/post-update.d/omarchy-zh-post-update（每次更新报 critical）
#   ⑧ ~/.local/state/omarchy-zh/
#
# 注意：本插件自己的「插件汉化」Tab 仍在（映射表组 + Omasnap），但它的资产随
# 插件分发在 lib/zh-maps/ + lib/apply-zh.py，与这里删掉的 omarchy-zh-cn 是两回事。
#
# 幂等：跑第二遍什么都不改，只打印「已是干净状态」。可重复跑。
# 只碰用户态：不 sudo、不提权、不动 /usr/share/omarchy。
# 会改的两个文件（shell.json / bindings.lua）先备份成 .bak-<时间戳>。
#
# 用法：
#   bash lib/migrate-drop-omarchy-zh-cn.sh --dry-run   # 只打印将要做什么
#   bash lib/migrate-drop-omarchy-zh-cn.sh             # 真跑
#
# 测试用环境变量（fixture 场景；真机上别设）：
#   MIGRATE_HOME=<dir>  把 $HOME 根换掉，~/.config / ~/.local/bin /
#                       ~/.local/share / ~/.local/state 都由它派生。
#                       设了它就不再读 XDG_CONFIG_HOME / XDG_DATA_HOME / XDG_STATE_HOME。
set -uo pipefail

usage() {
  sed -n '3,34p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

DRY=0
case "${1:-}" in
  "")           ;;
  --dry-run|-n) DRY=1 ;;
  -h|--help)    usage; exit 0 ;;
  *)            printf 'unknown option: %s（试 --help）\n' "$1" >&2; exit 2 ;;
esac

if [ -n "${MIGRATE_HOME:-}" ]; then
  HOME_ROOT=${MIGRATE_HOME%/}          # 去掉尾斜杠，免得打印出 //.config
  CONFIG_ROOT=$HOME_ROOT/.config
  DATA_ROOT=$HOME_ROOT/.local/share
  STATE_ROOT=$HOME_ROOT/.local/state
  BIN_ROOT=$HOME_ROOT/.local/bin
else
  HOME_ROOT=$HOME
  CONFIG_ROOT=${XDG_CONFIG_HOME:-$HOME/.config}
  DATA_ROOT=${XDG_DATA_HOME:-$HOME/.local/share}
  STATE_ROOT=${XDG_STATE_HOME:-$HOME/.local/state}
  BIN_ROOT=$HOME/.local/bin
fi

SHELL_JSON=$CONFIG_ROOT/omarchy/shell.json
PLUGINS_DIR=$CONFIG_ROOT/omarchy/plugins
MENU_CLONE=$CONFIG_ROOT/omarchy/extensions/omarchy-menu.jsonc
BINDINGS=$CONFIG_ROOT/hypr/bindings.lua
HOOK_DIR=$CONFIG_ROOT/omarchy/hooks/post-update.d
HOOK=$HOOK_DIR/omarchy-zh-post-update
ZH_DATA=$DATA_ROOT/omarchy-zh-cn
ZH_STATE=$STATE_ROOT/omarchy-zh
# 只删这三个名字，别的一律不碰（目录里还有 horizon.setup 自己的东西）。
ZH_SCRIPTS="omarchy-zh-sync omarchy-update-zh omarchy-menu-keybindings-zh"

WORK=0   # 有活要干（dry-run 也算）
FAIL=0

say()  { printf '%s\n' "$*"; }
note() { printf '  %s\n' "$*"; }
todo() { WORK=1; }

if [ "$(id -u)" -eq 0 ] && [ -z "${MIGRATE_HOME:-}" ]; then
  say "请不要用 root 跑：本脚本只碰当前用户的家目录。" >&2
  exit 1
fi

# 备份到 <path>.bak-<时间戳>；同一秒多次备份自动加 -1/-2 后缀。
# 成功时把备份路径打到 stdout。
backup_file() {
  local src=$1 base bak n=0
  base=$src.bak-$(date +%Y%m%d-%H%M%S)
  bak=$base
  while [ -e "$bak" ]; do n=$((n + 1)); bak=$base-$n; done
  cp -p -- "$src" "$bak" || return 1
  printf '%s\n' "$bak"
}

# 删一个文件/目录，删前校验它的父目录确实是 expected_parent（realpath 比对）。
# 绝不把未校验的路径交给 rm，也绝不用通配批量删。
remove_path() {
  local p=$1 expect=$2 what=$3 pr er
  pr=$(realpath -e -- "${p%/*}" 2>/dev/null) \
    || { say "  跳过（无法解析父目录）：$p"; return 0; }
  er=$(realpath -e -- "$expect" 2>/dev/null) \
    || { say "  跳过（无法解析 $expect）：$p"; return 0; }
  if [ "$pr" != "$er" ]; then
    say "  跳过（不在 $expect 下）：$p"
    return 0
  fi
  todo
  if [ "$DRY" -eq 1 ]; then
    note "[dry-run] 将删除$what $p"
    return 0
  fi
  if rm -rf -- "$p"; then
    note "已删除$what $p"
  else
    say "  删除失败$what：$p"; FAIL=1
  fi
}

say "horizon.setup 迁移：卸掉 omarchy-zh-cn 层$([ "$DRY" -eq 1 ] && echo '（dry-run，不落盘）')"

# ---- ① shell.json 的 bar layout：carvin.* 挂件 id 切回 omarchy.* ------------
# 只改 .bar.layout 各栏里条目的 .id；disabledPlugins、dock、idle、plugins、
# version 等其余字段原样保留（jq 的键序与缩进原样输出，故非 bar 字节不变）。
migrate_shell_json() {
  local n bak tmp
  if [ ! -f "$SHELL_JSON" ]; then
    note "跳过：没有 $SHELL_JSON"
    return 0
  fi
  if ! n=$(jq -r '[.bar.layout[]? | arrays | .[]? | (.id? // empty) | strings
                  | select(startswith("carvin."))] | length' "$SHELL_JSON" 2>/dev/null); then
    say "  跳过：$SHELL_JSON 解析失败（不是 JSON？），原文件未动"
    return 0
  fi
  if [ "$n" -eq 0 ]; then
    note "无需改动：bar layout 里没有 carvin.* 挂件"
    return 0
  fi
  todo
  if [ "$DRY" -eq 1 ]; then
    note "[dry-run] 将把 $n 个挂件 id carvin.* → omarchy.*（先备份 .bak-<时间戳>）"
    return 0
  fi
  bak=$(backup_file "$SHELL_JSON") || { say "  备份失败，中止"; FAIL=1; return 1; }
  tmp=$(mktemp -- "$SHELL_JSON.XXXXXX") || { say "  mktemp 失败，中止"; FAIL=1; return 1; }
  if jq '
      def fixitem:
        if type == "object" and (.id? | type) == "string" and (.id | startswith("carvin."))
        then .id |= sub("^carvin\\."; "omarchy.") else . end;
      def fixslot: if type == "array" then map(fixitem) else . end;
      if (.bar.layout | type) == "object"
      then .bar.layout |= with_entries(.value |= fixslot) else . end
    ' "$SHELL_JSON" > "$tmp"; then
    chmod --reference="$SHELL_JSON" "$tmp" 2>/dev/null
    mv -f -- "$tmp" "$SHELL_JSON" || { rm -f -- "$tmp"; say "  写回失败"; FAIL=1; return 1; }
    note "已改写 $n 个挂件 id（备份：$bak）"
  else
    rm -f -- "$tmp"
    say "  jq 改写失败，原文件未动（备份保留在 $bak）"
    FAIL=1
  fi
}

# ---- ② plugins/ 下的 carvin.* 目录（逐个校验后删）--------------------------
migrate_plugin_dirs() {
  local root_real p name parent_real found=0
  if [ ! -d "$PLUGINS_DIR" ]; then
    note "跳过：没有 $PLUGINS_DIR"
    return 0
  fi
  root_real=$(realpath -e -- "$PLUGINS_DIR" 2>/dev/null) \
    || { say "  跳过：无法解析 $PLUGINS_DIR"; return 0; }
  for p in "$PLUGINS_DIR"/carvin.*; do
    [ -e "$p" ] || [ -L "$p" ] || continue
    name=${p##*/}
    case "$name" in carvin.*) ;; *) continue ;; esac
    parent_real=$(realpath -e -- "${p%/*}" 2>/dev/null) || continue
    if [ "$parent_real" != "$root_real" ]; then
      say "  跳过（不在 $PLUGINS_DIR 下）：$p"
      continue
    fi
    found=$((found + 1))
    remove_path "$p" "$PLUGINS_DIR" ""
  done
  [ "$found" -gt 0 ] || note "无需改动：$PLUGINS_DIR 下没有 carvin.* 目录"
}

# ---- ③ ~/.local/share/omarchy-zh-cn/ ---------------------------------------
migrate_zh_data() {
  if [ ! -d "$ZH_DATA" ] && [ ! -L "$ZH_DATA" ]; then
    note "跳过：没有 $ZH_DATA"
    return 0
  fi
  [ "${ZH_DATA##*/}" = "omarchy-zh-cn" ] \
    || { say "  跳过（名字不是 omarchy-zh-cn）：$ZH_DATA"; return 0; }
  remove_path "$ZH_DATA" "$DATA_ROOT" ""
}

# ---- ④ 旧中文菜单克隆：按保留清单重建 -------------------------------------
# 这个文件是 omarchy-zh-cn 生成的全量中文菜单副本（真机 334 条）。0.4.5 原生
# 中文菜单已 425/425 全覆盖，副本里与上游同名的条目全是冗余，而且旧名会遮住
# 新条目（实测 style.* 顶掉 appearance.*，共遮 130 条）。所以只留「上游没有、
# 用户自己加的」条目，其余丢弃让原生接管。
#
# 关键：**不能整删** —— 本插件唯一的面板入口 `setup.horizon` 只存在于这个文件
# （上游 default 菜单 0 命中、zh-CN catalog 也没有），整删就没处点开面板了。
#
# 文件是 JSONC（行首 `//` 注释 + 尾逗号），必须走 JSON 解析而不是正则；
# 产出是合法 JSON（无注释、无尾逗号）。
MENU_KEEP_IDS="setup.horizon install.ai.dictation setup.default.agent.gemini remove.dictation"

# 把 $1 精简成 $2（$2 为空则只统计不写）。stdout 打 "kept=N dropped=M"；
# 解析失败打 "parsefail"；已经是最小集打 "nochange"。
prune_menu_clone() {
  python3 - "$1" "${2:-}" "$MENU_KEEP_IDS" <<'MENUPY'
import json, re, sys

src, dst, keep_raw = sys.argv[1], sys.argv[2], sys.argv[3]
keep = [k for k in keep_raw.split() if k]

raw = open(src, encoding="utf-8").read()
# 与上游 MenuModel.js 的 stripJsonc 同构：删行首 // 注释、删 , 后的 } / ]。
stripped = re.sub(r"^\s*//[^\n]*(\n|$)", "", raw, flags=re.M)
stripped = re.sub(r",(\s*[}\]])", r"\1", stripped)
try:
    data = json.loads(stripped)
except ValueError:
    print("parsefail")
    sys.exit(0)
if not isinstance(data, dict):
    print("parsefail")
    sys.exit(0)

kept = {k: data[k] for k in keep if k in data}
dropped = [k for k in data if k not in kept]
if not dropped:
    print("nochange")
    sys.exit(0)
if dst:
    with open(dst, "w", encoding="utf-8") as fh:
        json.dump(kept, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
print("kept=%d dropped=%d" % (len(kept), len(dropped)))
MENUPY
}

migrate_menu_clone() {
  local bak tmp="" res kept dropped
  if [ ! -f "$MENU_CLONE" ]; then
    note "跳过：没有 $MENU_CLONE"
    return 0
  fi
  [ "$DRY" -eq 1 ] || tmp=$(mktemp -- "$MENU_CLONE.XXXXXX") \
    || { say "  mktemp 失败，中止"; FAIL=1; return 1; }
  res=$(prune_menu_clone "$MENU_CLONE" "$tmp")
  case "$res" in
    parsefail) rm -f -- "$tmp"; say "  解析失败，原文件未动：$MENU_CLONE"; return 0 ;;
    nochange)  rm -f -- "$tmp"; note "无需改动：$MENU_CLONE 已只有用户自加条目"; return 0 ;;
  esac
  kept=${res#kept=}; kept=${kept%% *}
  dropped=${res##*dropped=}
  todo
  if [ "$DRY" -eq 1 ]; then
    rm -f -- "$tmp"
    if [ "$kept" -eq 0 ]; then
      note "[dry-run] 旧中文菜单副本无用户自加条目，将整个删除（先备份 .bak-<时间戳>）"
    else
      note "[dry-run] 将精简旧中文菜单克隆：保留 $kept 条用户自加，其余交给 0.4.5 原生（先备份 .bak-<时间戳>）"
    fi
    return 0
  fi
  # 产出必须能过 JSON 校验再落盘（JSONC → JSON，不能留注释或尾逗号）。
  if ! jq -e . "$tmp" >/dev/null 2>&1; then
    rm -f -- "$tmp"
    say "  精简结果不是合法 JSON，原文件未动：$MENU_CLONE"; FAIL=1; return 1
  fi
  bak=$(backup_file "$MENU_CLONE") || { rm -f -- "$tmp"; say "  备份失败，中止"; FAIL=1; return 1; }
  # 一条都不剩（文件里没有那 4 条用户自加项）→ 整个删掉，比留个空 {} 干净。
  if [ "$kept" -eq 0 ]; then
    rm -f -- "$tmp"
    if rm -f -- "$MENU_CLONE"; then
      note "旧中文菜单副本没有用户自加条目，已整个删除（备份 $bak），全部交给 0.4.5 原生中文菜单"
    else
      say "  删除失败：$MENU_CLONE"; FAIL=1
    fi
    return 0
  fi
  chmod --reference="$MENU_CLONE" "$tmp" 2>/dev/null
  if mv -f -- "$tmp" "$MENU_CLONE"; then
    note "已精简旧中文菜单克隆（备份 $bak）：保留 $kept 条用户自加、丢弃 $dropped 条冗余，其余交给 0.4.5 原生中文菜单"
  else
    rm -f -- "$tmp"; say "  写回失败：$MENU_CLONE"; FAIL=1
  fi
}

# ---- ⑤ bindings.lua 里 omarchy-zh-cn 的 marker 块 --------------------------
# 按 marker 精确删（含首尾两行），其它行一字不动。本插件自己也用 marker 块
# （`-- horizon.setup:xxx` … `-end`），前缀不同，故不会误伤；块里万一嵌着
# horizon.setup 行也原样放回，写完再核一遍计数，少了就从备份还原。
# marker 不成对时不动文件并报错，绝不猜边界。

# 把 zh 块从 $1 剥到 $2；块内 horizon.setup 行保留。成功时 stderr 打保留行数。
strip_zh_blocks() {
  awk '
    /^[[:space:]]*--[[:space:]]*>>>[[:space:]]*omarchy-zh-cn[[:space:]]*$/ {
      if (inblk) bad = 1
      inblk = 1; nb = 0; inh = 0; next
    }
    /^[[:space:]]*--[[:space:]]*<<<[[:space:]]*omarchy-zh-cn[[:space:]]*$/ {
      if (!inblk) { bad = 1; next }
      for (i = 1; i <= nb; i++) if (keep[i]) { print buf[i]; saved++ }
      inblk = 0; next
    }
    inblk {
      buf[++nb] = $0
      if ($0 ~ /^[[:space:]]*--[[:space:]]*horizon\.setup:/) {
        keep[nb] = 1
        if ($0 ~ /[[:space:]]*-end[[:space:]]*$/) inh = 0; else inh = 1
      } else keep[nb] = inh
      next
    }
    { print }
    END { if (inblk || bad) exit 3; if (saved) printf "%d\n", saved > "/dev/stderr" }
  ' "$1" > "$2" 2>"$2.kept"
}

migrate_bindings_blocks() {
  local n bak tmp kept before after
  if [ ! -f "$BINDINGS" ]; then
    note "跳过：没有 $BINDINGS"
    return 0
  fi
  n=$(grep -cE '^[[:space:]]*--[[:space:]]*>>>[[:space:]]*omarchy-zh-cn[[:space:]]*$' "$BINDINGS" || true)
  if [ "${n:-0}" -eq 0 ]; then
    # 只剩孤立的结尾 marker 说明文件被人手改过；不是本脚本的块，不动，但别报「干净」。
    if grep -qE '^[[:space:]]*--[[:space:]]*<<<[[:space:]]*omarchy-zh-cn[[:space:]]*$' "$BINDINGS"; then
      say "  注意：bindings.lua 里有孤立的 -- <<< omarchy-zh-cn，无对应开头；未改动，请人工确认"
    else
      note "无需改动：bindings.lua 里没有 omarchy-zh-cn 块"
    fi
    return 0
  fi
  todo
  if [ "$DRY" -eq 1 ]; then
    note "[dry-run] 将删除 $n 个 omarchy-zh-cn marker 块（先备份 .bak-<时间戳>），SUPER+K 恢复 Omarchy 原生"
    return 0
  fi
  bak=$(backup_file "$BINDINGS") || { say "  备份失败，中止"; FAIL=1; return 1; }
  tmp=$(mktemp -- "$BINDINGS.XXXXXX") || { say "  mktemp 失败，中止"; FAIL=1; return 1; }
  if ! strip_zh_blocks "$BINDINGS" "$tmp"; then
    rm -f -- "$tmp" "$tmp.kept"
    say "  marker 不成对，未改动 $BINDINGS（备份保留在 $bak）"
    FAIL=1
    return 1
  fi
  kept=$(cat "$tmp.kept" 2>/dev/null); rm -f -- "$tmp.kept"
  chmod --reference="$BINDINGS" "$tmp" 2>/dev/null
  mv -f -- "$tmp" "$BINDINGS" || { rm -f -- "$tmp"; say "  写回失败"; FAIL=1; return 1; }
  # 事后校验：horizon.setup 标记行数必须不减，少了就从备份还原。
  before=$(grep -c 'horizon.setup:' "$bak" 2>/dev/null || echo 0)
  after=$(grep -c 'horizon.setup:' "$BINDINGS" 2>/dev/null || echo 0)
  if [ "${after:-0}" -lt "${before:-0}" ]; then
    cp -p -- "$bak" "$BINDINGS"
    say "  horizon.setup 标记从 $before 掉到 $after，已从备份还原 $BINDINGS"
    FAIL=1
    return 1
  fi
  note "已删除 $n 个 omarchy-zh-cn 块（备份：$bak）；SUPER+K 恢复 Omarchy 原生"
  [ -z "${kept:-}" ] || note "块内保留了 $kept 行 horizon.setup 绑定（未误伤）"
}

# ---- ⑥ ~/.local/bin 的三个旧脚本（名字精确匹配，逐个校验）-----------------
migrate_bin_scripts() {
  local name p found=0
  if [ ! -d "$BIN_ROOT" ]; then
    note "跳过：没有 $BIN_ROOT"
    return 0
  fi
  for name in $ZH_SCRIPTS; do
    p=$BIN_ROOT/$name
    [ -e "$p" ] || [ -L "$p" ] || continue
    found=$((found + 1))
    remove_path "$p" "$BIN_ROOT" ""
  done
  [ "$found" -gt 0 ] || note "无需改动：$BIN_ROOT 下没有那三个 omarchy-zh 脚本"
}

# ---- ⑦ post-update hook（脚本没了它会每次更新报 critical）------------------
migrate_post_update_hook() {
  if [ ! -e "$HOOK" ] && [ ! -L "$HOOK" ]; then
    note "跳过：没有 $HOOK"
    return 0
  fi
  remove_path "$HOOK" "$HOOK_DIR" ""
}

# ---- ⑧ ~/.local/state/omarchy-zh/ ------------------------------------------
migrate_zh_state() {
  if [ ! -d "$ZH_STATE" ] && [ ! -L "$ZH_STATE" ]; then
    note "跳过：没有 $ZH_STATE"
    return 0
  fi
  remove_path "$ZH_STATE" "$STATE_ROOT" ""
}

migrate_shell_json
migrate_plugin_dirs
migrate_zh_data
migrate_menu_clone
migrate_bindings_blocks
migrate_bin_scripts
migrate_post_update_hook
migrate_zh_state

if [ "$FAIL" -ne 0 ]; then
  say "有步骤失败，见上面输出。"
  exit 1
fi
if [ "$WORK" -eq 0 ]; then
  say "已是干净状态"
elif [ "$DRY" -eq 1 ]; then
  say "以上为预演；去掉 --dry-run 再跑一次即生效。"
else
  say "迁移完成。执行 omarchy-restart-shell 让 bar 与快捷键重载。"
fi
