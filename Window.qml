import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

// Standalone floating window: browse Unity CLI commands under a
// user-configurable namespace (see Settings), fill in their parameters,
// run them, and read back the result. Opened/closed by BarWidget.qml's
// chip; this Item owns all state so the chip stays dumb.
Item {
  id: root

  // Shown in the window title and header, kept in sync with manifest.json's
  // "version" by hand. Small enough plugin that a second source of truth
  // isn't worth reading the manifest file at runtime for - but it means
  // "is this actually the build you just updated" never has to be a guess.
  readonly property string appVersion: "1.6.1"

  property var bar: null
  readonly property bool opened: window.visible

  function open() {
    window.visible = true
    // Always resets to the configured namespace on open, regardless of
    // what it was left at last time - that's the point of this tool,
    // "show me everything" is an occasional escape hatch, not something
    // that should silently persist across sessions.
    tcbOnly = true
    refreshCommands()
    Qt.callLater(function() {
      if (searchField) searchField.forceActiveFocus()
    })
  }
  function close() { window.visible = false }
  function toggle() { opened ? close() : open() }

  // ---- font size (persisted) ---------------------------------------------
  property string fontSizeChoice: "medium" // small | medium | large
  readonly property real uiScale: fontSizeChoice === "small" ? 0.86 : (fontSizeChoice === "large" ? 1.28 : 1.0)
  readonly property real fsCaption: Math.max(9, Math.round(Style.font.caption * uiScale))
  readonly property real fsBody: Math.max(10, Math.round(Style.font.body * uiScale))
  readonly property real fsSubtitle: Math.max(11, Math.round(Style.font.subtitle * uiScale))
  readonly property real fsTitle: Math.max(12, Math.round(Style.font.title * uiScale))
  readonly property real fsHeading: Math.max(13, Math.round(Style.font.heading * uiScale))
  readonly property string fontFamily: Style.font.family

  function setFontSize(choice) {
    if (choice === fontSizeChoice) return
    fontSizeChoice = choice
    saveSettings()
  }

  // ---- command namespace (persisted) -------------------------------------
  // What "tcb:: commands only" actually filters on. Defaults to "tcb::" for
  // backward compatibility, but this plugin is used by more than one
  // person's project now - everyone's custom [CliCommand] methods live
  // under their own prefix, so it has to be settable, not hardcoded.
  property string namespace: "tcb::"

  // Every namespace the user has ever switched/added to, so Settings can
  // offer them back as a one-click list instead of retyping. `namespace`
  // is always a member of this list (setNamespace/onLoaded both enforce it).
  property var savedNamespaces: ["tcb::"]

  function setNamespace(value) {
    var trimmed = String(value || "").trim()
    if (trimmed === "" || trimmed === namespace) return
    namespace = trimmed
    if (savedNamespaces.indexOf(trimmed) === -1) savedNamespaces = savedNamespaces.concat([trimmed])
    saveSettings()
    if (tcbOnly) refreshCommands()
  }

  // Drops a saved namespace. Refuses to remove the last one - there must
  // always be at least one to fall back to. Removing the active namespace
  // switches to whatever's left at the front of the list.
  function removeNamespace(value) {
    if (savedNamespaces.length <= 1) return
    var next = savedNamespaces.filter(function(n) { return n !== value })
    savedNamespaces = next
    if (namespace === value) {
      namespace = next[0]
      if (tcbOnly) refreshCommands()
    }
    saveSettings()
  }

  // ---- settings dialog ------------------------------------------------------
  property bool settingsOpen: false

  function openSettings() {
    newNamespaceField.text = ""
    settingsOpen = true
    Qt.callLater(function() { newNamespaceField.forceActiveFocus() })
  }
  function closeSettings() { settingsOpen = false }
  function addNamespaceFromDialog() {
    setNamespace(newNamespaceField.text)
    newNamespaceField.text = ""
  }

  // ---- recently-run commands (MRU, persisted) ------------------------------
  readonly property int maxRecentCommands: 8
  property var recentCommandNames: []

  function recordRecentCommand(name) {
    if (!name) return
    var next = [name].concat(recentCommandNames.filter(function(n) { return n !== name }))
    if (next.length > maxRecentCommands) next = next.slice(0, maxRecentCommands)
    recentCommandNames = next
    saveSettings()
  }

  function removeRecentCommand(name) {
    if (recentCommandNames.indexOf(name) === -1) return
    recentCommandNames = recentCommandNames.filter(function(n) { return n !== name })
    saveSettings()
  }

  function saveSettings() {
    settingsFile.setText(JSON.stringify({
      fontSize: fontSizeChoice,
      namespace: namespace,
      recentCommands: recentCommandNames,
      savedNamespaces: savedNamespaces
    }))
  }

  FileView {
    id: settingsFile
    // Deliberately NOT inside the plugin's own directory: Omarchy's plugin
    // dev-reload watches that whole tree with inotify (close_write/create/
    // delete/move) and does a full reload - including recreating this
    // window, which resets it to closed - on any write there. Writing our
    // own state file inside it would self-trigger that reload on every
    // command run (recordRecentCommand saves on every run), which is
    // exactly what was closing the window unexpectedly. Same location
    // Omarchy's own first-party plugins (e.g. weather) use for this reason.
    path: Quickshell.env("HOME") + "/.local/state/omarchy/settings/chris.unity-commander.json"
    watchChanges: false
    printErrors: false
    onLoaded: {
      try {
        var parsed = JSON.parse(text() || "{}")
        if (parsed && (parsed.fontSize === "small" || parsed.fontSize === "medium" || parsed.fontSize === "large"))
          root.fontSizeChoice = parsed.fontSize
        if (parsed && typeof parsed.namespace === "string" && parsed.namespace.trim() !== "")
          root.namespace = parsed.namespace.trim()
        if (parsed && Array.isArray(parsed.recentCommands))
          root.recentCommandNames = parsed.recentCommands.filter(function(n) { return typeof n === "string" })
        if (parsed && Array.isArray(parsed.savedNamespaces))
          root.savedNamespaces = parsed.savedNamespaces.filter(function(n) { return typeof n === "string" && n.trim() !== "" })
        if (root.savedNamespaces.indexOf(root.namespace) === -1)
          root.savedNamespaces = root.savedNamespaces.concat([root.namespace])
      } catch (e) { /* ignore malformed state file */ }
    }
  }

  // ---- command list state -------------------------------------------------
  property var commands: []
  // true = only tcb:: commands (the default, reset on every open() above);
  // false = every command the connected Unity Editor/Player exposes.
  property bool tcbOnly: true
  function setTcbOnly(value) {
    if (value === tcbOnly) return
    tcbOnly = value
    refreshCommands()
  }
  property string searchText: ""
  // Recent commands only bubble to the top when browsing (no search text) -
  // once you're actively searching, plain fuzzy-match relevance wins.
  readonly property var filteredCommands: searchText.trim().length === 0
    ? Model.orderRecentFirst(commands, recentCommandNames)
    : Model.filterCommands(commands, searchText)
  property int highlightedIndex: 0
  onSearchTextChanged: highlightedIndex = 0
  onFilteredCommandsChanged: {
    if (highlightedIndex >= filteredCommands.length) highlightedIndex = filteredCommands.length - 1
    if (highlightedIndex < 0 && filteredCommands.length > 0) highlightedIndex = 0
  }
  property bool commandsLoading: false
  property var listStatus: null // { status, message } | null while loading/ok
  property string projectPath: ""

  function refreshCommands() {
    if (listProc.running) return
    commandsLoading = true
    listStatus = null
    listProc.command = tcbOnly
      ? ["unity", "cmd", "--query", namespace, "--json", "--timeout", "15"]
      : ["unity", "cmd", "--json", "--timeout", "15"]
    listProc.running = true
  }

  Process {
    id: listProc
    stdout: StdioCollector { id: listStdout; waitForEnd: true }
    stderr: StdioCollector { id: listStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.commandsLoading = false
      var classified = Model.classifyResponse(listStdout.text, listStderr.text)
      if (classified.status === "success") {
        try {
          var parsed = Model.parseCommandList(listStdout.text)
          root.commands = parsed.commands
          root.projectPath = parsed.projectPath
          root.listStatus = { status: "success", message: "" }
        } catch (e) {
          root.commands = []
          root.listStatus = { status: "commandError", message: "Could not parse the command list." }
        }
      } else {
        root.commands = []
        root.listStatus = classified
      }
    }
  }

  // ---- selected command + param form state --------------------------------
  property var selectedCommand: null
  property var paramValues: ({})
  property var validationMessage: ""

  function selectCommand(cmd) {
    selectedCommand = cmd
    paramValues = Model.defaultValues(cmd)
    validationMessage = ""
    lastResult = null
  }

  function setParamValue(name, value) {
    var next = ({})
    for (var k in paramValues) next[k] = paramValues[k]
    next[name] = value
    paramValues = next
  }

  // ---- unit / manager name pickers -----------------------------------------
  property var unitNames: []
  property bool unitNamesLoading: false
  property var managerNames: []
  property bool managerNamesLoading: false

  // Sentinel option value for "unset this optional dropdown". A real
  // unit/manager name is never this string, so it can't collide; picking it
  // maps back to "" in the onChanged handlers below. Needed because
  // SearchableDropdown has no built-in clear affordance and an empty-string
  // option would be indistinguishable from "nothing selected yet".
  readonly property string clearSentinel: "__clear__"

  function withClearOption(names) {
    return [{ value: clearSentinel, label: "— Clear selection —", description: "Leave this parameter unset" }].concat(names)
  }

  // These two rely on a project convention, not a Unity built-in: a
  // "<namespace>get_unit_names" / "<namespace>get_manager_names" command
  // that returns a plain string array. That's how this plugin's own
  // author's project (tcb::) does it - anyone adopting a different
  // namespace needs the equivalent commands for the dropdowns to work.
  function refreshUnitNames() {
    if (unitNamesProc.running) return
    unitNamesLoading = true
    unitNamesProc.command = ["unity", "cmd", namespace + "get_unit_names", "--json", "--timeout", "10"]
    unitNamesProc.running = true
  }

  function refreshManagerNames() {
    if (managerNamesProc.running) return
    managerNamesLoading = true
    managerNamesProc.command = ["unity", "cmd", namespace + "get_manager_names", "--json", "--timeout", "10"]
    managerNamesProc.running = true
  }

  Process {
    id: unitNamesProc
    stdout: StdioCollector { id: unitNamesStdout; waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      root.unitNamesLoading = false
      root.unitNames = Model.parseNameList(unitNamesStdout.text)
    }
  }

  Process {
    id: managerNamesProc
    stdout: StdioCollector { id: managerNamesStdout; waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      root.managerNamesLoading = false
      root.managerNames = Model.parseNameList(managerNamesStdout.text)
    }
  }

  // ---- run command ----------------------------------------------------------
  property bool running: false
  property var lastResult: null // { status, message, payload } | null
  property bool showRawJson: false
  onLastResultChanged: {
    showRawJson = false
    if (lastResult) Qt.callLater(scrollResultIntoView)
  }

  // Scrolls so the result banner lands at the top of the viewport, rather
  // than jumping to the very bottom - a human-readable result can be long
  // (an array of squads, say), so "bottom" would just show its tail end.
  function scrollResultIntoView() {
    var flick = detailScrollView.contentItem
    if (!flick || flick.contentY === undefined || !resultsSection) return
    var target = flick.contentItem || flick
    var pt = resultsSection.mapToItem(target, 0, 0)
    flick.contentY = Math.max(0, Math.min(pt.y - Style.space(8), flick.contentHeight - flick.height))
  }

  function runSelectedCommand() {
    if (!selectedCommand || execProc.running) return
    var missing = Model.missingRequiredFields(selectedCommand, paramValues)
    if (missing.length > 0) {
      validationMessage = "Missing required parameter" + (missing.length > 1 ? "s" : "") + ": " + missing.join(", ")
      return
    }
    validationMessage = ""
    lastResult = null
    running = true
    recordRecentCommand(selectedCommand.name)
    execProc.command = ["unity"].concat(Model.buildArgs(selectedCommand, paramValues))
    execProc.running = true
  }

  property bool commandCopied: false

  function copyCommandToClipboard() {
    if (!selectedCommand) return
    var args = ["unity"].concat(Model.buildArgs(selectedCommand, paramValues))
    var line = args.map(function(a) { return Util.shellQuote(a) }).join(" ")
    Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(line) + " | wl-copy"])
    commandCopied = true
    commandCopiedTimer.restart()
  }

  Timer {
    id: commandCopiedTimer
    interval: 1500
    onTriggered: root.commandCopied = false
  }

  Process {
    id: execProc
    stdout: StdioCollector { id: execStdout; waitForEnd: true }
    stderr: StdioCollector { id: execStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.running = false
      root.lastResult = Model.classifyResponse(execStdout.text, execStderr.text)
    }
  }

  // ---- window ---------------------------------------------------------------
  FloatingWindow {
    id: window
    visible: false
    // Kept as a plain, stable string, not "... v" + appVersion: the OS
    // window title is what ~/.config/hypr/apps.lua's float/center rule
    // matches on, and a title that changes every version bump is a
    // fragile, easy-to-forget-to-update match target. The version still
    // shows in the in-app header text below.
    title: "Unity Commander"
    color: Color.background
    implicitWidth: 1120
    implicitHeight: 740
    minimumSize: Qt.size(820, 520)

    // A window-manager-initiated close (e.g. SUPER+W) destroys the actual
    // backing window without going through our own close()/toggle(), and
    // Quickshell's `closed` signal fires only after the fact - there's no
    // cancelable `closing` event to intercept. Without this, `visible`
    // could stay stuck reporting true, so the next click computed
    // `opened` as still true and called close() (a no-op) instead of
    // open() - the window would never come back.
    onClosed: window.visible = false

    Rectangle {
      anchors.fill: parent
      color: Color.background

      Row {
        anchors.fill: parent

        // ---- left pane: search + command list ----------------------------
        Rectangle {
          id: leftPane
          width: Style.space(340)
          height: parent.height
          color: Color.background

          Rectangle {
            anchors.right: parent.right
            width: 1
            height: parent.height
            color: Util.alpha(Color.foreground, 0.12)
          }

          Column {
            anchors.fill: parent
            anchors.margins: Style.space(14)
            spacing: Style.space(10)

            Row {
              width: parent.width
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                text: "Unity Commander v" + root.appVersion
                color: Color.foreground
                font.family: root.fontFamily
                font.pixelSize: root.fsHeading
                font.bold: true
                width: parent.width - fontSizePicker.width - refreshButton.width - parent.spacing * 2
                elide: Text.ElideRight
                anchors.verticalCenter: parent.verticalCenter
              }

              // Font size picker - always visible here (not tucked into the
              // per-command detail pane, which only exists once a command is
              // selected and was easy to miss entirely). Three real Buttons
              // rather than a ButtonGroup so each "A" can be drawn at its
              // own size instead of all three looking identical.
              Row {
                id: fontSizePicker
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(4)

                Button {
                  text: "A"
                  tooltipText: "Small text"
                  bordered: true
                  fontSize: 11
                  selected: root.fontSizeChoice === "small"
                  foreground: Color.foreground
                  accent: Color.accent
                  fontFamily: root.fontFamily
                  horizontalPadding: Style.spacing.controlGap
                  verticalPadding: Style.spacing.xxs
                  onClicked: root.setFontSize("small")
                }
                Button {
                  text: "A"
                  tooltipText: "Medium text"
                  bordered: true
                  fontSize: 14
                  selected: root.fontSizeChoice === "medium"
                  foreground: Color.foreground
                  accent: Color.accent
                  fontFamily: root.fontFamily
                  horizontalPadding: Style.spacing.controlGap
                  verticalPadding: Style.spacing.xxs
                  onClicked: root.setFontSize("medium")
                }
                Button {
                  text: "A"
                  tooltipText: "Large text"
                  bordered: true
                  fontSize: 18
                  selected: root.fontSizeChoice === "large"
                  foreground: Color.foreground
                  accent: Color.accent
                  fontFamily: root.fontFamily
                  horizontalPadding: Style.spacing.controlGap
                  verticalPadding: Style.spacing.xxs
                  onClicked: root.setFontSize("large")
                }
              }

              Button {
                id: refreshButton
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰑐"
                tooltipText: "Refresh command list"
                iconSpinning: root.commandsLoading
                horizontalPadding: Style.spacing.controlGap
                verticalPadding: Style.spacing.labelGap
                onClicked: root.refreshCommands()
              }
            }

            // Connectivity banner.
            Rectangle {
              width: parent.width
              visible: root.listStatus !== null || root.commandsLoading
              height: statusRow.implicitHeight + Style.space(14)
              radius: Style.cornerRadius
              color: root.commandsLoading ? Util.alpha(Color.foreground, 0.06)
                : (root.listStatus && root.listStatus.status === "success") ? Util.alpha("#5fb87a", 0.14)
                : (root.listStatus && root.listStatus.status === "unreachable") ? Util.alpha(Color.urgent, 0.16)
                : Util.alpha("#d1a34a", 0.16)

              Row {
                id: statusRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: Style.space(10)
                spacing: Style.space(8)

                Rectangle {
                  width: Style.space(8)
                  height: Style.space(8)
                  radius: width / 2
                  anchors.verticalCenter: parent.verticalCenter
                  color: root.commandsLoading ? Qt.darker(Color.foreground, 1.4)
                    : (root.listStatus && root.listStatus.status === "success") ? "#5fb87a"
                    : (root.listStatus && root.listStatus.status === "unreachable") ? Color.urgent
                    : "#d1a34a"
                }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width - Style.space(16)
                  wrapMode: Text.WordWrap
                  color: Color.foreground
                  font.family: root.fontFamily
                  font.pixelSize: root.fsCaption
                  text: root.commandsLoading ? "Loading commands…"
                    : (root.listStatus && root.listStatus.status === "success") ? ("Connected — " + root.projectPath)
                    : (root.listStatus && root.listStatus.status === "unreachable") ? ("Unity isn't running or not reachable: " + root.listStatus.message)
                    : (root.listStatus ? ("Couldn't list commands: " + root.listStatus.message) : "")
                }
              }
            }

            // Namespace filter. Always resets to <namespace>-only on
            // open() - "show me everything" is a deliberate escape hatch,
            // not something that should silently carry over between
            // sessions.
            Row {
              width: parent.width
              spacing: Style.space(8)

              ToggleSwitch {
                id: tcbOnlySwitch
                anchors.verticalCenter: parent.verticalCenter
                checked: !root.tcbOnly
                foreground: Color.foreground
                accent: Color.accent
                onToggled: root.setTcbOnly(!root.tcbOnly)
              }
              // Quick-switch among saved namespaces without opening
              // Settings. Manage the saved list itself (add/remove) there.
              Dropdown {
                visible: root.tcbOnly
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(130)
                showLabel: false
                foreground: Color.foreground
                background: Color.popups.background
                accent: Color.accent
                fontFamily: root.fontFamily
                options: root.savedNamespaces
                value: root.namespace
                onChanged: function(v) { root.setNamespace(v) }
              }
              Text {
                visible: root.tcbOnly
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: "commands only"
                color: Color.foreground
                font.family: root.fontFamily
                font.pixelSize: root.fsCaption
              }
              Text {
                visible: !root.tcbOnly
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: "All commands"
                color: Color.foreground
                font.family: root.fontFamily
                font.pixelSize: root.fsCaption
              }
              PanelActionButton {
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰒓"
                tooltipText: "Manage command namespaces"
                foreground: Color.foreground
                fontFamily: root.fontFamily
                onClicked: root.openSettings()
              }
            }

            TextField {
              id: searchField
              width: parent.width
              placeholderText: "Search commands…"
              foreground: Color.foreground
              accent: Color.accent
              font.family: root.fontFamily
              font.pixelSize: root.fsBody
              text: root.searchText
              onTextChanged: root.searchText = text
              focus: true

              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Down) {
                  root.highlightedIndex = Math.min(root.filteredCommands.length - 1, root.highlightedIndex + 1)
                  commandList.positionViewAtIndex(root.highlightedIndex, ListView.Contain)
                  event.accepted = true
                } else if (event.key === Qt.Key_Up) {
                  root.highlightedIndex = Math.max(0, root.highlightedIndex - 1)
                  commandList.positionViewAtIndex(root.highlightedIndex, ListView.Contain)
                  event.accepted = true
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  if (root.highlightedIndex >= 0 && root.highlightedIndex < root.filteredCommands.length)
                    root.selectCommand(root.filteredCommands[root.highlightedIndex])
                  event.accepted = true
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              text: (root.searchText.trim().length === 0 && root.recentCommandNames.length > 0)
                ? "Recent first · " + root.filteredCommands.length + " of " + root.commands.length + " commands"
                : root.filteredCommands.length + " of " + root.commands.length + " commands"
              color: Qt.darker(Color.foreground, 1.5)
              font.family: root.fontFamily
              font.pixelSize: root.fsCaption
            }

            ScrollView {
              width: parent.width
              height: parent.height - y
              clip: true
              ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

              ListView {
                id: commandList
                width: parent.width
                model: root.filteredCommands
                spacing: Style.space(4)
                boundsBehavior: Flickable.StopAtBounds

                delegate: Rectangle {
                  id: rowDelegate
                  required property var modelData
                  required property int index
                  width: commandList.width
                  height: rowContent.implicitHeight + Style.space(16)
                  radius: Style.cornerRadius
                  readonly property bool isSelected: root.selectedCommand && root.selectedCommand.name === modelData.name
                  readonly property bool isHighlighted: index === root.highlightedIndex
                  readonly property bool isRecent: root.searchText.trim().length === 0 && root.recentCommandNames.indexOf(modelData.name) !== -1
                  color: isSelected ? Style.selectedFillFor(Color.foreground, Color.accent)
                    : (rowMouse.containsMouse || isHighlighted) ? Style.hoverFillFor(Color.foreground, Color.accent) : "transparent"
                  border.width: isHighlighted && !isSelected ? 1 : 0
                  border.color: Util.alpha(Color.accent, 0.5)

                  Column {
                    id: rowContent
                    anchors.left: parent.left
                    anchors.right: removeRecentBtn.visible ? removeRecentBtn.left : parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Style.space(10)
                    anchors.rightMargin: removeRecentBtn.visible ? Style.space(8) : Style.space(10)
                    spacing: Style.space(2)

                    Text {
                      textFormat: Text.PlainText
                      width: parent.width
                      elide: Text.ElideRight
                      text: rowDelegate.modelData.name
                      color: rowDelegate.isSelected ? Style.selectedStateColor(Color.foreground, Color.accent)
                        : rowDelegate.isRecent ? Color.accent : Color.foreground
                      font.family: root.fontFamily
                      font.pixelSize: root.fsBody
                      font.bold: rowDelegate.isSelected
                    }
                    Text {
                      textFormat: Text.PlainText
                      width: parent.width
                      elide: Text.ElideRight
                      text: rowDelegate.modelData.description || ""
                      color: Qt.darker(Color.foreground, 1.5)
                      font.family: root.fontFamily
                      font.pixelSize: root.fsCaption
                    }
                  }

                  MouseArea {
                    id: rowMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      root.highlightedIndex = rowDelegate.index
                      root.selectCommand(rowDelegate.modelData)
                    }
                  }

                  // Only for rows currently in the recent list, and only
                  // surfaced on hover/keyboard-highlight - a permanently
                  // visible "x" on every recent row would be noisy.
                  PanelActionButton {
                    id: removeRecentBtn
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    visible: rowDelegate.isRecent && (rowMouse.containsMouse || rowDelegate.isHighlighted)
                    iconText: "󰅙"
                    tooltipText: "Remove from recent"
                    foreground: Color.foreground
                    fontFamily: root.fontFamily
                    onClicked: root.removeRecentCommand(rowDelegate.modelData.name)
                  }
                }

                Text {
                  visible: root.filteredCommands.length === 0 && !root.commandsLoading
                  anchors.horizontalCenter: parent.horizontalCenter
                  anchors.top: parent.top
                  anchors.topMargin: Style.space(24)
                  textFormat: Text.PlainText
                  text: root.commands.length === 0 ? "No commands loaded yet." : "No commands match your search."
                  color: Qt.darker(Color.foreground, 1.5)
                  font.family: root.fontFamily
                  font.pixelSize: root.fsCaption
                }
              }
            }
          }
        }

        // ---- right pane: detail / form / results --------------------------
        Item {
          width: parent.width - leftPane.width
          height: parent.height

          Text {
            visible: root.selectedCommand === null
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: "Select a command on the left to see its parameters."
            color: Qt.darker(Color.foreground, 1.5)
            font.family: root.fontFamily
            font.pixelSize: root.fsBody
          }

          ScrollView {
            id: detailScrollView
            anchors.fill: parent
            visible: root.selectedCommand !== null
            clip: true
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

            Column {
              width: parent.width - Style.space(28)
              x: Style.space(14)
              y: Style.space(14)
              spacing: Style.space(16)

              // ---- header: command name + description ------------------
              Column {
                width: parent.width
                spacing: Style.space(4)

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  wrapMode: Text.WordWrap
                  text: root.selectedCommand ? root.selectedCommand.name : ""
                  color: Color.foreground
                  font.family: root.fontFamily
                  font.pixelSize: root.fsHeading
                  font.bold: true
                }
                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  wrapMode: Text.WordWrap
                  text: root.selectedCommand ? (root.selectedCommand.description || "") : ""
                  color: Qt.darker(Color.foreground, 1.4)
                  font.family: root.fontFamily
                  font.pixelSize: root.fsBody
                }
              }

              PanelSeparator { foreground: Color.foreground }

              // ---- parameter form ------------------------------------------
              Column {
                id: parametersColumn
                width: parent.width
                spacing: Style.space(14)
                visible: root.selectedCommand && root.selectedCommand.parameters && root.selectedCommand.parameters.length > 0

                PanelSectionHeader {
                  text: "Parameters"
                  foreground: Color.foreground
                  fontFamily: root.fontFamily
                  fontSize: root.fsCaption
                }

                Repeater {
                  model: root.selectedCommand ? root.selectedCommand.parameters : []

                  delegate: Column {
                    id: paramRow
                    required property var modelData
                    width: parent.width
                    spacing: Style.space(6)
                    readonly property string kind: Model.fieldKind(modelData, root.selectedCommand ? root.selectedCommand.name : "", root.namespace)
                    readonly property var currentValue: root.paramValues[modelData.name]

                    Row {
                      width: parent.width
                      spacing: Style.space(6)

                      Text {
                        textFormat: Text.PlainText
                        text: paramRow.modelData.name
                        color: Color.foreground
                        font.family: root.fontFamily
                        font.pixelSize: root.fsBody
                        font.bold: true
                      }
                      Text {
                        textFormat: Text.PlainText
                        visible: !paramRow.modelData.required
                        text: "optional"
                        color: Qt.darker(Color.foreground, 1.6)
                        font.family: root.fontFamily
                        font.pixelSize: root.fsCaption
                        font.italic: true
                      }
                    }

                    Text {
                      textFormat: Text.PlainText
                      visible: !!paramRow.modelData.description
                      width: parent.width
                      wrapMode: Text.WordWrap
                      text: paramRow.modelData.description || ""
                      color: Qt.darker(Color.foreground, 1.5)
                      font.family: root.fontFamily
                      font.pixelSize: root.fsCaption
                    }

                    // Boolean -> checkbox-style toggle. Fixed width, not
                    // Math.min(parent.width, ...) - see the TextField comment
                    // below on why that's unsafe for the first Repeater delegate.
                    Toggle {
                      visible: paramRow.kind === "boolean"
                      width: Style.space(320)
                      label: paramRow.currentValue ? "On" : "Off"
                      foreground: Color.foreground
                      accent: Color.accent
                      fontFamily: root.fontFamily
                      checked: !!paramRow.currentValue
                      onClicked: root.setParamValue(paramRow.modelData.name, !paramRow.currentValue)
                    }

                    // unit -> fuzzy-searchable dropdown, refreshed on open.
                    //
                    // Width is a fixed Style token rather than
                    // Math.min(parent.width, ...): paramRow's width (the
                    // Repeater delegate's Column) reads as a transient
                    // negative value on the delegate created during the
                    // very first population of the form (before the
                    // ScrollView content has been laid out once), and nothing
                    // ever nudges that particular child's width binding to
                    // re-evaluate afterwards. Fixed-width controls (this,
                    // NumberField, and the plain Rectangle default) sidestep
                    // it entirely; TextField/Toggle re-derive correctly
                    // because their own internal state changes later.
                    SearchableDropdown {
                      visible: paramRow.kind === "unit"
                      width: Style.spacing.searchableDropdownWidth
                      placeholderText: root.unitNamesLoading ? "Loading units…" : "Search units…"
                      emptyText: root.unitNamesLoading ? "Loading…" : "No units found"
                      showLabel: false
                      foreground: Color.popups.text
                      background: Color.popups.background
                      accent: Color.accent
                      fontFamily: root.fontFamily
                      options: root.withClearOption(root.unitNames)
                      value: paramRow.currentValue || ""
                      onChanged: function(v) { root.setParamValue(paramRow.modelData.name, v === root.clearSentinel ? "" : v) }
                      onPopupOpenChanged: if (popupOpen) root.refreshUnitNames()
                    }

                    // *manager* -> fuzzy-searchable dropdown, refreshed on open.
                    SearchableDropdown {
                      visible: paramRow.kind === "manager"
                      width: Style.spacing.searchableDropdownWidth
                      placeholderText: root.managerNamesLoading ? "Loading managers…" : "Search managers…"
                      emptyText: root.managerNamesLoading ? "Loading…" : "No managers found"
                      showLabel: false
                      foreground: Color.popups.text
                      background: Color.popups.background
                      accent: Color.accent
                      fontFamily: root.fontFamily
                      options: root.withClearOption(root.managerNames)
                      value: paramRow.currentValue || ""
                      onChanged: function(v) { root.setParamValue(paramRow.modelData.name, v === root.clearSentinel ? "" : v) }
                      onPopupOpenChanged: if (popupOpen) root.refreshManagerNames()
                    }

                    // Int32/Int64 -> stepper field, plus a Clear button for
                    // optional ones: a SpinBox always displays *some* number,
                    // so without this there would be no way to omit an
                    // optional int param from the command (it would always
                    // send whatever the field currently shows). Clearing
                    // stores "" - the same "not sent" sentinel every other
                    // optional field uses (see Model.buildArgs).
                    Row {
                      visible: paramRow.kind === "int"
                      spacing: Style.space(8)

                      NumberField {
                        anchors.verticalCenter: parent.verticalCenter
                        from: -2147483648
                        to: 2147483647
                        value: typeof paramRow.currentValue === "number" ? paramRow.currentValue : 0
                        foreground: Color.foreground
                        accent: Color.accent
                        fontFamily: root.fontFamily
                        fontSize: root.fsBody
                        onModified: function(v) { root.setParamValue(paramRow.modelData.name, v) }
                      }

                      Button {
                        visible: !paramRow.modelData.required
                        anchors.verticalCenter: parent.verticalCenter
                        text: paramRow.currentValue === "" ? "Not sent" : "Clear"
                        enabled: paramRow.currentValue !== ""
                        bordered: true
                        fontFamily: root.fontFamily
                        fontSize: root.fsCaption
                        horizontalPadding: Style.spacing.controlGap
                        verticalPadding: Style.spacing.xxs
                        onClicked: root.setParamValue(paramRow.modelData.name, "")
                      }
                    }

                    // Everything else (String, Single, Double, ...) -> text field.
                    // `text` is seeded once from currentValue on creation rather than
                    // kept as a live binding: setParamValue() replaces root.paramValues
                    // wholesale, and a live binding back to it would re-fire
                    // onTextChanged -> setParamValue on every keystroke, which QML
                    // (correctly) reports as a binding loop.
                    //
                    // Width is a fixed Style token, not Math.min(parent.width, ...):
                    // see the comment on the unit/manager dropdowns above - the
                    // first Repeater delegate created (e.g. "x" on
                    // tcb::player-attack_location) can read a stale parent.width
                    // and never re-derive it, leaving the field zero-width.
                    TextField {
                      id: textField
                      visible: paramRow.kind === "text" || paramRow.kind === "float"
                      width: Style.space(360)
                      placeholderText: paramRow.modelData.defaultValue !== null && paramRow.modelData.defaultValue !== undefined
                        ? ("default: " + paramRow.modelData.defaultValue) : ""
                      foreground: Color.foreground
                      accent: Color.accent
                      font.family: root.fontFamily
                      font.pixelSize: root.fsBody
                      Component.onCompleted: text = paramRow.currentValue !== undefined ? String(paramRow.currentValue) : ""
                      onTextChanged: root.setParamValue(paramRow.modelData.name, text)
                    }
                  }
                }
              }

              // ---- run button + validation ----------------------------------
              Row {
                width: parent.width
                spacing: Style.space(10)

                Button {
                  text: root.running ? "Running…" : "Run command"
                  bordered: true
                  focusable: true
                  iconSpinning: root.running
                  iconText: root.running ? "󰑐" : ""
                  enabled: !root.running && root.selectedCommand !== null
                  onClicked: root.runSelectedCommand()
                }

                Button {
                  text: root.commandCopied ? "Copied!" : "Copy command"
                  tooltipText: "Copy the full \"unity cmd ...\" invocation, with your current parameters, to the clipboard"
                  bordered: true
                  focusable: true
                  enabled: root.selectedCommand !== null
                  onClicked: root.copyCommandToClipboard()
                }

                Text {
                  visible: root.validationMessage !== ""
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.validationMessage
                  color: Color.urgent
                  font.family: root.fontFamily
                  font.pixelSize: root.fsCaption
                }
              }

              // ---- results ---------------------------------------------------
              Column {
                id: resultsSection
                width: parent.width
                spacing: Style.space(10)
                visible: root.lastResult !== null

                readonly property var resultValue: root.lastResult ? Model.extractResult(root.lastResult.payload) : undefined
                readonly property var resultRows: resultsSection.visible ? Model.flattenForDisplay(resultsSection.resultValue) : []

                PanelSeparator { foreground: Color.foreground }

                Rectangle {
                  width: parent.width
                  radius: Style.cornerRadius
                  height: resultHeader.implicitHeight + Style.space(20)
                  color: !root.lastResult ? "transparent"
                    : root.lastResult.status === "success" ? Util.alpha("#5fb87a", 0.14)
                    : root.lastResult.status === "unreachable" ? Util.alpha(Color.urgent, 0.16)
                    : Util.alpha("#d1a34a", 0.16)

                  Column {
                    id: resultHeader
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.margins: Style.space(10)
                    spacing: Style.space(4)

                    Row {
                      width: parent.width
                      spacing: Style.space(10)

                      Text {
                        textFormat: Text.PlainText
                        text: !root.lastResult ? ""
                          : root.lastResult.status === "success" ? "Success"
                          : root.lastResult.status === "unreachable" ? "Unity isn't running / not reachable"
                          : "Command executed but returned an error"
                        color: Color.foreground
                        font.family: root.fontFamily
                        font.pixelSize: root.fsBody
                        font.bold: true
                      }

                      Button {
                        visible: root.lastResult && root.lastResult.status === "success"
                        text: root.showRawJson ? "Show formatted" : "Show raw JSON"
                        bordered: true
                        fontFamily: root.fontFamily
                        fontSize: root.fsCaption
                        horizontalPadding: Style.spacing.controlGap
                        verticalPadding: Style.spacing.xxs
                        onClicked: root.showRawJson = !root.showRawJson
                      }
                    }

                    Text {
                      visible: root.lastResult && root.lastResult.status !== "success"
                      textFormat: Text.PlainText
                      width: parent.width
                      wrapMode: Text.WordWrap
                      text: root.lastResult ? root.lastResult.message : ""
                      color: Color.foreground
                      font.family: root.fontFamily
                      font.pixelSize: root.fsCaption
                    }
                  }
                }

                // Human-readable view: the JSON result rendered as indented,
                // foldable rows (Model.flattenForDisplay + ResultRowView).
                // Only the first item of any list starts expanded; click a
                // list item's header to fold/unfold it.
                Column {
                  width: parent.width
                  spacing: Style.space(2)
                  visible: root.lastResult && root.lastResult.status === "success" && !root.showRawJson

                  Repeater {
                    model: resultsSection.resultRows
                    delegate: ResultRowView {
                      fontFamily: root.fontFamily
                      fontSize: root.fsCaption
                      accent: Color.accent
                      foreground: Color.foreground
                    }
                  }
                }

                // Raw JSON view, toggled by the button above - the full
                // envelope, exactly as the CLI printed it.
                Rectangle {
                  width: parent.width
                  visible: root.lastResult && root.lastResult.status === "success" && root.showRawJson
                  height: rawJsonText.implicitHeight + Style.space(20)
                  radius: Style.cornerRadius
                  color: Util.alpha(Color.foreground, 0.05)
                  border.width: 1
                  border.color: Util.alpha(Color.foreground, 0.12)

                  TextEdit {
                    id: rawJsonText
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: Style.space(10)
                    readOnly: true
                    selectByMouse: true
                    wrapMode: TextEdit.WrapAnywhere
                    color: Color.foreground
                    font.family: "monospace"
                    font.pixelSize: root.fsCaption
                    text: root.lastResult && root.lastResult.payload ? JSON.stringify(root.lastResult.payload, null, 2) : ""
                  }
                }
              }
            }
          }
        }
      }

      // ---- settings dialog --------------------------------------------------
      Rectangle {
        id: settingsScrim
        anchors.fill: parent
        visible: root.settingsOpen
        color: Util.alpha(Color.background, 0.75)

        // Swallows clicks so they don't reach the command list/form behind
        // the scrim - closing requires Done/Escape, not a stray click.
        MouseArea { anchors.fill: parent }

        Rectangle {
          id: settingsPanel
          width: Math.min(parent.width - Style.space(60), Style.space(440))
          height: settingsColumn.implicitHeight + Style.space(40)
          anchors.centerIn: parent
          radius: Style.cornerRadius
          color: Color.background
          border.width: 1
          border.color: Util.alpha(Color.foreground, 0.2)

          Column {
            id: settingsColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.space(20)
            spacing: Style.space(14)

            Text {
              textFormat: Text.PlainText
              text: "Settings"
              color: Color.foreground
              font.family: root.fontFamily
              font.pixelSize: root.fsTitle
              font.bold: true
            }

            PanelSeparator { foreground: Color.foreground }

            Column {
              width: parent.width
              spacing: Style.space(6)

              Text {
                textFormat: Text.PlainText
                text: "Command namespaces"
                color: Color.foreground
                font.family: root.fontFamily
                font.pixelSize: root.fsBody
                font.bold: true
              }
              Text {
                textFormat: Text.PlainText
                width: parent.width
                wrapMode: Text.WordWrap
                text: "Save the namespace(s) your Unity projects use (e.g. \"tcb::\" or \"myco::\"), then switch between them from the dropdown next to search. Your project's [CliCommand] methods need to live under the active prefix - including \""
                  + root.namespace + "get_unit_names\" and \"" + root.namespace + "get_manager_names\" if you want the unit/manager dropdowns to work."
                color: Qt.darker(Color.foreground, 1.5)
                font.family: root.fontFamily
                font.pixelSize: root.fsCaption
              }

              Column {
                width: parent.width
                spacing: Style.space(4)

                Repeater {
                  model: root.savedNamespaces

                  delegate: Item {
                    id: nsRow
                    required property string modelData
                    required property int index
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: nsRowContent.implicitHeight + Style.space(6)
                    readonly property bool isActive: nsRow.modelData === root.namespace

                    Row {
                      id: nsRowContent
                      anchors.left: parent.left
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.space(10)

                      Text {
                        textFormat: Text.PlainText
                        anchors.verticalCenter: parent.verticalCenter
                        text: nsRow.modelData + (nsRow.isActive ? " (active)" : "")
                        color: nsRow.isActive ? Color.accent : Color.foreground
                        font.family: root.fontFamily
                        font.pixelSize: root.fsBody
                        font.bold: nsRow.isActive
                      }
                      Button {
                        visible: !nsRow.isActive
                        text: "Switch"
                        bordered: true
                        focusable: true
                        fontFamily: root.fontFamily
                        onClicked: root.setNamespace(nsRow.modelData)
                      }
                      Button {
                        visible: root.savedNamespaces.length > 1
                        text: "Remove"
                        bordered: true
                        focusable: true
                        fontFamily: root.fontFamily
                        onClicked: root.removeNamespace(nsRow.modelData)
                      }
                    }
                  }
                }
              }

              Row {
                width: parent.width
                spacing: Style.space(8)

                TextField {
                  id: newNamespaceField
                  width: parent.width - addNamespaceButton.width - parent.spacing
                  foreground: Color.foreground
                  accent: Color.accent
                  font.family: root.fontFamily
                  font.pixelSize: root.fsBody
                  placeholderText: "Add a namespace, e.g. myco::"
                  Keys.onReturnPressed: root.addNamespaceFromDialog()
                  Keys.onEscapePressed: root.closeSettings()
                }
                Button {
                  id: addNamespaceButton
                  text: "Add"
                  bordered: true
                  focusable: true
                  fontFamily: root.fontFamily
                  onClicked: root.addNamespaceFromDialog()
                }
              }
            }

            Row {
              anchors.right: parent.right
              spacing: Style.space(10)

              Button {
                text: "Done"
                bordered: true
                focusable: true
                fontFamily: root.fontFamily
                onClicked: root.closeSettings()
              }
            }
          }
        }
      }
    }
  }
}
