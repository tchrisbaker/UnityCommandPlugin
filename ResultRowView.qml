import QtQuick
import qs.Commons

// Recursive row renderer for the human-readable results view
// (Model.flattenForDisplay). "group" rows are one foldable list item;
// every other row kind has no fold state of its own. Lives in its own file
// (rather than as an inline `component` in Window.qml) because QML rejects
// a self-referential inline component ("Inline components form a cycle!")
// - a plain top-level component file can reference itself by type name.
Column {
  id: rowView

  required property var modelData
  property string fontFamily: Style.font.family
  property real fontSize: Style.font.caption
  property color accent: Color.accent
  property color foreground: Color.foreground

  // Anchors, not `width: parent.width`: rowView is itself a Repeater
  // delegate, and a plain width binding can read a stale/negative
  // `parent.width` at creation (see groupItem below for the confirmed,
  // fixed instance of this). Anchoring re-resolves more robustly.
  anchors.left: parent ? parent.left : undefined
  anchors.right: parent ? parent.right : undefined
  property bool expanded: modelData.kind !== "group" || modelData.index === 0

  topPadding: (modelData.kind === "section" || modelData.kind === "group") ? Style.space(8) : Style.space(2)
  bottomPadding: Style.space(2)

  // Nested-object heading - not foldable, just a visual grouping label.
  Text {
    visible: rowView.modelData.kind === "section"
    leftPadding: Style.space(rowView.modelData.depth * 16)
    textFormat: Text.PlainText
    text: rowView.modelData.label
    color: Qt.darker(rowView.foreground, 1.3)
    font.family: rowView.fontFamily
    font.pixelSize: rowView.fontSize
    font.bold: true
    font.capitalization: Font.AllUppercase
  }

  // Plain label: value line.
  Row {
    visible: rowView.modelData.kind === "row"
    x: Style.space(rowView.modelData.depth * 16)
    width: parent.width - x
    spacing: Style.space(8)

    Text {
      visible: rowView.modelData.label !== ""
      textFormat: Text.PlainText
      text: rowView.modelData.label
      color: rowView.accent
      font.family: rowView.fontFamily
      font.pixelSize: rowView.fontSize
      width: Style.space(150)
      elide: Text.ElideRight
    }
    Text {
      textFormat: Text.PlainText
      text: rowView.modelData.value !== undefined ? rowView.modelData.value : ""
      color: rowView.foreground
      font.family: rowView.fontFamily
      font.pixelSize: rowView.fontSize
      wrapMode: Text.WordWrap
      width: parent.width - (rowView.modelData.label !== "" ? (Style.space(150) + Style.space(8)) : 0)
    }
  }

  // Foldable list-item header ("#1", "#2", ...) - click anywhere on it to
  // toggle. Only index 0 starts expanded (see `expanded` above).
  Item {
    id: groupItem
    visible: rowView.modelData.kind === "group"
    // Sized from groupHeaderRow's own content (implicitWidth), not
    // `parent.width`: rowView (like paramRow elsewhere in this plugin) is
    // itself a Repeater delegate, and reading its width at creation can
    // yield a stale/negative value (confirmed by direct measurement: -47)
    // that never re-resolves - the same bug already worked around for the
    // unit/manager dropdowns. A MouseArea anchored to a negative-width Item
    // has no hit area at all, which is why clicking this header did nothing.
    width: groupHeaderRow.implicitWidth + Style.space(20)
    // Fixed height, not `groupHeaderRow.implicitHeight`: a MouseArea
    // anchored to this Item ends up with zero-height hit area if that
    // binding hasn't resolved by the time input is dispatched, even though
    // the (unclipped) Text inside still paints fine - the row *looks*
    // right but nothing under it is clickable.
    height: rowView.fontSize + Style.space(10)

    Row {
      id: groupHeaderRow
      x: Style.space(rowView.modelData.depth * 16)
      spacing: Style.space(6)

      Text {
        textFormat: Text.PlainText
        text: rowView.expanded ? "▾" : "▸"
        color: rowView.accent
        font.family: rowView.fontFamily
        font.pixelSize: rowView.fontSize
        anchors.verticalCenter: parent.verticalCenter
      }
      Text {
        textFormat: Text.PlainText
        text: rowView.modelData.label
        color: Qt.darker(rowView.foreground, 1.3)
        font.family: rowView.fontFamily
        font.pixelSize: rowView.fontSize
        font.bold: true
        font.capitalization: Font.AllUppercase
        anchors.verticalCenter: parent.verticalCenter
      }
      // The list item's own first field, shown as a title so "#1" reads as
      // "#1 Enemy Manager (Ranged)" instead of a bare, meaningless index.
      // Not uppercased/tagged like the "#1" label above - it should read as
      // an actual name, not a section tag.
      Text {
        visible: !!rowView.modelData.title
        textFormat: Text.PlainText
        text: rowView.modelData.title
        color: rowView.foreground
        font.family: rowView.fontFamily
        font.pixelSize: rowView.fontSize
        font.bold: true
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: rowView.expanded = !rowView.expanded
    }
  }

  // A group's own rows, shown only while it's expanded.
  Column {
    visible: rowView.modelData.kind === "group" && rowView.expanded
    width: parent.width
    spacing: 0

    // Loader + setSource, not a direct `ResultRowView { ... }` delegate:
    // QML rejects a component directly instantiating its own type from
    // within its own file ("instantiated recursively" / "Type unavailable").
    // Loading it by URL sidesteps that static-resolution restriction; the
    // required `modelData` (and the rest) go through setSource's second
    // argument since a bare `item.prop = ...` in onLoaded would run after
    // required-property validation already failed.
    Repeater {
      model: rowView.modelData.rows
      delegate: Loader {
        id: nestedLoader
        required property var modelData
        width: parent ? parent.width : 0
        Component.onCompleted: setSource("ResultRowView.qml", {
          modelData: nestedLoader.modelData,
          fontFamily: rowView.fontFamily,
          fontSize: rowView.fontSize,
          accent: rowView.accent,
          foreground: rowView.foreground
        })
      }
    }
  }
}
