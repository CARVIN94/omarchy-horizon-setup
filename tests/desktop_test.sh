#!/usr/bin/env bash
# horizon.setup 桌面海洋层测试。配置指向临时文件，绝不碰真机配置。
#
# 核心闸门：
#   ① 缺省即关：没有配置文件时状态是「关」，不是报错。
#   ② 幂等：同值重复写，文件字节不变。
#   ③ 状态即真相：写进去的值必须能原样读回来，不缓存不猜。
#   ④ fail-closed：未知鲨鱼种类/超长序列一律拒绝，文件一字不动。
#   ⑤ 原子写：写完不留临时文件（半截文件会让读者看到坏配置）。
#   ⑥ 脱钩：后端不得引用渲染实现（ocean/ 目录属另一个组件）。
#
# 运行：bash tests/desktop_test.sh
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected=[$3] actual=[$2]"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# 配置必须来自 TMP：否则测试会读写真实主目录，且用例互相污染。
export HORIZON_SETUP_CONF="$TMP/conf/horizon-setup.conf"
mkdir -p "$TMP/conf"

# shellcheck source=../lib/desktop.sh
source "$ROOT/lib/desktop.sh"

field() { desktop_rows | awk -F'\t' -v k="$1" '$1 == k { print $'"$2"' }'; }

printf '\n=== 1. 缺省即关 ===\n'
[ -f "$HORIZON_SETUP_CONF" ] && bad "前置：配置文件不应存在" || ok "前置：配置文件不存在"
if desktop_ocean_on; then bad "缺文件时必须是关"; else ok "缺文件时必须是关"; fi
eq "缺省阵容回落到 classic" "$(desktop_sharks)" "classic"
eq "行契约 4 列" "$(desktop_rows | awk -F'\t' '{print NF}' | sort -u | tr -d '\n')" "4"
eq "行契约含 ocean 与 sharks" "$(field ocean 2),$(field sharks 2)" "桌面海洋,鲨鱼阵容"

printf '\n=== 2. 状态即真相 ===\n'
desktop_write_ocean 1
if desktop_ocean_on; then ok "写 1 后为开"; else bad "写 1 后为开"; fi
eq "面板行同步为开" "$(field ocean 3)" "1"
desktop_write_ocean 0
if desktop_ocean_on; then bad "写 0 后为关"; else ok "写 0 后为关"; fi
eq "面板行同步为关" "$(field ocean 3)" "0"
# 关掉时保留整行而不是删键：「从没配过」与「明确关掉」必须可区分。
eq "关闭时保留 desktop_ocean=0 整行" \
  "$(grep -c '^desktop_ocean=0$' "$HORIZON_SETUP_CONF")" "1"

printf '\n=== 3. 幂等（字节不变）===\n'
desktop_write_ocean 1
cp "$HORIZON_SETUP_CONF" "$TMP/snap-once"
desktop_write_ocean 1
eq "二次写 ocean 字节不变" \
  "$(cmp -s "$TMP/snap-once" "$HORIZON_SETUP_CONF" && echo same)" "same"
desktop_write_sharks "classic,hammerhead,tiger"
cp "$HORIZON_SETUP_CONF" "$TMP/snap-sharks"
desktop_write_sharks "classic,hammerhead,tiger"
eq "二次写 sharks 字节不变" \
  "$(cmp -s "$TMP/snap-sharks" "$HORIZON_SETUP_CONF" && echo same)" "same"
eq "阵容原样读回" "$(desktop_sharks)" "classic,hammerhead,tiger"
# 两个键互不覆盖：写一个不得丢掉另一个。
desktop_write_ocean 0
eq "写 ocean 不影响 sharks" "$(desktop_sharks)" "classic,hammerhead,tiger"
desktop_write_ocean 1
eq "写回 ocean 后仍只有一行 desktop_ocean" \
  "$(grep -c '^desktop_ocean=' "$HORIZON_SETUP_CONF")" "1"

printf '\n=== 4. 白名单 fail-closed ===\n'
cp "$HORIZON_SETUP_CONF" "$TMP/before-bogus"
if desktop_write_sharks "bogus" 2>/dev/null; then
  bad "未知种类必须非 0 退出"
else
  ok "未知种类非 0 退出"
fi
eq "拒绝时文件一字不动" \
  "$(cmp -s "$TMP/before-bogus" "$HORIZON_SETUP_CONF" && echo same)" "same"
# 子串误判是这里最可能的错法："tiger" 是 "greathammer" 的一部分？不是，
# 但 "hammer" 是 "hammerhead" 的一部分——整词匹配才挡得住。
if desktop_write_sharks "hammer" 2>/dev/null; then
  bad "白名单必须整词匹配（hammer 不是种类）"
else
  ok "白名单整词匹配"
fi
if desktop_write_sharks "" 2>/dev/null; then
  bad "空阵容必须拒绝"
else
  ok "空阵容拒绝"
fi
if desktop_write_sharks "classic,,tiger" 2>/dev/null; then
  bad "空元素必须拒绝"
else
  ok "空元素拒绝"
fi
eq "多次拒绝后文件仍一字不动" \
  "$(cmp -s "$TMP/before-bogus" "$HORIZON_SETUP_CONF" && echo same)" "same"

printf '\n=== 5. 序列上限 ===\n'
desktop_write_sharks "classic,classic,classic,classic,classic,classic"
eq "6 条允许" "$(desktop_sharks | awk -F, '{print NF}')" "6"
cp "$HORIZON_SETUP_CONF" "$TMP/before-over"
if desktop_write_sharks "classic,classic,classic,classic,classic,classic,classic" 2>/dev/null; then
  bad "7 条必须拒绝"
else
  ok "7 条拒绝"
fi
eq "超限拒绝后文件一字不动" \
  "$(cmp -s "$TMP/before-over" "$HORIZON_SETUP_CONF" && echo same)" "same"

printf '\n=== 6. 原子写：不留临时文件 ===\n'
desktop_write_ocean 0
desktop_write_sharks "mako,nurse"
# 临时文件与目标同目录（跨文件系统 mv 不原子），故只数配置目录本身。
eq "配置目录只剩配置文件" "$(ls -A "$TMP/conf" | tr '\n' ' ' | sed 's/ $//')" "horizon-setup.conf"
desktop_write_ocean 1
desktop_write_sharks "classic"
eq "多次写后仍无残留" "$(ls -A "$TMP/conf" | tr '\n' ' ' | sed 's/ $//')" "horizon-setup.conf"

printf '\n=== 7. 脱钩：后端不引用渲染实现 ===\n'
hits=$(grep -n 'ocean/' "$ROOT/lib/desktop.sh" "$ROOT/setup.sh" || true)
eq "lib/desktop.sh 与 setup.sh 不出现 ocean/ 引用" "${hits:-<none>}" "<none>"

# 面板预设的 csv 是白名单的第二份拷贝：两边漂移就会「面板能选、脚本拒收」。
# 不 import QML（纯 shell 环境跑不了），改为把 csv 抠出来交给同一个校验函数。
bad_presets=$(grep -o 'csv: "[^"]*"' "$ROOT/DesktopTab.qml" | cut -d'"' -f2 \
  | while read -r csv; do desktop_sharks_valid "$csv" || printf '%s ' "$csv"; done)
eq "DesktopTab 预设全部通过白名单" "${bad_presets:-<none>}" "<none>"
eq "DesktopTab 预设数量非零" "$(grep -c 'csv: "' "$ROOT/DesktopTab.qml" | tr -d ' ')" "5"
# 首项必须等于后端缺省值：否则首次打开就落进「不匹配任何预设」的提示。
eq "首个预设等于缺省阵容" \
  "$(grep -o 'csv: "[^"]*"' "$ROOT/DesktopTab.qml" | head -1 | cut -d'"' -f2)" \
  "$DESKTOP_SHARK_DEFAULT"

printf '\n=== 8. setup.sh 契约 ===\n'
# 状态行按名取值：前五个字段的历史顺序不能被本层改动影响。
line=$(HORIZON_SETUP_CONF="$HORIZON_SETUP_CONF" bash "$ROOT/setup.sh" status 2>/dev/null)
eq "status 含 desktop 字段" "$(printf '%s' "$line" | tr ' ' '\n' | grep -c '^desktop=')" "1"
eq "status 含 sharks 字段" "$(printf '%s' "$line" | tr ' ' '\n' | grep -c '^sharks=')" "1"
eq "前五个字段顺序不变" \
  "$(printf '%s' "$line" | tr ' ' '\n' | head -5 | cut -d= -f1 | tr '\n' ' ' | sed 's/ $//')" \
  "keys scroll clip npm ghproxy"
eq "desktop 子命令输出 TAB 行" \
  "$(HORIZON_SETUP_CONF="$HORIZON_SETUP_CONF" bash "$ROOT/setup.sh" desktop 2>/dev/null | awk -F'\t' 'NF != 4 { n++ } END { print n + 0 }')" "0"

echo
echo "desktop_test: $PASS ok, $FAIL failed"
[ "$FAIL" -eq 0 ]
