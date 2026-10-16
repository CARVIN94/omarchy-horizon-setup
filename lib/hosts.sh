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

hst_err() { printf 'horizon.setup: %s\n' "$*" >&2; }

# ---- 检测 -----------------------------------------------------------------

# hosts 管理块是否存在。
hst_on() {
  [[ -r "$HST_FILE" ]] && grep -qxF "$HST_START" "$HST_FILE"
}

# $1 = 1 开启 / 0 关闭。一次授权完成：装 root 刷新器 + 装每日 timer + 立即写 hosts
# （或反向卸载）。真正的 root 动作在 hst_write_sys_timer 里。
hst_write() { hst_write_sys_timer "$1"; }

# 供每日定时/手动调用：只在「已开启」时刷新（关闭态不动 hosts）。
hst_refresh() {
  hst_on || return 0
  [[ -x "$HST_SYS_BIN" ]] && "$HST_SYS_BIN" refresh
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
  cat <<'HDR'
# ===== horizon.setup — GitHub hosts 安装（一次粘贴，一次密码）=====
# 装 root 刷新器 + 每日 04:00 系统级 timer + 立即写一次 hosts。
# 装完后每日自动刷新，零密码。sudo 缓存 5 分钟，故只需输一次。
sudo -v
sudo /usr/bin/install -m 0755 -o root -g root /dev/stdin /usr/local/bin/horizon-setup-hosts-refresh <<'REFRESH_EOF'
HDR
  hst_refresh_script
  cat <<'MID'
REFRESH_EOF
sudo /usr/bin/tee /etc/systemd/system/horizon-setup-hosts.service >/dev/null <<'SVC_EOF'
[Unit]
Description=horizon.setup - refresh GitHub hosts
After=network-online.target
ConditionPathExists=/usr/local/bin/horizon-setup-hosts-refresh

[Service]
Type=oneshot
ExecStart=/usr/local/bin/horizon-setup-hosts-refresh refresh
SVC_EOF
sudo /usr/bin/tee /etc/systemd/system/horizon-setup-hosts.timer >/dev/null <<'TMR_EOF'
[Unit]
Description=horizon.setup - daily GitHub hosts refresh

[Timer]
OnCalendar=*-*-* 04:00:00
Persistent=true
Unit=horizon-setup-hosts.service

[Install]
WantedBy=timers.target
TMR_EOF
sudo /usr/bin/systemctl daemon-reload
sudo /usr/bin/systemctl enable --now horizon-setup-hosts.timer
sudo /usr/bin/systemctl start horizon-setup-hosts.service
echo "===== 安装完成 ====="
systemctl is-enabled horizon-setup-hosts.timer
grep -c 'horizon.setup:github-hosts' /etc/hosts
MID
}

# $1 = 1 安装 / 0 卸载
hst_write_sys_timer() {
  local dir script
  dir=$(mktemp -d) || return 1
  chmod 700 "$dir"
  script="$dir/refresh.sh"
  hst_refresh_script > "$script" || { rm -rf "$dir"; return 1; }

  local unit="$dir/${HST_SYS_UNIT}.service"
  cat > "$unit" <<EOF
[Unit]
Description=horizon.setup - refresh GitHub hosts
After=network-online.target
ConditionPathExists=$HST_SYS_BIN

[Service]
Type=oneshot
ExecStart=$HST_SYS_BIN refresh
EOF
  local timer="$dir/${HST_SYS_UNIT}.timer"
  cat > "$timer" <<EOF
[Unit]
Description=horizon.setup - daily GitHub hosts refresh

[Timer]
OnCalendar=${HST_TIMER_TIME}
Persistent=true
Unit=${HST_SYS_UNIT}.service

[Install]
WantedBy=timers.target
EOF

  # 把「安装/卸载 + 立即刷新」压进同一次授权
  local runner="$dir/run.sh"
  cat > "$runner" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "1" ]]; then
  /usr/bin/install -m 0755 -o root -g root "$script" "$HST_SYS_BIN"
  /usr/bin/install -m 0644 -o root -g root "$unit" "${HST_SYS_UNIT_DIR}/${HST_SYS_UNIT}.service"
  /usr/bin/install -m 0644 -o root -g root "$timer" "${HST_SYS_UNIT_DIR}/${HST_SYS_UNIT}.timer"
  /usr/bin/systemctl daemon-reload
  /usr/bin/systemctl enable --now "${HST_SYS_UNIT}.timer"
  /usr/bin/systemctl start "${HST_SYS_UNIT}.service"   # 立即刷新一次（写入 hosts）
else
  /usr/bin/systemctl disable --now "${HST_SYS_UNIT}.timer" 2>/dev/null || true
  # 先删 hosts 块再卸载刷新器——顺序反了就删不掉了
  [[ -x "$HST_SYS_BIN" ]] && "$HST_SYS_BIN" off || true
  /usr/bin/rm -f "$HST_SYS_BIN" \
    "${HST_SYS_UNIT_DIR}/${HST_SYS_UNIT}.service" \
    "${HST_SYS_UNIT_DIR}/${HST_SYS_UNIT}.timer"
  /usr/bin/systemctl daemon-reload
fi
EOF
  chmod 700 "$runner"

  command -v "$HST_PKEXEC" >/dev/null 2>&1 || { hst_err "pkexec 不可用"; rm -rf "$dir"; return 127; }
  "$HST_PKEXEC" /usr/bin/bash "$runner" "$1"
  local rc=$?
  rm -rf "$dir"
  return $rc
}
