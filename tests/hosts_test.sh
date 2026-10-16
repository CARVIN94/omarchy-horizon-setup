#!/usr/bin/env bash
# horizon.setup — hosts 管理层测试。
#
# 被测对象是**当前契约**：lib/hosts.sh 只负责「生成 root 刷新器 + 生成 unit 文件
# + 把它们交给一次 pkexec」，真正的 hosts 写入逻辑在 root 脚本里（装成
# root:root）。因此这里测两层：
#   A. root 刷新器脚本（fixture 化 /etc/hosts，直接跑，零权限）
#   B. lib 侧的生成与调用（pkexec/install/systemctl 用桩替换，只碰临时目录）
#
# 不联网（file:// fixture）、不提权（桩 pkexec）、不碰真实 /etc/hosts。
#
# 运行：bash tests/hosts_test.sh
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected=[$3] actual=[$2]"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HORIZON_HOSTS_URL="file://$TMP/fetch.txt"
export HST_FILE="$TMP/hosts"

source "$ROOT/lib/hosts.sh"
hst_refresh_script > "$TMP/refresh.sh"
bash -n "$TMP/refresh.sh" && ok "root 刷新器语法可解析" || bad "root 刷新器语法错误"
ROOT_SCRIPT="$TMP/refresh.sh"

run_root() { HORIZON_HOSTS_FILE="$TMP/hosts" /usr/bin/bash "$ROOT_SCRIPT" "$1" >"$TMP/out" 2>&1; echo $?; }
new_hosts()  { printf '%s\n' "$@" > "$TMP/hosts"; }
new_fetch()  { printf '%s\n' "$@" > "$TMP/fetch.txt"; }
count_lines() { grep -c "$1" "$TMP/hosts" 2>/dev/null || true; }

printf '\n=== A. root 刷新器：写块、幂等、迁移、移除 ===\n'

new_hosts "127.0.0.1 localhost"
new_fetch "20.205.243.166 github.com" "20.205.243.168 api.github.com"
rc=$(run_root on)
eq "on 返回 0" "$rc" "0"
eq "标记块写入" "$(count_lines '^# horizon.setup:github-hosts$')" "1"
eq "标记块尾写入" "$(count_lines '^# horizon.setup:github-hosts-end$')" "1"
eq "域名条目写入" "$(count_lines ' github.com$')" "1"
eq "原始行保留" "$(count_lines '^127.0.0.1 localhost$')" "1"

for _ in 1 2 3; do run_root on >/dev/null; done
eq "重复 on 后 start 唯一" "$(count_lines '^# horizon.setup:github-hosts$')" "1"
eq "重复 on 后 end 唯一" "$(count_lines '^# horizon.setup:github-hosts-end$')" "1"
eq "github.com 条目唯一" "$(count_lines ' github.com$')" "1"

new_hosts "127.0.0.1 localhost" \
          "# github-hosts:start" "140.82.112.4 github.com" "# github-hosts:end" \
          "# Github Hosts Start" "140.82.114.25 github.com" "# Github Hosts End" \
          "# fetch-github-hosts begin" "185.199.108.133 github.com" "# fetch-github-hosts end"
rc=$(run_root on)
eq "迁移后 on 返回 0" "$rc" "0"
eq "maxiaof 遗留块已清" "$(count_lines '^# github-hosts:start$')" "0"
eq "GitHub Hosts 遗留块已清" "$(count_lines '^# Github Hosts Start$')" "0"
eq "GitCDN 遗留块已清" "$(count_lines '^# fetch-github-hosts begin$')" "0"
eq "github.com 只一条映射" "$(count_lines ' github.com$')" "1"
eq "本插件标记存在" "$(count_lines '^# horizon.setup:github-hosts$')" "1"

new_hosts "127.0.0.1 localhost"
rc=$(run_root refresh)
eq "关闭态 refresh 返回 0" "$rc" "0"
eq "关闭态不写标记" "$(count_lines '^# horizon.setup:github-hosts$')" "0"

new_hosts "127.0.0.1 localhost"
run_root on >/dev/null
rc=$(run_root off)
eq "off 返回 0" "$rc" "0"
eq "off 后无标记" "$(count_lines 'horizon.setup:github-hosts')" "0"
eq "off 后无域名条目" "$(count_lines 'github.com')" "0"
eq "off 后原始行保留" "$(count_lines '^127.0.0.1 localhost$')" "1"

printf '\n=== B. root 刷新器：安全闸门（脏内容必须拒绝）===\n'

new_hosts "127.0.0.1 localhost"
new_fetch "1.2.3.4 ok.com" "EVIL; rm -rf /tmp/should-not-exist"
rc=$(run_root on)
if [ "$rc" != "0" ]; then ok "脏内容被拒绝"; else bad "脏内容竟被写入"; fi
eq "hosts 未被污染" "$(count_lines 'EVIL')" "0"
eq "未写入标记" "$(count_lines '^# horizon.setup:github-hosts$')" "0"

for probe in "not-an-ip github.com" "1.2.3.4" "999.999.999.999 github.com" \
             "1.2.3.4 github.com;rm" "1.2.3.4 /etc/passwd" "1.2.3.4 github.com extra"; do
  new_fetch "$probe"
  rc=$(run_root on)
  if [ "$rc" != "0" ]; then ok "拒绝 [$probe]"; else bad "应拒绝 [$probe]"; fi
done

new_hosts "127.0.0.1 localhost"
new_fetch "::1 v6.example.com"
rc=$(run_root on)
eq "合法 IPv6 放行" "$rc" "0"
eq "IPv6 条目写入" "$(count_lines 'v6.example.com')" "1"

printf '\n=== C. 运行时路径：只走 systemctl，不再提权 ===\n'
# 安装好后，开关只调 systemctl start <unit>@on|off.service —— polkit 规则
# 放行本单元，故免密；且不执行任何用户可写脚本（真正干活的是 root 刷新器）。
mkdir -p "$TMP/bin"
cat > "$TMP/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$HST_ACTIONS"
exit 0
STUB
chmod +x "$TMP/bin/systemctl"
export PATH="$TMP/bin:$PATH"
export HST_ACTIONS="$TMP/actions.log"
export HST_SYS_UNIT_DIR="$TMP/sys-unit"
mkdir -p "$HST_SYS_UNIT_DIR"

# --- C1. 未安装 ⇒ 明确报错（不回落 pkexec） ---
printf '127.0.0.1 localhost\n' > "$HST_FILE"
rm -rf "$TMP/sys-bin"; export HST_SYS_BIN="$TMP/sys-bin/refresh"
: > "$HST_ACTIONS"
hst_installed && bad "未安装时 hst_installed 应为假" || ok "未安装时 hst_installed 为假"
rc=0; err=$(hst_write 1 2>&1) || rc=$?
[ "$rc" != "0" ] && ok "未安装时 hst_write 返回非 0" || bad "未安装时竟成功"
echo "$err" | grep -q 'hosts-install-block' && ok "错误提示给出安装路径" || bad "错误提示不含安装路径" "$err"
eq "未安装时不调用 systemctl" "$(wc -l < "$HST_ACTIONS")" "0"
echo "$err" | grep -qi 'pkexec' && bad "回落到 pkexec（不该）" || ok "未回落 pkexec"

# --- C2. 已安装 ⇒ 走 systemctl start <unit>@on/off ---
mkdir -p "$TMP/sys-bin"; printf '#!/bin/sh\n' > "$HST_SYS_BIN"; chmod +x "$HST_SYS_BIN"
cat > "$HST_SYS_UNIT_DIR/${HST_SYS_UNIT}@.service" <<EOF
[Service]
ExecStart=$HST_SYS_BIN %i
EOF
hst_installed && ok "已安装时 hst_installed 为真" || bad "已安装时应为真"
: > "$HST_ACTIONS"
rc=0; hst_write 1 >/dev/null 2>&1 || rc=$?
eq "开启返回 0" "$rc" "0"
eq "开启调用 systemctl start @on" "$(cat "$HST_ACTIONS")" "start ${HST_SYS_UNIT}@on.service"
: > "$HST_ACTIONS"
rc=0; hst_write 0 >/dev/null 2>&1 || rc=$?
eq "关闭返回 0" "$rc" "0"
eq "关闭调用 systemctl start @off" "$(cat "$HST_ACTIONS")" "start ${HST_SYS_UNIT}@off.service"
# refresh 只在「块已存在（=已开启）」时动作，故先造出块
printf '127.0.0.1 localhost\n%s\n1.2.3.4 github.com\n%s\n' "$HST_START" "$HST_END" > "$HST_FILE"
: > "$HST_ACTIONS"
rc=0; hst_refresh >/dev/null 2>&1 || rc=$?
eq "刷新返回 0" "$rc" "0"
eq "刷新调用 systemctl start @refresh" "$(cat "$HST_ACTIONS")" "start ${HST_SYS_UNIT}@refresh.service"

# --- C3. 关闭态 refresh 不应动手（块不存在时）---
printf '127.0.0.1 localhost\n' > "$HST_FILE"
: > "$HST_ACTIONS"
rc=0; hst_refresh >/dev/null 2>&1 || rc=$?
eq "关闭态 refresh 返回 0" "$rc" "0"
eq "关闭态不调用 systemctl" "$(wc -l < "$HST_ACTIONS")" "0"

printf '\n=== D. 检测函数 ===\n'
new_hosts "127.0.0.1 localhost"
if hst_on; then bad "无块时 hst_on 应为假"; else ok "无块时 hst_on 为假"; fi
new_hosts "127.0.0.1 localhost" "$HST_START" "1.1.1.1 a.com" "$HST_END"
if hst_on; then ok "有块时 hst_on 为真"; else bad "有块时 hst_on 应为真"; fi
eq "status 输出 hosts=1" "$(hst_status)" "hosts=1"
new_hosts "127.0.0.1 localhost"
eq "status 输出 hosts=0" "$(hst_status)" "hosts=0"

printf '\n=== E. 一次性安装块：可审计 + 红线 ===\n'
# 内容即命令：用户 `bash` 它执行。必须能通过语法解析（粘贴即可用）。
block="$TMP/install-block.sh"
bash "$ROOT/setup.sh" hosts-install-block > "$block" 2>/dev/null
[ -s "$block" ] && ok "安装块已生成" || bad "安装块为空"
bash -n "$block" && ok "安装块语法可解析" || bad "安装块语法错误"

# 红线：块内不得引用插件目录（用户可写）。若有，等于把 root 交给它。
if grep -qE '\.config/omarchy|horizon-setup/setup\.sh' "$block"; then
  bad "安装块引用了插件目录（红线）" "$(grep -nE '\.config/omarchy' "$block" | head -2)"
else
  ok "安装块未引用插件目录"
fi

# 关键动作齐全：装刷新器/装 unit/启用 timer/立即刷新
for needle in 'install -m 0755 -o root -g root' \
              'systemctl daemon-reload' \
              'systemctl enable --now horizon-setup-hosts.timer' \
              'systemctl start horizon-setup-hosts@on.service'; do
  grep -qF "$needle" "$block" && ok "安装块含 [$needle]" || bad "安装块缺 [$needle]"
done
# 只输一次密码
grep -q '^sudo -v$' "$block" && ok "开头 sudo -v（只输一次密码）" || bad "缺 sudo -v"
# 刷新器内容与 lib 里生成的一致（唯一事实源，无第二份）
hst_refresh_script > "$TMP/expected-refresh.sh"
awk '/^REFRESH_EOF$/{exit} found{print} /<<.REFRESH_EOF.$/{found=1}' "$block" > "$TMP/actual-refresh.sh"
if diff -q "$TMP/expected-refresh.sh" "$TMP/actual-refresh.sh" >/dev/null 2>&1; then
  ok "块内刷新器与 lib 生成物一致（单一事实源）"
else
  bad "块内刷新器与 lib 生成物不一致（出现第二份）"
fi

printf '\n---------------------------------------\n'
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
