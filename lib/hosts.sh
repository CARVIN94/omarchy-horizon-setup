#!/usr/bin/env bash
# horizon.setup — GitHub hosts 管理（把 github.com 等域名指到可用 IP）。
#
# 背景：国内访问 github.com 的 HTTPS 是按 SNI 的概率性阻断（DNS 干净、TCP
# 常通、TLS 阶段丢包），换 DNS/改 hosts 的 IP 都只能「挑当时相对好的那个」，
# 无法根治。本模块的作用是每天自动刷新一次 IP，让系统始终用上较新的快照。
#
# 被 setup.sh source，因此这里只定义函数，不执行动作。
#
# ---- 安全模型（重要）------------------------------------------------------
# 写 /etc/hosts 需要 root，但**绝不 pkexec 本插件的脚本**：插件目录用户可写，
# 提权它等于把「改写本文件」变成 root 执行（Omarchy 自己在 omarchy-windows-vm
# 里明令避免这点）。本模块只 pkexec root 所有的 /usr/bin/cp，传入的数据是
# 主机名映射表（数据，不是代码），不产生任意代码执行。
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
HST_PKEXEC="${HST_PKEXEC:-/usr/bin/pkexec}"
# 提权步骤的超时上限（秒）。留足时间给权限框，同时避免面板永久挂住。
HST_TIMEOUT="${HST_TIMEOUT:-20}"

hst_err() { printf 'horizon.setup: %s\n' "$*" >&2; }

# ---- 检测 -----------------------------------------------------------------

# hosts 管理块是否存在。
hst_on() {
  [[ -r "$HST_FILE" ]] && grep -qxF "$HST_START" "$HST_FILE"
}

# $1 = 1 开启 / 0 关闭。一次授权完成：装 root 刷新器 + 装每日 timer + 立即写 hosts
# （或反向卸载）。运行时一律经 systemctl，由 polkit 规则免密放行。
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

# ---- 安装/卸载系统级定时（一次 root）--------------------------------------
#
# 全部 root 侧动作打包进**同一个 pkexec**：polkit 对同一操作内的连续调用有
# 授权缓存，用户只输一次密码就同时完成「装刷新器 + 装 timer + 立即刷新」。
# 绝不 pkexec 本插件脚本：这里 pkexec 的是 /usr/bin/bash，参数是嵌在
# 命令行里的常量脚本路径（root 所有的目标路径），不含任何用户可写内容。

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

strip_block() {
  awk -v s="$START" -v e="$END" \
      -v l1s='# github-hosts:start' -v l1e='# github-hosts:end' \
      -v l2s='# Github Hosts Start' -v l2e='# Github Hosts End' \
      -v l3s='# fetch-github-hosts begin' -v l3e='# fetch-github-hosts end' '
    $0==s{skip=1;next} $0==e{skip=0;next}
    $0==l1s{skip=1;next} $0==l1e{skip=0;next}
    $0==l2s{skip=1;next} $0==l2e{skip=0;next}
    $0==l3s{skip=1;next} $0==l3e{skip=0;next}
    !skip'
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
