import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Horizon Setup 配置面板：全屏 overlay 居中小卡（与剪贴板同形态），
// 不占顶栏。呼出：omarchy-shell shell toggle horizon.setup（菜单/快捷键）。
//
// 四个 Tab 按「这块配置属于谁」分组，而不是按实现方式：
//   Mac 习惯   —— 与 macOS 肌肉记忆直接相关
//   开发环境   —— npm / GitHub，与 Mac 习惯无关
//   防火墙     —— ufw 规则（读写分离：读免权限，写走 pkexec 授权）
//   插件汉化   —— 第三方插件显示文案的汉化重放（写插件目录，免权限）
//
// 检测/写盘逻辑全部在 setup.sh 与 lib/*.sh，本文件只是展示壳，
// 不持有任何状态副本。
Item {
  id: root

  property bool opened: false
  property var switches: ({ keys: false, scroll: false, clip: false,
                         npm: false, ghproxy: false, gtranslate: false,
                         ufw: false, rules: 0 })
  property bool busy: false
  // 写配置失败时的提示（只来自 stderr）。成功则为空。
  // 下方状态栏优先展示它 —— 否则失败时面板没有任何反馈。
  property string notice: ""
  property string activeTab: "mac"

  readonly property var tabs: [
    { value: "mac", label: "Mac 习惯" },
    { value: "dev", label: "开发环境" },
    { value: "lan", label: "防火墙" },
    { value: "zh", label: "插件汉化" }
  ]

  readonly property var macItems: [
    { key: "keys", label: "Mac 快捷键",
      description: "Command 键按 Ctrl 语义发键；关标签(Cmd+W)/关窗(Cmd+Q)/刷新(Cmd+R)/恢复标签(Cmd+Shift+T)/删到行尾(Cmd+Delete)/纯文本粘贴(Cmd+Shift+V)/注释(Cmd+/)、行首尾、保存等 21 组；截图 Cmd+Shift+X；音量 Super+F10/F11/F12", checked: switches.keys },
    { key: "scroll", label: "自然滚动",
      description: "滚轮方向改为「内容跟手」；鼠标与触控板都改", checked: switches.scroll },
    { key: "clip", label: "剪贴板快捷键",
      description: "Super+Alt+C 呼出剪贴板历史", checked: switches.clip }
  ]

  readonly property var devItems: [
    { key: "npm", label: "npm 换源",
      description: "npm registry 指向 npmmirror，装包走国内镜像", checked: switches.npm },
    { key: "ghproxy", label: "GitHub 代理",
      description: "git fetch 走 gh-proxy.org 镜像；push 仍直连 GitHub。（hosts 加速需另行一次性安装）", checked: switches.ghproxy },
    { key: "gtranslate", label: "Google 翻译修复",
      description: "把 translate.googleapis.com 指到当天真能返回译文的 IP，恢复浏览器网页翻译。需一次性安装。", checked: switches.gtranslate }
  ]

  readonly property int enabledCount: (switches.keys ? 1 : 0) + (switches.scroll ? 1 : 0)
      + (switches.clip ? 1 : 0) + (switches.npm ? 1 : 0) + (switches.ghproxy ? 1 : 0)
      + (switches.gtranslate ? 1 : 0)
      + (switches.ufw ? 1 : 0)
  readonly property int totalCount: 7

  readonly property string setupSh: Qt.resolvedUrl("setup.sh").toString().replace("file://", "")

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
    root.notice = ""          // 开新一轮，先清上一次的失败提示
    toggleProc.command = [root.setupSh, "toggle", target]
    toggleProc.running = false
    toggleProc.running = true
  }

  // stderr 内容。成功时 stderr 为空、不触发本函数，故 notice 保持 ""。
  function setNotice(text) {
    var s = String(text).replace(/\s+$/, "")
    if (s.length > 0) root.notice = s
  }

  function applyStatus(text) {
    // status 行形如：
    // keys=1 scroll=0 clip=1 npm=1 ghproxy=1 ufw=1 rules=10 ghhosts=0 ghtimer=1 gtranslate=0
    var out = String(text).trim()
    var next = {}
    out.split(/\s+/).forEach(function(pair) {
      var kv = pair.split("=")
      if (kv.length !== 2) return
      // 布尔开关是 0/1；rules 是计数，保留原值。
      next[kv[0]] = (kv[1] === "0") ? false : (kv[1] === "1" ? true : kv[1])
    })
    if (next.keys !== undefined) root.switches = next
    root.busy = false
  }

  Process {
    id: statusProc
    command: [root.setupSh, "status"]
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
    // stderr 必须接：写配置的失败原因（如需 root 授权、超时）只在 stderr。
    // 之前只接 stdout，失败时面板一声不吭，用户只能猜「权限框没弹出」。
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.setNotice(text)
    }
    onRunningChanged: if (!running && root.busy) root.busy = false
  }

  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color border: Color.menu.border
  readonly property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  readonly property color scrim: Color.menu.scrim
  readonly property int cornerRadius: Style.cornerRadius

  // ---- 删除确认（防火墙 Tab 触发）----
  // ConfirmDialog 是 Item：要覆盖整个面板必须放在 PanelWindow 层级并
  // anchors.fill + z，塞进卡片的 Column 会被当成布局项压成一条（实测烂）。
  property bool deleteConfirmOpen: false
  property var deleteTarget: null

  function requestDelete(row) {
    root.deleteTarget = row
    root.deleteConfirmOpen = true
  }

  function cancelDelete() {
    root.deleteConfirmOpen = false
    root.deleteTarget = null
  }

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
      width: Style.space(560)
      height: Math.min(rows.implicitHeight + contentTopInset + contentBottomInset,
                       panel.height - Style.space(80))
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
        // 确认框打开时把 keyCatcher 抬到卡片之上：z 提升让它的
        // Keys.BeforeItem 在层级上盖住卡片内的按钮，按键才会先进这里。
        // Menu.qml / Clipboard.qml 都设了同样的 z（20）；缺它时 Esc 会落到
        // 卡片上、把整个面板关掉而不是取消确认框（实测踩过）。
        z: root.deleteConfirmOpen ? 20 : 0
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          // ConfirmDialog 是 Item，不自带按键处理，必须由宿主转发
          // （Omarchy 的 Menu.qml / Clipboard.qml 同样是这么接的）。
          if (root.deleteConfirmOpen) {
            if (deleteConfirm.handleKey(event)) event.accepted = true
            return
          }
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
                text: "Omarchy · 输入习惯 · 工具链 · 防火墙 · 汉化"
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

          // ---- Tab 栏 ----
          ButtonGroup {
            width: parent.width
            options: root.tabs
            value: root.activeTab
            foreground: root.foreground
            fontFamily: Style.font.menuFamily
            onChanged: function(v) { root.activeTab = v }
          }

          PanelSeparator {
            width: parent.width
            foreground: root.foreground
          }

          // ---- Tab 内容 ----
          Item {
            width: parent.width
            implicitHeight: root.activeTab === "lan"
                ? lanTab.implicitHeight
                : (root.activeTab === "zh"
                    ? zhTab.implicitHeight
                    : Math.max(macList.implicitHeight, devList.implicitHeight))

            ToggleList {
              id: macList
              width: parent.width
              visible: root.activeTab === "mac"
              title: "键位、滚动与剪贴板"
              items: root.macItems
              busy: root.busy
              foreground: root.foreground
              onToggled: function(key) { root.applyToggle(key) }
            }

            ToggleList {
              id: devList
              width: parent.width
              visible: root.activeTab === "dev"
              title: "包管理与网络"
              items: root.devItems
              busy: root.busy
              foreground: root.foreground
              onToggled: function(key) { root.applyToggle(key) }
            }

            FirewallTab {
              id: lanTab
              width: parent.width
              height: implicitHeight
              visible: root.activeTab === "lan"
              // busy 由本组件独占持有：防火墙 Tab 只上报开始/结束，
              // 避免它反过来覆写 root.busy 的绑定（会静默破坏防连点）。
              externalBusy: root.busy
              foreground: root.foreground
              onDeleteConfirmRequested: function(row) { root.requestDelete(row) }
              onBusyStarted: root.busy = true
              onBusyFinished: root.busy = false
              onVisibleChanged: if (visible) refresh()
            }

            ZhcnTab {
              id: zhTab
              width: parent.width
              height: implicitHeight
              visible: root.activeTab === "zh"
              // 同 FirewallTab：busy 单一真相在 Panel，本 Tab 只上报起止。
              externalBusy: root.busy
              foreground: root.foreground
              onBusyStarted: root.busy = true
              onBusyFinished: root.busy = false
            }
          }

          PanelSeparator {
            width: parent.width
            foreground: root.foreground
          }

          // ---- 底部状态栏 ----
          // 优先级：失败提示 > 正在写入 > 常态提示。
          // 提示独占整行并允许换行（它可能含 setup.sh 的完整 stderr）。
          Text {
            width: parent.width
            visible: root.notice.length > 0
            textFormat: Text.PlainText
            text: root.notice
            color: root.foreground
            wrapMode: Text.WordWrap
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.caption
          }

          Row {
            width: parent.width
            spacing: Style.space(8)
            visible: root.notice.length === 0

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

    // 删除确认框：必须挂在 PanelWindow 层级（不是卡片内），用
    // anchors.fill + z 覆盖整块面板。塞进卡片的 Column 会被当布局项压扁。
    ConfirmDialog {
      id: deleteConfirm
      anchors.fill: parent
      z: 10
      opened: root.deleteConfirmOpen
      message: root.deleteTarget
          ? "删除防火墙规则 " + root.deleteTarget.dport + "/" + root.deleteTarget.proto
            + "（来源 " + root.deleteTarget.src + "）？"
          : ""
      confirmText: "删除"
      cancelText: "取消"
      // 默认选中「取消」。ConfirmDialog 的默认是 1（=确认，这里即删除），
      // 一次误按回车就会真删规则——对 22/tcp 这类等于直接切断 SSH。
      // 且它的 selectedIndex 不会在重开时自动复位，故每次打开都显式归位。
      selectedIndex: 0
      onOpenedChanged: if (opened) selectedIndex = 0
      background: root.background
      foreground: root.foreground
      scrim: root.scrim
      fontFamily: Style.font.menuFamily
      cornerRadius: root.cornerRadius
      onConfirmed: {
        var r = root.deleteTarget
        root.deleteConfirmOpen = false
        root.deleteTarget = null
        if (r) lanTab.performDelete(r)
      }
      onCanceled: root.cancelDelete()
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
