import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// 插件汉化 Tab：列出汉化映射表及其对目标插件的应用状态，提供应用/还原。
//
// 数据流与其它 Tab 一致——检测即真相，不持状态副本：
//   * setup.sh zhcn               → 每行一张映射表（TAB 分隔 7 列）
//   * setup.sh zhcn-apply <id>    → 应用（写插件目录，免权限）
//   * setup.sh zhcn-revert <id>   → 还原英文（写插件目录，免权限）
// 每次写操作后重拉 zhcn 行，UI 永不乐观更新。上游 git pull 把英文带回来
// 后状态自然转 clean；源码字面量被上游改动则转 mismatch——此时按钮禁用，
// 需先更新映射表，绝不猜着重放。
Item {
  id: root

  signal busyStarted()
  signal busyFinished()
  property bool externalBusy: false
  property bool opActive: false
  property var rows: []
  property color foreground: Color.menu.text
  property string fontFamily: Style.font.menuFamily
  property string formError: ""

  readonly property string setupSh: Qt.resolvedUrl("setup.sh").toString().replace("file://", "")

  // 「能不能点汉化 / 能不能点还原」是跨两组状态词的判据，必须集中一处。
  // 映射表组用 clean/applied；Omasnap 那层用 stock/zh（它由 lib/omasnapzh.sh
  // 汇报，语义相同但词不同——曾因此让按钮永远点不动）。mismatch/missing 两组
  // 都不给点。以后新增一层，只在这里补词，不去改按钮条件。
  readonly property var canApply: ({ clean: true, stock: true, stale: true })
  readonly property var canRevert: ({ applied: true, zh: true })

  readonly property var stateLabel: ({
    clean: "未汉化",
    applied: "已汉化",
    mismatch: "已失配（上游改动了文案，先更新映射表）",
    missing: "插件未安装",
    // Omasnap 专用：汉化的目标版本变了，需要重新编译。
    stale: "汉化已过期（上游版本变了，需重新编译）"
  })

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
    var out = []
    String(text).trim().split("\n").forEach(function(line) {
      if (!line) return
      var f = line.split("\t")
      // 行契约 7 列：id title state applied clean mismatch total。
      // 列数不符宁可整行不显示也不猜列（同 RuleList 的教训）。
      if (f.length !== 7) return
      out.push({
        id: f[0], title: f[1], state: f[2],
        applied: f[3], clean: f[4], mismatch: f[5], total: f[6]
      })
    })
    return out
  }

  function runOp(argv) {
    if (root.externalBusy) return
    root.formError = ""
    root.beginOp()
    opProc.command = [root.setupSh].concat(argv)
    opProc.running = false
    opProc.running = true
  }

  // 启动即显示本 Tab（或插件热重载后 visible 未翻转）时 onVisibleChanged
  // 不触发，rows 会永远为空——实测面板空列表。onCompleted 兜底补一发。
  Component.onCompleted: refresh()
  onVisibleChanged: if (visible) refresh()

  Process {
    id: rowsProc
    command: [root.setupSh, "zhcn"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.rows = root.parseRows(text)
    }
    onExited: function(code) {
      if (code !== 0) root.formError = "读取汉化状态失败（exit " + code + "）"
    }
  }

  Process {
    id: opProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { id: opErr; waitForEnd: true }
    onExited: function(code) {
      root.endOp()
      if (code !== 0)
        root.formError = "操作失败" + (opErr.text ? "：" + String(opErr.text).trim() : "")
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
      text: "第三方插件显示文案"
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    Text {
      width: parent.width
      textFormat: Text.PlainText
      text: "汉化只改界面文案；上游更新后重新汉化即可，命令触发词与示例保持原样。"
      color: Qt.darker(root.foreground, 1.5)
      wrapMode: Text.WordWrap
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Repeater {
      model: root.rows

      delegate: BorderSurface {
        required property var modelData
        width: col.width
        implicitHeight: rowCol.implicitHeight + Style.spacing.panelPadding * 2
        radius: Style.cornerRadius
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
        borderSpec: Border.surfaceSpec("menu", "border", root.foreground, Math.max(Style.space(1), Style.space(0.5)))

        Column {
          id: rowCol
          anchors.fill: parent
          anchors.margins: Style.spacing.panelPadding
          spacing: Style.space(4)

          Item {
            width: parent.width
            height: btnRow.height

            Text {
              anchors.left: parent.left
              anchors.right: btnRow.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: modelData.title
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              elide: Text.ElideRight
            }

            Row {
              id: btnRow
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(6)

              Button {
                text: "汉化"
                focusable: true
                bordered: true
                enabled: !root.externalBusy && (root.canApply[modelData.state] === true)
                selected: root.canApply[modelData.state] === true
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.runOp(["zhcn-apply", modelData.id])
              }

              Button {
                text: "还原"
                focusable: true
                bordered: true
                enabled: !root.externalBusy && (root.canRevert[modelData.state] === true)
                selected: false
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.runOp(["zhcn-revert", modelData.id])
              }
            }
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: (root.stateLabel[modelData.state] || modelData.state)
              + " · " + modelData.applied + "/" + modelData.total + " 条"
              + (Number(modelData.mismatch) > 0 ? " · 失配 " + modelData.mismatch + " 条" : "")
            color: modelData.state === "mismatch" ? root.foreground : Qt.darker(root.foreground, 1.5)
            wrapMode: Text.WordWrap
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
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
