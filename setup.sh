#!/usr/bin/env bash
# horizon.setup — Omarchy 配置面板的后端：检测与切换。
#
# 设计原则：检测即真相。不维护任何状态文件，状态全部从系统/配置实读；
# 配置用带标记的管理块（marker block）幂等管理，toggle 先删旧块再按
# 开关当前状态重建，reload 后复读校验。
#
# 分层：
#   lib/macos.sh    Mac 习惯：快捷键桥接、自然滚动、剪贴板
#   lib/devtools.sh 开发环境：npm 换源、GitHub 代理
#   lib/firewall.sh 局域网：ufw 规则的读取与增删（读免权限，写走 pkexec）
#
# 用法:
#   setup.sh status
#   setup.sh toggle keys|scroll|clip|npm|ghproxy
#   setup.sh rules
#   setup.sh fw-add <port> <proto> <src> <comment> [action]
#   setup.sh fw-del <port> <proto> <src> <comment> [action]
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/macos.sh
source "$HERE/lib/macos.sh"
# shellcheck source=lib/devtools.sh
source "$HERE/lib/devtools.sh"
# shellcheck source=lib/firewall.sh
source "$HERE/lib/firewall.sh"

mac_ensure_hypr_env

b() { if "$1"; then echo 1; else echo 0; fi; }

status() {
  # 前五个字段的历史契约保持不变（面板与既有脚本依赖此顺序）。
  printf 'keys=%s scroll=%s clip=%s npm=%s ghproxy=%s ufw=%s rules=%s\n' \
    "$(b mac_keys_on)" "$(b mac_scroll_on)" "$(b mac_clip_on)" \
    "$(b dev_npm_on)" "$(b dev_ghproxy_on)" \
    "$(b fw_enabled)" "$(fw_list_merged | wc -l)"
}

# 规则列表：面板消费，每行一条（TAB 分隔）。
#   action proto dport src comment families iface
rules() { fw_rows; }

do_toggle() { # $1=target
  case "$1" in
    keys)
      local k s
      if mac_keys_on; then k=0; else k=1; fi
      s=$(b mac_scroll_on)
      mac_write_input_block "$k" "$s"
      mac_write_selectall_binding "$k"
      mac_write_textedit_bindings "$k"
      ;;
    scroll)
      local k s
      k=$(b mac_keys_on)
      if mac_scroll_on; then s=0; else s=1; fi
      mac_write_input_block "$k" "$s"
      ;;
    clip)
      local c
      if mac_clip_on; then c=0; else c=1; fi
      mac_write_clip_binding "$c"
      ;;
    npm)
      local n
      if dev_npm_on; then n=0; else n=1; fi
      dev_write_npm_registry "$n"
      ;;
    ghproxy)
      local g
      if dev_ghproxy_on; then g=0; else g=1; fi
      dev_write_ghproxy "$g"
      ;;
    *)
      echo "unknown toggle target: $1" >&2; exit 2
      ;;
  esac
}

usage() {
  cat >&2 <<'USAGE'
usage:
  setup.sh status
  setup.sh toggle keys|scroll|clip|npm|ghproxy
  setup.sh rules
  setup.sh fw-add <port> <proto> <src> <comment> [allow|deny|reject|limit]
  setup.sh fw-del <port> <proto> <src> <comment> [allow|deny|reject|limit]
USAGE
}

main() {
  case "${1:-}" in
    status)
      status
      ;;
    rules)
      rules
      ;;
    toggle)
      do_toggle "${2:-}"
      status
      ;;
    fw-add)
      [ $# -ge 5 ] || { usage; exit 2; }
      fw_add "$2" "$3" "$4" "$5" "${6:-allow}"
      status
      ;;
    fw-del)
      [ $# -ge 5 ] || { usage; exit 2; }
      fw_del "$2" "$3" "$4" "$5" "${6:-allow}"
      status
      ;;
    *)
      usage
      exit 2
      ;;
  esac
}

main "$@"
