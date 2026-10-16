#!/usr/bin/env bash
# horizon.setup — 开发环境开关测试。
#
# 核心闸门：**开关点击必须即时响应**，且 **hosts 写入绝非静默空转**。
#
# 历史教训（两个真 bug，都有对应闸门）：
#   ① 曾把「需要 root 的 hosts 写入」同步放进开关，polkit 认证不可靠 ⇒
#      面板 toggleProc 永远等不到输出，开关完全点不动。
#   ② 曾写成 `bash -c 'hst_write 1'`，新 shell 丢掉函数定义 ⇒
#      command not found 被 2>/dev/null 吞掉，pkexec/systemctl 从未被调用，
#      表现上像「权限框没弹出」。
# 两者都用桩件证明：成功路径必须真的触达提权动作；失败路径必须返回非 0
# 且给出可读原因，绝不允许「返回 0 却什么也没做」。
#
# 运行：bash tests/devtools_test.sh
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected=[$3] actual=[$2]"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export GIT_CONFIG_GLOBAL="$TMP/gitconfig"
export HST_FILE="$TMP/hosts"
export HST_SYS_UNIT="${HST_SYS_UNIT:-horizon-setup-hosts}"
export HST_SYS_BIN="$TMP/sys-bin/horizon-setup-hosts-refresh"
export HST_SYS_UNIT_DIR="$TMP/sys-unit"
mkdir -p "$HST_SYS_UNIT_DIR"
export PKEXEC_LOG="$TMP/pkexec.log"
export SYSTEMCTL_LOG="$TMP/systemctl.log"
: > "$PKEXEC_LOG"; : > "$SYSTEMCTL_LOG"

# 桩：记录调用。pkexec 再挂起（模拟权限框无人应答）。
mkdir -p "$TMP/bin"
cat > "$TMP/bin/pkexec" <<'STUB'
#!/usr/bin/env bash
echo called >> "$PKEXEC_LOG"
sleep 600
STUB
# 桩 systemctl：忠实模拟 root 侧 —— 收到 start <unit>@<inst>.service 就真跑
# 生成出来的刷新器（用 fixture 的 /etc/hosts 与 hosts 内容），这样断言「块是否
# 真的恢复」才是验真，而不是验一个只会 append 日志的空桩。
cat > "$TMP/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$SYSTEMCTL_LOG"
if [ "${1:-}" = "start" ] && [[ "${2:-}" == *@*.service ]]; then
  inst="${2##*@}"; inst="${inst%.service}"
  HORIZON_HOSTS_FILE="$HST_FILE" HORIZON_HOSTS_URL="file://$HST_FETCH" \
    /usr/bin/bash "$HST_REFRESH_SCRIPT" "$inst" >/dev/null 2>&1
fi
exit "${SYSTEMCTL_RC:-0}"
STUB
chmod +x "$TMP/bin/systemctl"
export PATH="$TMP/bin:$PATH"
export HST_PKEXEC="$TMP/bin/pkexec"
export HST_TIMEOUT=3
export HST_FETCH="$TMP/hosts-src.txt"
export HST_REFRESH_SCRIPT="$TMP/refresh.sh"

source "$ROOT/lib/hosts.sh"
source "$ROOT/lib/devtools.sh"
# 生成刷新器（与生产同一来源）
hst_refresh_script > "$HST_REFRESH_SCRIPT"
printf '20.205.243.166 github.com\n20.205.243.168 api.github.com\n' > "$HST_FETCH"

printf '\n=== 1. 开关即时响应（回归闸门：不被提权阻塞）===\n'
t0=$(date +%s)
dev_write_ghproxy 1 >/dev/null 2>&1
d=$(( $(date +%s) - t0 ))
[ "$d" -le 6 ] && ok "开启耗时 ${d}s（即时）" || bad "开启耗时 ${d}s —— 被提权阻塞"
dev_ghproxy_on && ok "开关状态为开（git 配置已写）" || bad "开关状态应为开"

printf '\n=== 2. hosts 未安装 ⇒ 失败要出声，且绝不回落 pkexec ===\n'
# 故意不装 root 侧
rm -rf "$TMP/sys-bin"
: > "$SYSTEMCTL_LOG"; : > "$PKEXEC_LOG"
err=$(dev_write_ghproxy 1 2>&1 >/dev/null)
if dev_ghproxy_on; then ok "hosts 失败不影响开关状态（git 已开）"; else bad "hosts 失败把开关带走了"; fi
echo "$err" | grep -q 'hosts-install-block' && ok "stderr 给出安装路径" || bad "stderr 缺安装指引" "$err"
eq "未安装时不调用 systemctl" "$(wc -l < "$SYSTEMCTL_LOG")" "0"
eq "未安装时不回落 pkexec" "$(wc -l < "$PKEXEC_LOG")" "0"

printf '\n=== 3. 已安装 ⇒ 真的触达 systemctl（防「静默空转」）===\n'
mkdir -p "$TMP/sys-bin"; printf '#!/bin/sh\n' > "$HST_SYS_BIN"; chmod +x "$HST_SYS_BIN"
printf '[Service]\nExecStart=%s %%i\n' "$HST_SYS_BIN" > "$HST_SYS_UNIT_DIR/${HST_SYS_UNIT}@.service"
printf '127.0.0.1 localhost\n%s\n1.2.3.4 github.com\n%s\n' "$HST_START" "$HST_END" > "$HST_FILE"
: > "$SYSTEMCTL_LOG"
dev_write_ghproxy 1 >/dev/null 2>&1
scalls=$(grep -c "^start ${HST_SYS_UNIT}@" "$SYSTEMCTL_LOG" 2>/dev/null || echo 0)
if [ "${scalls:-0}" -ge 1 ]; then
  ok "systemctl 真被调用（hosts 写入非空转）：$(head -1 "$SYSTEMCTL_LOG")"
else
  bad "systemctl 从未被调用 —— hosts 写入静默空转"
fi
# 仍然秒回
t0=$(date +%s); dev_write_ghproxy 1 >/dev/null 2>&1; d=$(( $(date +%s) - t0 ))
[ "$d" -le 6 ] && ok "已安装时开启仍耗时 ${d}s" || bad "已安装时耗时 ${d}s"

printf '\n=== 4. git 部分：写入与清除 ===\n'
eq "insteadOf 已写入" "$(git config --global --get "$DEV_GHPROXY_KEY")" "https://github.com/"
dev_write_ghproxy 0 >/dev/null 2>&1
if dev_ghproxy_on; then bad "关闭后应为关"; else ok "关闭后状态为关"; fi
eq "insteadOf 已清除" "$(git config --global --get "$DEV_GHPROXY_KEY" 2>/dev/null || echo -)" "-"
dev_write_ghproxy 1 >/dev/null 2>&1

printf '\n=== 5. 开关状态只看 git（不因 hosts 缺失而假关）===\n'
if dev_ghproxy_on; then ok "开关状态为开" || true; else bad "开关误判为关"; fi
hst_on && ok "hosts 块存在" || bad "hosts 块应存在"


printf '\n=== 6. 回归闸门：关了必须能开回来（off → on 恢复 hosts 块）===\n'
# 真 bug：ON 分支曾用 hst_refresh 抄近路，而 hst_refresh 首行
# `hst_on || return 0` 会让它在「块已被 OFF 删掉」时直接空转 ⇒ 关了就开不回。
mkdir -p "$TMP/sys-bin"; printf '#!/bin/sh\n' > "$HST_SYS_BIN"; chmod +x "$HST_SYS_BIN"
printf '[Service]\nExecStart=%s %%i\n' "$HST_SYS_BIN" > "$HST_SYS_UNIT_DIR/${HST_SYS_UNIT}@.service"

# 刷新器必须非空（曾在 source 之前生成 ⇒ 空文件 ⇒ 桩空转，测试假绿）
[ -s "$HST_REFRESH_SCRIPT" ] && ok "刷新器已生成（非空）" || bad "刷新器为空文件"
# 从「确定无块」起，避免沿用上一段留下的状态造成假绿
printf '127.0.0.1 localhost\n' > "$HST_FILE"
if hst_on; then bad "前置条件错：块本不该存在"; else ok "起点无块"; fi

# 初次 ON：块必须真的出现
dev_write_ghproxy 1 >/dev/null 2>&1
if hst_on; then ok "初次 ON 后块已写入"; else bad "初次 ON 后块不存在"; fi

# OFF：块必须被删掉
: > "$SYSTEMCTL_LOG"
dev_write_ghproxy 0 >/dev/null 2>&1
if hst_on; then bad "OFF 后块仍存在（没删掉）"; else ok "OFF 后块已移除"; fi
eq "OFF 调的是 @off" "$(grep -c "@off.service" "$SYSTEMCTL_LOG" 2>/dev/null || echo 0)" "1"

# ON：块必须回来（这就是被 bug 卡死的那一步）
: > "$SYSTEMCTL_LOG"
dev_write_ghproxy 1 >/dev/null 2>&1
if hst_on; then
  ok "OFF 后再 ON，块已恢复"
else
  bad "OFF 后再 ON，块没有恢复 —— 开关开不回来"
fi
eq "ON 调的是 @on（不是 @refresh）" "$(grep -c "@on.service" "$SYSTEMCTL_LOG")" "1"
eq "ON 没有误用 @refresh" "$(grep -c "@refresh.service" "$SYSTEMCTL_LOG")" "0"
# 开关状态本身也必须是开
if dev_ghproxy_on; then ok "开关状态为开"; else bad "开关状态应为开"; fi

printf '\n---------------------------------------\n'
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
