#!/usr/bin/env bash
# horizon.setup — GitHub hosts 管理（把 github.com 等域名指到可用 IP）。
#
# 背景：国内访问 github.com 的 HTTPS 是按 SNI 的概率性阻断（DNS 干净、TCP
# 常通、TLS 阶段丢包），且各 IP 状态小时级翻转。单条映射实测 0/10，写多条
# 存活 IP 则 9/10 —— 所以本模块每天探活一次，把所有还活着的 IP 都写进去。
#
# 被 setup.sh source，因此这里只定义函数，不执行动作。
#
# ---- 安全模型（重要）------------------------------------------------------
# 写 /etc/hosts 需要 root，但**绝不提权本插件的脚本**：插件目录用户可写，
# 提权它等于把「改写本文件」变成 root 执行（Omarchy 自己在 omarchy-windows-vm
# 里明令避免这点）。做法是：安装阶段用 sudo 执行 root 所有的 /usr/bin/install
# 与 /usr/bin/tee，把刷新器装成 root:root；此后运行时只用 systemctl 触发该
# root 刷新器，由 polkit 规则免密放行。全程不执行任何用户可写内容。
#
# 取来的 hosts 内容先在无权限侧逐行白名单校验，畸形内容一律拒绝写入。

# 标记块边界（/etc/hosts 中本插件管理的区间）。
HST_START='# horizon.setup:github-hosts'
HST_END='# horizon.setup:github-hosts-end'
HST_FILE="${HST_FILE:-/etc/hosts}"

# root 侧安装物：刷新器脚本 + 系统级 timer。
HST_SYS_UNIT="${HST_SYS_UNIT:-horizon-setup-hosts}"
HST_SYS_BIN="${HST_SYS_BIN:-/usr/local/bin/horizon-setup-hosts-refresh}"
HST_SYS_UNIT_DIR="${HST_SYS_UNIT_DIR:-/etc/systemd/system}"
HST_TIMER_TIME="${HST_TIMER_TIME:-*-*-* 04:00:00}"

hst_err() { printf 'horizon.setup: %s\n' "$*" >&2; }

# ---- 检测 -----------------------------------------------------------------

# hosts 管理块是否存在。
hst_on() {
  [[ -r "$HST_FILE" ]] && grep -qxF "$HST_START" "$HST_FILE"
}

# $1 = 1 开启 / 0 关闭。
# 已安装 ⇒ systemctl start @on|@off（polkit 规则免密，且不执行任何用户可写
# 脚本——真正干活的是 root:root 的刷新器）。未安装 ⇒ 明确提示先做一次性
# 安装，不回落到 pkexec（本机 polkit 的 PAM 栈缺失，密码认证恒失败）。
hst_write() {
  local inst
  if [[ "$1" == 1 ]]; then inst=on; else inst=off; fi
  if hst_installed; then
    systemctl start "${HST_SYS_UNIT}@${inst}.service"
  else
    hst_err "尚未安装 hosts 加速。一次性安装: setup.sh hosts-install-block | bash"
    return 1
  fi
}

# 供每日定时/手动调用：只在「已开启」时刷新（关闭态不动 hosts）。
hst_refresh() {
  hst_on || return 0
  # 已安装时交给 root 刷新器；此处必须以 install 判定，因为它就是那条
  # 免密 systemctl 路径的前置条件。
  hst_installed || { hst_err "尚未安装 hosts 加速"; return 1; }
  systemctl start "${HST_SYS_UNIT}@refresh.service"
}

# 状态：块存在即开启。
hst_status() {
  if hst_on; then printf 'hosts=1\n'; else printf 'hosts=0\n'; fi
}

# ---- 安装系统级定时（一次 sudo）-------------------------------------------
#
# 安装块由用户手动粘贴执行（`setup.sh hosts-install-block | bash`），内部
# 开头 `sudo -v` 缓存一次凭据，于是后续 install/tee/systemctl 都免密。
# 不走 pkexec：本机 polkit 的 PAM 栈缺失，密码认证恒失败（实测）。
# 安装块只执行 root 所有的二进制，绝不含用户可写内容。

hst_sys_timer_on() {
  systemctl is-enabled "${HST_SYS_UNIT}.timer" >/dev/null 2>&1
}

# root 侧的刷新器：与本文件同逻辑，但必须独立成文（装成 root 所有，
# 不能 source 用户可写的插件文件，否则等于把 root 交给插件目录）。
hst_refresh_script() {
  cat <<'ROOTEOF'
#!/usr/bin/env bash
# horizon.setup — GitHub hosts 每日刷新（root 侧，由系统 timer 调用）
# 与插件 lib/hosts.sh 同一逻辑，但独立成文：本文件装为 root:root，避免
# 「root 执行用户可写脚本」这一红线。
set -euo pipefail
URL="${HORIZON_HOSTS_URL:-https://hosts.gitcdn.top/hosts.txt}"
# 环境变量可覆盖，仅为测试留口；生产由 systemd 以 root 跑，环境受控。
FILE="${HORIZON_HOSTS_FILE:-/etc/hosts}"
START='# horizon.setup:github-hosts'
END='# horizon.setup:github-hosts-end'
MAX=400

valid_line() {
  # 恰好两个字段：IP + 主机名。用 read 拆分，避免嵌套引号参数展开。
  local ip host extra
  read -r ip host extra <<< "$1"
  [[ -n "$ip" && -n "$host" && -z "$extra" ]] || return 1
  [[ "$host" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    local o; IFS=. read -r -a o <<< "$ip"; local x
    for x in "${o[@]}"; do ((x <= 255)) || return 1; done
    return 0
  fi
  [[ "$ip" =~ ^[0-9A-Fa-f:]+$ && "$ip" == *:* ]] && return 0
  return 1
}

# ---- 候选 IP 池 + 探活 ----------------------------------------------------
#
# 为什么必须有这一步（都是本机实测，不是推测）：
#   1. 上游快照与**所有**公共 DNS 对 github.com 都只给 20.205.243.166 一条 A
#      记录，而该地址会整段死亡。单 IP 钉死 ⇒ 实测 0/10 可用。
#   2. 同一份 hosts 里给 github.com 写 6 个候选 ⇒ 实测 9/10 可用（glibc 返回
#      全部地址，客户端逐个 connect，死的被跳过）。差别不在 hosts 写法，只在
#      「有几条候选」。
#   3. 探活后立刻复用「刚探活成功的那个 IP」成功率只有 3/10（TLS 阶段概率性
#      阻断），故**必须把存活 IP 全部写入**，不能只写最快的那一个。
# 故：对核心域名并行探活，把存活 IP 全量写进 hosts；探测全灭时保留上游原行兜底。
# 注意并非所有域名都救得回来（实测三类，详见 README 的「已知天花板」）：
#   A 单 IP 死、池中有活 → 探活有效（github.com / api / codeload）
#   B 整段同时死         → 无效（raw / objects 共用 185.199.108-111.133）
#   C 按域名 SNI 阻断    → 无效（gist 换 7 个 IP 全 reset）
# B/C 两类探活全灭、走上游兜底，属预期行为，不是 bug。
POOL_DOMAINS='github.com api.github.com codeload.github.com raw.githubusercontent.com objects.githubusercontent.com gist.github.com'

pool_ips() {
  case "$1" in
    github.com)   echo "140.82.113.3 140.82.113.4 140.82.112.3 140.82.114.3 140.82.114.4 20.205.243.169 20.205.243.166" ;;
    api.github.com) echo "20.205.243.168 140.82.113.6 20.205.243.166" ;;
    codeload.github.com) echo "20.205.243.165 140.82.113.9" ;;
    raw.githubusercontent.com|objects.githubusercontent.com)
                  echo "185.199.108.133 185.199.109.133 185.199.110.133 185.199.111.133" ;;
    gist.github.com) echo "20.205.243.166 140.82.112.3 140.82.113.3" ;;
    *)            echo "" ;;
  esac
}

# 单个 (域名, IP) 探活：--resolve 绕过本机 hosts/解析，直连该 IP 并说该 SNI。
#
# 判据必须**两层**，只判 HTTP 状态码会放进假节点：
#   * 状态码：200/301/302/403/404 都算链路成立（403/404 说明 TCP 与 TLS 已过，
#     只是路径不对）；连不上/握手失败（curl 返回 000）算死。
#   * 指纹：真 GitHub 的应答必带 `strict-transport-security`、`server: github.com`
#     或 `etag` 之一；只会回 `text/plain "OK"` 的中转/劫持节点三个都没有。
#
# 为什么指纹不可省（真机踩过，实测）：/etc/hosts 里 github.com 的一个候选
# 20.205.243.169 的 TCP/TLS 全通、HTTP 回 200，但任何 git 请求都只拿到
# `text/plain "OK"` —— git 于是报 `info/refs not valid: is this a git repository?`，
# 而浏览器、gh auth、curl 首页全都正常，表面上看不出问题。只看状态码的探活
# 会把它当活 IP 写进 hosts，于是每天刷新后 push 就随机失败一次。
probe_one() {
  local hdr code fp
  hdr=$(curl -sS -o /dev/null -D - --connect-timeout 2 --max-time 4 \
              --resolve "$1:443:$2" "https://$1/" 2>/dev/null) || return 0
  code=$(printf '%s\n' "$hdr" | sed -n 's|^HTTP/[0-9.]* \([0-9][0-9][0-9]\).*|\1|p' | tail -1)
  case "$code" in 200|301|302|403|404) ;; *) return 0 ;; esac
  fp=$(printf '%s\n' "$hdr" | grep -icE '^(strict-transport-security|etag):|^server: *github\.com')
  [ "${fp:-0}" -gt 0 ] || return 0
  printf '%s %s\n' "$2" "$1"
}

# 全池并行探活，输出 `<ip> <domain>` 行。没有存活项时输出为空。
probe_pool() {
  local d ip dir f
  dir=$(mktemp -d)
  for d in $POOL_DOMAINS; do
    for ip in $(pool_ips "$d"); do
      ( probe_one "$d" "$ip" > "$dir/$d@$ip" ) &
    done
  done
  wait || true
  for f in "$dir"/*; do
    [ -s "$f" ] && cat "$f"
  done
  rm -rf "$dir"
  return 0
}

# stdin = 上游校验过的映射；stdout = 核心域名换成多行存活 IP 的映射。
# 某域名一个存活 IP 都没有时保留上游那一行（宁可赌一次，也不留空）。
#
# 末尾必须 return 0：最后一个 read 到 EOF 会返回 1，而调用方是
# `raw=$(... | apply_probe)`，在上层 set -e 下会把整个刷新器带走。
apply_probe() {
  local probed line ip host a
  local -A alive=()
  probed=$(probe_pool)
  while read -r a host; do
    [ -n "${host:-}" ] && alive["$host"]+="$a"$'\n'
  done <<< "$probed"

  while IFS= read -r line; do
    if [ -z "${line//[[:space:]]/}" ] || [[ "$line" =~ ^[[:space:]]*# ]]; then
      printf '%s\n' "$line"; continue
    fi
    read -r ip host _ <<< "$line"
    if [ -n "${alive[$host]:-}" ]; then
      while read -r a; do
        [ -n "$a" ] && printf '%s %s\n' "$a" "$host"
      done <<< "${alive[$host]}"
    else
      printf '%s\n' "$line"
    fi
  done
  return 0
}

# 从 stdin 读 hosts，去掉「本插件的块」与「外部工具的遗留块」，并把尾部
# 空行收掉，输出到 stdout。
#
# 三个真实故障点（都由 tests/hosts_test.sh 用**真实样本**锁住）：
#  1. 遗留块的起始行**带后缀**，如 `# github-hosts:start  (maxiaof/..., 2026-10-15)`，
#     故必须**前缀匹配**，全等比较 `$0==l1s` 永远匹配不上 → 遗留块永久残留。
#  2. 旧写法 `$0==l1e{skip=0;next}` 在 **skip 已经是 0** 时也照样 `next`（不打印），
#     于是每次刷新都把外部的 end 标记**吞掉**，而 start 又因 1) 不置位，
#     两者叠加就得到「start+数据永远留着、end 已消失」的畸形状态。
#  3. 渲染时每次 `printf '\n...'` 追加一个空行，从不收尾 ⇒ 空行逐次堆积。
# 故改为：整文件先读入内存（hosts 几百行），按「区间」判定丢弃，最后只收
# 一次尾部空行。
strip_block() {
  awk -v s="$START" -v e="$END" \
      -v l1s='# github-hosts:start' -v l1e='# github-hosts:end' \
      -v l2s='# Github Hosts Start' -v l2e='# Github Hosts End' \
      -v l3s='# fetch-github-hosts begin' -v l3e='# fetch-github-hosts end' '
    { line[NR] = $0 }

    function is_lstart(t) {
      return index(t, l1s) == 1 || index(t, l2s) == 1 || index(t, l3s) == 1
    }
    function is_lend(t) {
      return index(t, l1e) == 1 || index(t, l2e) == 1 || index(t, l3e) == 1
    }

    END {
      i = 1
      while (i <= NR) {
        # 本插件的块（自己的起止都是**精确**文本，无后缀）
        if (line[i] == s) {
          j = i + 1
          while (j <= NR && line[j] != e) j++
          i = (j <= NR ? j + 1 : NR + 1)   # 缺 end 时丢到 EOF
          continue
        }
        # 外部遗留块：起始**前缀**匹配（容忍后缀）；到它的 end、或撞上
        # 本插件的起始时为止。撞上本插件起始不丢，交由上一段处理。
        if (is_lstart(line[i])) {
          j = i + 1
          while (j <= NR && !is_lend(line[j]) && line[j] != s) j++
          i = j
          continue
        }
        keep[++n] = line[i]
        i++
      }
      # 只收**尾部**空行（中间空行保留，它们是用户文件的可读性分隔）
      while (n > 0 && keep[n] ~ /^[[:space:]]*$/) n--
      for (k = 1; k <= n; k++) print keep[k]
    }
  '
}

case "${1:-refresh}" in
  on|refresh)
    # 关闭态不动 hosts（开关状态由插件侧的块存在性表达）
    grep -qxF "$START" "$FILE" || [ "${1:-}" = "on" ] || exit 0
    raw=$(curl -fsSL --max-time 30 "$URL") || { echo "horizon.setup: 抓取失败" >&2; exit 1; }
    raw=$(printf '%s\n' "$raw" | sed -e '/^# fetch-github-hosts/d' -e '/^# last fetch time:/d' -e '/^# update url:/d')
    n=0
    while IFS= read -r line; do
      n=$((n+1)); (( n <= MAX )) || exit 1
      [[ -z "${line//[[:space:]]/}" ]] && continue
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      valid_line "$line" || { echo "horizon.setup: 非法行 $line" >&2; exit 1; }
    done <<< "$raw"
    # 探活：把核心域名换成「当时真正连得上」的多个 IP。用环境变量可关，
    # 测试靠它断网（否则每个 fixture 用例都会去 curl 真实网络）。
    if [ "${HORIZON_HOSTS_PROBE:-1}" = 1 ]; then
      raw=$(printf '%s\n' "$raw" | apply_probe)
    fi
    tmp=$(mktemp); chmod 600 "$tmp"
    { strip_block < "$FILE"; printf '\n%s\n%s\n%s\n' "$START" "$raw" "$END"; } > "$tmp"
    mv "$tmp" "$FILE"; chmod 644 "$FILE"
    ;;
  off)
    grep -qxF "$START" "$FILE" || exit 0
    tmp=$(mktemp); chmod 600 "$tmp"
    strip_block < "$FILE" > "$tmp"
    mv "$tmp" "$FILE"; chmod 644 "$FILE"
    ;;
  *) echo "usage: $0 [on|off|refresh]" >&2; exit 2 ;;
esac
ROOTEOF
}

# 生成一次性安装块（stdout）。内容即命令：用户 `bash` 它执行，sudo 缓存
# 5 分钟故只输一次密码。**红线**：块内不得引用插件目录（用户可写）。
hst_emit_install_block() {
  # 全部用**未引号 heredoc** 以便展开 $HST_SYS_*（目标路径）。内容里的
  # `%i`、polkit 的 `==` 等都不含 $ 或反引号，安全。
  cat <<HDR
# ===== horizon.setup — GitHub hosts 安装（一次粘贴，一次密码）=====
# 装四件（全部 root:root）：
#   1. $HST_SYS_BIN                      root 刷新器
#   2. ${HST_SYS_UNIT_DIR}/${HST_SYS_UNIT}@.service   模板服务(on/off/refresh)
#   3. ${HST_SYS_UNIT_DIR}/${HST_SYS_UNIT}.timer      每日 04:00
#   4. /etc/polkit-1/rules.d/99-${HST_SYS_UNIT}.rules  免密放行本单元
#
# 装完后**运行时不再需要任何提权**：面板开关改用
#   systemctl start ${HST_SYS_UNIT}@on|off.service
# 走 polkit 规则免密，且不执行任何用户可写脚本（真正干活的是 root 刷新器）。
#
# sudo 缓存 5 分钟，故全程只输一次密码。
sudo -v
sudo /usr/bin/install -m 0755 -o root -g root /dev/stdin $HST_SYS_BIN <<'REFRESH_EOF'
HDR
  hst_refresh_script
  cat <<HDR2
REFRESH_EOF
sudo /usr/bin/tee ${HST_SYS_UNIT_DIR}/${HST_SYS_UNIT}@.service >/dev/null <<'SERVICE_EOF'
HDR2
  hst_service_template
  cat <<HDR3
SERVICE_EOF
sudo /usr/bin/tee ${HST_SYS_UNIT_DIR}/${HST_SYS_UNIT}.timer >/dev/null <<'TIMER_EOF'
HDR3
  hst_timer_unit
  cat <<HDR4
TIMER_EOF
sudo /usr/bin/tee /etc/polkit-1/rules.d/99-${HST_SYS_UNIT}.rules >/dev/null <<'POLICY_EOF'
HDR4
  hst_polkit_rule
  cat <<HDR5
POLICY_EOF
sudo /usr/bin/systemctl daemon-reload
sudo /usr/bin/systemctl enable --now ${HST_SYS_UNIT}.timer
sudo /usr/bin/systemctl start ${HST_SYS_UNIT}@on.service
echo "===== 安装完成 ====="
echo -n "timer: "; systemctl is-enabled ${HST_SYS_UNIT}.timer
echo -n "polkit 规则: "; ls -l /etc/polkit-1/rules.d/99-${HST_SYS_UNIT}.rules >/dev/null 2>&1 && echo 在位 || echo 缺失
echo -n "hosts 块条数: "; grep -c 'horizon.setup:github-hosts' /etc/hosts
echo -n "github.com 映射条数（探活已生效则为多条）: "; grep -cE '^[0-9.]+[[:space:]]+github\.com$' /etc/hosts
echo
echo "此后免密自检（应立即成功、无密码框）："
systemctl start ${HST_SYS_UNIT}@refresh.service && echo "  ★ systemctl start 免密成功"
HDR5
}


# ---- 模板 service / timer / polkit 规则（一次性安装的内容）---------------
#
# 为什么是 template（@）：安装一次后，运行时不再需要任何提权——开关只调
#   systemctl start horizon-setup-hosts@on.service / @off.service
# polkit 规则放行**仅本插件的单元**，故这条 systemctl 不弹密码、也不会把
# 「执行任意脚本」交给 root（真正的脚本是 root:root 的刷新器）。
#
# 确证的两个事实（白盒）：
#   * action id = org.freedesktop.systemd1.manage-units（默认 auth_admin）
#   * detail 键为 "unit" 与 "verb"（libsystemd-core-261 里 verb 作为独立
#     字符串仅出现 1 次，unit 出现 9 次）

# 模板服务：%i 取 on|off|refresh
hst_service_template() {
  cat <<EOF
[Unit]
Description=horizon.setup - update GitHub hosts (%i)
ConditionPathExists=$HST_SYS_BIN

[Service]
Type=oneshot
ExecStart=$HST_SYS_BIN %i
EOF
}

hst_timer_unit() {
  cat <<EOF
[Unit]
Description=horizon.setup - daily GitHub hosts refresh

[Timer]
OnCalendar=${HST_TIMER_TIME}
Persistent=true
Unit=${HST_SYS_UNIT}@refresh.service

[Install]
WantedBy=timers.target
EOF
}

# polkit 规则：只放行本插件的单元与三个动词，且只对 manage-units。
# 越权面 = 「谁都能让这一个单元跑一次刷新」，而该单元只写经白名单校验的
# GitHub hosts 映射，故风险有限且授权面远小于 empower 组那种全放行。
hst_polkit_rule() {
  # 单引号 heredoc 不做变量展开，故规则内单元名靠后续替换写死；这里用
  # 未引号 heredoc，让 ${HST_SYS_UNIT} 展开（JS 内无 $ 与反引号，安全）。
  cat <<POLKEOF
// horizon.setup：允许免密管理本插件的 hosts 刷新单元（仅 on/off/refresh）。
// 装为 root:root；授权面仅限本单元，不涉及其它任何 systemd 单元。
polkit.addRule(function(action, subject) {
    if (action.id != "org.freedesktop.systemd1.manage-units")
        return polkit.Result.NOT_HANDLED;
    var unit = action.lookup("unit");
    var verb = action.lookup("verb");
    if (unit && unit.indexOf("${HST_SYS_UNIT}@") == 0 &&
        (verb == "start" || verb == "stop" || verb == "restart"))
        return polkit.Result.YES;
    return polkit.Result.NOT_HANDLED;
});
POLKEOF
}

# 是否已完成一次性安装。
hst_installed() {
  [[ -x "$HST_SYS_BIN" && -f "$HST_SYS_UNIT_DIR/${HST_SYS_UNIT}@.service" ]]
}
