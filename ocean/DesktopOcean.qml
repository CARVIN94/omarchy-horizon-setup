import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import "Render.js" as Render
import "Species.js" as Species
import "World.js" as World

// 桌面海洋：把桌面背景换成 ASCII 鲨鱼群，鱼群会被鲨鱼捕食。
//
// 作为 service 插件常驻，但只有 desktop_ocean=1 时才真正创建窗口并跑帧，
// 关掉时零 CPU——这是桌面装饰，不该在用户没开的时候还占着渲染。
//
// 画在 WlrLayer.Bottom（壁纸之上、窗口之下），并设 mask: Region {} 让整个
// 表面不接收输入：桌面图标、右键菜单、拖拽文件全都照常工作。
// 这两点都在本机实测过，不是照文档抄的。
Item {
  id: root

  // 配置文件由 lib/desktop.sh 写、这里只读。两者唯一契约是这两个键。
  readonly property string confPath: Quickshell.env("HORIZON_SETUP_CONF")
      || (Quickshell.env("HOME") + "/.config/omarchy/horizon-setup.conf")

  property bool oceanOn: false
  property string sharksSpec: "classic"

  // 用户关掉了动画（omarchy toggle animations）时，桌面不该还在动：
  // 那台机器很可能就是因为 CPU 弱才关的。
  readonly property bool paused: Style.reduceMotion

  // 解析 "classic,hammerhead" → [{kind, size}]。第一个最大，后面依次缩小，
  // 这样同种鲨鱼也会因为大小不同产生深度层次。
  function parseSharks(csv) {
    var known = ["classic", "hammerhead", "greathammer", "tiger",
                 "zebra", "mako", "thresher", "nurse"]
    var out = []
    var parts = String(csv || "").split(",")
    for (var i = 0; i < parts.length && out.length < 6; i++) {
      var k = parts[i].trim()
      if (k === "") continue
      // 未知种类忽略而非回退：后端已经校验过，能走到这里说明文件被手改过，
      // 静默画一条经典鲨鱼比画一条错种类的鲨鱼更不容易误导。
      if (known.indexOf(k) === -1) continue
      out.push({ kind: k, size: 1 - out.length * 0.1 })
    }
    if (out.length === 0) out.push({ kind: "classic", size: 1 })
    return out
  }

  function applyConf(text) {
    var on = false
    var csv = "classic"
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (line === "" || line.charAt(0) === "#") continue
      var eq = line.indexOf("=")
      if (eq <= 0) continue
      var key = line.substring(0, eq).trim()
      var val = line.substring(eq + 1).trim()
      if (key === "desktop_ocean") on = (val === "1")
      else if (key === "desktop_sharks") csv = val
    }
    root.oceanOn = on
    root.sharksSpec = csv
  }

  FileView {
    id: confFile
    path: root.confPath
    watchChanges: true
    printErrors: false
    onLoaded: root.applyConf(text())
    // 文件被创建/改写时 text() 还是旧值，必须走 reload → onLoaded 才拿到新内容。
    onFileChanged: reload()
    // 配置文件不存在是正常状态（用户从没开过），等同于「关」。
    onLoadFailed: root.applyConf("")
  }

  Variants {
    model: Quickshell.screens

    delegate: OceanWindow {
      required property var modelData
      screen: modelData
      ocean: root
    }
  }
}
