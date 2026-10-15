import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

// 规则列表：展示 ufw 规则并发出删除意图。
//
// 纯展示组件——不执行任何命令、不持有数据来源。删除由调用方（FirewallTab）
// 在确认后执行，避免「列表项自己会写防火墙」这种隐含权限。
//
// 高度契约（与 Omarchy 的 panels 一致）：可视高度 = min(内容高度, 上限)。
// 早期版本把上限写成 190px 常量，而 ufw 把新规则**追加在末尾**，于是超过
// 约 4 条就被静默裁掉、用户以为「没添加成功」（真实踩过）。现在：
//   * 上限足够装下常见规模，超出才滚动；
//   * 滚动条 AsNeeded 常显，绝不静默裁切。
Item {
  id: root

  property var rows: []
  property bool busy: false
  property bool showHeader: true
  property color foreground: Color.menu.text
  property string fontFamily: Style.font.menuFamily

  // 列表可视高度上限。默认值按「面板卡片能长到的空间」给足，
  // 让常见规模（十几条）无需滚动即可看全。
  property real maxListHeight: Style.space(560)

  signal deleteRequested(var row)

  // 滚到列表末尾。新增的规则由 ufw 追加在末尾，调用方在写入成功后调用它，
  // 让用户直接看到结果——否则「加完了却没看见」会被当成失败。
  function scrollToEnd() {
    flick.contentY = Math.max(0, flick.contentHeight - flick.height)
  }

  // 内容是否超出（供调用方/提示使用）
  readonly property bool overflowing: ruleCol.implicitHeight > flick.height + 1

  implicitHeight: col.implicitHeight

  Column {
    id: col
    width: root.width
    spacing: Style.space(8)

    PanelSectionHeader {
      width: parent.width
      visible: root.showHeader
      text: "当前规则（" + root.rows.length + "）"
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    // Omarchy 的既有形状：Flickable 高度由内容限量，卡片高度随隐式高度增长。
    Flickable {
      id: flick
      width: parent.width
      height: Math.min(ruleCol.implicitHeight, root.maxListHeight)
      contentHeight: ruleCol.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      interactive: contentHeight > height
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      Column {
        id: ruleCol
        width: flick.width
        spacing: Style.space(4)

        Repeater {
          model: root.rows

          delegate: BorderSurface {
            id: rowCard
            required property var modelData
            width: ruleCol.width
            height: Math.max(Style.space(38), lineText.implicitHeight + Style.space(16))
            radius: Style.cornerRadius
            color: "transparent"
            borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)

            // 接口规则由外部工具（ufw-docker 等）安装，本面板只读展示。
            readonly property bool external: modelData.iface !== ""
            // 无备注意味着无法把删除条件精确表达给 ufw（会退化成五元组
            // 宽松匹配），因此不提供删除入口。
            readonly property bool deletable: !external && modelData.comment !== ""

            Row {
              anchors.fill: parent
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              spacing: Style.space(8)

              Text {
                id: lineText
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - delBtn.width - Style.space(8)
                textFormat: Text.PlainText
                text: modelData.action + "  " + modelData.dport + "/" + modelData.proto
                      + "  ← " + modelData.src
                      + (modelData.families.indexOf("6") >= 0 ? "  [v4+v6]" : "")
                      + (modelData.comment ? "  · " + modelData.comment : "")
                      + (modelData.iface ? "  · 接口 " + modelData.iface + "（只读）" : "")
                      + (rowCard.deletable ? "" : (rowCard.external ? "" : "  · 无备注，不可删"))
                color: rowCard.external ? Qt.darker(root.foreground, 1.6) : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }

              Button {
                id: delBtn
                anchors.verticalCenter: parent.verticalCenter
                visible: rowCard.deletable
                text: "删除"
                focusable: true
                bordered: true
                enabled: !root.busy
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.deleteRequested(modelData)
              }
            }
          }
        }
      }
    }
  }
}
