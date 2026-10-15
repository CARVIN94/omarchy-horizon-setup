#!/usr/bin/env bash
# horizon.setup — ufw 规则的读取、校验与增删。
#
# 设计原则（与 setup.sh 同）：检测即真相。
#   * 读取零权限：/etc/ufw/user.rules 与 user6.rules 都是 644，规则以 ufw
#     自己的 `### tuple ###` 行落盘，直接解析即可——不弹授权框。
#   * 写入才提权：只 `pkexec /usr/bin/ufw <args>`，绝不 pkexec 本脚本
#     （插件目录用户可写，提权它等于把「改写本文件」变成 root 执行；
#     参见 omarchy-windows-vm 的同款警告）。参数全在无权限侧校验。
#
# ufw 落盘格式（backend_iptables.py:878 写入、:697 解析）：
#   ### tuple ### <action> <protocol> <dport> <dst> <sport> <src> <ifaces> comment=<hex>
# 字段序反直觉：dport 在 dst 之前、sport 在 src 之前。comment 是 hex 编码。
#
# 删除语义（实测 dry-run + 源码双向确认，勿凭直觉改）：
#   1. `delete <spec> comment '<c>'` → 只删 comment 也精确相等的那条（ret=0）；
#      comment 不匹配则一条不动。
#   2. `delete <spec>`（不带 comment）→ 按五元组宽松匹配（ret=-2），
#      会连带删掉同五元组但 comment 不同的规则。
#      ⇒ 删除必须始终带 comment；comment 为空的规则拒绝删除。
#   3. action 必须一致：`delete allow ... port 22` 删不掉 `limit tcp 22`
#      （实测 T1/T2）。故删除按每条规则自身 action 下发。
#   4. 删除的 iptype 默认 "both"（parser.py:222），一次调用会同时覆盖 v4/v6。
#      但 v6 孪生规则只在「来源为 any」时才会生成：v4 CIDR 来源（如
#      192.168.0.0/24）不产生 v6 条目（2026-10-15 真机实测：新增
#      10.99.99.0/24 规则的 65001/tcp 只落在 user.rules，user6.rules 无对应
#      条目）。故面板按「孪生合并」展示，没有孪生时即单族规则。

FW_RULES_FILE="${FW_RULES_FILE:-/etc/ufw/user.rules}"
FW_RULES6_FILE="${FW_RULES6_FILE:-/etc/ufw/user6.rules}"
FW_UFW_BIN="${FW_UFW_BIN:-/usr/bin/ufw}"
FW_PKEXEC_BIN="${FW_PKEXEC_BIN:-/usr/bin/pkexec}"

# ---- comment 编解码 -------------------------------------------------------

# ufw 以 utf-8 → hex 存 comment（util.py:hex_encode）。
fw_hex_encode() { printf '%s' "$1" | od -An -tx1 | tr -d ' \n'; }

fw_hex_decode() { # $1=hex
  local h="$1" out="" i
  (( ${#h} % 2 == 0 )) || h="${h%?}"   # ufw 自身对奇数长度也截断（util.py:hex_decode）
  for ((i = 0; i < ${#h}; i += 2)); do
    out+="\\x${h:i:2}"
  done
  printf '%b' "$out"
}

# ---- 读取 -----------------------------------------------------------------

fw_parse_file() { # $1=path $2=v4|v6
  local file="$1" fam="$2" line hex
  [[ -r "$file" ]] || return 0
  while IFS= read -r line; do
    [[ "$line" == '### tuple ###'* ]] || continue
    line="${line#'### tuple ###'}"
    line="${line#"${line%%[![:space:]]*}"}"
    hex=""
    if [[ "$line" == *' comment='* ]]; then
      hex="${line##* comment=}"
      line="${line%% comment=*}"
    fi
    # shellcheck disable=SC2086
    set -- $line
    [[ $# -ge 7 ]] || continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$fam" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$(fw_hex_decode "$hex")"
  done < "$file"
}

# 输出所有 ufw 用户规则，TAB 分隔：
#   fam action proto dport dst sport src ifaces comment
fw_list() {
  fw_parse_file "$FW_RULES_FILE"  v4
  fw_parse_file "$FW_RULES6_FILE" v6
}

# 合并 v4/v6 孪生规则为一条，供面板展示与删除。
#
# 孪生判定必须先把「任意来源」归一化：v4 落盘为 0.0.0.0/0、v6 为 ::/0，
# 直接按原始字符串分组会把同一条逻辑规则拆成两条（曾因此漏合并 53317）。
#
# 输出（TAB 分隔）：action proto dport src comment families iface
#   families ∈ {4, 6, 46}；iface 非空表示接口规则（外部工具安装，只读，
#   面板不提供删除）。普通规则的 in/out 是方向标记，归一到空字符串。
fw_list_merged() {
  fw_list | awk -F'\t' '
    function norm_src(s) {
      return (s == "0.0.0.0/0" || s == "::/0") ? "any" : s
    }
    {
      fam=$1; action=$2; proto=$3; dport=$4; src=norm_src($7)
      iface=$8; comment=$9
      if (iface != "in" && iface != "out" && iface != "") {
        # 接口规则：按接口名归组，且不参与增删
        key = "I\t" action "\t" proto "\t" dport "\t" iface "\t" comment
        iface_out = iface
      } else {
        key = "R\t" action "\t" proto "\t" dport "\t" src "\t" comment
        iface_out = ""    # 普通规则的 in/out 是方向标记，面板不需要
      }
      if (!(seen[key])) {
        seen[key]=1; order[++n]=key
        act[key]=action; pro[key]=proto; dpo[key]=dport
        srcs[key]=src; cmt[key]=comment; ifc[key]=iface_out
        fams[key]=(fam == "v4") ? "4" : "6"
      } else {
        # 追加族标记：v4 且尚无 4 → 前缀；v6 且尚无 6 → 后缀，保持 4 在前
        if (fam == "v4" && index(fams[key], "4") == 0) fams[key]="4" fams[key]
        else if (fam == "v6" && index(fams[key], "6") == 0) fams[key]=fams[key] "6"
      }
    }
    END {
      for (i=1;i<=n;i++) {
        k=order[i]
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", \
          act[k], pro[k], dpo[k], srcs[k], cmt[k], fams[k], ifc[k]
      }
    }'
}

# ---- 校验（全部在无权限侧完成）--------------------------------------------

FW_PORT_RE='^[0-9]{1,5}(:[0-9]{1,5})?$'
FW_IPV4_RE='^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$'
FW_PROTO_RE='^(tcp|udp)$'
FW_ACTION_RE='^(allow|deny|reject|limit)$'
FW_COMMENT_MAX=60

fw_err() { printf 'horizon.setup: %s\n' "$*" >&2; }

fw_valid_port_spec() { # $1=port|port:port
  [[ "$1" =~ $FW_PORT_RE ]] || return 1
  local a="${1%%:*}" b="${1##*:}"
  ((a >= 1 && a <= 65535)) || return 1
  if [[ "$1" == *:* ]]; then
    ((b >= 1 && b <= 65535)) || return 1
    ((a <= b)) || return 1
  fi
  return 0
}

fw_valid_src() { # $1=cidr|ip|any
  [[ "$1" == "any" ]] && return 0
  [[ "$1" =~ $FW_IPV4_RE ]] || return 1
  local octets="${1%%/*}" pfx=""
  [[ "$1" == */* ]] && pfx="${1##*/}"
  local -a o
  IFS=. read -r -a o <<< "$octets"
  local x
  for x in "${o[@]}"; do ((x <= 255)) || return 1; done
  [[ -z "$pfx" ]] || ((pfx <= 32)) || return 1
  return 0
}

fw_valid_proto()  { [[ "$1" =~ $FW_PROTO_RE ]]; }
fw_valid_action() { [[ "$1" =~ $FW_ACTION_RE ]]; }

# comment 会进入 root 侧 ufw 的参数向量。限制为 1-60 字符、无控制字符、
# 无首尾空白。调用方用参数数组传递，不经 shell 解析，故分号等字符是安全的
# 字面量（见 tests/firewall_test.sh 第 10 节）。
# 注意：bash 的 [...] 里 \n \t 是字面反斜杠+字母，不是控制符，故控制字符
# 必须用 $'...' 或 [[:cntrl:]] 表达。
fw_valid_comment() {
  local c="$1"
  (( ${#c} >= 1 && ${#c} <= FW_COMMENT_MAX )) || return 1
  [[ "$c" != *[$'\n\t\r']* ]] || return 1
  [[ "$c" == *[[:cntrl:]]* ]] && return 1
  [[ "$c" != ' '* && "$c" != *' ' ]] || return 1
  return 0
}

# ---- 提权执行 -------------------------------------------------------------

fw_run_ufw() {
  command -v "$FW_PKEXEC_BIN" >/dev/null 2>&1 || { fw_err "pkexec 不可用"; return 127; }
  [[ -x "$FW_UFW_BIN" ]] || { fw_err "ufw 不可用: $FW_UFW_BIN"; return 127; }
  "$FW_PKEXEC_BIN" "$FW_UFW_BIN" "$@"
}

# ---- 增删 -----------------------------------------------------------------

# 组装规则参数（不含 delete）。结果写入全局数组 FW_SPEC。
# 形态：<action> [from <src>] to any port <dport> proto <proto>
fw_build_spec() { # $1=action $2=port $3=proto $4=src
  FW_SPEC=("$1")
  [[ "$4" == "any" ]] || FW_SPEC+=(from "$4")
  FW_SPEC+=(to any port "$2" proto "$3")
}

fw_validate_common() { # $1=port $2=proto $3=src $4=action
  fw_valid_port_spec "$1" || { fw_err "端口非法: $1"; return 2; }
  fw_valid_proto "$2"     || { fw_err "协议非法: $2"; return 2; }
  fw_valid_src "$3"       || { fw_err "来源非法: $3"; return 2; }
  fw_valid_action "$4"    || { fw_err "动作非法: $4"; return 2; }
  return 0
}

fw_add() { # $1=port $2=proto $3=src $4=comment $5=action(默认 allow)
  local port="$1" proto="$2" src="$3" comment="$4" action="${5:-allow}"
  fw_validate_common "$port" "$proto" "$src" "$action" || return $?
  fw_valid_comment "$comment" || { fw_err "备注非法（1-${FW_COMMENT_MAX} 字符，不可首尾空白）"; return 2; }

  local -a spec
  fw_build_spec "$action" "$port" "$proto" "$src"
  spec=("${FW_SPEC[@]}" comment "$comment")
  fw_run_ufw "${spec[@]}" >/dev/null || return 1
}

# 精确删除一条规则。必须传 action 与非空 comment：
#   * 无 comment  → 退化为五元组宽松匹配，可能误删同端口他人规则（拒绝）
#   * action 不符 → 静默删不掉（见文件头第 3 条）
fw_del() { # $1=port $2=proto $3=src $4=comment $5=action
  local port="$1" proto="$2" src="$3" comment="$4" action="${5:-allow}"
  fw_validate_common "$port" "$proto" "$src" "$action" || return $?
  [[ -n "$comment" ]] || {
    fw_err "拒绝删除：comment 为空会退化为五元组宽松匹配，可能误删同端口其他规则"
    return 2
  }
  fw_valid_comment "$comment" || { fw_err "备注非法"; return 2; }

  local -a spec
  fw_build_spec "$action" "$port" "$proto" "$src"
  spec=("${FW_SPEC[@]}" comment "$comment")
  fw_run_ufw delete "${spec[@]}" >/dev/null || return 1
}

# ---- 状态 -----------------------------------------------------------------

fw_enabled() {
  local conf="${FW_CONF_FILE:-/etc/ufw/ufw.conf}"
  [[ -r "$conf" ]] && grep -q '^ENABLED=yes' "$conf"
}

# 面板消费：每行一条合并后的规则（TAB 分隔，列序见 fw_list_merged）。
# 本文件不定义 b()——`0/1` 格式化由调用方 setup.sh 统一提供，避免两处实现。
fw_rows() { fw_list_merged; }
