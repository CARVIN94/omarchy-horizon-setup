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

printf '\n=== C. lib 侧：生成的 runner 是一次授权的原子脚本 ===\n'
# root 脚本用绝对路径（/usr/bin/install 等）是**正确的防御**：root 侧不应
# 依赖 PATH。故这里对生成的 runner 做文本契约断言，而不是削弱它以便桩测。
runner="$TMP/runner.sh"
cat > "$runner" <<EOF
$(cat <<'X'
X
)
EOF
# 直接调用 lib 的生成逻辑，落到临时 unit 目录，桩 pkexec 只收下 runner 内容
mkdir -p "$TMP/bin"
cat > "$TMP/bin/pkexec" <<'STUB'
#!/usr/bin/env bash
shift
cp "$1" "$TMP/runner.sh"
echo "pkexec-called $1" >> "$HST_ACTIONS"
exit 0
STUB
cat > "$TMP/bin/install" <<'STUB'
#!/usr/bin/env bash
echo "install $*" >> "$HST_ACTIONS"; exit 0
STUB
cat > "$TMP/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >> "$HST_ACTIONS"; exit 0
STUB
chmod +x "$TMP/bin"/*
export HST_PKEXEC="$TMP/bin/pkexec"
export HST_SYS_BIN="$TMP/sys-bin/refresh"
export HST_SYS_UNIT_DIR="$TMP/sys-unit"
export TMP
export HST_ACTIONS="$TMP/actions.log"
: > "$HST_ACTIONS"

# 让生成器把 unit 文件写进临时目录，并把 runner 落到 $TMP/runner.sh
rc=0
hst_write_sys_timer 1 >/dev/null 2>&1 || rc=$?
eq "lib 生成并交出 runner（pkexec 被调用）" "$(grep -c 'pkexec-called' "$HST_ACTIONS")" "1"
[ -s "$TMP/runner.sh" ] && ok "runner 已生成" || bad "runner 未生成"

# runner 文本契约：root 侧只碰 root 所有的二进制，绝不碰插件脚本
for needle in "/usr/bin/install -m 0755" "/usr/bin/install -m 0644" \
              "/usr/bin/systemctl enable --now" "/usr/bin/systemctl start" \
              "/usr/bin/systemctl disable --now"; do
  grep -qF "$needle" "$TMP/runner.sh" && ok "runner 含 [$needle]" || bad "runner 缺 [$needle]"
done
# 红线：runner 不得引用插件目录（用户可写），否则等于把 root 交给它
grep -q '\.config/omarchy' "$TMP/runner.sh" && bad "runner 引用了插件目录（红线）" || ok "runner 未引用插件目录"

# 关闭顺序：删 hosts 块必须在卸载刷新器之前
off_line=$(grep -n 'HST_SYS_BIN" off\|refresh.sh off\|" off' "$TMP/runner.sh" | head -1 | cut -d: -f1)
rm_line=$(grep -n '/usr/bin/rm -f' "$TMP/runner.sh" | head -1 | cut -d: -f1)
if [ -n "$off_line" ] && [ -n "$rm_line" ] && [ "$off_line" -lt "$rm_line" ]; then
  ok "顺序正确：删块(行$off_line) 在 卸载刷新器(行$rm_line) 之前"
else
  bad "顺序错误（off=$off_line rm=$rm_line）"
fi

# 卸载链路
: > "$HST_ACTIONS"
hst_write_sys_timer 0 >/dev/null 2>&1 || true
grep -q 'disable --now' "$TMP/runner.sh" && ok "卸载 runner 停 timer" || bad "卸载未停 timer"

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
              'systemctl start horizon-setup-hosts.service'; do
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
