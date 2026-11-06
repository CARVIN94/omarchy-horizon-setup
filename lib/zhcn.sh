#!/usr/bin/env bash
# horizon.setup — 汉化管理：状态检测与重放。
#
# 三组目标（omasnap-ui 的实现不在本文件，见下）：
#   keystroke        evindor.keystroke 的显示文案（多张映射表聚合一行）
#   activity-monitor stappmus.activity-monitor 的显示文案
#   omasnap-ui       Omasnap 界面 —— 由 lib/omasnapzh.sh 提供（上游无 i18n，
#                    要改源码重编译，与映射表组不同层，但共用同一行契约）
#
# 注：Omarchy 自身（omarchy.* 挂件、菜单、通知等）的界面语言由 Omarchy 0.4.5
# 起的自带多语言接管（/usr/share/omarchy/default/i18n/*，Commons/I18n.qml +
# Translations.qml），本层不再做 bar 挂件切换。
#
# 但第三方插件不在此列：evindor.keystroke、stappmus.activity-monitor 上游
# 没有任何 i18n 设施（无 .ts/.qm、无 tr()），中文只能靠改源码实现，故映射表
# 组仍保留。
#
# 映射表资产随插件分发在 lib/（不再依赖任何外部共享目录）：
#   lib/apply-zh.py  幂等应用器（check/apply/revert；失配整体拒绝，绝不半应用）
#   lib/zh-maps/*.json 显示文案映射表：精确片段 + 期望次数 + group 归属
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
# 映射表组的 state ∈ missing|clean|applied|mismatch；
# omasnap-ui 行的 state ∈ missing|stock|zh|stale（由 lib/omasnapzh.sh 定义）。
# 面板 ZhcnTab.qml 按 id 路由，两组状态词不同但共用这 7 列。

# 资产位置从本文件自身定位，不依赖调用者的变量或当前目录：本文件就在 lib/ 下，
# 故 ZH_SELF 即资产目录。名字刻意独立，避免覆盖调用者（setup.sh）自己算出的根目录。
ZH_SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

ZH_APPLY="${ZH_APPLY:-$ZH_SELF/apply-zh.py}"
ZH_MAPS="${ZH_MAPS:-$ZH_SELF/zh-maps}"

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
  local state

  # Omasnap：上游无 i18n，走「源码打词表 + 重编译」，与映射表组不同层，
  # 但输出同一套 7 列契约，面板与 CLI 因此零改动。
  if declare -F omasnapzh_row >/dev/null; then
    omasnapzh_row
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
  # omasnap 不是映射表组：它要改源码并重新编译（约 3 分钟）。
  if [ "$1" = "omasnap-ui" ]; then omasnapzh_install; return; fi
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
  if [ "$1" = "omasnap-ui" ]; then omasnapzh_revert; return; fi
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
