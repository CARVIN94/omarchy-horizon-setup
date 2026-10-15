#!/usr/bin/env bash
# horizon.setup — 与 mac 习惯无关的开发环境开关：npm 换源、GitHub 代理。
#
# 被 setup.sh source，因此这里只定义函数，不执行动作。

DEV_NPMRC="${DEV_NPMRC:-$HOME/.npmrc}"
DEV_NPM_MIRROR="https://registry.npmmirror.com"

# GitHub 镜像前缀：git 的 insteadOf 会把 https://github.com/ 自动改写走代理。
# 只影响 https clone/fetch；push 仍走真实 origin（镜像是只读的，push 会失败）。
DEV_GHPROXY_KEY='url.https://gh-proxy.org/https://github.com/.insteadOf'

# ---- 检测 -----------------------------------------------------------------

# npm 换源：~/.npmrc 的 registry 指向 npmmirror（官方源则为关闭态）。
dev_npm_on() {
  [[ -f "$DEV_NPMRC" ]] && grep -q "^registry=${DEV_NPM_MIRROR}\$" "$DEV_NPMRC"
}

# GitHub 代理：git config --global insteadOf 把 github.com 改写到镜像。
dev_ghproxy_on() {
  [[ "$(git config --global --get "$DEV_GHPROXY_KEY" 2>/dev/null)" == "https://github.com/" ]]
}

# ---- 写入 -----------------------------------------------------------------

dev_write_npm_registry() {
  if [[ "$1" == 1 ]]; then
    touch "$DEV_NPMRC"
    if grep -q '^registry=' "$DEV_NPMRC"; then
      sed -i.bak "s|^registry=.*|registry=${DEV_NPM_MIRROR}|" "$DEV_NPMRC" && rm -f "$DEV_NPMRC.bak"
    else
      echo "registry=${DEV_NPM_MIRROR}" >> "$DEV_NPMRC"
    fi
  else
    # 关闭 = 移除本插件写入的镜像行（不留默认值，让 npm 回落官方源）。
    # sed 表达式用 | 分隔符（镜像 URL 含 /）。
    sed -i.bak "\|^registry=${DEV_NPM_MIRROR}\$|d" "$DEV_NPMRC" && rm -f "$DEV_NPMRC.bak"
    [ -s "$DEV_NPMRC" ] || rm -f "$DEV_NPMRC"
  fi
}

dev_write_ghproxy() {
  if [[ "$1" == 1 ]]; then
    git config --global "$DEV_GHPROXY_KEY" "https://github.com/"
  else
    git config --global --unset "$DEV_GHPROXY_KEY" 2>/dev/null || true
  fi
}
