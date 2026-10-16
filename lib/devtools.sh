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

# GitHub 加速。开关状态只看 git 配置——它是**免密且必成**的，面板点击必须
# 即时响应。hosts 改写需要 root，而 root 授权（pkexec/polkit）在本机并
# 不总是可用，若把它算进开关状态，授权一失败开关就「点不动」（真 bug）。
# hosts 部分的状态独立展示（ghhosts/ghtimer），开启时做**有界尝试**、失败
# 不阻塞开关。
dev_ghproxy_on() {
  [[ "$(git config --global --get "$DEV_GHPROXY_KEY" 2>/dev/null)" == "https://github.com/" ]]
}

# 每日定时状态（面板独立展示）。
dev_ghproxy_timer_on() { hst_sys_timer_on; }

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

# 开/关 GitHub 代理：git fetch 镜像即时必成；hosts 改写是**有界尝试**，
# 成功与否都不影响开关（详见 dev_ghproxy_on 的注释）。
# 开/关 GitHub 加速。
#   git 部分：免密、即时、必成 —— 开关的成败只由它决定。
#   hosts 部分：需要 root，做成**有界尝试**（默认 8s），失败只降级不阻塞。
# 这样面板点击永远有响应，hosts 是否就绪看 ghhosts/ghtimer 两个状态位。
DEV_HOSTS_ATTEMPT_TIMEOUT="${DEV_HOSTS_ATTEMPT_TIMEOUT:-8}"

dev_write_ghproxy() {
  if [[ "$1" == 1 ]]; then
    git config --global "$DEV_GHPROXY_KEY" "https://github.com/"
    # 一律走 hst_write 1（强制 @on 写入）。**不能用 hst_refresh 抄近路**：
    # hst_refresh 首行是 `hst_on || return 0`（只在「已开启」时刷新，给每日
    # 定时用）。而开关刚被关掉后块已不存在 ⇒ 它会直接 return 0 什么都不做，
    # 结果是「关了就再也开不回来」（真 bug，由 off-then-on 闸门锁住）。
    # 必须在**当前 shell** 调用：bash -c 起新 shell，看不到已 source 的函数，
    # 会静默 command not found（真 bug，由另一闸门锁住）。
    if ! hst_write 1; then
      hst_err "git 镜像已开启；hosts 改写未完成（需 root 授权或超时）。可执行: setup.sh hosts-install-block | bash"
    fi
  else
    git config --global --unset "$DEV_GHPROXY_KEY" 2>/dev/null || true
    if ! hst_write 0; then
      hst_err "git 镜像已关闭；hosts 块未移除（需 root 授权或超时）。"
    fi
  fi
}
