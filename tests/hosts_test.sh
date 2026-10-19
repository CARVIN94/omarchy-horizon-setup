#!/usr/bin/env bash
# horizon.setup — hosts 管理层测试。
#
# 被测对象是**当前契约**：lib/hosts.sh 只负责「生成 root 刷新器 + 生成 unit 文件
# + 生成一次性安装块」，真正的 hosts 写入逻辑在 root 脚本里（装成 root:root）。
# 因此这里测两层：
#   A. root 刷新器脚本（fixture 化 /etc/hosts，直接跑，零权限）
#   B. lib 侧的生成与调用（systemctl 用桩替换，只碰临时目录）
#
# 不联网（file:// fixture + 桩 curl，且 HORIZON_HOSTS_PROBE=0 断探活）、
# 不提权（从不真跑安装块）、不碰真实 /etc/hosts。
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

# 断网：探活默认开启，但测试必须零联网 ⇒ 一律显式关掉。探活本身另有专测（见 F 段）。
run_root() { HORIZON_HOSTS_PROBE=0 HORIZON_HOSTS_FILE="$TMP/hosts" /usr/bin/bash "$ROOT_SCRIPT" "$1" >"$TMP/out" 2>&1; echo $?; }
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
          "# github-hosts:start  (maxiaof/github-hosts, 2026-10-15)" \
          "140.82.112.4 github.com" "185.199.110.133 objects.githubusercontent.com" \
          "# github-hosts:end" \
          "# Github Hosts Start" "140.82.114.25 github.com" "# Github Hosts End" \
          "# fetch-github-hosts begin" "185.199.108.133 github.com" "# fetch-github-hosts end"
rc=$(run_root on)
eq "迁移后 on 返回 0" "$rc" "0"
# 断言**不带 ^...$ 锚定**：真实样本的 start 行带后缀，锚定会漏掉残留
eq "maxiaof 遗留块已清（含带后缀的行）" "$(count_lines 'github-hosts:start')" "0"
eq "GitHub Hosts 遗留块已清" "$(count_lines 'Github Hosts Start')" "0"
eq "GitCDN 遗留块已清" "$(count_lines 'fetch-github-hosts begin')" "0"
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

# 自检行报的必须是「github.com 的映射条数」，不能顺带算进 github.community、
# github-com.s3.amazonaws.com 之类的旁支域名（`.` 在 BRE 里是通配符，会误匹配）。
printf '20.205.243.166 github.com\n52.217.91.112 github-com.s3.amazonaws.com\n140.82.112.17 github.community\n' > "$TMP/selfcheck"
n=$(grep -cE '^[0-9.]+[[:space:]]+github\.com$' "$TMP/selfcheck")
eq "自检行只数 github.com 本域（不误匹配 github.community 等）" "$n" "1"
grep -qF '^[0-9.]+[[:space:]]+github\.com$' "$block" \
  && ok "安装块自检行用锚定正则" || bad "安装块自检行仍是宽匹配（会误数旁支域名）"


printf '\n=== 12. 退化态：遗留 start 无 end（真机就是这个状态）===\n'
# 真机实况：maxiaof 的 end 曾被旧实现的 `$0==l1e{skip=0;next}` 在 skip=0 时
# 照样 `next` 吞掉，而 start 又因带后缀匹配不上 ⇒ 只剩「start + 数据」。
# 要求：从该 start 起全部丢弃，且不留任何带后缀的残留。
new_hosts "# Static table" "127.0.0.1 localhost" "::1 localhost" \
          "# github-hosts:start  (maxiaof/github-hosts, 2026-10-15)" \
          "140.82.112.4 github.com" "185.199.110.133 objects.githubusercontent.com"
rc=$(run_root on)
eq "退化态 on 返回 0" "$rc" "0"
eq "带后缀的 start 已清除" "$(count_lines 'github-hosts:start')" "0"
eq "遗留数据已清除" "$(count_lines 'objects.githubusercontent.com')" "0"
eq "本插件块已写入" "$(count_lines '^# horizon.setup:github-hosts$')" "1"
eq "原始行保留" "$(count_lines '^::1 localhost$')" "1"

printf '\n=== 13. 空行不堆积（每次刷新最多一个分隔空行）===\n'
# 每次渲染都 printf "\n..." 追加一个空行；不收尾就逐次堆积（真机曾到 9 个）。
new_hosts "127.0.0.1 localhost"
new_fetch "20.205.243.166 github.com"
for i in 1 2 3 4 5; do run_root on >/dev/null; done
blank=$(grep -c '^$' "$TMP/hosts" 2>/dev/null || echo 0)
if [ "$blank" -le 1 ]; then
  ok "连跑 5 次空行仍为 ${blank}（≤1，未堆积）"
else
  bad "空行堆积到 ${blank}（应 ≤1）"
fi
eq "块仍唯一" "$(count_lines '^# horizon.setup:github-hosts$')" "1"
before=$(sha256sum "$TMP/hosts" | cut -d' ' -f1)
run_root on >/dev/null
after=$(sha256sum "$TMP/hosts" | cut -d' ' -f1)
[ "$before" = "$after" ] && ok "再刷新逐字节稳定" || bad "刷新后内容仍变化"

printf '\n=== 14. 探活：核心域名必须写多个 IP（单 IP 实测 0/10、多 IP 9/10）===\n'
# 真机实测：上游快照与所有公共 DNS 对 github.com 都只给 20.205.243.166 一条 A，
# 该地址整段死亡时单 IP hosts 可用率 0/10；同一 hosts 写 6 个候选则 9/10。
# 故刷新器必须探活并把**存活 IP 全量写入**，只写最优那个不行（探活后立刻复用
# 同一 IP 成功率仅 3/10）。
#
# 探活靠 curl --resolve；这里用桩 curl 同时接管「抓上游」（转给真 curl）与
# 「探活」（按 $PROBE_ALIVE 决定死活），全程零联网。
real_curl=$(command -v curl)
mkdir -p "$TMP/pbin"
cat > "$TMP/pbin/curl" <<STUBCURL
#!/usr/bin/env bash
# 探活调用含 --resolve <host>:443:<ip>；命中 \$PROBE_ALIVE 里的 IP 即算活。
# 其余调用（抓 file:// 上游）原样转给真 curl。
for b in "\$@"; do
  case "\$b" in
    *:443:*)
      ip=\${b##*:}
      grep -qxF "\$ip" "\${PROBE_ALIVE:-/dev/null}" 2>/dev/null && { echo 200; exit 0; }
      echo 000; exit 0
      ;;
  esac
done
exec "$real_curl" "\$@"
STUBCURL
chmod +x "$TMP/pbin/curl"

# --- 14a. 核心域名有候选池（池子空 ⇒ 探活等于没做）---
# 只取 case 之前的函数定义：刷新器末尾的 case 会 exit，直接 source 会带走进程。
awk '/^case /{exit} {print}' "$TMP/refresh.sh" > "$TMP/refresh-fns.sh"
pool_out=$(/usr/bin/bash -c '
  source "$1"
  for d in github.com api.github.com codeload.github.com raw.githubusercontent.com objects.githubusercontent.com gist.github.com; do
    printf "%s %s\n" "$d" "$(pool_ips "$d" | wc -w)"
  done' _ "$TMP/refresh-fns.sh" 2>/dev/null)
gh_n=$(printf '%s\n' "$pool_out" | awk '$1=="github.com"{print $2}')
if [ "${gh_n:-0}" -ge 2 ]; then ok "github.com 候选池含 ${gh_n} 个 IP（≥2）"; else bad "github.com 候选池仅 ${gh_n:-0} 个（应 ≥2）"; fi
for d in raw.githubusercontent.com objects.githubusercontent.com api.github.com codeload.github.com; do
  n=$(printf '%s\n' "$pool_out" | awk -v D="$d" '$1==D{print $2}')
  if [ "${n:-0}" -ge 2 ]; then ok "${d} 候选池含 ${n} 个 IP（≥2）"; else bad "${d} 候选池仅 ${n:-0} 个（应 ≥2）"; fi
done

# --- 14b. 存活 IP 全部写入（不是只写一个）---
new_hosts "127.0.0.1 localhost"
new_fetch "20.205.243.166 github.com" "185.199.109.133 raw.githubusercontent.com"
printf '140.82.113.3\n140.82.113.4\n20.205.243.169\n' > "$TMP/alive"
PROBE_ALIVE="$TMP/alive" HORIZON_HOSTS_PROBE=1 PATH="$TMP/pbin:$PATH" \
  HORIZON_HOSTS_FILE="$TMP/hosts" HORIZON_HOSTS_URL="file://$TMP/fetch.txt" \
  /usr/bin/bash "$ROOT_SCRIPT" on >"$TMP/out" 2>&1
eq "探活开启时 on 返回 0" "$?" "0"
eq "github.com 写入 3 条存活 IP" "$(count_lines ' github.com$')" "3"
for ip in 140.82.113.3 140.82.113.4 20.205.243.169; do
  eq "存活 IP $ip 已写入" "$(count_lines "^$ip github\.com$")" "1"
done
eq "死 IP 20.205.243.166 未被写入 github.com" "$(count_lines '^20\.205\.243\.166 github\.com$')" "0"
eq "raw 无存活项 ⇒ 保留上游原行（兜底不空）" "$(count_lines '^185\.199\.109\.133 raw\.githubusercontent\.com$')" "1"

# --- 14c. 探活全灭 ⇒ 保留上游原行（宁可赌一次也不留空）---
new_hosts "127.0.0.1 localhost"
new_fetch "20.205.243.166 github.com"
: > "$TMP/alive"
PROBE_ALIVE="$TMP/alive" HORIZON_HOSTS_PROBE=1 PATH="$TMP/pbin:$PATH" \
  HORIZON_HOSTS_FILE="$TMP/hosts" HORIZON_HOSTS_URL="file://$TMP/fetch.txt" \
  /usr/bin/bash "$ROOT_SCRIPT" on >"$TMP/out" 2>&1
eq "全灭时 on 仍返回 0" "$?" "0"
eq "全灭时保留上游 github.com 行" "$(count_lines '^20\.205\.243\.166 github\.com$')" "1"

# --- 14d. 关闭探活 ⇒ 原样写入上游（测试默认路径，也是逃生阀）---
new_hosts "127.0.0.1 localhost"
new_fetch "20.205.243.166 github.com"
rc=$(run_root on)
eq "探活关闭时 on 返回 0" "$rc" "0"
eq "探活关闭时按上游原样写 1 条" "$(count_lines ' github.com$')" "1"

# --- 14e. 探活结果仍需过写的都是合法行（复用 B 段同一闸门，不因探活而放宽）---
new_hosts "127.0.0.1 localhost"
new_fetch "1.2.3.4 ok.com" "EVIL; rm -rf /tmp/should-not-exist"
printf '5.6.7.8\n' > "$TMP/alive"
PROBE_ALIVE="$TMP/alive" HORIZON_HOSTS_PROBE=1 PATH="$TMP/pbin:$PATH" \
  HORIZON_HOSTS_FILE="$TMP/hosts" HORIZON_HOSTS_URL="file://$TMP/fetch.txt" \
  /usr/bin/bash "$ROOT_SCRIPT" on >"$TMP/out" 2>&1
rc=$?
[ "$rc" != "0" ] && ok "探活开启时脏输入仍被拒绝" || bad "探活开启时脏输入竟通过"
eq "探活开启时 hosts 未被污染" "$(count_lines 'EVIL')" "0"

printf '\n---------------------------------------\n'
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
