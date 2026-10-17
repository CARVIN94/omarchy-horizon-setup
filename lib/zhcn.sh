#!/usr/bin/env bash
# horizon.setup — 汉化管理：状态检测与重放。
#
# 三组目标：
#   omarchy-shell    Omarchy 系统汉化 —— bar 挂件从 omarchy.* 原版切到
#                    carvin.* 中文版（omarchy-zh-sync 重建的 22 个汉化插件）。
#                    检测即真相：实读 ~/.config/omarchy/shell.json 的 bar
#                    layout，可汉化挂件全部 carvin.* = applied、全 omarchy.* =
#                    clean、混合 = mismatch。
#   keystroke        evindor.keystroke 的显示文案（多张映射表聚合一行）
#   activity-monitor stappmus.activity-monitor 的显示文案
#
# 映射表资产在 ~/.local/share/omarchy-zh-cn/（与 omarchy-zh-sync 同生态）：
#   apply-zh.py     幂等应用器（check/apply/revert；失配整体拒绝，绝不半应用）
#   maps/*.json     显示文案映射表：精确片段 + 期望次数 + group 归属
#   patches/*.patch git diff 快照（留档）
#
# 设计原则与本插件其余部分一致——检测即真相：状态每次实读配置与映射表，
# 不维护状态副本。上游 git pull 把英文带回来即转 clean，重新汉化即可；
# 源码字面量被上游改动则报 mismatch，面板照实展示、绝不猜。
#
# 用法（被 setup.sh source，这里只定义函数）：
#   zhcn_rows                  # 每行一个组，TAB 分隔（见下）
#   zhcn_apply <group>         # 应用
#   zhcn_revert <group>        # 还原英文
#
# zhcn_rows 行契约（TAB 分隔 7 列）：
#   group  title  state  applied  clean  mismatch  total
# state ∈ missing|clean|applied|mismatch

ZH_ROOT="${ZH_ROOT:-$HOME/.local/share/omarchy-zh-cn}"
ZH_APPLY="${ZH_APPLY:-$ZH_ROOT/apply-zh.py}"
ZH_MAPS="${ZH_MAPS:-$ZH_ROOT/maps}"
ZH_SHELL_JSON="${ZH_SHELL_JSON:-$HOME/.config/omarchy/shell.json}"

# 可汉化的 bar 挂件集（omarchy-zh-sync 重建了 carvin.* 中文版的那些；
# keyboard-layout/workspaces 无中文版且无显示文案，不在列）。
ZH_SHELL_WIDGETS="agents audio bluetooth clock indicators monitor network power system-update tray weather"

# ---- omarchy-shell 组：bar 挂件切换 -----------------------------------------

zh_shell_pairs() { # $1=方向 输出 "id" 行
  local w
  for w in $ZH_SHELL_WIDGETS; do
    case "$1" in
      to-zh) echo "omarchy.$w carvin.$w" ;;
      to-en) echo "carvin.$w omarchy.$w" ;;
    esac
  done
}

zh_shell_state() {
  local total=0 zh=0 id w
  [ -f "$ZH_SHELL_JSON" ] || { echo "0 0"; return; }
  for w in $ZH_SHELL_WIDGETS; do
    if jq -e --arg a "omarchy.$w" --arg b "carvin.$w" \
        '.bar.layout | [.left[], .center[], .right[]] | map(.id) | (index($a) != null or index($b) != null)' \
        "$ZH_SHELL_JSON" >/dev/null 2>&1; then
      total=$((total + 1))
      if jq -e --arg b "carvin.$w" \
          '.bar.layout | [.left[], .center[], .right[]] | map(.id) | index($b) != null' \
          "$ZH_SHELL_JSON" >/dev/null 2>&1; then
        zh=$((zh + 1))
      fi
    fi
  done
  echo "$total $zh"
}

# jq 原子改写 bar.layout 内的 id；disabledPlugins 等其它字段绝不动。
zh_shell_rewrite() { # $1=from $2=to
  [ -f "$ZH_SHELL_JSON" ] || { echo "missing $ZH_SHELL_JSON" >&2; return 2; }
  local tmp
  tmp=$(mktemp "${ZH_SHELL_JSON}.XXXXXX")
  jq --arg from "$1" --arg to "$2" '
    .bar.layout |= (
      with_entries(.value |= map(if .id == $from then .id = $to else . end))
    )' "$ZH_SHELL_JSON" > "$tmp" && mv "$tmp" "$ZH_SHELL_JSON"
}

zh_shell_apply() {
  local p from to n=0
  while read -r from to; do
    if jq -e --arg a "$from" '.bar.layout | [.left[], .center[], .right[]] | map(.id) | index($a) != null' "$ZH_SHELL_JSON" >/dev/null 2>&1; then
      zh_shell_rewrite "$from" "$to" || return 1
      n=$((n + 1))
    fi
  done < <(zh_shell_pairs to-zh)
  echo "bar widgets switched to Chinese: $n"
}

zh_shell_revert() {
  local from to n=0
  while read -r from to; do
    if jq -e --arg a "$from" '.bar.layout | [.left[], .center[], .right[]] | map(.id) | index($a) != null' "$ZH_SHELL_JSON" >/dev/null 2>&1; then
      zh_shell_rewrite "$from" "$to" || return 1
      n=$((n + 1))
    fi
  done < <(zh_shell_pairs to-en)
  echo "bar widgets switched back to English: $n"
}

# ---- 映射表组：按 group 聚合 -------------------------------------------------

zh_group_of() {
  local id
  id=$(jq -r '.id // empty' "$1")
  # keystroke-* 系列表（core/ui/align/ext/tests…）一律归 keystroke 组，
  # 无论各表 group 字段怎么写——多表聚合必须一行。
  case "$id" in
    keystroke-*) echo "keystroke"; return ;;
  esac
  jq -r '.group // .id' "$1"
}

zhcn_rows() {
  local total zh state
  # 第一行：Omarchy 系统汉化（bar 挂件切中文版）
  read -r total zh < <(zh_shell_state)
  if [ "$total" = "0" ]; then
    printf 'omarchy-shell\tOmarchy 系统汉化\tmissing\t0\t0\t0\t0\n'
  else
    if [ "$zh" = "0" ]; then state=clean
    elif [ "$zh" = "$total" ]; then state=applied
    else state=mismatch
    fi
    printf 'omarchy-shell\tOmarchy 系统汉化\t%s\t%s\t%s\t0\t%s\n' \
      "$state" "$zh" "$((total - zh))" "$total"
  fi

  # 映射表组：聚合各 group 的 check 计数
  [ -f "$ZH_APPLY" ] || return 0
  local -A g_title g_state_a g_state_c g_state_m g_total g_missing
  local -A g_seen
  local m id title group line root
  for m in "$ZH_MAPS"/*.json; do
    [ -f "$m" ] || continue
    group=$(zh_group_of "$m")
    title=$(jq -r '.title // .id' "$m")
    # 组标题优先用内建映射（keystroke 多表聚合必须一行一个名），
    # 未知组回退到组内首个表的 title。
    if [ -z "${g_seen[$group]:-}" ]; then
      g_seen[$group]=1
      case "$group" in
        keystroke) g_title[$group]="Keystroke" ;;
        activity-monitor) g_title[$group]="活动监视器" ;;
        *) g_title[$group]="$title" ;;
      esac
    fi
    root=$(jq -r '.root // empty' "$m")
    root="${root/#\~/$HOME}"
    if [ ! -d "$root" ]; then
      # 目标插件没装：计 missing（不是 mismatch——没坏，只是不在场）。
      g_missing[$group]=$(( ${g_missing[$group]:-0} + 1 ))
      g_total[$group]=$(( ${g_total[$group]:-0} + 1 ))
      continue
    fi
    line=$(python3 "$ZH_APPLY" check "$m" 2>/dev/null | head -1) || true
    [ -n "$line" ] || line="state=mismatch applied=0 clean=0 mismatch=0 total=0"
    local a c mm t
    a=$(sed -n 's/.*applied=\([0-9]*\).*/\1/p' <<<"$line")
    c=$(sed -n 's/.*clean=\([0-9]*\).*/\1/p' <<<"$line")
    mm=$(sed -n 's/.*mismatch=\([0-9]*\).*/\1/p' <<<"$line")
    t=$(sed -n 's/.*total=\([0-9]*\).*/\1/p' <<<"$line")
    g_state_a[$group]=$(( ${g_state_a[$group]:-0} + ${a:-0} ))
    g_state_c[$group]=$(( ${g_state_c[$group]:-0} + ${c:-0} ))
    g_state_m[$group]=$(( ${g_state_m[$group]:-0} + ${mm:-0} ))
    g_total[$group]=$(( ${g_total[$group]:-0} + ${t:-0} ))
  done

  # 稳定行序：keystroke → activity-monitor → 其它按名字典序。
  local g ordered
  ordered=$(printf '%s\n' "${!g_seen[@]}" | sort | awk '
    $0 == "keystroke" { k = 1; next }
    $0 == "activity-monitor" { a = 1; next }
    { rest = rest $0 "\n" }
    END { if (k) print "keystroke"; if (a) print "activity-monitor"; printf "%s", rest }')
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    if [ "${g_state_m[$g]:-0}" -gt 0 ] \
       || { [ "${g_missing[$g]:-0}" -gt 0 ] && [ "$(( ${g_state_a[$g]:-0} + ${g_state_c[$g]:-0} ))" -gt 0 ]; }; then
      state=mismatch
    elif [ "${g_missing[$g]:-0}" -gt 0 ]; then state=missing
    elif [ "${g_state_c[$g]:-0}" -gt 0 ]; then state=clean
    else state=applied
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$g" "${g_title[$g]}" "$state" "${g_state_a[$g]:-0}" "${g_state_c[$g]:-0}" "${g_state_m[$g]:-0}" "${g_total[$g]:-0}"
  done <<< "$ordered"
}

zhcn_apply() {
  if [ "$1" = "omarchy-shell" ]; then zh_shell_apply; return; fi
  local m group n=0
  for m in "$ZH_MAPS"/*.json; do
    [ -f "$m" ] || continue
    group=$(zh_group_of "$m")
    [ "$group" = "$1" ] || continue
    python3 "$ZH_APPLY" apply "$m" || return 1
    n=$((n + 1))
  done
  [ "$n" -gt 0 ] || { echo "unknown group: $1" >&2; return 2; }
}

zhcn_revert() {
  if [ "$1" = "omarchy-shell" ]; then zh_shell_revert; return; fi
  local m group n=0
  for m in "$ZH_MAPS"/*.json; do
    [ -f "$m" ] || continue
    group=$(zh_group_of "$m")
    [ "$group" = "$1" ] || continue
    python3 "$ZH_APPLY" revert "$m" || return 1
    n=$((n + 1))
  done
  [ "$n" -gt 0 ] || { echo "unknown group: $1" >&2; return 2; }
}
