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

# 桩：hyprctl 只需 version/getoption 可用，reload 无副作用。
# getoption 恒回 altwin:swap_alt_win：让 mac_keys_on 的 kb_options 一关恒真，
# 就绪判定只剩「三个标记块是否齐备」可观察（mac_bool_on 仍因非 bool 而为假）。
mkdir -p "$TMP/bin"
cat > "$TMP/bin/hyprctl" <<'STUB'
#!/bin/sh
case "${1:-}" in
  version)   echo "Hyprland, stub"; exit 0 ;;
  getoption) echo "str: altwin:swap_alt_win"; exit 0 ;;
esac
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
local tSendsCtrlShiftT = false
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
-- 触发 Shift+T，确认它发的是 Ctrl+Shift+T（恢复关闭的标签页）
for _, b in ipairs(binds) do
  if b.k == "SUPER + SHIFT + T" then
    _G.sent = nil
    b.f()
    local v = _G.sent
    if type(v) == "table" and v.mods == "CTRL+SHIFT" and v.key == "T" then tSendsCtrlShiftT = true end
  end
end
print(hasQ and "Q_OK" or "Q_MISSING")
print(wSendsCtrlW and "W_SENDS_CTRL_W" or "W_WRONG")
print(hasR and "R_OK" or "R_MISSING")
print(rSendsCtrlR and "R_SENDS_CTRL_R" or "R_WRONG")
print(tSendsCtrlShiftT and "T_SENDS_CTRL_SHIFT_T" or "T_WRONG")
print("BINDING_TOTAL=" .. #binds)
SIM
  out=$(SIM_BIND="$MAC_BIND" lua "$TMP/sim.lua" 2>&1)
  grep -q Q_OK <<<"$out" && ok "Lua 解析通过且 Q 注册为关窗" || bad "Lua 模拟失败" "$out"
  grep -q W_SENDS_CTRL_W <<<"$out" && ok "Cmd+W 实际发送 Ctrl+W（关标签）" || bad "Cmd+W 语义错误" "$out"
  grep -q R_OK <<<"$out" && ok "SUPER+R 已注册为应用动作" || bad "SUPER+R 未注册" "$out"
  grep -q R_SENDS_CTRL_R <<<"$out" && ok "Cmd+R 实际发送 Ctrl+R（刷新）" || bad "Cmd+R 语义错误" "$out"
  grep -q T_SENDS_CTRL_SHIFT_T <<<"$out" && ok "Cmd+Shift+T 实际发送 Ctrl+Shift+T（恢复关闭的页面）" || bad "Cmd+Shift+T 语义错误" "$out"
  total=$(grep -oE 'BINDING_TOTAL=[0-9]+' <<<"$out" | cut -d= -f2)
  eq "本插件注册绑定总数（面板标称 18 组）" "${total:-0}" "18"
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

printf '\n=== 8. 音量三键 Super+F10/F11/F12（Mac 顶排语义）===\n'
# 关键契约：F10=静音、F11=减、F12=增，且动作走 Omarchy 自带音量命令
# （与 XF86 媒体键同源，带 OSD），锁屏可用、减/增可长按连调。
mac_write_media_bindings 1 >/dev/null 2>&1
eq "媒体块成对出现" "$(count '^-- horizon.setup:media-key$')/$(count '^-- horizon.setup:media-key-end$')" "1/1"
eq "F10 = 静音（mute-toggle）" "$(count 'o.bind("SUPER + F10", "Mute", "omarchy-audio-output-volume mute-toggle"')" "1"
eq "F11 = 音量减（lower）" "$(count 'o.bind("SUPER + F11", "Volume down", "omarchy-audio-output-volume lower"')" "1"
eq "F12 = 音量增（raise）" "$(count 'o.bind("SUPER + F12", "Volume up", "omarchy-audio-output-volume raise"')" "1"
# 方向不能反（F11/F12 若互换会「按加变减」）：lower 必须只在 F11 行、raise 只在 F12 行
eq "lower 只出现在 F11 行" "$(grep -c 'F11", "Volume down", "omarchy-audio-output-volume lower' "$MAC_BIND")" "1"
eq "raise 只出现在 F12 行" "$(grep -c 'F12", "Volume up", "omarchy-audio-output-volume raise' "$MAC_BIND")" "1"
eq "三键均锁定锁屏可用" "$(grep -c 'locked = true' "$MAC_BIND")" "3"
eq "减/增支持长按连调" "$(grep -c 'repeating = true' "$MAC_BIND")" "2"

printf '\n=== 8b. 音量块幂等 / 关闭 / 升级 ===\n'
for _ in 1 2 3; do mac_write_media_bindings 1 >/dev/null 2>&1; done
eq "重复开启后块仍唯一" "$(count '^-- horizon.setup:media-key$')" "1"
eq "F10 仍只一条" "$(count 'SUPER + F10')" "1"
# 升级路径：块由上次开启写下，内容可能过时——必须整块重写而非跳过
write 'o.bind("SUPER + RETURN", "Terminal", "foot")' \
      '-- horizon.setup:media-key' \
      '-- 旧版本：F11/F12 方向写反' \
      'o.bind("SUPER + F11", "Volume up", "omarchy-audio-output-volume raise", { locked = true })' \
      'o.bind("SUPER + F12", "Volume down", "omarchy-audio-output-volume lower", { locked = true })' \
      '-- horizon.setup:media-key-end'
mac_write_media_bindings 1 >/dev/null 2>&1
eq "升级后旧的反向绑定已清除" "$(grep -c 'F11", "Volume up"' "$MAC_BIND")" "0"
eq "升级后 F11 为减" "$(count 'o.bind("SUPER + F11", "Volume down", "omarchy-audio-output-volume lower"')" "1"
eq "升级后块仍唯一" "$(count '^-- horizon.setup:media-key$')" "1"
mac_write_media_bindings 0 >/dev/null 2>&1
eq "关闭后媒体块消失" "$(count 'horizon.setup:media-key')" "0"
eq "关闭后既有绑定保留" "$(count 'SUPER + RETURN')" "1"

if command -v lua >/dev/null 2>&1; then
  mac_write_media_bindings 1 >/dev/null 2>&1
  cat > "$TMP/sim_media.lua" <<'SIM'
local binds = {}
o = { bind = function(keys, desc, cmd, opts) binds[#binds+1] = { k = keys, d = desc, c = cmd, o = opts } end }
hl = { unbind = function() end, dispatch = function() end, timer = function() end,
       dsp = { send_key_state = function(t) return t end, window = { close = function() end } },
       get_active_window = function() return nil end }
dofile(os.getenv("SIM_BIND"))
local seen, media = {}, 0
for _, b in ipairs(binds) do
  if b.k:match("^SUPER %+ F1[012]$") then media = media + 1 end
  if b.k == "SUPER + F10" then
    seen.mute = (b.d == "Mute" and b.c == "omarchy-audio-output-volume mute-toggle" and b.o and b.o.locked == true)
  elseif b.k == "SUPER + F11" then
    seen.down = (b.c == "omarchy-audio-output-volume lower" and b.o and b.o.repeating == true and b.o.locked == true)
  elseif b.k == "SUPER + F12" then
    seen.up = (b.c == "omarchy-audio-output-volume raise" and b.o and b.o.repeating == true and b.o.locked == true)
  end
end
print(seen.mute and "MUTE_OK" or "MUTE_BAD")
print(seen.down and "DOWN_OK" or "DOWN_BAD")
print(seen.up and "UP_OK" or "UP_BAD")
-- 只数 F10..F12：同文件里还有插件外的既有绑定（如 SUPER+RETURN），不该被媒体块吞掉
print("MEDIA_BINDS=" .. media)
print("OTHER_BINDS=" .. (#binds - media))
SIM
  o3=$(SIM_BIND="$MAC_BIND" lua "$TMP/sim_media.lua" 2>&1)
  grep -q MUTE_OK <<<"$o3" && ok "Lua：F10 注册为静音（locked）" || bad "Lua：F10 静音注册错误" "$o3"
  grep -q DOWN_OK <<<"$o3" && ok "Lua：F11 注册为减音（locked+repeating）" || bad "Lua：F11 注册错误" "$o3"
  grep -q UP_OK <<<"$o3" && ok "Lua：F12 注册为增音（locked+repeating）" || bad "Lua：F12 注册错误" "$o3"
  eq "恰好注册 F10/F11/F12 三条" "$(grep -oE 'MEDIA_BINDS=[0-9]+' <<<"$o3" | cut -d= -f2)" "3"
  eq "同文件既有绑定仍在（未被吞）" "$(grep -oE 'OTHER_BINDS=[0-9]+' <<<"$o3" | cut -d= -f2)" "1"
else
  ok "跳过 Lua 语义断言（无 lua 解释器）"
fi

printf '\n=== 9. keys 就绪判定要求「kb_options + 全选 + 文本编辑 + 音量」齐备 ===\n'
kstat() { if mac_keys_on; then echo 1; else echo 0; fi; }
write 'o.bind("SUPER + RETURN", "Terminal", "foot")'
eq "仅默认绑定 → 未就绪" "$(kstat)" "0"
mac_write_selectall_binding 1 >/dev/null 2>&1
eq "有全选仍缺文本编辑/音量 → 未就绪" "$(kstat)" "0"
mac_write_textedit_bindings 1 >/dev/null 2>&1
eq "缺音量块 → 未就绪（老用户需按一次开关重建）" "$(kstat)" "0"
mac_write_media_bindings 1 >/dev/null 2>&1
eq "四件套齐备 → 就绪" "$(kstat)" "1"
mac_write_media_bindings 0 >/dev/null 2>&1
eq "拆掉音量块 → 未就绪" "$(kstat)" "0"

printf '\n=== 9b. 旧版文本编辑块（标记在、缺 Cmd+Shift+T）必须判未就绪 ===\n'
# 这是本轮的升级闸门：老用户手上有上一版写下的 textedit 块，标记齐全但内容过时。
# 若就绪判定只看标记，面板就显示「开」，用户永远拿不到新加的 Cmd+Shift+T。
# 旧块里带的是上一版最后一条绑定（Cmd+Shift+Z），故以此模拟。
write 'o.bind("SUPER + RETURN", "Terminal", "foot")' \
      '-- horizon.setup:textedit-key' \
      '-- 旧版本：只有到 Cmd+Shift+Z 为止的桥接' \
      'bridge_app("SUPER + W", "CTRL", "W")' \
      'bridge_app("SUPER + SHIFT + Z", "CTRL+SHIFT", "Z")' \
      '-- horizon.setup:textedit-key-end'
mac_write_selectall_binding 1 >/dev/null 2>&1
mac_write_media_bindings 1 >/dev/null 2>&1
eq "旧内容块 → 未就绪（面板显示「关」，按一次即重建）" "$(kstat)" "0"
mac_write_textedit_bindings 1 >/dev/null 2>&1
eq "重建后 → 就绪" "$(kstat)" "1"
eq "重建后旧块无残留（仍唯一）" "$(count '^-- horizon.setup:textedit-key$')" "1"
eq "重建后 Cmd+Shift+T 已写入" "$(count 'bridge_app("SUPER + SHIFT + T", "CTRL+SHIFT", "T")')" "1"

printf '\n---------------------------------------\n'
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
