#!/usr/bin/env bash
# horizon.setup — 插件汉化：状态检测与重放。
#
# 汉化资产在 ~/.local/share/omarchy-zh-cn/（与 omarchy-zh-sync 同一生态）：
#   apply-zh.py     幂等应用器（check/apply/revert；失配整体拒绝，绝不半应用）
#   maps/*.json     显示文案映射表：精确片段 + 期望次数 + title
#   patches/*.patch git diff 快照（留档；升级冲突时可作 git apply --3way 参照）
#
# 设计原则与本插件其余部分一致——检测即真相：状态每次实读映射表与目标
# 文件，由 apply-zh.py check 判定，不维护状态副本。上游 git pull 后
# 英文回来即 clean，重新汉化即可；源码字面量被上游改动则报 mismatch，
# 面板照实展示、绝不猜。
#
# 用法（被 setup.sh source，这里只定义函数）：
#   zhcn_rows                  # 每行一张映射表，TAB 分隔（见下）
#   zhcn_apply <id>            # 应用
#   zhcn_revert <id>           # 还原英文
#
# zhcn_rows 行契约（TAB 分隔 7 列）：
#   id  title  state  applied  clean  mismatch  total
# state ∈ missing|clean|applied|mismatch

ZH_ROOT="${ZH_ROOT:-$HOME/.local/share/omarchy-zh-cn}"
ZH_APPLY="${ZH_APPLY:-$ZH_ROOT/apply-zh.py}"
ZH_MAPS="${ZH_MAPS:-$ZH_ROOT/maps}"

zh_map_path() { echo "$ZH_MAPS/$1.json"; }

zh_map_exists() { [ -f "$(zh_map_path "$1")" ]; }

zhcn_rows() {
  local m id title root line
  [ -f "$ZH_APPLY" ] || return 0
  for m in "$ZH_MAPS"/*.json; do
    [ -f "$m" ] || continue
    id=$(jq -r '.id // empty' "$m")
    [ -n "$id" ] || continue
    title=$(jq -r '.title // .id' "$m")
    root=$(jq -r '.root // empty' "$m")
    root="${root/#\~/$HOME}"
    if [ ! -d "$root" ]; then
      printf '%s\t%s\tmissing\t0\t0\t0\t0\n' "$id" "$title"
      continue
    fi
    # check 的首行形如 state=.. applied=.. clean=.. mismatch=.. total=..；
    # 失配时它还会输出 mismatch-detail 行并在 stderr 留痕，这里只取首行。
    line=$(python3 "$ZH_APPLY" check "$m" 2>/dev/null | head -1) || true
    [ -n "$line" ] || line="state=mismatch applied=0 clean=0 mismatch=0 total=0"
    line=${line//state=/}
    line=${line//applied=/}
    line=${line//clean=/}
    line=${line//mismatch=/}
    line=${line//total=/}
    printf '%s\t%s\t%s\n' "$id" "$title" "${line// /$'\t'}"
  done
}

zhcn_apply() {
  zh_map_exists "$1" || { echo "unknown map: $1" >&2; return 2; }
  python3 "$ZH_APPLY" apply "$(zh_map_path "$1")"
}

zhcn_revert() {
  zh_map_exists "$1" || { echo "unknown map: $1" >&2; return 2; }
  python3 "$ZH_APPLY" revert "$(zh_map_path "$1")"
}
