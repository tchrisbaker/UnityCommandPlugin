import QtQuick
import qs.Ui
import qs.Commons

// Bar chip for Unity Commander. Clicking it opens the standalone command
// browser window (Window.qml) - the chip itself carries no state beyond
// forwarding to that window, mirroring the bar-chip + floating-window
// pattern used by System Monitor's Task Manager.
BarWidget {
  id: root
  moduleName: "chris.unity-commander"

  readonly property bool opened: windowLoader.item ? windowLoader.item.opened === true : false

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function open() { if (windowLoader.item) windowLoader.item.open() }
  function close() { if (windowLoader.item) windowLoader.item.close() }
  function toggle() { if (windowLoader.item) windowLoader.item.toggle() }

  Loader {
    id: windowLoader
    active: true
    source: Qt.resolvedUrl("Window.qml")
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "UC"
    tooltipText: "Unity Commander — browse & run tcb:: commands"
    onPressed: function(buttonId) { root.toggle() }
  }
}
