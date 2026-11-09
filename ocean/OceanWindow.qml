import QtQuick
import Quickshell
import Quickshell.Wayland
import "Render.js" as Render
import "Species.js" as Species
import "World.js" as World

// 单屏的海洋窗口：一个 PanelWindow + 一个独立 World + 一个 Canvas。
// 每屏各自一份仿真，多屏时鱼群不会跨屏「瞬移」。
PanelWindow {
  id: win

  required property var ocean

  visible: ocean.oceanOn
  anchors { top: true; bottom: true; left: true; right: true }
  color: "#000000"

  WlrLayershell.namespace: "horizon-ocean"
  WlrLayershell.layer: WlrLayer.Bottom
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  exclusionMode: ExclusionMode.Ignore
  // 空 Region = 整个表面不接收任何输入，桌面操作照常。
  mask: Region {}

  // 15Hz 固定步长。鱼群与鲨鱼都是慢动作，15fps 视觉上足够；
  // 实测每帧仿真 ~8ms、光栅 ~15ms，若按屏幕 60Hz 用 FrameAnimation 驱动，
  // 桌面常驻会稳定吃掉一整个核（实测 130%+ CPU）。
  readonly property real stepDt: 1 / 15
  property var world: null
  property var state: null
  property int lastCols: -1

  // Quickshell 在拿到真实尺寸前会先报 100x100（默认值）。用它播种会把
  // 85 条鱼全挤在左上角——之后尺寸变大只 clamp 边界、不重新播种，
  // 画面就永远是一小团（实测踩过，故此处直接忽略不合理的尺寸）。
  readonly property real minSpan: 200

  function ensureWorld(force) {
    if (width < minSpan || height < minSpan) return
    if (!state) state = Render.makeState()
    // 先定网格，再用网格尺寸播种：个人空间是按格给的。
    Render.resize(state, width, height, 1)
    // 网格列数变了说明屏幕尺寸真的变了，必须重新播种：
    // World.resize 只会把跑到界外的鱼拉回来，不会重新分布。
    var colsChanged = state.cols !== lastCols
    lastCols = state.cols
    if (!world || colsChanged || force === true) {
      world = World.makeWorld({ sharks: ocean.parseSharks(ocean.sharksSpec) })
      World.resize(world, width, height, state.cw, state.ch, Species)
    }
  }

  onWidthChanged: ensureWorld()
  onHeightChanged: ensureWorld()
  Component.onCompleted: ensureWorld()

  // 阵容变了要重建世界：鲨鱼的种类与条数是 seed 时定下的。
  Connections {
    target: ocean
    function onSharksSpecChanged() {
      if (!win.world) return
      // 必须让 ensureWorld 自己建并播种：在外面先 makeWorld 会让 world 非空，
      // 而 colsChanged 为 false 时它就不调 World.resize，新世界一条鱼都没有
      // （实测全黑）。种子只能由一处负责。
      win.ensureWorld(true)
    }
  }

  Canvas {
    id: canvas
    anchors.fill: parent
    renderStrategy: Canvas.Threaded

    // QML Canvas 的 canvasSize 默认等于逻辑尺寸，在 dpr=2 的屏幕上会被
    // 放大成 2 倍物理像素，ASCII 字形边缘发虚。按上游 renderer.resize()
    // 的做法显式给它物理像素尺寸，再把上下文缩放到逻辑坐标系。
    readonly property real dpr: win.screen ? win.screen.devicePixelRatio : 1
    canvasSize: Qt.size(Math.round(width * dpr), Math.round(height * dpr))

    onPaint: {
      var ctx = getContext("2d")
      var w = win.width, h = win.height
      ctx.reset()
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
      ctx.fillStyle = "#000000"
      ctx.fillRect(0, 0, w, h)
      if (!win.world || !win.state || win.state.cols === 0) return

      Render.raster(win.world, win.state, win.stepDt)

      // 字体与基线只在整帧开头设一次：每个字形都设一遍等于白送几万次属性写入。
      ctx.font = "600 " + Math.round(win.state.ch * 0.74) + "px monospace"
      ctx.textAlign = "left"
      ctx.textBaseline = "middle"
      Render.paint(ctx, win.state, win.world)
    }
  }

  // 只在真正显示、且用户没关动画时才跑。Timer 而非 FrameAnimation：
  // 仿真和绘制本来就是 15Hz，没必要跟着屏幕刷新率空转 60 次。
  Timer {
    interval: 1000 / 15
    running: win.visible && !win.ocean.paused
    repeat: true
    onTriggered: {
      if (!win.world) return
      World.step(win.world, win.stepDt, Species)
      canvas.requestPaint()
    }
  }
}
