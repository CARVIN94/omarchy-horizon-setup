import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// 防火墙 Tab：列出 ufw 用户规则，并提供增删。
//
// 数据流与其它 Tab 一致——检测即真相，不持有状态副本：
//   * setup.sh rules   → 每行一条规则（TAB 分隔）
//   * setup.sh fw-add  → 新增（提权走 pkexec，会弹一次授权框）
//   * setup.sh fw-del  → 删除（同样提权）
// 任何写操作完成后重新拉取 rules，UI 永不乐观更新。
Item {
  id: root

  // 忙碌状态由 Panel 统一持有（单一真相）：本组件只上报开始/结束，
  // 绝不写 busy —— 若在此写 `busy = true`，会覆写 Panel 传入的绑定，
  // 静默破坏面板级防连点与「正在写入配置…」指示。
  signal busyStarted()
  signal busyFinished()
  property bool externalBusy: false
  // 内部操作标志：只有本组件真正发起过写操作，才会配对发出
  // busyFinished；普通 rules 刷新不得清掉别处的忙碌态。
  property bool opActive: false
  property var rows: []
  property color foreground: Color.menu.text
  property string fontFamily: Style.font.menuFamily

  // 新增表单状态
  property string draftPort: ""
  property string draftProto: "tcp"
  property string draftSrc: "192.168.0.0/24"
  property string draftComment: ""
  property string formError: ""

  readonly property string setupSh: Qt.resolvedUrl("setup.sh").toString().replace("file://", "")

  // 端口/来源的本地预校验：与 lib/firewall.sh 同规则，用于即时反馈；
  // 真正的权威校验仍在脚本侧（UI 校验只是为了少弹一次授权框）。
  readonly property var portOk: /^[0-9]{1,5}(:[0-9]{1,5})?$/.test(draftPort)
  readonly property var srcOk: draftSrc === "any" || /^[0-9]{1,3}(\.[0-9]{1,3}){3}(\/[0-9]{1,2})?$/.test(draftSrc)
  readonly property var commentOk: draftComment.length >= 1 && draftComment.length <= 60
      && draftComment === draftComment.trim()
  readonly property var canSubmit: portOk && srcOk && commentOk && !externalBusy

  function beginOp() {
    root.opActive = true
    root.busyStarted()
  }

  function endOp() {
    if (!root.opActive) return
    root.opActive = false
    root.busyFinished()
  }

  // 启动即显示本 Tab（或面板重开后 activeTab 未翻转）时 onVisibleChanged
  // 不触发，规则列表会永远为空——与 ZhcnTab 同款隐患，onCompleted 兜底。
  Component.onCompleted: refresh()

  function refresh() {
    rulesProc.running = false
    rulesProc.running = true
  }

  function parseRows(text) {
    var out = []
    String(text).trim().split("\n").forEach(function(line) {
      if (!line) return
      var f = line.split("\t")
      // 契约：列数恒为 7（空字段在脚本侧写成哨兵 "-"）。列数不符说明
      // 脚本与面板的协议不一致，此时宁可整行不显示也不猜列——早期按
      // "< 7 丢弃" 的判断曾在尾部空列上误丢整条规则。
      if (f.length !== 7) return
      var unsentinel = function(v) { return v === "-" ? "" : v }
      out.push({
        action: f[0], proto: f[1], dport: f[2], src: f[3],
        comment: unsentinel(f[4]), families: f[5], iface: unsentinel(f[6])
      })
    })
    return out
  }

  // 接口规则由外部工具（如 ufw-docker）安装，本面板只展示不提供删除。
  function submitAdd() {
    if (!canSubmit) return
    formError = ""
    root.beginOp()
    addProc.command = [setupSh, "fw-add", draftPort, draftProto, draftSrc, draftComment, "allow"]
    addProc.running = false
    addProc.running = true
  }

  function submitDel(row) {
    if (root.externalBusy || row.iface !== "") return
    if (row.comment === "") {
      // 无备注意味着无法精确表达删除条件（会退化成五元组宽松匹配），
      // 脚本侧同样拒绝；这里给出解释而不是静默失败。
      formError = "该规则没有备注，无法安全删除（避免误删同端口的其他规则）"
      return
    }
    formError = ""
    // 确认框不放在本组件内：ConfirmDialog 是 Item，要覆盖全屏必须挂在
    // PanelWindow 层级（见 Panel.qml），因此这里只上报意图。
    root.deleteConfirmRequested(row)
  }

  // 执行删除。由 Panel 在确认框点「删除」后调用——规则知识与执行都留在
  // 本组件，Panel 只负责放置那个必须全屏的对话框。
  function performDelete(row) {
    if (!row) return
    root.beginOp()
    delProc.command = [root.setupSh, "fw-del", row.dport, row.proto, row.src, row.comment, row.action]
    delProc.running = false
    delProc.running = true
  }

  signal deleteConfirmRequested(var row)

  // 新增成功后的提示（与 formError 分开，成功不该显示成红色错误）
  property string formNotice: ""

  // 切到本 Tab 时把焦点落在端口输入框，键盘用户可直接输入。
  onVisibleChanged: if (visible) Qt.callLater(function() { portField.forceActiveFocus() })

  Process {
    id: rulesProc
    command: [root.setupSh, "rules"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.rows = root.parseRows(text)
    }
  }

  Process {
    id: addProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { id: addErr; waitForEnd: true }
    onExited: function(code) {
      root.endOp()
      if (code === 0) {
        var what = root.draftPort + "/" + root.draftProto
        root.draftPort = ""
        root.draftComment = ""
        root.formNotice = "已添加 " + what + "，已滚到列表末尾"
        root.refresh()
        // 等 rules 回来后内容高度才更新，故延后一拍再滚。
        Qt.callLater(function() { ruleList.scrollToEnd() })
      } else {
        root.formNotice = ""
        root.formError = "写入失败（可能需要授权）" + (addErr.text ? "：" + String(addErr.text).trim() : "")
      }
    }
  }

  Process {
    id: delProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { id: delErr; waitForEnd: true }
    onExited: function(code) {
      root.endOp()
      if (code !== 0) {
        root.formError = "删除失败（可能需要授权）" + (delErr.text ? "：" + String(delErr.text).trim() : "")
      }
      root.refresh()
    }
  }

  // 确认框已移至 Panel.qml 的 PanelWindow 层级——ConfirmDialog 是 Item，
  // 要全屏覆盖必须挂在面板根层级，塞进卡片 Column 会被压成一条。
  // 本组件只上报 deleteConfirmRequested，由 Panel 回调 performDelete。

  // 面板需要本 Tab 的高度；Item 自身不提供 implicitHeight，必须显式声明，
  // 否则外层拿到的隐式高度为 0，卡片会塌成空白（曾实测整块空白）。
  implicitHeight: col.implicitHeight
  height: implicitHeight

  Column {
    id: col
    width: root.width
    spacing: Style.space(8)

    // ---- 新增表单 ----
    PanelSectionHeader {
      width: parent.width
      text: "新增规则"
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    // 表单分两行：单行放不下「端口+协议+来源+备注+按钮」，实测会挤出卡片
    // 右边缘（添加按钮被裁切）。第一行选端口/协议/来源，第二行写备注。
    Row {
      id: formRow
      width: parent.width
      spacing: Style.space(8)

      TextField {
        id: portField
        width: Style.space(110)
        activeFocusOnTab: true
        placeholderText: "端口/范围"
        text: root.draftPort
        foreground: root.foreground
        onTextChanged: root.draftPort = text
      }

      ButtonGroup {
        id: protoGroup
        width: Style.space(118)
        options: ["tcp", "udp"]
        value: root.draftProto
        foreground: root.foreground
        fontFamily: root.fontFamily
        onChanged: function(v) { root.draftProto = v }
      }

      TextField {
        id: srcField
        width: Math.max(Style.space(160),
                        formRow.width - portField.width - protoGroup.width - formRow.spacing * 2)
        activeFocusOnTab: true
        placeholderText: "来源，如 192.168.0.0/24 或 any"
        text: root.draftSrc
        foreground: root.foreground
        onTextChanged: root.draftSrc = text
      }
    }

    Row {
      id: commentRow
      width: parent.width
      spacing: Style.space(8)

      TextField {
        id: commentField
        // Button 未设显式 width，只有 implicitWidth；必须用它计算剩余空间，
        // 否则相减结果为负。
        width: Math.max(Style.space(140),
                        commentRow.width - addBtn.implicitWidth - commentRow.spacing)
        activeFocusOnTab: true
        placeholderText: "备注（必填，如 DSH web 3082）"
        text: root.draftComment
        foreground: root.foreground
        onTextChanged: root.draftComment = text
        onAccepted: root.submitAdd()
      }

      Button {
        id: addBtn
        text: "添加"
        // Button.focusable 默认 false，不设则键盘用户无法聚焦/回车触发。
        focusable: true
        enabled: root.canSubmit
        selected: root.canSubmit
        bordered: true
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.submitAdd()
      }
    }

    Text {
      visible: root.formError !== ""
      width: parent.width
      textFormat: Text.PlainText
      text: root.formError
      color: Color.polkit.textError
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    // 成功提示：用常规前景色而非错误色，避免「加成功了却看着像报错」。
    Text {
      visible: root.formNotice !== "" && root.formError === ""
      width: parent.width
      textFormat: Text.PlainText
      text: root.formNotice
      color: Qt.darker(root.foreground, 1.3)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    PanelSeparator { width: parent.width; foreground: root.foreground }

    // ---- 规则列表 ----
    RuleList {
      id: ruleList
      width: parent.width
      rows: root.rows
      busy: root.externalBusy
      foreground: root.foreground
      onDeleteRequested: function(row) { root.submitDel(row) }
    }
  }
}
