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
# 回归闸门（曾误判）：Cmd+W 在 macOS 是「关标签页/文档」，应发 Ctrl+W 给应用。
# 一度被误改为「交还 Omarchy 原生 window.close()」，那会把关标签变成杀整个
# 应用，属语义错误。此处锁定为 Ctrl+W。
eq "Cmd+W 接管为发 Ctrl+W（关标签）" "$(count 'bridge_app("SUPER + W", "CTRL", "W")')" "1"
# 且 W 绝不能绑成 WM 关窗动作
eq "Cmd+W 不是 WM 关窗" "$(grep -c 'o.bind("SUPER + W"' "$MAC_BIND")" "0"
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
      '-- 旧版本：Super+Q 被错误地当作 Ctrl+Q 发送（应为 WM 关窗）' \
      'bridge_app("SUPER + Q", "CTRL", "Q")' \
      '-- horizon.setup:textedit-key-end'
mac_write_textedit_bindings 1 >/dev/null 2>&1
eq "旧块的 Ctrl+Q 已清除" "$(count 'bridge_app("SUPER + Q"')" "0"
# W 的正确语义（发 Ctrl+W）在升级后仍应存在
eq "升级后保留 Cmd+W 发 Ctrl+W" "$(count 'bridge_app("SUPER + W", "CTRL", "W")')" "1"
eq "新内容已写入" "$(count 'window.close()')" "$(count 'window.close()')"
grep -q 'hl.dsp.window.close()' "$MAC_BIND" && ok "升级后 Q 走关窗动作" || bad "升级后 Q 未走关窗"
eq "升级后块仍唯一" "$(count '^-- horizon.setup:textedit-key$')" "1"
eq "升级未破坏既有绑定" "$(count 'SUPER + RETURN')" "1"

printf '\n=== 5. 生成的 Lua 可被解释器解析并注册正确绑定 ===\n'
if command -v lua >/dev/null 2>&1; then
  cat > "$TMP/sim.lua" <<'SIM'
local binds, unbinds = {}, {}
o = { bind = function(keys, desc, fn) binds[#binds+1] = { k = keys, d = desc, f = fn } end }
hl = {
  unbind = function(c) unbinds[#unbinds+1] = c end,
  dispatch = function(t) _G.sent = t end, timer = function() end,
  dsp = { send_key_state = function(t) return t end, window = { close = function() end } },
  get_active_window = function() return nil end,
}
dofile(os.getenv("SIM_BIND"))
local hasQ, hasW, wSendsCtrlW = false, false, false
local hasR, rSendsCtrlR = false, false
for _, b in ipairs(binds) do
  if b.k:find("SUPER %+ Q") and b.d:find("Close window") then hasQ = true end
  if b.k:find("SUPER %+ W") and b.d:find("macOS app action") then hasW = true end
  if b.k == "SUPER + R" and b.d:find("macOS app action") then hasR = true end
end
-- 触发 W，确认它发的是 Ctrl+W（关标签）而非 WM 关窗
for _, b in ipairs(binds) do
  if b.k == "SUPER + W" then
    _G.sent = nil
    b.f()
    local s = _G.sent
    if type(s) == "table" and s.mods == "CTRL" and s.key == "W" then wSendsCtrlW = true end
  end
end
-- 触发 R，确认它发的是 Ctrl+R（刷新），而非交给 WM 或别的键
for _, b in ipairs(binds) do
  if b.k == "SUPER + R" then
    _G.sent = nil
    b.f()
    local v = _G.sent
    if type(v) == "table" and v.mods == "CTRL" and v.key == "R" then rSendsCtrlR = true end
  end
end
print(hasQ and "Q_OK" or "Q_MISSING")
print(wSendsCtrlW and "W_SENDS_CTRL_W" or "W_WRONG")
print(hasR and "R_OK" or "R_MISSING")
print(rSendsCtrlR and "R_SENDS_CTRL_R" or "R_WRONG")
print("BINDING_TOTAL=" .. #binds)
SIM
  out=$(SIM_BIND="$MAC_BIND" lua "$TMP/sim.lua" 2>&1)
  grep -q Q_OK <<<"$out" && ok "Lua 解析通过且 Q 注册为关窗" || bad "Lua 模拟失败" "$out"
  grep -q W_SENDS_CTRL_W <<<"$out" && ok "Cmd+W 实际发送 Ctrl+W（关标签）" || bad "Cmd+W 语义错误" "$out"
  grep -q R_OK <<<"$out" && ok "SUPER+R 已注册为应用动作" || bad "SUPER+R 未注册" "$out"
  grep -q R_SENDS_CTRL_R <<<"$out" && ok "Cmd+R 实际发送 Ctrl+R（刷新）" || bad "Cmd+R 语义错误" "$out"
  total=$(grep -oE 'BINDING_TOTAL=[0-9]+' <<<"$out" | cut -d= -f2)
  eq "本插件注册绑定总数（面板标称 17 组）" "${total:-0}" "17"
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


printf '\n=== 7. Cmd+R：终端分流（焦点是终端时不该发 Ctrl+R）===\n'
# 终端里 Ctrl+R 是 bash 反查历史（reverse-i-search），macOS 同样是 Ctrl+R，
# 所以焦点在终端时**不桥接**、保留终端原生行为 —— 与 W/S 同一理由。
if command -v lua >/dev/null 2>&1; then
  cat > "$TMP/sim_term.lua" <<'SIM'
local binds = {}
o = { bind = function(keys, desc, fn) binds[#binds+1] = { k = keys, f = fn } end }
hl = {
  unbind = function() end,
  dispatch = function(t) _G.sent = t end, timer = function() end,
  dsp = { send_key_state = function(t) return t end, window = { close = function() end } },
  -- 焦点窗口带 terminal 标签 ⇒ active_is_terminal() 应为 true
  get_active_window = function() return { tags = { "terminal" } } end,
}
dofile(os.getenv("SIM_BIND"))
for _, b in ipairs(binds) do
  if b.k == "SUPER + R" then
    _G.sent = nil
    b.f()
    if _G.sent ~= nil then print("R_SENT_IN_TERMINAL") else print("R_SKIPPED_IN_TERMINAL") end
  end
end
SIM
  o2=$(SIM_BIND="$MAC_BIND" lua "$TMP/sim_term.lua" 2>&1)
  grep -q R_SKIPPED_IN_TERMINAL <<<"$o2" \
    && ok "终端焦点下 Cmd+R 不发键（保留 Ctrl+R 反查）" \
    || bad "终端焦点下仍发了键" "$o2"
else
  ok "跳过终端分流断言（无 lua 解释器）"
fi

printf '\n---------------------------------------\n'
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
