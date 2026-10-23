#!/usr/bin/env bash
# horizon.setup — Google 翻译 hosts 管理（把 translate.googleapis.com 指到
# 当前真正能返回译文的 IP）。
#
# 背景（本机实测，2026-10）：
#   * Chrome/Chromium 的网页翻译只调 translate.googleapis.com。该域名在
#     国内的解析被指到不可用的国外地址（实测 74.125.x / 173.194.x / 192.179.x
#     全部 TCP 超时），于是浏览器翻译整体失效。
#   * 网上流传的做法（「ping google.cn 拿到 IP 写进 hosts」）**今天已失效**：
#     实测 113.108.239.x（www.google.cn 所在段）整个 /24 没有一个 IP 带翻译
#     后端；120.253.255.98 这类老答案对 /translate_a/* 一律 404。
#   * 真正可用的是少数国家 GFE 节点，且**与 DNS 答案不在同一主机地址**：实测
#     同一 /24 里 DNS 给的 .95 是死的，而 .101/.138/.139/.148 可用。故候选池
#     必须包含「同 /24 的邻居」，光用 DNS 答案一定全灭。
#   * 命中率极低：实测 108.177.0.0/16 约 2800 个地址里只有 9 个可用（约 0.3%），
#     且状态小时级漂移（同一 IP 十分钟前 200、十分钟后 429/超时）。所以：
#     每天重探、把**所有**存活 IP 全量写进 hosts（glibc 会逐个 connect）。
#
# 判据（不能只看状态码，本机踩过）：
#   绝大多数 IP 对 translate.googleapis.com 会回 **200/404 但内容是 Google 的
#   错误页**（该 GFE 上没有翻译后端），只看状态码会把它们当活节点写进 hosts，
#   翻译依旧是坏的。唯一可靠判据是**真的拿到那句译文**：探测用
#   translate_a/t?client=chrome&sl=en&tl=zh-CN&q=hello，应答必须严格等于
#   `["你好"]`。这是功能级判据，不是连通性判据。
#
# 安全模型（与 lib/hosts.sh 同一红线）：
#   写 /etc/hosts 需要 root，但**绝不提权本插件的脚本**（插件目录用户可写，
#   提权它等于把「改写本文件」变成 root 执行）。做法：安装阶段用 sudo 执行
#   root 所有的 /usr/bin/install 与 /usr/bin/tee，把刷新器装成 root:root；
#   此后运行时只用 systemctl 触发，由 polkit 规则免密放行。
#
# 被 setup.sh source，因此这里只定义函数，不执行动作。

# 标记块边界（/etc/hosts 中本模块管理的区间），与 github 块互不重叠。
GT_START='# horizon.setup:gtranslate'
GT_END='# horizon.setup:gtranslate-end'
GT_HOST='translate.googleapis.com'
GT_FILE="${GT_FILE:-/etc/hosts}"

# root 侧安装物：刷新器脚本 + 系统级 timer（与 github 那套相互独立）。
GT_SYS_UNIT="${GT_SYS_UNIT:-horizon-setup-gtranslate}"
GT_SYS_BIN="${GT_SYS_BIN:-/usr/local/bin/horizon-setup-gtranslate-refresh}"
GT_SYS_UNIT_DIR="${GT_SYS_UNIT_DIR:-/etc/systemd/system}"
GT_TIMER_TIME="${GT_TIMER_TIME:-*-*-* 04:20:00}"
# 探活缓存：只当**加速线索**用，里面每条仍要重新探活才认（检测即真相）。
GT_CACHE="${GT_CACHE:-/var/lib/horizon-setup/gtranslate-ips}"

gt_err() { printf 'horizon.setup: %s\n' "$*" >&2; }

# ---- 检测 -----------------------------------------------------------------

# hosts 管理块是否存在。
gt_on() {
  [[ -r "$GT_FILE" ]] && grep -qxF "$GT_START" "$GT_FILE"
}

# 是否已完成一次性安装。
gt_installed() {
  [[ -x "$GT_SYS_BIN" && -f "$GT_SYS_UNIT_DIR/${GT_SYS_UNIT}@.service" ]]
}

# 状态：块存在即开启。
gt_status() {
  if gt_on; then printf 'gtranslate=1\n'; else printf 'gtranslate=0\n'; fi
}

# ---- 运行时写盘（只走 systemctl，不再提权）-------------------------------

# $1 = 1 开启 / 0 关闭。
gt_write() {
  local inst
  if [[ "$1" == 1 ]]; then inst=on; else inst=off; fi
  if gt_installed; then
    systemctl start "${GT_SYS_UNIT}@${inst}.service"
  else
    gt_err "尚未安装 Google 翻译 hosts。一次性安装: setup.sh gtranslate-install-block | bash"
    return 1
  fi
}

# 供每日定时/手动调用：只在「已开启」时刷新（关闭态不动 hosts）。
gt_refresh() {
  gt_on || return 0
  gt_installed || { gt_err "尚未安装 Google 翻译 hosts"; return 1; }
  systemctl start "${GT_SYS_UNIT}@refresh.service"
}

# ---- root 侧刷新器（装成 root:root 的独立脚本）----------------------------
#
# 与插件 lib 里这段是同一逻辑，但必须独立成文：不能 source 用户可写的插件
# 文件，否则等于把 root 交给插件目录。
gt_refresh_script() {
  cat <<'ROOTEOF'
#!/usr/bin/env bash
# horizon.setup — Google 翻译 hosts 刷新（root 侧，由系统 timer 或 polkit 触发）
set -euo pipefail

HOST='translate.googleapis.com'
FILE="${HORIZON_GT_FILE:-/etc/hosts}"
START='# horizon.setup:gtranslate'
END='# horizon.setup:gtranslate-end'
CACHE="${HORIZON_GT_CACHE:-/var/lib/horizon-setup/gtranslate-ips}"
# 单次刷新最多探多少个地址。5 个种子段 + 线索 /24 展开约 1500 个，会被截到
# 这个数；因为 candidates 按「可信度降序」输出（线索 → 种子段），截断切掉的
# 只是最不可能命中的尾部，不影响正确性，只影响那一轮能发现几个节点。
MAX_PROBE="${HORIZON_GT_MAX_PROBE:-1200}"
# 同时开多少个探测进程。
JOBS="${HORIZON_GT_JOBS:-24}"
# 探活开关：测试靠它断网。
PROBE_ON="${HORIZON_GT_PROBE:-1}"
# 期望译文。判据是「真的拿到这句译文」，不是状态码。
EXPECT='["你好"]'
Q='q=hello'

# 只认「IP 主机名」两字段的合法行（与 github 块同一闸门）。
valid_line() {
  local ip host extra
  read -r ip host extra <<< "$1"
  [[ -n "$ip" && -n "$host" && -z "$extra" ]] || return 1
  [[ "$host" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    local o; IFS=. read -r -a o <<< "$ip"; local x
    for x in "${o[@]}"; do ((x <= 255)) || return 1; done
    return 0
  fi
  return 1
}

# 单个 IP 探活：--resolve 绕过本机 hosts/解析，直连该 IP 并说该 SNI。
# 仅当应答**严格等于**期望译文才认活（见文件头「判据」）。
probe_one() {
  local ip="$1" out
  out=$(curl -s --max-time 4 --connect-timeout 2 \
              --resolve "$HOST:443:$ip" \
              "https://$HOST/translate_a/t?client=chrome&sl=en&tl=zh-CN&$Q" 2>/dev/null) || return 0
  [ "$out" = "$EXPECT" ] || return 0
  printf '%s\n' "$ip"
}

# 从 stdin 读候选 IP，并行探活，把存活 IP 逐行写 stdout。
# 去重且保序，避免同一 IP 被写进 hosts 两次。
#
# MAX_PROBE 的截断用**保序去重后的前 N 个**。调用方（candidates）负责把
# 最可信的线索排在前面（缓存里的上轮命中 → DNS 答案 → 种子段展开），
# 否则截断会把高价值候选切掉、只探一堆邻居（本模块第一版就是这样丢掉了
# 缓存线索）。
probe_many() {
  local dir ip
  dir=$(mktemp -d)
  awk '!seen[$0]++' | head -n "$MAX_PROBE" > "$dir/cand"
  while read -r ip; do
    [ -n "$ip" ] || continue
    ( probe_one "$ip" > "$dir/out.$ip" ) &
    while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n || true; done
  done < "$dir/cand"
  wait || true
  for f in "$dir"/out.*; do
    [ -s "$f" ] && cat "$f"
  done
  rm -rf "$dir"
  return 0
}

# 第一轮候选：只探**已有线索本身**（缓存里的上轮命中 + DNS 答案），不展开邻居。
# 目的：常态下这些线索仍然活着，几秒就能拿到足够多的 IP，无需扫 1200+ 个地址。
quick_candidates() {
  local ips=()
  [ -r "$CACHE" ] && ips+=( $(grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' "$CACHE" 2>/dev/null || true) )
  if [ "$PROBE_ON" = 1 ]; then
    ips+=( $(getent ahostsv4 "$HOST" 2>/dev/null | awk '{print $1}' | sort -u || true) )
  fi
  printf '%s\n' "${ips[@]:-}" | awk 'NF'
}

# 候选来源（全部只是**线索**，每一条都要过 probe_one）：
#   1. 上次刷新的存活清单（缓存）：最省时、命中率最高，且自带上一轮的 /24。
#   2. **种子网段**：本机实测反复验证过有翻译后端的 /24。这是最可靠的一档——
#      实测 DNS 会把它指到根本没有翻译后端的段（如 173.194.43.x，整段 0 命中），
#      只信 DNS 必然全灭；而种子段每次扫都能出节点。
#   3. 系统 DNS 答案：通常全灭，但很便宜，留着兜住「Google 换段」的情况。
#
# 种子段的来历（本机实测，不是抄来的）：2026-10 扫描 108.177.0.0/16 与若干
# GFE 段，逐 IP 用真实译文应答判定，反复命中的是 108.177.96/98/104/122 与
# 74.125.20 这几个 /24。它们会随时间漂移，所以：
#   * 种子只是起点，每条 IP 仍要过 probe_one；
#   * 缓存里记的是**上一轮真命中**的 IP，其 /24 会自动进入下一轮候选，
#     于是种子段失效时能被自动替换掉，不需要人肉改代码。
GT_SEED_SEGMENTS="${HORIZON_GT_SEED:-108.177.96 108.177.98 108.177.104 108.177.122 74.125.20}"

# 快路径够用的门槛：拿到这么多个存活 IP 就不必走慢路径。
GT_ENOUGH="${HORIZON_GT_ENOUGH:-3}"

# 慢路径：种子段 + 线索所在 /24 的完整邻居展开（约 1200 个地址，100s 量级）。
# 只有在快路径拿不到**足够**存活节点时才走。
deep_candidates() {
  local ips=() ip pfx seg
  [ -r "$CACHE" ] && ips+=( $(grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' "$CACHE" 2>/dev/null || true) )
  if [ "$PROBE_ON" = 1 ]; then
    ips+=( $(getent ahostsv4 "$HOST" 2>/dev/null | awk '{print $1}' | sort -u || true) )
  fi

  # **顺序即优先级**（probe_many 按 MAX_PROBE 保序截断）：
  #   1. 线索 IP 本身 —— 缓存里的上一轮命中，最可能还活着，最先探。
  #   2. 种子段与线索所在 /24 的邻居。
  # 反过来（先邻居后线索）会让截断吃掉最可信的那几条，本模块第一版就踩了。
  printf '%s\n' "${ips[@]:-}" | awk 'NF'

  # 需要展开成邻居的 /24 集合 = 种子段 + 每个线索 IP 所在 /24。
  # 注意这里不判断线索 IP 本身死活 —— 死的线索所在 /24 恰恰最可能有活节点
  # （实测 DNS 给的 .95 是死的、同 /24 的 .101/.138/.139/.148 可用）。
  local -A seen=()
  for seg in $GT_SEED_SEGMENTS; do
    [[ "$seg" =~ ^([0-9]{1,3}\.){2}[0-9]{1,3}$ ]] || continue
    seen[$seg]=1
  done
  for ip in "${ips[@]:-}"; do
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || continue
    seen[${ip%.*}]=1
  done
  for pfx in "${!seen[@]}"; do
    for i in $(seq 1 254); do printf '%s.%s\n' "$pfx" "$i"; done
  done
}

# 从 stdin 读 hosts，去掉本模块的块，输出到 stdout（与 github 块互不干扰：
# 只认自己的精确起止，绝不碰别人的区间）。
strip_gt_block() {
  awk -v s="$START" -v e="$END" '
    { line[NR] = $0 }
    END {
      i = 1
      while (i <= NR) {
        if (line[i] == s) {
          j = i + 1
          while (j <= NR && line[j] != e) j++
          i = (j <= NR ? j + 1 : NR + 1)
          continue
        }
        keep[++n] = line[i]
        i++
      }
      while (n > 0 && keep[n] ~ /^[[:space:]]*$/) n--
      for (k = 1; k <= n; k++) print keep[k]
    }
  '
}

# 缓存目录属 root；写失败只降级（缓存是加速项，不是事实源）。
save_cache() {
  local dir; dir=$(dirname "$CACHE")
  mkdir -p "$dir" 2>/dev/null || return 0
  { cat > "$CACHE.tmp" && mv "$CACHE.tmp" "$CACHE"; } 2>/dev/null || true
}

write_block() { # stdin = 已校验的映射行
  local body tmp
  body=$(cat)
  tmp=$(mktemp); chmod 600 "$tmp"
  { strip_gt_block < "$FILE"; printf '\n%s\n%s\n%s\n' "$START" "$body" "$END"; } > "$tmp"
  mv "$tmp" "$FILE"; chmod 644 "$FILE"
}

case "${1:-refresh}" in
  on|refresh)
    # 关闭态不动 hosts（开关状态由插件侧的块存在性表达）。
    grep -qxF "$START" "$FILE" || [ "${1:-}" = "on" ] || exit 0
    alive=""
    if [ "$PROBE_ON" = 1 ]; then
      # 两阶段：先只探已有线索（缓存里的上轮命中 + DNS 答案），几秒即可收工；
      # 只有它们凑不够 GT_ENOUGH 个存活节点时才展开 1200+ 个邻居地址
      # （那一步 100s 量级，不该变成每次刷新的常态开销）。
      alive=$(quick_candidates | probe_many)
      if [ "$(printf '%s\n' "$alive" | awk 'NF' | wc -l)" -lt "$GT_ENOUGH" ]; then
        echo "horizon.setup: 线索不足，展开邻居段深探（较慢）" >&2
        alive=$(deep_candidates | probe_many)
      fi
      save_cache <<< "$alive"
      if [ -z "$alive" ]; then
        # 全灭：**不写块**。这与 GitHub 那套（保留上游原行兜底）刻意不同——
        # 那边上游快照本身常是好 IP，留着有意义；这里的兜底只能取 DNS 答案，
        # 而 DNS 答案实测就是不可用的（本机实测 173.194.43.95 连测三次全 DEAD）。
        # 写进去的后果是「块存在 ⇒ 状态位为真 ⇒ 面板显示已开启」，但翻译依旧
        # 坏 —— 这是本模块最不该有的假绿。宁可保持关闭态并明确报错。
        echo "horizon.setup: 本轮探活全灭（种子段与 DNS 段均无可用节点），不写块以免假绿" >&2
        exit 1
      fi
      # 存活 IP 全量写入：只写最快那个实测成功率低（TLS 概率性丢包）。
      # 已按 probe_one 判据验过「真能返回译文」，故状态位为真即代表可用。
      body=$(printf '%s\n' "$alive" | awk -v h="$HOST" 'NF{print $0" "h}')
    else
      # 逃生阀：探活被显式关掉（HORIZON_GT_PROBE=0，测试与离线调试用）。
      # 此时无从验证可用性，只能按 DNS 答案写，且**明说不保证可用**。
      ip=$(getent ahostsv4 "$HOST" 2>/dev/null | awk 'NR==1{print $1}')
      [ -n "${ip:-}" ] || { echo "horizon.setup: DNS 无答案，无法写块" >&2; exit 1; }
      echo "horizon.setup: 探活已关闭，按 DNS 答案写入 $ip（未经验证）" >&2
      body="$ip $HOST"
    fi
    # 写前逐行过闸门（探活结果同样不许放宽校验）。
    while IFS= read -r line; do
      [ -z "${line//[[:space:]]/}" ] && continue
      valid_line "$line" || { echo "horizon.setup: 非法行 $line" >&2; exit 1; }
    done <<< "$body"
    printf '%s\n' "$body" | write_block
    ;;
  off)
    grep -qxF "$START" "$FILE" || exit 0
    tmp=$(mktemp); chmod 600 "$tmp"
    strip_gt_block < "$FILE" > "$tmp"
    mv "$tmp" "$FILE"; chmod 644 "$FILE"
    ;;
  *) echo "usage: $0 [on|off|refresh]" >&2; exit 2 ;;
esac
ROOTEOF
}

# ---- 模板 service / timer / polkit 规则 -----------------------------------

# 模板服务：%i 取 on|off|refresh（与 github 那套同形，但独立单元名）。
gt_service_template() {
  cat <<EOF
[Unit]
Description=horizon.setup - Google Translate hosts (%i)
ConditionPathExists=$GT_SYS_BIN

[Service]
Type=oneshot
ExecStart=$GT_SYS_BIN %i
TimeoutStartSec=300
EOF
}

gt_timer_unit() {
  cat <<EOF
[Unit]
Description=horizon.setup - daily Google Translate hosts refresh

[Timer]
OnCalendar=${GT_TIMER_TIME}
Persistent=true
Unit=${GT_SYS_UNIT}@refresh.service

[Install]
WantedBy=timers.target
EOF
}

# polkit 规则：只放行本模块的单元与三个动词，且只对 manage-units。
gt_polkit_rule() {
  cat <<POLKEOF
// horizon.setup：允许免密管理本插件的 Google 翻译 hosts 刷新单元
// （仅 on/off/refresh）。授权面仅限本单元，不涉及其它任何 systemd 单元。
polkit.addRule(function(action, subject) {
    if (action.id != "org.freedesktop.systemd1.manage-units")
        return polkit.Result.NOT_HANDLED;
    var unit = action.lookup("unit");
    var verb = action.lookup("verb");
    if (unit && unit.indexOf("${GT_SYS_UNIT}@") == 0 &&
        (verb == "start" || verb == "stop" || verb == "restart"))
        return polkit.Result.YES;
    return polkit.Result.NOT_HANDLED;
});
POLKEOF
}

# 生成一次性安装块（stdout）。安装块只执行 root 所有的二进制，不含任何
# 用户可写内容（红线）。
gt_emit_install_block() {
  cat <<HDR
# ===== horizon.setup — Google 翻译 hosts 安装（一次粘贴，一次密码）=====
# 装四件（全部 root:root）：
#   1. $GT_SYS_BIN            root 刷新器
#   2. ${GT_SYS_UNIT_DIR}/${GT_SYS_UNIT}@.service     模板服务(on/off/refresh)
#   3. ${GT_SYS_UNIT_DIR}/${GT_SYS_UNIT}.timer        每日 ${GT_TIMER_TIME#*-*-* }
#   4. /etc/polkit-1/rules.d/99-${GT_SYS_UNIT}.rules  免密放行本单元
#
# 只改 /etc/hosts 里本插件的标记块，与 GitHub 加速那块互不干扰。
# sudo 缓存 5 分钟，故全程只输一次密码。
sudo -v
sudo /usr/bin/install -m 0755 -o root -g root /dev/stdin $GT_SYS_BIN <<'REFRESH_EOF'
HDR
  gt_refresh_script
  cat <<HDR2
REFRESH_EOF
sudo /usr/bin/install -d -m 0755 -o root -g root $(dirname "$GT_CACHE")
sudo /usr/bin/tee ${GT_SYS_UNIT_DIR}/${GT_SYS_UNIT}@.service >/dev/null <<'SERVICE_EOF'
HDR2
  gt_service_template
  cat <<HDR3
SERVICE_EOF
sudo /usr/bin/tee ${GT_SYS_UNIT_DIR}/${GT_SYS_UNIT}.timer >/dev/null <<'TIMER_EOF'
HDR3
  gt_timer_unit
  cat <<HDR4
TIMER_EOF
sudo /usr/bin/tee /etc/polkit-1/rules.d/99-${GT_SYS_UNIT}.rules >/dev/null <<'POLICY_EOF'
HDR4
  gt_polkit_rule
  cat <<HDR5
POLICY_EOF
sudo /usr/bin/systemctl daemon-reload
sudo /usr/bin/systemctl enable --now ${GT_SYS_UNIT}.timer
sudo /usr/bin/systemctl start ${GT_SYS_UNIT}@on.service
echo "===== 安装完成 ====="
echo -n "timer: "; systemctl is-enabled ${GT_SYS_UNIT}.timer
echo -n "polkit 规则: "; ls -l /etc/polkit-1/rules.d/99-${GT_SYS_UNIT}.rules >/dev/null 2>&1 && echo 在位 || echo 缺失
echo -n "翻译块条数: "; grep -c 'horizon.setup:gtranslate' /etc/hosts
echo -n "translate.googleapis.com 映射条数（探活已生效则为多条）: "
grep -cE '^[0-9.]+[[:space:]]+translate\.googleapis\.com$' /etc/hosts
echo
echo "此后免密自检（应立即成功、无密码框）："
systemctl start ${GT_SYS_UNIT}@refresh.service && echo "  ★ systemctl start 免密成功"
HDR5
}
