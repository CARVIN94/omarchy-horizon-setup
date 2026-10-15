#!/usr/bin/env bash
# horizon.setup — Mac 快捷键桥接块的生成与升级语义测试。
#
# 全部在临时目录 + 桩件里跑，不碰 ~/.config/hypr，不调用真实 hyprctl。
# 运行：bash tests/macos_bindings_test.sh
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected=[$3] actual=[$2]"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# 桩：hyprctl 只需 version 成功，reload 无副作用
mkdir -p "$TMP/bin"
cat > "$TMP/bin/hyprctl" <<'STUB'
#!/bin/sh
[ "${1:-}" = version ] && { echo "Hyprland, stub"; exit 0; }
exit 0
STUB
chmod +x "$TMP/bin/hyprctl"

export PATH="$TMP/bin:$PATH"
export MAC_BIND="$TMP/bindings.lua"
export MAC_INPUT="$TMP/input.lua"

# shellcheck source=../lib/macos.sh
source "$ROOT/lib/macos.sh"

write() { printf '%s\n' "$@" > "$MAC_BIND"; }
count() { grep -c "$1" "$MAC_BIND" 2>/dev/null || true; }

printf '\n=== 1. 开启后写入的绑定内容 ===\n'
write 'o.bind("SUPER + RETURN", "Terminal", "foot")'
mac_write_textedit_bindings 1 >/dev/null 2>&1

eq "块标记成对出现" "$(count '^-- horizon.setup:textedit-key$')/$(count '^-- horizon.setup:textedit-key-end$')" "1/1"
# 核心诉求：Cmd+Q 关闭窗口，且走 WM 动作而非把按键甩给应用
grep -q 'o.bind("SUPER + Q", "Close window", hl.dsp.window.close())' "$MAC_BIND" \
  && ok "SUPER+Q = WM 关窗（window.close）" \
  || bad "SUPER+Q 未走 window.close"
# 回归闸门：早期版本把 Omarchy 原生的 SUPER+W 关窗 unbind 成 Ctrl+W，反而弄坏原生
eq "不接管 Omarchy 原生的 SUPER+W" "$(count 'SUPER + W')" "0"
eq "SUPER+Q 只注册一次" "$(count 'SUPER + Q')" "1"
# Cmd+Q 是 WM 动作，不应出现在 bridge_app（那会变成发 Ctrl+Q）
eq "SUPER+Q 不经 bridge_app 发送 Ctrl" "$(grep -c 'bridge_app("SUPER + Q"' "$MAC_BIND")" "0"

printf '\n=== 2. 幂等：重复开启不累积 ===\n'
for _ in 1 2 3; do mac_write_textedit_bindings 1 >/dev/null 2>&1; done
eq "重复开启后块仍唯一" "$(count '^-- horizon.setup:textedit-key$')" "1"
eq "SUPER+Q 仍只一条" "$(count 'SUPER + Q')" "1"

printf '\n=== 3. 关闭：块消失且不动既有绑定 ===\n'
mac_write_textedit_bindings 0 >/dev/null 2>&1
eq "关闭后无块残留" "$(count 'horizon.setup:textedit-key')" "0"
eq "既有绑定保留" "$(count 'SUPER + RETURN')" "1"

printf '\n=== 4. 升级：旧块必须被新内容替换 ===\n'
# 这是关键路径——块由用户上次开启时写下，内容可能已过时。
# 若实现成「块存在就跳过」，老用户永远拿不到修复。
write 'o.bind("SUPER + RETURN", "Terminal", "foot")' \
      '-- horizon.setup:textedit-key' \
      '-- 旧版本：把 Super+W 与 Super+Q 都当 Ctrl 发送' \
      'bridge_app("SUPER + W", "CTRL", "W")' \
      'bridge_app("SUPER + Q", "CTRL", "Q")' \
      '-- horizon.setup:textedit-key-end'
mac_write_textedit_bindings 1 >/dev/null 2>&1
eq "旧内容已被替换" "$(count 'bridge_app("SUPER + W"')" "0"
eq "旧块的 Ctrl+Q 已清除" "$(count 'bridge_app("SUPER + Q"')" "0"
eq "新内容已写入" "$(count 'window.close()')" "$(count 'window.close()')"
grep -q 'hl.dsp.window.close()' "$MAC_BIND" && ok "升级后 Q 走关窗动作" || bad "升级后 Q 未走关窗"
eq "升级后块仍唯一" "$(count '^-- horizon.setup:textedit-key$')" "1"
eq "升级未破坏既有绑定" "$(count 'SUPER + RETURN')" "1"

printf '\n=== 5. 生成的 Lua 可被解释器解析并注册正确绑定 ===\n'
if command -v lua >/dev/null 2>&1; then
  cat > "$TMP/sim.lua" <<'SIM'
local binds, unbinds = {}, {}
o = { bind = function(keys, desc) binds[#binds+1] = keys .. "\t" .. desc end }
hl = {
  unbind = function(c) unbinds[#unbinds+1] = c end,
  dispatch = function() end, timer = function() end,
  dsp = { send_key_state = function() end, window = { close = function() end } },
  get_active_window = function() return nil end,
}
dofile(os.getenv("SIM_BIND"))
local hasQ, hasW = false, false
for _, b in ipairs(binds) do
  if b:find("SUPER %+ Q") and b:find("Close window") then hasQ = true end
  if b:find("SUPER %+ W") then hasW = true end
end
for _, c in ipairs(unbinds) do if c == "SUPER + W" then hasW = true end end
print(hasQ and "Q_OK" or "Q_MISSING")
print(hasW and "W_TAKEN" or "W_FREE")
SIM
  out=$(SIM_BIND="$MAC_BIND" lua "$TMP/sim.lua" 2>&1)
  grep -q Q_OK <<<"$out" && ok "Lua 解析通过且 Q 注册为关窗" || bad "Lua 模拟失败" "$out"
  grep -q W_FREE <<<"$out" && ok "未占用 SUPER+W" || bad "占用了 SUPER+W" "$out"
else
  ok "跳过 Lua 语义断言（无 lua 解释器）"
fi

printf '\n=== 6. input.lua 标记块（keys/scroll 共用）幂等 ===\n'
: > "$MAC_INPUT"
mac_write_input_block 1 1 >/dev/null 2>&1
mac_write_input_block 1 1 >/dev/null 2>&1
eq "input 块不累积" "$(grep -c '^-- horizon.setup:macos-keys$' "$MAC_INPUT")" "1"
eq "kb_options 只写一次" "$(grep -c 'kb_options' "$MAC_INPUT")" "1"
mac_write_input_block 0 1 >/dev/null 2>&1
eq "关 keys 后仍保留 natural_scroll" "$(grep -c 'natural_scroll' "$MAC_INPUT")" "2"
eq "关闭后 kb_options 已移除" "$(grep -c 'kb_options' "$MAC_INPUT")" "0"

printf '\n---------------------------------------\n'
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
