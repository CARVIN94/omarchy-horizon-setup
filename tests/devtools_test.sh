#!/usr/bin/env bash
# horizon.setup — 开发环境开关测试。
#
# 核心闸门：**开关点击必须即时响应**。曾把「需要 root 的 hosts 写入」同步
# 放进开关，而 pkexec 的 polkit 认证在本机并不可靠 ⇒ 开关永远等不到输出，
# 面板点不动。这里用「永远挂起的 pkexec 桩」证明开关不被它阻塞。
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

# 隔离 git 配置与 hosts
export GIT_CONFIG_GLOBAL="$TMP/gitconfig"
export HST_FILE="$TMP/hosts"
export HST_SYS_BIN="$TMP/sys-bin/refresh"
export HST_SYS_UNIT_DIR="$TMP/sys-unit"
export DEV_HOSTS_ATTEMPT_TIMEOUT=30
export HST_TIMEOUT=3

# 桩 pkexec：**记录是否被调用**，然后挂起（模拟权限框无人应答）。
# 「记录被调用」是关键闸门 —— 曾把 hosts 写入写成 `bash -c 'hst_write 1'`，
# 新 shell 看不到已 source 的函数，会静默 command not found、pkexec 永不
# 被调用，而外壳 timeout 又把错误吞掉 ⇒ 一切看起来都像"权限框没弹出"。
mkdir -p "$TMP/bin"
cat > "$TMP/bin/pkexec" <<'STUB'
#!/usr/bin/env bash
echo called >> "$PKEXEC_LOG"
sleep 600
STUB
chmod +x "$TMP/bin/pkexec"
export PATH="$TMP/bin:$PATH"
export HST_PKEXEC="$TMP/bin/pkexec"
export PKEXEC_LOG="$TMP/pkexec.log"
: > "$PKEXEC_LOG"

source "$ROOT/lib/hosts.sh"
source "$ROOT/lib/devtools.sh"

printf '\n=== 1. 开关不得被 root 授权阻塞（回归闸门）===\n'
start=$(date +%s)
dev_write_ghproxy 1 >/dev/null 2>&1
elapsed=$(( $(date +%s) - start ))
if [ "$elapsed" -le "$((HST_TIMEOUT + 5))" ]; then
  ok "开启耗时 ${elapsed}s（未被卡死在权限框）"
else
  bad "开启耗时 ${elapsed}s —— 超出 HST_TIMEOUT+5"
fi
dev_ghproxy_on && ok "开关状态为开（git 配置已写）" || bad "开关状态应为开"

# ★ 最关键闸门：pkexec 必须真的被调用。若为 0，说明 hosts 写入根本没执行
#   （典型成因：bash -c 开新 shell 丢掉函数定义，命令静默 not found）。
pkcalls=$(grep -c '^called$' "$PKEXEC_LOG" 2>/dev/null || echo 0)
if [ "${pkcalls:-0}" -ge 1 ]; then
  ok "pkexec 真被调用 ${pkcalls} 次（hosts 写入非空转）"
else
  bad "pkexec 从未被调用 —— hosts 写入空转（函数没被找到）"
fi

printf '\n=== 2. git 部分：写入与清除 ===\n'
eq "insteadOf 已写入" \
   "$(git config --global --get "$DEV_GHPROXY_KEY")" "https://github.com/"
dev_write_ghproxy 0 >/dev/null 2>&1
if dev_ghproxy_on; then bad "关闭后应为关"; else ok "关闭后状态为关"; fi
eq "insteadOf 已清除" "$(git config --global --get "$DEV_GHPROXY_KEY" 2>/dev/null || echo -)" "-"
dev_write_ghproxy 1 >/dev/null 2>&1   # 恢复

printf '\n=== 3. 开关状态只看 git（不因 hosts 缺失而假关）===\n'
# hosts 未写入（pkexec 挂起），但开关仍应为开
printf '127.0.0.1 localhost\n' > "$HST_FILE"
if dev_ghproxy_on; then ok "hosts 未就绪时开关仍为开" || true; else bad "hosts 缺失把开关误判为关"; fi
hst_on && bad "hosts 未写入时 hst_on 应假" || ok "hosts 未就绪时 ghhosts=0"

printf '\n=== 4. 定时器检测 ===\n'
if dev_ghproxy_timer_on; then bad "未装时 timer 应假"; else ok "未装时 ghtimer=0"; fi

printf '\n---------------------------------------\n'
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
