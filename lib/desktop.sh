#!/usr/bin/env bash
# horizon.setup — 桌面层：桌面海洋（ASCII 鲨鱼群）的开关与鲨鱼阵容。
#
# 被 setup.sh source，因此这里只定义函数，不执行动作。
#
# 配置独立成一份纯 key=value 文件，不与 Omarchy 自身配置混用：
# Omarchy 的 shell.json / hypr 配置由它自己管，插件只在旁边记自己的意图。
# 混写会让「卸载插件」和「用户手改 Omarchy」互相踩，且状态无法独立读回。
#
# 本文件只负责「意图」，不负责渲染：怎么把鲨鱼画到桌面上是渲染层的事，
# 后端只回答「开没开、阵容是什么」，两边靠 setup.sh 的文本契约解耦。

DESKTOP_CONF="${HORIZON_SETUP_CONF:-$HOME/.config/omarchy/horizon-setup.conf}"

# 种类白名单是 CLI 校验与面板选项的唯一来源：两边各写一份必然漂移，
# 新增一种鲨鱼要改两处、漏一处就变成「面板能选、脚本拒收」。
DESKTOP_SHARK_KINDS="classic hammerhead zebra tiger greathammer mako thresher nurse"
DESKTOP_SHARK_DEFAULT="classic"
# 上限 6 条：再多在桌面上也互相遮挡看不清，且每条都是独立一份光栅成本。
DESKTOP_SHARK_MAX=6

# ---- 读写基础 ---------------------------------------------------------------

# 读一个键的当前值（同键多行时后写覆盖先写）。键不存在则输出为空。
desktop_conf_get() { # $1=key
  [ -f "$DESKTOP_CONF" ] || return 0
  # 用 index() 定位而非 -F= 切分：值里本身可能带 =（如未来加的 URL）。
  awk -v k="$1" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2) }
                 END { if (v != "") print v }' "$DESKTOP_CONF"
}

# 原子写一个键：临时文件与目标同目录（跨文件系统 mv 不是原子替换），
# 写完 mv 覆盖，任何时刻读者只会看到完整的旧文件或完整的新文件。
# 同值直接返回，既保证「重复写字节不变」，也避免无谓改 mtime。
desktop_conf_set() { # $1=key $2=value
  local key=$1 val=$2 tmp
  if [ -f "$DESKTOP_CONF" ] && [ "$(desktop_conf_get "$key")" = "$val" ]; then
    return 0
  fi
  mkdir -p "$(dirname "$DESKTOP_CONF")" || return 1
  tmp=$(mktemp -- "$DESKTOP_CONF.XXXXXX") || return 1
  {
    # 先剔掉该键的旧行（含重复行），再追加唯一一行：文件永远不会长出
    # 同一键的两份，读侧不必猜哪个生效。
    if [ -f "$DESKTOP_CONF" ]; then
      grep -v "^${key}=" "$DESKTOP_CONF" || true
    fi
    printf '%s=%s\n' "$key" "$val"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 644 "$tmp"
  mv -f -- "$tmp" "$DESKTOP_CONF"
}

# ---- 检测 -------------------------------------------------------------------

desktop_ocean_on() { [ "$(desktop_conf_get desktop_ocean)" = 1 ]; }

# 阵容校验：白名单 + 条数上限 + 不许有空元素（"a,,b" 也算错）。
desktop_sharks_valid() { # $1=csv
  local csv=$1 kind
  local -a kinds
  [ -n "$csv" ] || return 1
  IFS=',' read -r -a kinds <<< "$csv"
  [ "${#kinds[@]}" -le "$DESKTOP_SHARK_MAX" ] || return 1
  for kind in "${kinds[@]}"; do
    # 两侧加空格做整词匹配，避免 "tiger" 命中 "greathammer" 这类子串误判。
    [[ " $DESKTOP_SHARK_KINDS " == *" $kind "* ]] || return 1
  done
  return 0
}

desktop_sharks() {
  local csv
  csv=$(desktop_conf_get desktop_sharks)
  # 手改文件可能塞进非法值。写入口是唯一校验点（拒绝并说明原因），
  # 但读侧也要兜底：把非法值原样交给渲染层只会画出怪物或直接崩，
  # 回落默认阵容是这里唯一安全的选择。
  if desktop_sharks_valid "$csv"; then
    printf '%s\n' "$csv"
  else
    printf '%s\n' "$DESKTOP_SHARK_DEFAULT"
  fi
}

# ---- 写入 -------------------------------------------------------------------

desktop_write_ocean() { # $1=0|1
  case "${1:-}" in
    0|1) ;;
    *) echo "desktop_ocean 只接受 0 或 1（收到: ${1:-}）" >&2; return 2 ;;
  esac
  # 关闭时保留 desktop_ocean=0 整行而不是删掉：状态要可读，
  # 删行会让「从没配过」和「明确关掉」在文件里长得一样。
  desktop_conf_set desktop_ocean "$1"
}

desktop_write_sharks() { # $1=csv
  local csv=${1:-}
  if ! desktop_sharks_valid "$csv"; then
    echo "未知的鲨鱼阵容: ${csv:-<空>}（只认 $DESKTOP_SHARK_KINDS，最多 $DESKTOP_SHARK_MAX 条，逗号分隔）" >&2
    return 2
  fi
  desktop_conf_set desktop_sharks "$csv"
}

# ---- 面板消费 ---------------------------------------------------------------

# 每行一条（TAB 分隔 4 列）：key  label  value  description
desktop_rows() {
  local on sharks
  if desktop_ocean_on; then on=1; else on=0; fi
  sharks=$(desktop_sharks)
  printf 'ocean\t桌面海洋\t%s\t把桌面背景换成 ASCII 鲨鱼群，鱼群会被鲨鱼捕食；点击穿透，不影响桌面操作\n' "$on"
  printf 'sharks\t鲨鱼阵容\t%s\t种类与条数决定热闹程度；每条鲨鱼都独立捕食\n' "$sharks"
}
