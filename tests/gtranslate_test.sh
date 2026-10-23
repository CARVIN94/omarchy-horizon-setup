#!/usr/bin/env bash
# horizon.setup — Google 翻译 hosts 管理层测试。
#
# 被测对象与 hosts_test.sh 同构：lib/gtranslate.sh 只负责「生成 root 刷新器 +
# 生成 unit 文件 + 生成一次性安装块」，真正的 hosts 写入逻辑在 root 脚本里。
# 因此这里测两层：
#   A. root 刷新器脚本（fixture 化 hosts，桩 curl，零权限）
#   B. lib 侧的生成与调用（systemctl 用桩替换，只碰临时目录）
#
# 不联网（桩 curl 全接管）、不提权（从不真跑安装块）、不碰真实 /etc/hosts。
#
# 运行：bash tests/gtranslate_test.sh
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected=[$3] actual=[$2]"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export GT_FILE="$TMP/hosts"
export GT_CACHE="$TMP/cache"
export GT_SYS_UNIT_DIR="$TMP/sys-unit"
export GT_SYS_BIN="$TMP/sys-bin/refresh"

source "$ROOT/lib/gtranslate.sh"
gt_refresh_script > "$TMP/refresh.sh"
bash -n "$TMP/refresh.sh" && ok "root 刷新器语法可解析" || bad "root 刷新器语法错误"
ROOT_SCRIPT="$TMP/refresh.sh"
# 只取 case 之前的函数定义：刷新器末尾的 case 会 exit，直接 source 会带走进程。
awk '/^case /{exit} {print}' "$ROOT_SCRIPT" > "$TMP/refresh-fns.sh"

# 探活恒关的跑法：只测写块/清块/闸门，不碰网络。
run_off() {
  HORIZON_GT_PROBE=0 HORIZON_GT_FILE="$TMP/hosts" HORIZON_GT_CACHE="$TMP/cache" \
    /usr/bin/bash "$ROOT_SCRIPT" "$1" >"$TMP/out" 2>&1
  echo $?
}
new_hosts() { printf '%s\n' "$@" > "$TMP/hosts"; }
count_lines() { grep -c "$1" "$TMP/hosts" 2>/dev/null || true; }

printf '\n=== A. root 刷新器：写块 / 幂等 / 移除 ===\n'

# 探活关闭时，兜底用 DNS 那一条。用桩 getent 控制它，避免真解析。
mkdir -p "$TMP/bin"
cat > "$TMP/bin/getent" <<'STUB'
#!/usr/bin/env bash
# 只应答 translate.googleapis.com 的 ahostsv4 查询
case "$*" in
  *ahostsv4*translate.googleapis.com*) echo "203.0.113.7"; exit 0 ;;
esac
exit 2
STUB
chmod +x "$TMP/bin/getent"
export PATH="$TMP/bin:$PATH"

new_hosts "127.0.0.1 localhost"
rc=$(run_off on)
eq "on 返回 0" "$rc" "0"
eq "起始标记写入" "$(count_lines '^# horizon.setup:gtranslate$')" "1"
eq "结束标记写入" "$(count_lines '^# horizon.setup:gtranslate-end$')" "1"
eq "映射写入" "$(count_lines ' translate\.googleapis\.com$')" "1"
eq "原有行保留" "$(count_lines '^127.0.0.1 localhost$')" "1"

for _ in 1 2 3; do run_off on >/dev/null; done
eq "重复 on 后起始标记唯一" "$(count_lines '^# horizon.setup:gtranslate$')" "1"
eq "重复 on 后结束标记唯一" "$(count_lines '^# horizon.setup:gtranslate-end$')" "1"
eq "重复 on 后映射唯一" "$(count_lines ' translate\.googleapis\.com$')" "1"

rc=$(run_off off)
eq "off 返回 0" "$rc" "0"
eq "off 后无标记" "$(count_lines 'horizon.setup:gtranslate')" "0"
eq "off 后无映射" "$(count_lines 'translate\.googleapis\.com')" "0"
eq "off 后原有行保留" "$(count_lines '^127.0.0.1 localhost$')" "1"

# 关闭态 refresh 不应动手
new_hosts "127.0.0.1 localhost"
rc=$(run_off refresh)
eq "关闭态 refresh 返回 0" "$rc" "0"
eq "关闭态 refresh 不写块" "$(count_lines 'horizon.setup:gtranslate')" "0"

printf '\n=== B. 与 GitHub 块互不干扰（两个独立区间）===\n'
# 关键回归：GitHub 那套的 strip_block 会清「外部遗留块」，若本模块的块
# 被它误判成遗留块，两个开关就会互相踩掉对方的映射。
new_hosts "127.0.0.1 localhost" \
  "# horizon.setup:github-hosts" "140.82.113.3 github.com" "# horizon.setup:github-hosts-end"
run_off on >/dev/null
eq "GitHub 块仍在" "$(count_lines '^# horizon.setup:github-hosts$')" "1"
eq "GitHub 映射仍在" "$(count_lines '^140\.82\.113\.3 github\.com$')" "1"
eq "翻译块已写" "$(count_lines '^# horizon.setup:gtranslate$')" "1"

run_off off >/dev/null
eq "翻译块已清" "$(count_lines 'horizon.setup:gtranslate')" "0"
eq "清翻译块不动 GitHub 块" "$(count_lines '^# horizon.setup:github-hosts$')" "1"
eq "清翻译块不动 GitHub 映射" "$(count_lines '^140\.82\.113\.3 github\.com$')" "1"

# 反向：GitHub 刷新器不得吃掉翻译块
new_hosts "127.0.0.1 localhost"
run_off on >/dev/null
source "$ROOT/lib/hosts.sh"
printf 'file://%s/fetch.txt\n' "$TMP" > /dev/null
printf '140.82.113.3 github.com\n' > "$TMP/fetch.txt"
HST_FILE="$TMP/hosts" HORIZON_HOSTS_URL="file://$TMP/fetch.txt" HORIZON_HOSTS_PROBE=0 \
  /usr/bin/bash <(hst_refresh_script) on >"$TMP/out2" 2>&1 || true
eq "GitHub 刷新后翻译块仍在" "$(count_lines '^# horizon.setup:gtranslate$')" "1"
eq "GitHub 刷新后翻译映射仍在" "$(count_lines ' translate\.googleapis\.com$')" "1"

printf '\n=== C. 安全闸门（脏内容必须拒绝）===\n'
# 注意：探活路径本身产不出脏内容——probe_one 只认严格等于期望译文的应答，
# 注入串根本活不到写盘那一步（D 段已锁住）。所以脏值真正的入口是
# **DNS 兜底路径**：getent 若被污染/劫持，返回的东西会直接进 hosts。
# 本段就从这个入口注入，验证 valid_line 第二道防线。
new_hosts "127.0.0.1 localhost"
mkdir -p "$TMP/dbin"
cat > "$TMP/bin/getent" <<'EVILGETENT'
#!/usr/bin/env bash
case "$*" in
  *ahostsv4*translate.googleapis.com*) printf '5.6.7.8; rm -rf /tmp/should-not-exist\n' ;;
esac
exit 0
EVILGETENT
chmod +x "$TMP/bin/getent"
# 探活全灭（喂空桩 curl）⇒ 走兜底 ⇒ 兜底值来自被污染的 getent
cat > "$TMP/dbin/curl" <<'EMPTYCURL'
#!/usr/bin/env bash
exit 0
EMPTYCURL
chmod +x "$TMP/dbin/curl"
: > "$TMP/cache"
HORIZON_GT_PROBE=1 PATH="$TMP/dbin:$TMP/bin:$PATH" HORIZON_GT_FILE="$TMP/hosts" \
  HORIZON_GT_CACHE="$TMP/cache" /usr/bin/bash "$ROOT_SCRIPT" on >"$TMP/out" 2>&1
rc=$?
[ "$rc" != "0" ] && ok "被污染的兜底值被拒绝（valid_line 闸门生效）" \
  || bad "脏兜底值竟被写入"
eq "hosts 未被污染" "$(count_lines 'rm -rf')" "0"

printf '\n=== D. 探活判据：只认「真拿到译文」 ===\n'
# 这是本模块最重要的一条：绝大多数 IP 会回 200/404 但内容是 Google 错误页，
# 只看状态码会把它们当活节点写进 hosts，翻译依旧坏（本机实测踩过）。
cat > "$TMP/dbin/curl" <<'STUBCURL'
#!/usr/bin/env bash
# PROBE_GOOD 里的 IP → 真译文；PROBE_BAD 里的 IP → 200 但内容不是译文
for b in "$@"; do case "$b" in *:443:*) ip=${b##*:} ;; esac; done
if grep -qxF "$ip" "${PROBE_GOOD:-/dev/null}" 2>/dev/null; then
  printf '["你好"]'; exit 0
fi
if grep -qxF "$ip" "${PROBE_BAD:-/dev/null}" 2>/dev/null; then
  # 真机形态：HTTP 200，但内容是 Google 的错误页
  printf '<!DOCTYPE html><html><title>Error 404 (Not Found)!!1</title></html>'; exit 0
fi
exit 0
STUBCURL
chmod +x "$TMP/dbin/curl"

# 让候选池可预期：桩 curl 之外，把 getent 也固定成一个 /24
cat > "$TMP/bin/getent" <<'STUB2'
#!/usr/bin/env bash
case "$*" in
  *ahostsv4*translate.googleapis.com*) echo "192.0.2.5"; exit 0 ;;
esac
exit 2
STUB2
chmod +x "$TMP/bin/getent"

new_hosts "127.0.0.1 localhost"
printf '192.0.2.5\n192.0.2.6\n' > "$TMP/good"
printf '192.0.2.7\n' > "$TMP/bad"
: > "$TMP/cache"
# 种子段用 HORIZON_GT_SEED 收窄到测试段：否则真实种子（108.177.x 等）会先
# 占满 MAX_PROBE 预算，桩 IP 根本轮不到探，测的就不是判据而是截断顺序。
GTSEED="192.0.2"
HORIZON_GT_SEED="$GTSEED" HORIZON_GT_PROBE=1 PROBE_GOOD="$TMP/good" PROBE_BAD="$TMP/bad" \
  HORIZON_GT_MAX_PROBE=32 HORIZON_GT_JOBS=8 \
  PATH="$TMP/dbin:$PATH" HORIZON_GT_FILE="$TMP/hosts" HORIZON_GT_CACHE="$TMP/cache" \
  /usr/bin/bash "$ROOT_SCRIPT" on >"$TMP/out" 2>&1
eq "探活开启时 on 返回 0" "$?" "0"
eq "两个真命中都写入" "$(count_lines ' translate\.googleapis\.com$')" "2"
eq "真命中 192.0.2.5 写入" "$(count_lines '^192\.0\.2\.5 translate\.googleapis\.com$')" "1"
eq "真命中 192.0.2.6 写入" "$(count_lines '^192\.0\.2\.6 translate\.googleapis\.com$')" "1"
eq "只回错误页的 192.0.2.7 未写入" "$(
  count_lines '^192\.0\.2\.7 translate\.googleapis\.com$')" "0"

# 全灭：**不写块、返回非 0**。这是本模块最关键的一条语义——
# 兜底只能取 DNS 答案，而 DNS 答案实测就是不可用的（173.194.43.95 连测三次
# 全 DEAD）。若照样写块，块存在 ⇒ 状态位为真 ⇒ 面板显示「已开启」，
# 而翻译依旧坏，形成假绿。宁可保持关闭态 + 明确报错。
new_hosts "127.0.0.1 localhost"
: > "$TMP/good"; : > "$TMP/bad"; : > "$TMP/cache"
HORIZON_GT_SEED="$GTSEED" HORIZON_GT_PROBE=1 PROBE_GOOD="$TMP/good" PROBE_BAD="$TMP/bad" \
  PATH="$TMP/dbin:$PATH" HORIZON_GT_FILE="$TMP/hosts" HORIZON_GT_CACHE="$TMP/cache" \
  /usr/bin/bash "$ROOT_SCRIPT" on >"$TMP/out" 2>&1
rc=$?
[ "$rc" != "0" ] && ok "全灭时返回非 0（不静默成功）" || bad "全灭时竟返回 0"
eq "全灭时不写块（避免假绿）" "$(count_lines 'horizon.setup:gtranslate')" "0"
eq "全灭时无映射" "$(count_lines 'translate\.googleapis\.com')" "0"
grep -q '假绿' "$TMP/out" && ok "全灭时给出可读原因" || bad "全灭时无原因说明" "$(cat "$TMP/out")"

# 缓存里已有的存活 IP 会被优先复探（加速线索，但仍需重新过判据）
new_hosts "127.0.0.1 localhost"
printf '198.51.100.9\n' > "$TMP/cache"
printf '198.51.100.9\n' > "$TMP/good"
HORIZON_GT_SEED="198.51.100" HORIZON_GT_PROBE=1 PROBE_GOOD="$TMP/good" PROBE_BAD="$TMP/bad" \
  HORIZON_GT_MAX_PROBE=8 \
  PATH="$TMP/dbin:$PATH" HORIZON_GT_FILE="$TMP/hosts" HORIZON_GT_CACHE="$TMP/cache" \
  /usr/bin/bash "$ROOT_SCRIPT" on >"$TMP/out" 2>&1
eq "缓存线索的 IP 仍要复探后才写入" "$(count_lines '^198\.51\.100\.9 translate\.googleapis\.com$')" "1"

# 缓存里已不再可用的 IP 必须被剔除（不能因为「上次活」就照写）
new_hosts "127.0.0.1 localhost"
printf '198.51.100.9\n' > "$TMP/cache"
: > "$TMP/good"
HORIZON_GT_SEED="198.51.100" HORIZON_GT_PROBE=1 PROBE_GOOD="$TMP/good" PROBE_BAD="$TMP/bad" \
  PATH="$TMP/dbin:$PATH" HORIZON_GT_FILE="$TMP/hosts" HORIZON_GT_CACHE="$TMP/cache" \
  /usr/bin/bash "$ROOT_SCRIPT" on >"$TMP/out" 2>&1
eq "缓存里已失效的 IP 不再写入" "$(count_lines '^198\.51\.100\.9 translate\.googleapis\.com$')" "0"

# 种子段本身要能产出候选（否则「已知好段」这个修法等于没接上）。
# 注意不能用 PATH=/nonexistent 来屏蔽 getent：那会让 bash 自己都找不到，
# 连 candidates 都调不起来（本测试第一版就栽在这）。用空 getent 桩代替。
printf '#!/bin/bash\nexit 2\n' > "$TMP/bin/getent"
chmod +x "$TMP/bin/getent"
cand=$(HORIZON_GT_SEED="203.0.113" HORIZON_GT_PROBE=1 \
  PATH="$TMP/bin:/usr/bin:/bin" /usr/bin/bash -c 'source "$1"; deep_candidates' _ "$TMP/refresh-fns.sh" 2>/dev/null \
  | grep -c '^203\.0\.113\.')
if [ "${cand:-0}" -ge 254 ]; then ok "种子段展开出 ${cand} 个候选"; else bad "种子段未展开（${cand:-0}）"; fi

printf '\n=== E. 运行时路径：只走 systemctl，不再提权 ===\n'
cat > "$TMP/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$GT_ACTIONS"
exit 0
STUB
chmod +x "$TMP/bin/systemctl"
export GT_ACTIONS="$TMP/actions.log"

# E1. 未安装 ⇒ 明确报错，不回落 pkexec
printf '127.0.0.1 localhost\n' > "$GT_FILE"
rm -rf "$TMP/sys-bin" "$TMP/sys-unit"
: > "$GT_ACTIONS"
gt_installed && bad "未安装时 gt_installed 应为假" || ok "未安装时 gt_installed 为假"
rc=0; err=$(gt_write 1 2>&1) || rc=$?
[ "$rc" != "0" ] && ok "未安装时 gt_write 返回非 0" || bad "未安装时竟成功"
echo "$err" | grep -q 'gtranslate-install-block' && ok "错误提示给出安装命令" || bad "提示不含安装命令" "$err"
eq "未安装时不调用 systemctl" "$(wc -l < "$GT_ACTIONS")" "0"
echo "$err" | grep -qi 'pkexec' && bad "回落到 pkexec（不该）" || ok "未回落 pkexec"

# E2. 已安装 ⇒ 走 systemctl start <unit>@on/off
mkdir -p "$TMP/sys-bin" "$TMP/sys-unit"
printf '#!/bin/sh\n' > "$GT_SYS_BIN"; chmod +x "$GT_SYS_BIN"
printf '[Service]\nExecStart=%s %%i\n' "$GT_SYS_BIN" > "$GT_SYS_UNIT_DIR/${GT_SYS_UNIT}@.service"
gt_installed && ok "已安装时 gt_installed 为真" || bad "已安装时应为真"
: > "$GT_ACTIONS"
rc=0; gt_write 1 >/dev/null 2>&1 || rc=$?
eq "开启返回 0" "$rc" "0"
eq "开启调用 systemctl start @on" "$(cat "$GT_ACTIONS")" "start ${GT_SYS_UNIT}@on.service"
: > "$GT_ACTIONS"
rc=0; gt_write 0 >/dev/null 2>&1 || rc=$?
eq "关闭返回 0" "$rc" "0"
eq "关闭调用 systemctl start @off" "$(cat "$GT_ACTIONS")" "start ${GT_SYS_UNIT}@off.service"

# refresh 只在块已存在时动作
printf '127.0.0.1 localhost\n%s\n1.2.3.4 translate.googleapis.com\n%s\n' "$GT_START" "$GT_END" > "$GT_FILE"
: > "$GT_ACTIONS"
rc=0; gt_refresh >/dev/null 2>&1 || rc=$?
eq "刷新返回 0" "$rc" "0"
eq "刷新调用 systemctl start @refresh" "$(cat "$GT_ACTIONS")" "start ${GT_SYS_UNIT}@refresh.service"
printf '127.0.0.1 localhost\n' > "$GT_FILE"
: > "$GT_ACTIONS"
rc=0; gt_refresh >/dev/null 2>&1 || rc=$?
eq "关闭态刷新返回 0" "$rc" "0"
eq "关闭态刷新不调用 systemctl" "$(wc -l < "$GT_ACTIONS")" "0"

printf '\n=== F. 检测函数 ===\n'
new_hosts "127.0.0.1 localhost"
gt_on && bad "无块时 gt_on 应为假" || ok "无块时 gt_on 为假"
new_hosts "127.0.0.1 localhost" "$GT_START" "1.1.1.1 translate.googleapis.com" "$GT_END"
gt_on && ok "有块时 gt_on 为真" || bad "有块时 gt_on 应为真"
eq "gt_status 输出 gtranslate=1" "$(gt_status)" "gtranslate=1"
new_hosts "127.0.0.1 localhost"
eq "gt_status 输出 gtranslate=0" "$(gt_status)" "gtranslate=0"

printf '\n=== G. 一次性安装块：可审计 + 红线 ===\n'
block="$TMP/install-block.sh"
bash "$ROOT/setup.sh" gtranslate-install-block > "$block" 2>/dev/null
[ -s "$block" ] && ok "安装块已生成" || bad "安装块为空"
bash -n "$block" && ok "安装块语法可解析" || bad "安装块语法错误"

# 红线：块内不得引用插件目录（用户可写）
if grep -qE '\.config/omarchy|horizon-setup/setup\.sh|\.worktrees' "$block"; then
  bad "安装块引用了插件目录（红线）" "$(grep -nE '\.config/omarchy|\.worktrees' "$block" | head -2)"
else
  ok "安装块未引用插件目录"
fi

for needle in 'install -m 0755 -o root -g root' \
              'systemctl daemon-reload' \
              'systemctl enable --now horizon-setup-gtranslate.timer' \
              'systemctl start horizon-setup-gtranslate@on.service'; do
  grep -qF "$needle" "$block" && ok "安装块含 [$needle]" || bad "安装块缺 [$needle]"
done
grep -q '^sudo -v$' "$block" && ok "开头 sudo -v（只输一次密码）" || bad "缺 sudo -v"

# 单一事实源：块内刷新器必须与 lib 生成物逐字节一致
gt_refresh_script > "$TMP/expected-refresh.sh"
awk '/^REFRESH_EOF$/{exit} found{print} /<<.REFRESH_EOF.$/{found=1}' "$block" > "$TMP/actual-refresh.sh"
if diff -q "$TMP/expected-refresh.sh" "$TMP/actual-refresh.sh" >/dev/null 2>&1; then
  ok "块内刷新器与 lib 生成物一致（单一事实源）"
else
  bad "块内刷新器与 lib 生成物不一致（出现第二份）"
fi

# 自检行必须锚定本域，不能把 translate.googleapis.com.example 之类算进来
printf '1.2.3.4 translate.googleapis.com\n1.2.3.5 translate.googleapis.com.evil\n' > "$TMP/selfcheck"
n=$(grep -cE '^[0-9.]+[[:space:]]+translate\.googleapis\.com$' "$TMP/selfcheck")
eq "自检行只数本域" "$n" "1"
grep -qF '^[0-9.]+[[:space:]]+translate\.googleapis\.com$' "$block" \
  && ok "安装块自检行用锚定正则" || bad "安装块自检行仍是宽匹配"

# 单元名与 github 那套必须不同，否则两个开关会互相覆盖
grep -q 'horizon-setup-hosts@' "$block" && bad "翻译安装块误用了 github 的单元名" \
  || ok "翻译安装块未使用 github 的单元名"

printf '\n=== H. 空行不堆积 ===\n'
# 前面的用例会把 getent 桩换成空/污染版；本段走的是探活关闭路径（只看 DNS），
# 故必须复位成能给出答案的桩，否则测的是「DNS 无答案」而不是空行堆积。
cat > "$TMP/bin/getent" <<'STUB3'
#!/usr/bin/env bash
case "$*" in
  *ahostsv4*translate.googleapis.com*) echo "192.0.2.5"; exit 0 ;;
esac
exit 2
STUB3
chmod +x "$TMP/bin/getent"
new_hosts "127.0.0.1 localhost"
for i in 1 2 3 4 5; do run_off on >/dev/null; done
blank=$(grep -c '^$' "$TMP/hosts" 2>/dev/null || echo 0)
if [ "$blank" -le 1 ]; then ok "连跑 5 次空行仍为 ${blank}（≤1）"; else bad "空行堆积到 ${blank}"; fi
eq "块仍唯一" "$(count_lines '^# horizon.setup:gtranslate$')" "1"

printf '\n---------------------------------------\n'
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
