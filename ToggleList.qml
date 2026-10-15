import QtQuick
import qs.Commons
import qs.Ui

// 一个开关组：标题 + 一组 Toggle。纯展示壳，不持有状态——
// 每个开关的 checked 由调用方从实测状态传入，点击只发出 toggled(key)。
Item {
  id: root

  property string title: ""
  property var items: []          // [{ key, label, description, checked }]
  property bool busy: false
  property color foreground: Color.menu.text
  property string fontFamily: Style.font.menuFamily

  signal toggled(string key)

  implicitHeight: col.implicitHeight

  Column {
    id: col
    width: parent.width
    spacing: Style.space(6)

    PanelSectionHeader {
      width: parent.width
      text: root.title
      visible: root.title !== ""
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    Repeater {
      model: root.items

      delegate: Toggle {
        required property var modelData
        width: col.width
        label: modelData.label
        description: modelData.description
        checked: modelData.checked === true
        enabled: !root.busy
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.toggled(modelData.key)
      }
    }
  }
}
