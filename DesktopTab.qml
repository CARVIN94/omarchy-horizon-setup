import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// 桌面 Tab：桌面海洋（ASCII 鲨鱼群）的开关与鲨鱼阵容。
//
// 数据流与其它 Tab 一致——检测即真相，不持状态副本：
//   * setup.sh desktop              → 每行一项（TAB 分隔 4 列）
//   * setup.sh desktop-ocean <0|1>  → 开关（写本插件自有配置文件，免权限）
//   * setup.sh desktop-sharks <csv> → 阵容（同上）
// 每次写操作后重拉 desktop 行，UI 永不乐观更新：写入被拒（未知种类、
// 超长序列）时界面必须跟着回到文件的真实状态，而不是停在用户点的那格。
Item {
  id: root

  // busy 单一真相在 Panel：本组件只上报起止，绝不写 busy。
  signal busyStarted()
  signal busyFinished()
  property bool externalBusy: false
  // 只有本组件真发起过写操作才配对发 busyFinished，普通刷新不得清掉别处的忙碌态。
  property bool opActive: false

  property bool oceanOn: false
  property string sharks: "classic"
  property color foreground: Color.menu.text
  property string fontFamily: Style.font.menuFamily
  property string formError: ""

  readonly property string setupSh: Qt.resolvedUrl("setup.sh").toString().replace("file://", "")

  // 预设阵容是唯一可编辑面：不做自由编辑 UI——手打 csv 的错法太多
  // （拼错种类、条数超限），而白名单与上限都在脚本侧，来回试错更糟。
  // csv 必须与 lib/desktop.sh 的白名单逐字一致，新增种类要同时改两处。
  // 第一项必须是后端的缺省值（单条 classic），否则首次打开就落进
  // 「不匹配任何预设」的提示里——那提示是给手改配置的人看的，不是常态。
  readonly property var presets: [
    { value: "classic1", label: "单条经典", csv: "classic" },
    { value: "classic4", label: "四条经典", csv: "classic,classic,classic,classic" },
    { value: "hammertiger", label: "锤头 + 虎鲨", csv: "hammerhead,tiger" },
    { value: "bigmako", label: "单条大鲨", csv: "greathammer" },
    { value: "mixed", label: "混合鱼群", csv: "classic,mako,zebra,thresher,nurse" }
  ]

  // 当前阵容命中哪个预设；都不命中就留空（不伪造一个选中项）。
  readonly property string activePreset: {
    for (var i = 0; i < presets.length; i++)
      if (presets[i].csv === sharks) return presets[i].value
    return ""
  }

  // 预设分两行展示：ButtonGroup 是 Row，不给换行，五个中文标签会把卡片挤爆。
  readonly property var presetRow1: presets.slice(0, 2)
  readonly property var presetRow2: presets.slice(2)

  // 选中即写盘；由两个 ButtonGroup 共用，免得「哪行点到哪」有两份逻辑。
  function choosePreset(v) {
    for (var i = 0; i < presets.length; i++)
      if (presets[i].value === v) {
        runOp(["desktop-sharks", presets[i].csv])
        return
      }
  }

  function beginOp() {
    root.opActive = true
    root.busyStarted()
  }

  function endOp() {
    if (!root.opActive) return
    root.opActive = false
    root.busyFinished()
  }

  function refresh() {
    rowsProc.running = false
    rowsProc.running = true
  }

  function parseRows(text) {
    var next = { ocean: false, sharks: "classic" }
    String(text).trim().split("\n").forEach(function(line) {
      if (!line) return
      var f = line.split("\t")
      // 行契约 4 列：key label value description。列数不符整行不认，
      // 不猜列——与 RuleList/ZhcnTab 同一条教训。
      if (f.length !== 4) return
      if (f[0] === "ocean") next.ocean = (f[2] === "1")
      else if (f[0] === "sharks") next.sharks = f[2]
    })
    return next
  }

  function runOp(argv) {
    if (root.externalBusy) return
    root.formError = ""
    root.beginOp()
    opProc.command = [root.setupSh].concat(argv)
    opProc.running = false
    opProc.running = true
  }

  // 启动即显示本 Tab（或面板重开后 activeTab 未翻转）时 onVisibleChanged
  // 不触发，状态会永远停在默认值——与 ZhcnTab 同款隐患，onCompleted 兜底。
  Component.onCompleted: refresh()
  onVisibleChanged: if (visible) refresh()

  Process {
    id: rowsProc
    command: [root.setupSh, "desktop"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var s = root.parseRows(text)
        root.oceanOn = s.ocean
        root.sharks = s.sharks
      }
    }
    onExited: function(code) {
      if (code !== 0) root.formError = "读取桌面状态失败（exit " + code + "）"
    }
  }

  Process {
    id: opProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { id: opErr; waitForEnd: true }
    onExited: function(code) {
      root.endOp()
      // 写失败必须说出来：脚本侧会给出「未知种类」这类可操作原因，
      // 吞掉它用户只会看到开关弹回去、不知道为什么。
      var err = String(opErr.text || "").trim()
      if (code !== 0)
        root.formError = "写入失败" + (err ? "：" + err : "（exit " + code + "）")
      else if (err.length > 0)
        root.formError = err
      root.refresh()
    }
  }

  // 面板需要本 Tab 的高度；外层取 implicitHeight，缺声明会塌成空白。
  implicitHeight: col.implicitHeight
  height: implicitHeight

  Column {
    id: col
    width: root.width
    spacing: Style.space(8)

    PanelSectionHeader {
      width: parent.width
      text: "桌面海洋"
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    Text {
      width: parent.width
      textFormat: Text.PlainText
      text: "桌面背景换成 ASCII 鲨鱼群：鱼群游动，鲨鱼在后面捕食。"
        + "绘制在桌面层，点击穿透——不挡图标、不影响桌面操作。"
      color: Qt.darker(root.foreground, 1.5)
      wrapMode: Text.WordWrap
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    ToggleList {
      width: parent.width
      title: ""
      items: [ { key: "ocean", label: "启用桌面海洋",
                 description: root.oceanOn ? "已开启，桌面上有鲨鱼在捕食" : "已关闭，桌面保持原样",
                 checked: root.oceanOn } ]
      busy: root.externalBusy
      foreground: root.foreground
      fontFamily: root.fontFamily
      onToggled: root.runOp(["desktop-ocean", root.oceanOn ? "0" : "1"])
    }

    PanelSectionHeader {
      width: parent.width
      text: "鲨鱼阵容"
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    Text {
      width: parent.width
      textFormat: Text.PlainText
      text: "当前：" + root.sharks + "（最多 6 条；条数越多越热闹，也越难看清）"
      color: Qt.darker(root.foreground, 1.5)
      wrapMode: Text.WordWrap
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    // 两行 chips：ButtonGroup 是 Row，不给换行，故拆成两个组，
    // 每组只取预设列表的一段，避免五个中文标签把卡片挤爆。
    ButtonGroup {
      width: col.width
      options: root.presetRow1
      value: root.activePreset
      foreground: root.foreground
      fontFamily: root.fontFamily
      enabled: !root.externalBusy
      onChanged: function(v) { root.choosePreset(v) }
    }

    ButtonGroup {
      width: col.width
      options: root.presetRow2
      value: root.activePreset
      foreground: root.foreground
      fontFamily: root.fontFamily
      enabled: !root.externalBusy
      onChanged: function(v) { root.choosePreset(v) }
    }

    Text {
      width: parent.width
      visible: root.activePreset === ""
      textFormat: Text.PlainText
      text: "当前阵容不匹配任何预设（可能是手改配置所致）；选一个预设即可覆盖。"
      color: Qt.darker(root.foreground, 1.5)
      wrapMode: Text.WordWrap
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      width: parent.width
      visible: root.formError.length > 0
      textFormat: Text.PlainText
      text: root.formError
      color: root.foreground
      wrapMode: Text.WordWrap
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
