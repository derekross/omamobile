// SPDX-License-Identifier: MIT
pragma ComponentBehavior: Bound
import QtQuick

// The cellular signal: four bars, `level` of them filled and the rest empty
// outlines. Four bars is the standard and the icon font has only a three-bar
// set, so these are drawn. With the airplane glyph (cellular off) they are the
// only cellular symbols (StatusModel.js has the rule). `size` is the height.
Item {
  id: bars

  property int level: 0
  property color color: "white"
  property real size: 16

  implicitWidth: Math.round(size * 1.12)
  implicitHeight: Math.round(size)
  width: implicitWidth
  height: implicitHeight

  Repeater {
    model: 4

    Rectangle {
      required property int index
      readonly property real barWidth: bars.width * 0.19
      readonly property bool filled: index < bars.level

      x: Math.round(index * (bars.width - barWidth) / 3)
      width: Math.max(2, Math.round(barWidth))
      height: Math.round(bars.height * (0.34 + 0.22 * index))
      y: bars.height - height
      radius: width * 0.18
      antialiasing: true
      color: filled ? bars.color : "transparent"
      border.width: filled ? 0 : Math.max(1, Math.round(width * 0.24))
      border.color: bars.color
    }
  }
}
