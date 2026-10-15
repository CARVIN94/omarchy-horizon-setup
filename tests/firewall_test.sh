#!/usr/bin/env bash
# horizon.setup 防火墙层测试。全部使用 fixture + 桩件，不接触真实防火墙，
# 不触发任何授权框。
#
# 运行：bash tests/firewall_test.sh
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected=[$3] actual=[$2]"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export FW_RULES_FILE="$HERE/fixtures/user.rules"
export FW_RULES6_FILE="$HERE/fixtures/user6.rules"
export FW_FAKE_LOG="$TMP/calls.log"
export FW_PKEXEC_BIN="$HERE/fake/pkexec"
export FW_UFW_BIN="$HERE/fake/ufw"
export FW_FAKE_UFW="$HERE/fake/ufw"
chmod +x "$HERE/fake/pkexec" "$HERE/fake/ufw"

# shellcheck source=../lib/firewall.sh
source "$ROOT/lib/firewall.sh"

printf '\n=== 1. 解析：字段与注释解码 ===\n'
# 列序：1=fam 2=action 3=proto 4=dport 5=dst 6=sport 7=src 8=ifaces 9=comment
# 真实 tuple：allow tcp 3082 0.0.0.0/0 any 192.168.0.0/24 in comment=445348207765622033303832
row=$(fw_list | awk -F'\t' '$4=="9000" && $3=="tcp"')
eq "9000/tcp 动作"   "$(cut -f2 <<<"$row")" "allow"
eq "9000/tcp 来源"   "$(cut -f7 <<<"$row")" "10.20.30.0/24"
eq "9000/tcp 注释"   "$(cut -f9 <<<"$row")" "example web"
eq "9000/tcp 族"     "$(cut -f1 <<<"$row")" "v4"
eq "9000/tcp 协议"   "$(cut -f3 <<<"$row")" "tcp"

row=$(fw_list | awk -F'\t' '$4=="53317" && $3=="udp"')
eq "53317/udp 无注释" "$(cut -f9 <<<"$row")" ""

printf '\n=== 2. 解析：区分 action 与接口规则 ===\n'
eq "22 是 limit 不是 allow" "$(fw_list | awk -F'\t' '$4=="22"{print $2}' | head -1)" "limit"
eq "22 的 v4/v6 各一条"     "$(fw_list | awk -F'\t' '$4=="22"' | wc -l)" "2"
eq "docker0 是接口规则"     "$(fw_list | awk -F'\t' '$8 ~ /docker0/{print $8}')" "in_docker0"

printf '\n=== 3. 合并：v4/v6 孪生规则并为一条 ===\n'
# 合并后列序：1=action 2=proto 3=dport 4=src 5=comment 6=families 7=iface
n53317=$(fw_rows | awk -F'\t' '$3=="53317" && $2=="udp"' | wc -l)
eq "53317/udp 只出现一次" "$n53317" "1"
eq "53317/udp 覆盖两族"   "$(fw_rows | awk -F'\t' '$3=="53317" && $2=="udp"{print $6}')" "46"
eq "53317/udp 来源归一化为 any" "$(fw_rows | awk -F'\t' '$3=="53317" && $2=="udp"{print $4}')" "any"
eq "9000 仅 v4"           "$(fw_rows | awk -F'\t' '$3=="9000" && $2=="tcp"{print $6}')" "4"
eq "9000 注释保留"        "$(fw_rows | awk -F'\t' '$3=="9000" && $2=="tcp"{print $5}')" "example web"
eq "22 limit 也合并为一"  "$(fw_rows | awk -F'\t' '$3=="22"' | wc -l)" "1"
eq "接口规则出现在合并列表" "$(fw_rows | awk -F'\t' '$7 ~ /docker0/' | wc -l)" "1"
eq "接口规则带接口名"     "$(fw_rows | awk -F'\t' '$7 ~ /docker0/{print $7}')" "in_docker0"
eq "接口规则 iface 列非空即可辨识" "$(fw_rows | awk -F'\t' '$3=="9000"{print $7}')" ""

printf '\n=== 4. 校验：端口 ===\n'
for good in 80 3082 8000:9999 1 65535; do
  fw_valid_port_spec "$good" && ok "接受端口 $good" || bad "应接受端口 $good"
done
for badp in 0 65536 99999 80:70 "80:" ":80" "abc" "80 81" "-1" ""; do
  fw_valid_port_spec "$badp" && bad "应拒绝端口 [$badp]" || ok "拒绝端口 [$badp]"
done

printf '\n=== 5. 校验：来源 ===\n'
for good in any 192.168.0.0/24 10.0.0.1 0.0.0.0/0 255.255.255.255 192.168.1.5/32; do
  fw_valid_src "$good" && ok "接受来源 $good" || bad "应接受来源 $good"
done
for bads in "192.168.0.0/33" "256.1.1.1" "192.168.0.1/24/8" "1.2.3" "any/24" "172.17.0.1;rm" ""; do
  fw_valid_src "$bads" && bad "应拒绝来源 [$bads]" || ok "拒绝来源 [$bads]"
done

printf '\n=== 6. 校验：协议/动作/注释 ===\n'
fw_valid_proto tcp && ok "接受 tcp" || bad "应接受 tcp"
fw_valid_proto udp && ok "接受 udp" || bad "应接受 udp"
for badx in TCP icmp any "" "tcp;x"; do
  fw_valid_proto "$badx" && bad "应拒绝协议 [$badx]" || ok "拒绝协议 [$badx]"
done
for a in allow deny reject limit; do
  fw_valid_action "$a" && ok "接受动作 $a" || bad "应接受动作 $a"
done
fw_valid_action "allow;rm" && bad "应拒绝动作注入" || ok "拒绝动作注入"

fw_valid_comment "DSH web 3082" && ok "接受含空格注释" || bad "应接受含空格注释"
fw_valid_comment "允许局域网访问" && ok "接受中文注释" || bad "应接受中文注释"
fw_valid_comment " lead" && bad "应拒绝前导空格" || ok "拒绝前导空格"
fw_valid_comment "trail " && bad "应拒绝尾随空格" || ok "拒绝尾随空格"
fw_valid_comment "" && bad "应拒绝空注释" || ok "拒绝空注释"
long=$(printf 'x%.0s' {1..61})
fw_valid_comment "$long" && bad "应拒绝超长注释" || ok "拒绝超长注释"
fw_valid_comment "$(printf 'x%.0s' {1..60})" && ok "接受 60 字注释" || bad "应接受 60 字注释"

printf '\n=== 7. 增：生成正确的 root 侧参数向量 ===\n'
last_call() { rm -f "$FW_FAKE_LOG"; }
show_calls() { sed 's/\x1f/ /g' "$FW_FAKE_LOG"; }

: > "$FW_FAKE_LOG"
fw_add 3082 tcp 192.168.0.0/24 "DSH web 3082" allow
eq "add 参数向量" "$(show_calls)" "allow from 192.168.0.0/24 to any port 3082 proto tcp comment DSH web 3082"

: > "$FW_FAKE_LOG"
fw_add 8000:9999 udp any "LAN range" allow
eq "add any 来源省略 from" "$(show_calls)" "allow to any port 8000:9999 proto udp comment LAN range"

: > "$FW_FAKE_LOG"
fw_add 22 tcp any "omarchy-sshd" limit
eq "add 支持 limit 动作" "$(show_calls)" "limit to any port 22 proto tcp comment omarchy-sshd"

printf '\n=== 8. 增：非法输入必须在提权前被拦下 ===\n'
# 逐项显式调用，避免 set -- 把 '' 变成字面两字符
expect_reject_add() { # $1=描述 $2=port $3=proto $4=src $5=comment $6=action
  : > "$FW_FAKE_LOG"
  fw_add "$2" "$3" "$4" "$5" "$6" >/dev/null 2>&1
  local rc=$?
  if [ $rc -eq 2 ] && [ ! -s "$FW_FAKE_LOG" ]; then
    ok "拒绝且未提权: $1"
  else
    bad "应拒绝且不提权: $1" "rc=$rc calls=$(show_calls)"
  fi
}
expect_reject_add "端口 0"          0    tcp  any           c allow
expect_reject_add "端口越界"        70000 tcp any           c allow
expect_reject_add "协议非法"        3082 icmp any           c allow
expect_reject_add "来源非法"        3082 tcp 300.1.1.1     c allow
expect_reject_add "空注释"          3082 tcp any           "" allow
expect_reject_add "动作非法"        3082 tcp any           c bogus

printf '\n=== 9. 删：必须带 action 与 comment ===\n'
: > "$FW_FAKE_LOG"
fw_del 3082 tcp 192.168.0.0/24 "DSH web 3082" allow
eq "del 参数向量" "$(show_calls)" "delete allow from 192.168.0.0/24 to any port 3082 proto tcp comment DSH web 3082"

: > "$FW_FAKE_LOG"
fw_del 22 tcp any "omarchy-sshd" limit
eq "del 用规则的 action（limit 规则必须用 limit 删）" "$(show_calls)" "delete limit to any port 22 proto tcp comment omarchy-sshd"

: > "$FW_FAKE_LOG"
fw_del 3082 tcp 192.168.0.0/24 "" allow >/dev/null 2>&1
rc=$?
if [ $rc -eq 2 ] && [ ! -s "$FW_FAKE_LOG" ]; then
  ok "拒绝空 comment 删除（宽松匹配风险）"
else
  bad "空 comment 删除必须被拒" "rc=$rc calls=$(show_calls)"
fi

printf '\n=== 10. 传参不经 shell：注入尝试保持为字面量 ===\n'
: > "$FW_FAKE_LOG"
fw_add 3082 tcp 192.168.0.0/24 'x; touch /tmp/pwned' allow 2>/dev/null
if [ -s "$FW_FAKE_LOG" ]; then
  # 记录格式：首字段 + \x1f 分隔的其余参数 => 参数总数 = 分隔符数 + 1
  nargs=$(( $(head -1 "$FW_FAKE_LOG" | tr -cd '\037' | wc -c) + 1 ))
  # allow from S to any port P proto tcp comment C = 11 个独立参数
  eq "分号注释仍是单参数传递" "$nargs" "11"
  # 且分号原样存在于该参数内部（未被拆成第二条命令）
  grep -q 'touch /tmp/pwned' "$FW_FAKE_LOG" && ok "分号内容原样保留" || bad "分号内容丢失"
else
  ok "分号注释被校验拒绝（亦安全）"
fi
[ -f /tmp/pwned ] && bad "发生了注入" || ok "未产生注入副作用"

printf '\n=== 11. 状态契约：setup.sh status 与 rules 必须自洽 ===\n'
# 断言真实入口（setup.sh），而不是库里的私有辅助函数——后者一旦改名，
# 测试仍会通过而面板会坏。
out=$(bash "$ROOT/setup.sh" status)
[[ "$out" =~ ^keys=[01]\ scroll=[01]\ clip=[01]\ npm=[01]\ ghproxy=[01]\ ufw=[01]\ rules=[0-9]+$ ]] \
  && ok "status 格式完整: $out" || bad "status 格式" "$out"
eq "status 的 rules 与 setup.sh rules 行数一致" \
   "$(sed 's/.*rules=//' <<<"$out")" \
   "$(bash "$ROOT/setup.sh" rules | wc -l)"
eq "rules 输出列数固定为 7" \
   "$(bash "$ROOT/setup.sh" rules | awk -F'\t' 'NR==1{print NF}')" "7"

printf '\n---------------------------------------\n'
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
