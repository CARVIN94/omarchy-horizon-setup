import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Horizon Setup 配置面板：全屏 overlay 居中小卡（与剪贴板同形态），
// 不占顶栏。呼出：omarchy-shell shell toggle horizon.setup（菜单/快捷键）。
//
// 检测/写盘逻辑全部在同目录 setup.sh（status / toggle），
// 本文件只是展示壳，不持有任何状态副本。
Item {
  id: root

  property bool opened: false
  property var state: ({ keys: false, scroll: false, clip: false, npm: false, ghproxy: false })
  property bool busy: false

  readonly property int enabledCount: (state.keys ? 1 : 0) + (state.scroll ? 1 : 0)
      + (state.clip ? 1 : 0) + (state.npm ? 1 : 0) + (state.ghproxy ? 1 : 0)
  readonly property int totalCount: 5

  // ---- overlay 生命周期（omarchy-shell IPC 调用的入口）----

  function open(payloadJson) {
    root.opened = true
    root.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() { root.opened = false }
  function toggle() { root.opened ? root.close() : root.open("{}") }
  function refresh() { statusProc.running = false; statusProc.running = true }
  function ping() { return "ok" }

  function applyToggle(target) {
    if (root.busy) return
    root.busy = true
    toggleProc.command = [Qt.resolvedUrl("setup.sh").toString().replace("file://", ""), "toggle", target]
    toggleProc.running = false
    toggleProc.running = true
  }

  function applyStatus(text) {
    // status 行形如：keys=1 scroll=0 clip=1 npm=1 ghproxy=1
    var out = String(text).trim()
    var next = {}
    out.split(/\s+/).forEach(function(pair) {
      var kv = pair.split("=")
      if (kv.length === 2) next[kv[0]] = kv[1] === "1"
    })
    if (next.keys !== undefined) root.state = next
    root.busy = false
  }

  Process {
    id: statusProc
    command: [Qt.resolvedUrl("setup.sh").toString().replace("file://", ""), "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStatus(text)
    }
  }

  Process {
    id: toggleProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStatus(text)
    }
    onRunningChanged: if (!running && root.busy) root.busy = false
  }

  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color border: Color.menu.border
  readonly property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  readonly property color scrim: Color.menu.scrim
  readonly property int cornerRadius: Style.cornerRadius

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "horizon-setup"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    BorderSurface {
      id: card
      anchors.centerIn: parent
      width: Style.space(430)
      height: rows.implicitHeight + contentTopInset + contentBottomInset
      radius: root.cornerRadius
      color: root.background
      borderSpec: root.borderSpec
      padding: Style.spacing.panelPadding

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        anchors.leftMargin: card.contentLeftInset
        anchors.rightMargin: card.contentRightInset
        anchors.topMargin: card.contentTopInset
        anchors.bottomMargin: card.contentBottomInset
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            root.close()
            event.accepted = true
          }
        }

        Column {
          id: rows
          anchors.fill: parent
          spacing: Style.spacing.md

          // ---- 头部：标题 + 状态徽章 ----
          Item {
            width: parent.width
            implicitHeight: headerCol.implicitHeight

            Column {
              id: headerCol
              anchors.left: parent.left
              anchors.right: badge.left
              anchors.rightMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(3)

              Text {
                textFormat: Text.PlainText
                text: "Horizon Setup"
                color: root.foreground
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.title
                font.bold: true
                width: parent.width
                elide: Text.ElideRight
              }

              Text {
                textFormat: Text.PlainText
                text: "Omarchy · Mac 习惯定制"
                color: Qt.darker(root.foreground, 1.5)
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.caption
                width: parent.width
                elide: Text.ElideRight
              }
            }

            Rectangle {
              id: badge
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              width: badgeText.implicitWidth + Style.space(14)
              height: badgeText.implicitHeight + Style.space(8)
              radius: height / 2
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
              border.width: 1
              border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.18)

              Text {
                id: badgeText
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: root.busy ? "…" : root.enabledCount + "/" + root.totalCount
                color: root.foreground
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }
          }

          PanelSeparator {
            width: parent.width
            foreground: root.foreground
          }

          // ---- 开关组 ----
          Column {
            width: parent.width
            spacing: Style.space(6)

            Toggle {
              width: parent.width
              label: "Mac 快捷键"
              description: "Cmd→Ctrl；全选/行首尾/保存/查找/撤销等 16 组"
              checked: root.state.keys
              enabled: !root.busy
              foreground: root.foreground
              fontFamily: Style.font.menuFamily
              onClicked: root.applyToggle("keys")
            }

            Toggle {
              width: parent.width
              label: "自然滚动"
              description: "鼠标与触控板均为 Mac 方向"
              checked: root.state.scroll
              enabled: !root.busy
              foreground: root.foreground
              fontFamily: Style.font.menuFamily
              onClicked: root.applyToggle("scroll")
            }

            Toggle {
              width: parent.width
              label: "剪贴板快捷键"
              description: "Super+Alt+C 呼出剪贴板"
              checked: root.state.clip
              enabled: !root.busy
              foreground: root.foreground
              fontFamily: Style.font.menuFamily
              onClicked: root.applyToggle("clip")
            }

            Toggle {
              width: parent.width
              label: "npm 换源"
              description: "registry → npmmirror（国内镜像）"
              checked: root.state.npm
              enabled: !root.busy
              foreground: root.foreground
              fontFamily: Style.font.menuFamily
              onClicked: root.applyToggle("npm")
            }

            Toggle {
              width: parent.width
              label: "GitHub 代理"
              description: "clone/fetch 自动走 gh-proxy.org"
              checked: root.state.ghproxy
              enabled: !root.busy
              foreground: root.foreground
              fontFamily: Style.font.menuFamily
              onClicked: root.applyToggle("ghproxy")
            }
          }

          PanelSeparator {
            width: parent.width
            foreground: root.foreground
          }

          // ---- 底部状态栏 ----
          Row {
            width: parent.width
            spacing: Style.space(8)

            Text {
              textFormat: Text.PlainText
              text: root.busy ? "正在写入配置…" : "Esc 关闭 · 点击空白处退出"
              color: root.busy ? root.foreground : Qt.darker(root.foreground, 1.6)
              opacity: root.busy ? 1 : 0.75
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }
  }

  IpcHandler {
    target: "horizon.setup"
    function refresh(): void { root.refresh() }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
  }
}
