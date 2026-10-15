import QtQuick
import qs.Commons
import qs.Ui

// 规则列表：展示 ufw 规则并发出删除意图。
//
// 纯展示组件——不执行任何命令、不持有数据来源。删除由调用方（FirewallTab）
// 在确认后执行，避免「列表项自己会写防火墙」这种隐含权限。
Item {
  id: root

  property var rows: []
  property bool busy: false
  property bool showHeader: true
  property color foreground: Color.menu.text
  property string fontFamily: Style.font.menuFamily

  // 列表区高度上限；超出内部滚动，避免与父级高度形成循环绑定。
  property real listHeight: Style.space(190)

  signal deleteRequested(var row)

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

    Flickable {
      width: parent.width
      height: Math.min(root.listHeight,
                       Math.max(Style.space(80), ruleCol.implicitHeight))
      contentHeight: ruleCol.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds

      Column {
        id: ruleCol
        width: parent.width
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
