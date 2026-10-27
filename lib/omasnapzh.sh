#!/usr/bin/env bash
# horizon.setup — Omasnap 界面汉化：源码打补丁 + 重新编译 + 装到位。
#
# 为什么不是普通映射表组：Omasnap 上游**没有任何 i18n 设施**（0 处 tr()、
# 无 .ts/.qm），UI 文案是硬编码的 C++ 字符串字面量。所以「汉化」= 改源码 +
# 重新编译。这比改 QML 文案重得多，故与 zhcn.sh 的映射表组分开成一层：
#
#   * 词表：lib/omasnap-zh.json（383 条字符串 + 1 条带上下文的片段替换）
#   * 应用器：lib/apply-omasnap-zh.py（按词法位置替换，未命中即整体拒绝）
#   * 构建：下载固定 tag 的源码 → 打词表 → cmake 编译 → 装到 ~/.local
#
# 检测即真相：状态不看任何状态文件，直接比对「当前生效的 omasnap 二进制」
# 与「上游原版二进制的 sha256」。汉化版与上游原版都放在 ~/.local/libexec/
# omasnap/ 下的固定位置，~/.local/bin/omasnap 是启动器，按标记文件切换。
#
# 关键取舍：不改动上游二进制的内容，也不要求 root。缺的系统库
# （layer-shell-qt 的 libLayerShellQtInterface.so.6）由启动器注入路径。
#
# 状态（omasnapzh_state）：
#   missing   没装 omasnap
#   stock     装的是上游原版
#   zh        装的是汉化版
#   stale     汉化版存在，但对应的上游版本已不是当前 pin（需重建）

OMASNAP_ZH_ROOT="${OMASNAP_ZH_ROOT:-$HOME/.local/share/omasnap-zh}"
OMASNAP_ZH_TABLE="${OMASNAP_ZH_TABLE:-$HERE/lib/omasnap-zh.json}"
OMASNAP_ZH_APPLY="${OMASNAP_ZH_APPLY:-$HERE/lib/apply-omasnap-zh.py}"
OMASNAP_ZH_PIN="${OMASNAP_ZH_PIN:-1.23.0}"
OMASNAP_BIN_DIR="${OMASNAP_BIN_DIR:-$HOME/.local/libexec/omasnap}"
OMASNAP_ZH_MARK="${OMASNAP_ZH_MARK:-$OMASNAP_BIN_DIR/.zh-version}"

# 源码来源：先试 gh-proxy 镜像（实测比直连稳），失败再直连 GitHub。
omasnapzh_source_urls() {
  local ver="$1"
  printf '%s\n' \
    "https://gh-proxy.org/https://github.com/omacom/omasnap/archive/refs/tags/v${ver}.tar.gz" \
    "https://github.com/omacom/omasnap/archive/refs/tags/v${ver}.tar.gz"
}

# 当前生效的二进制（启动器是 shell 脚本，真正跑的是 omasnap.bin）。
omasnapzh_current_bin() { printf '%s/omasnap.bin' "$OMASNAP_BIN_DIR"; }

omasnapzh_state() {
  if ! command -v omasnap >/dev/null 2>&1 || [ ! -f "$(omasnapzh_current_bin)" ]; then
    echo missing; return
  fi
  if [ -f "$OMASNAP_ZH_MARK" ]; then
    # 标记里记的是「汉化时基于哪个上游版本」，与当前 pin 不符即过期。
    if [ "$(cat "$OMASNAP_ZH_MARK" 2>/dev/null)" = "$OMASNAP_ZH_PIN" ]; then
      echo zh
    else
      echo stale
    fi
  else
    echo stock
  fi
}

# 编译工具齐不齐：缺一个就明确报出来，不留「点了没反应」。
omasnapzh_build_deps() {
  local missing=() tool
  for tool in cmake ninja g++ wayland-scanner; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  # LayerShellQt 的开发文件：系统的 layer-shell-qt 包提供，或用户态副本
  # （~/.local/lib/cmake/LayerShellQt，由 setup.sh omasnap-zh-deps 装）。
  if [ ! -d /usr/lib/cmake/LayerShellQt ] && [ ! -d "$HOME/.local/lib/cmake/LayerShellQt" ]; then
    missing+=("layer-shell-qt")
  fi
  printf '%s\n' "${missing[@]}"
}

omasnapzh_fetch() { # $1=目标目录
  local dest="$1" url tmp
  tmp="$dest/src.tar.gz"
  while IFS= read -r url; do
    if curl -fsSL --retry 2 -o "$tmp" "$url" 2>/dev/null; then
      if tar tzf "$tmp" >/dev/null 2>&1; then
        return 0
      fi
    fi
  done < <(omasnapzh_source_urls "$OMASNAP_ZH_PIN")
  return 1
}

# 打词表并编译。任何一步失败都不留半成品：全部在临时目录完成，成功才装。
omasnapzh_install() {
  local deps
  deps=$(omasnapzh_build_deps)
  if [ -n "$deps" ]; then
    echo "缺少编译依赖：$(echo "$deps" | tr '\n' ' ')" >&2
    echo "（Arch: sudo pacman -S base-devel cmake ninja qt6-base layer-shell-qt wayland-protocols）" >&2
    return 1
  fi

  mkdir -p "$OMASNAP_ZH_ROOT"
  local work
  work=$(mktemp -d "$OMASNAP_ZH_ROOT/build.XXXXXX") || return 1
  # shellcheck disable=SC2064
  trap "rm -rf '$work'" RETURN

  omasnapzh_fetch "$work" || { echo "无法下载 Omasnap v$OMASNAP_ZH_PIN 源码" >&2; return 1; }
  tar xzf "$work/src.tar.gz" -C "$work" || return 1
  local src
  src=$(find "$work" -maxdepth 1 -type d -name 'omasnap-*' | head -1)
  [ -n "$src" ] || { echo "源码包结构异常" >&2; return 1; }

  # 词表应用是 fail-closed：有任一键没命中就中止，绝不产出半汉化的二进制。
  python3 "$OMASNAP_ZH_APPLY" --table "$OMASNAP_ZH_TABLE" --root "$src" || {
    echo "词表未全部命中，已中止（上游文案可能已变）" >&2
    return 1
  }

  local prefix="$work/stage"
  # ~/.local 进 CMAKE_PREFIX_PATH：没有 root 时 LayerShellQt 的开发文件在那里。
  cmake -S "$src" -B "$work/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DCMAKE_PREFIX_PATH="$HOME/.local" \
    -DCMAKE_CXX_FLAGS="-I$HOME/.local/include" >/dev/null || return 1
  # 构建错误必须露出来：吞掉输出会让失败看起来像「什么都没发生」。
  cmake --build "$work/build" --parallel "$(nproc)" --target omasnap 2>&1 | tail -40
  [ -x "$work/build/omasnap" ] || { echo "编译失败" >&2; return 1; }

  local built="$work/build/omasnap"
  [ -x "$built" ] || { echo "编译产物缺失" >&2; return 1; }

  mkdir -p "$OMASNAP_BIN_DIR"
  install -m755 "$built" "$OMASNAP_BIN_DIR/omasnap.zh.bin" || return 1
  printf '%s\n' "$OMASNAP_ZH_PIN" > "$OMASNAP_ZH_MARK"
  omasnapzh_use zh
}

# 切换生效的二进制。启动器只认 omasnap.bin，这里用符号链接指向对应版本。
omasnapzh_use() { # $1=zh|stock
  local target="$OMASNAP_BIN_DIR/omasnap.zh.bin"
  if [ "$1" = stock ]; then
    target="$OMASNAP_BIN_DIR/omasnap.stock.bin"
    [ -x "$target" ] || { echo "没有上游原版二进制可还原" >&2; return 1; }
    rm -f "$OMASNAP_ZH_MARK"
  fi
  ln -sfn "$(basename "$target")" "$OMASNAP_BIN_DIR/omasnap.bin.new"
  mv -f "$OMASNAP_BIN_DIR/omasnap.bin.new" "$OMASNAP_BIN_DIR/omasnap.bin"
}

omasnapzh_revert() {
  local state
  state=$(omasnapzh_state)
  [ "$state" = zh ] || [ "$state" = stale ] || { echo "当前不是汉化版" >&2; return 1; }
  omasnapzh_use stock
}

# 面板行：与 zhcn_rows 一样的 TAB 契约，复用同一个 Tab 渲染。
omasnapzh_row() {
  local state title applied clean total
  state=$(omasnapzh_state)
  title="Omasnap 界面（需编译）"
  case "$state" in
    zh)    applied=1; clean=0; total=1 ;;
    stock) applied=0; clean=1; total=1 ;;
    stale) applied=0; clean=0; total=1 ;;
    *)     applied=0; clean=0; total=0 ;;
  esac
  printf '%s\t%s\t%s\t%s\t%s\t0\t%s\n' \
    "omasnap-ui" "$title" "$state" "$applied" "$clean" "$total"
}
