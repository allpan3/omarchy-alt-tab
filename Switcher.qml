import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets
import Quickshell.Hyprland
import QtQuick
import qs.Commons
import "WindowModel.js" as WindowModel

// macOS-style Alt-Tab window switcher, an Omarchy "menu" plugin.
//
// Bind Alt+Tab manually as shown in README.md. Repeated named
// summons cycle; releasing the configured modifier selects. Typing latches
// sticky search (Enter/Escape). This local fork adds Ctrl and Shift-alone handling.
//
// The window list is the shell's own Hyprland model (Hyprland.toplevels):
// no subprocess, no JSON to parse, nothing to buffer. Each window
// contributes a small fixed set of fields, clipped, and never more than
// maxWindows of them are kept (WindowModel.js). MRU order comes from the
// focus history Service.qml tracks off the compositor's events.
//
// Visuals follow the Omarchy design exploration "app switcher A":
// "two-line" (default) and "bare" (jump numbers, alt+<n> activates directly).
// The palette is mapped live from the active Omarchy theme via the shell's
// Color singleton; nothing is hard-coded.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property var service: null // the host hands over this plugin's Service.qml instance
  property bool opened: false

  readonly property string pluginId: manifest && manifest.id ? String(manifest.id) : ""

  // ── Bounds ─────────────────────────────────────────────────────────
  readonly property int maxWindows: 256 // windows kept from the compositor's model, MRU first
  readonly property int maxRows: 20     // rows on screen at once; the list pages beyond that
  readonly property int maxField: 256   // characters of title / class kept per window
  readonly property int maxFilter: 128  // characters of typed filter

  // ── State ──────────────────────────────────────────────────────────
  property string variant: "two-line" // or "bare"
  property string mode: "all"         // "sameclass" (Cmd+` style) / "sameworkspace"
  property string refClass: ""        // class the sameclass filter locked onto
  property var windows: []            // MRU-ordered rows (WindowModel.rowFor)
  property var visibleWindows: []     // rows matching the filter
  property int viewStart: 0           // first row of the page on screen
  readonly property var visibleRows: visibleWindows.slice(viewStart, viewStart + maxRows)
  property string filterText: ""
  property int selectedIndex: 0
  property bool sticky: false         // typing latched: only Enter/Escape close
  property bool revealed: false       // show-delay gate: a quick tap never renders
  property bool holdOpen: false       // demo/debug: stay open, ignore modifier release
  property bool shiftPressReverses: true
  property int sessionSerial: 0
  property string modifier: "alt"     // key whose release commits: "ctrl", "alt", "super"
                                      // or "none" (picker: Enter/Escape only)

  // Hyprland >= 0.56 in Lua-config mode rejects classic dispatcher syntax.
  readonly property bool luaDispatchMode: Hyprland.usingLua === true

  readonly property bool multiWorkspace: {
    var seen = {}
    var count = 0
    for (var i = 0; i < windows.length; i++) {
      var id = windows[i].workspaceId
      if (!seen[id]) { seen[id] = true; count++ }
    }
    return count > 1
  }

  // ── Palette: mapped from the active Omarchy theme ──────────────────
  readonly property color themeBg: Color.background
  readonly property color themeFg: Color.foreground
  readonly property color themeAccent: Color.accent
  readonly property bool isLight: themeBg.hslLightness > 0.5
  readonly property color panel: themeBg // opaque: nothing shows through the card
  readonly property color line: isLight ? Qt.darker(themeBg, 1.18) : Qt.lighter(themeBg, 1.7)
  readonly property color dim: Color.muted
  readonly property color dim2: Qt.rgba(themeFg.r, themeFg.g, themeFg.b, 0.35)
  readonly property color selBg: Qt.rgba(themeAccent.r, themeAccent.g, themeAccent.b, isLight ? 0.10 : 0.13)

  readonly property string fontFamily: Qt.fontFamilies().indexOf("JetBrains Mono") >= 0
    ? "JetBrains Mono" : "JetBrainsMono Nerd Font"

  // ── Lifecycle: host calls open(payload) on summon, close() on hide ─
  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    if (!payload || typeof payload !== "object") payload = ({})
    if (payload.variant === "bare" || payload.variant === "two-line")
      variant = payload.variant
    var dir = payload.dir === "prev" ? -1 : 1

    if (!opened) {
      // The mode is locked in by the summon that opens the switcher;
      // repeated summons only cycle.
      mode = (payload.mode === "sameclass" || payload.mode === "sameworkspace")
        ? payload.mode : "all"
      // {"hold": true} keeps the switcher up regardless of the modifier state —
      // for screenshots, demos and debugging.
      holdOpen = payload.hold === true
      // Which modifier the summoning bind holds; its release commits the
      // selection. Set it in the binding payload; Alt is the default.
      modifier = (payload.modifier === "ctrl" || payload.modifier === "super" || payload.modifier === "none")
        ? payload.modifier : "alt"
      shiftPressReverses = payload.shiftPressReverses !== false
      sessionSerial++
      pendingFocusAddress = ""
      focusTimer.stop()
      refClass = ""
      sticky = false
      revealed = false
      filterText = ""
      selectedIndex = 0
      viewStart = 0
      loadWindows()
      opened = true
      // MRU[0] is the focused window; the first step lands on the
      // previously used one, macOS-style.
      cycle(dir)
      revealTimer.restart()
    } else {
      cycle(dir)
    }
  }

  function close() {
    sessionSerial++
    opened = false
    revealTimer.stop()
    releaseDelay.stop()
  }

  function ping() { return "ok" }

  IpcHandler {
    enabled: root.pluginId !== ""
    target: root.pluginId
    function shiftPress(modifiers: string): void { root.shiftPressed(modifiers) }
  }

  // xremap's existing copy/paste rules emit Ctrl+Insert and Shift+Insert.
  // Interpret those as the typed C/V inside this Ctrl-based picker. No clipboard
  // action runs here. Typing makes the picker sticky so Ctrl can be released.
  function typedCharacter(event) {
    if (modifier === "ctrl" && event.key === Qt.Key_Insert) {
      if (event.modifiers & Qt.ShiftModifier) return "v"
      if (event.modifiers & Qt.ControlModifier) return "c"
    }
    var ch = event.text
    if ((!ch || ch.charCodeAt(0) < 32) && event.key >= Qt.Key_A && event.key <= Qt.Key_Z)
      ch = String.fromCharCode(97 + event.key - Qt.Key_A)
    return ch && ch.length === 1 && ch.charCodeAt(0) >= 32 && ch.charCodeAt(0) !== 127 ? ch : ""
  }

  // Modifier key events can be filtered before Qt's Keys handlers see them.
  // input.lua forwards only actual Shift press edges from Hyprland. Keep this
  // as the single cycling path so a Qt event cannot cause a second step.
  function shiftPressed(modifiers) {
    if (!opened || sticky || !shiftPressReverses) return
    if (String(modifiers).split(",").indexOf(modifier) < 0) return
    cycle(-1)
  }

  function keyPressed(event) {
    if (!opened) return
    if (event.key === Qt.Key_Shift) {
      // The compositor observer handles this, including repeat suppression.
      event.accepted = true
    } else if (event.key === Qt.Key_Escape) {
      dismiss()
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      activate()
    } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_QuoteLeft) {
      cycle(event.modifiers & Qt.ShiftModifier ? -1 : 1)
    } else if (event.key === Qt.Key_Down) {
      cycle(1)
    } else if (event.key === Qt.Key_Backtab || event.key === Qt.Key_Up) {
      cycle(-1)
    } else if (event.key === Qt.Key_Backspace) {
      filterText = filterText.slice(0, -1)
      applyFilter()
    } else if (variant === "bare" && !sticky && event.key >= Qt.Key_1 && event.key <= Qt.Key_9) {
      var idx = event.key - Qt.Key_1
      if (idx < visibleRows.length) { select(viewStart + idx); activate() }
    } else {
      var ch = typedCharacter(event)
      if (!ch) return
      if (filterText.length < maxFilter) filterText += ch
      sticky = true
      revealed = true
      selectedIndex = 0
      applyFilter()
    }
    event.accepted = true
  }

  function keyReleased(event) {
    var isModifier = modifier === "ctrl" ? event.key === Qt.Key_Control
      : modifier === "super" ? (event.key === Qt.Key_Super_L || event.key === Qt.Key_Super_R || event.key === Qt.Key_Meta)
      : modifier === "alt" && event.key === Qt.Key_Alt
    if (isModifier && !sticky && autoCommit) {
      // xremap can briefly release Ctrl while emitting a different chord.
      // Query after that chord has settled instead of selecting mid-sequence.
      releaseDelay.restart()
      event.accepted = true
    }
  }

  function checkModifier() {
    if (!opened || sticky || !autoCommit || modifierCheck.running) return
    modifierCheck.forSession = sessionSerial
    modifierCheck.running = true
  }

  function modifierResult(text, serial) {
    if (!opened || sticky || !autoCommit || serial !== sessionSerial) return
    // Only a recognized answer can select; a failed IPC query leaves it open.
    if (text.trim().endsWith("SWITCHER_MODIFIER:false")) activate()
  }

  Timer { id: releaseDelay; interval: 20; onTriggered: root.checkModifier() }
  Timer {
    interval: 80
    running: root.opened && root.autoCommit && !root.sticky
    repeat: true
    triggeredOnStart: true
    onTriggered: root.checkModifier()
  }
  Process {
    id: modifierCheck
    property int forSession: -1
    readonly property string keyPrefix: root.modifier === "ctrl" ? "Control" : root.modifier === "super" ? "Super" : "Alt"
    // Hyprland eval discards return values. Its error response carries this
    // read-only result back over IPC, without changing compositor state.
    command: ["timeout", "1", "hyprctl", "eval",
      'error("SWITCHER_MODIFIER:" .. tostring(hl.is_key_down("' + keyPrefix + '_L") or hl.is_key_down("' + keyPrefix + '_R")), 0)']
    stdout: StdioCollector { onStreamFinished: root.modifierResult(text, modifierCheck.forSession) }
  }


  // ── MRU window list ────────────────────────────────────────────────
  // The focus history lives in Service.qml. Look it up live first (the
  // host re-creates services on plugin reloads), then fall back to the
  // instance injected at load time; without either, the compositor's last
  // focus snapshot still orders the list.
  function historyRanker() {
    var svc = null
    if (shell && typeof shell.serviceFor === "function") {
      try { svc = shell.serviceFor(pluginId) } catch (e) { svc = null }
    }
    if (!svc) svc = service
    if (!svc || typeof svc.historyRank !== "function") return null
    return function (address) {
      try { return Number(svc.historyRank(address)) } catch (e) { return -1 }
    }
  }

  function loadWindows() {
    var model = Hyprland.toplevels
    var values = model && model.values ? model.values : []
    var active = Hyprland.activeToplevel
    var activeAddress = active && active.address ? String(active.address) : ""
    var list = WindowModel.collect(values, activeAddress, historyRanker(), maxWindows, maxField)
    // sameclass / sameworkspace: narrow the list relative to the active
    // window (MRU[0]), like macOS Cmd+`.
    if (mode !== "all" && list.length > 0) {
      var ref = list[0]
      refClass = ref.class
      list = list.filter(function (w) {
        return mode === "sameclass"
          ? w.class === ref.class
          : w.workspaceId === ref.workspaceId
      })
    }
    windows = list
    applyFilter()
  }

  function applyFilter() {
    var needle = filterText.toLowerCase()
    var list = []
    for (var i = 0; i < windows.length; i++) {
      var w = windows[i]
      var haystack = (w.title + " " + w.class).toLowerCase()
      if (needle === "" || haystack.indexOf(needle) >= 0) list.push(w)
    }
    visibleWindows = list
    select(selectedIndex < list.length ? selectedIndex : 0)
  }

  // Moves the selection and keeps it on the visible page.
  function select(index) {
    selectedIndex = index
    var start = viewStart
    if (index < start) start = index
    else if (index >= start + maxRows) start = index - maxRows + 1
    start = Math.min(start, visibleWindows.length - maxRows)
    viewStart = Math.max(0, start)
  }

  function cycle(dir) {
    if (visibleWindows.length === 0) return
    select((selectedIndex + dir + visibleWindows.length) % visibleWindows.length)
  }

  // ── Activation ─────────────────────────────────────────────────────
  property string pendingFocusAddress: ""

  function dispatchFocus(addr) {
    // The address is our own copy of a value Hyprland reported, and this
    // is the one place it is spliced into a command: check its shape here.
    if (!WindowModel.isAddress(addr)) return
    // Focus AND raise — in a floating-heavy layout focuswindow alone
    // leaves the window buried under others.
    if (luaDispatchMode) {
      Hyprland.dispatch('hl.dsp.focus({ window = "address:0x' + addr + '" })')
      Hyprland.dispatch("hl.dsp.window.bring_to_top()")
    } else {
      Hyprland.dispatch("focuswindow address:0x" + addr)
      Hyprland.dispatch("alterzorder top")
    }
  }

  function activate() {
    var target = visibleWindows[selectedIndex]
    dismiss()
    if (!target) return
    // Hyprland restores keyboard focus when an exclusive-focus layer
    // unmaps, and that restore races — and can override — a focus
    // dispatched while the layer is still up. Dispatch immediately for an
    // instant visual switch, then once more after the restore has landed
    // to make the result stick.
    dispatchFocus(target.address)
    pendingFocusAddress = target.address
    focusRetries = 0
    focusTimer.restart()
  }

  property int focusRetries: 0
  Timer {
    id: focusTimer
    interval: 50
    repeat: true
    onTriggered: {
      var addr = root.pendingFocusAddress
      if (addr === "" || root.focusRetries >= 3) { stop(); root.pendingFocusAddress = ""; return }
      root.focusRetries++
      root.dispatchFocus(addr)
    }
  }

  function dismiss() {
    // Route through the host so its open/closed bookkeeping stays correct.
    if (shell && typeof shell.hide === "function") shell.hide(pluginId)
    else close()
  }

  // ── Text helpers ───────────────────────────────────────────────────
  // Chromium web apps (an omarchy-launch-webapp `--app=` window) report a
  // class built from the URL and the profile: "chrome-app.slack.com__-Default",
  // "chrome-discord.com__channels_@me-Default". No desktop entry carries that
  // id, so heuristicLookup misses and the last-dot-segment rule below turns it
  // into "Com Default" beside a placeholder icon. The host is the part that
  // identifies the app, and it is also what sits in the launcher's Exec line --
  // so match on that.
  //
  // The class is a string the window chooses for itself, so the match has to
  // be narrow in both directions. The capture must look like a hostname (a
  // dot and a TLD), or a window calling itself "chrome-a__-Default" would
  // borrow the identity of the first launcher whose Exec happens to contain
  // an "a". And it is compared against the "//host" boundary of the URL, not
  // as a bare substring anywhere in the command line.
  function webappEntry(cls) {
    var match = String(cls || "").match(/^chrome-([a-z0-9-]+(?:\.[a-z0-9-]+)*\.[a-z]{2,})(?:__|-Default)/)
    if (!match) return null

    var needle = "//" + match[1]
    var entries = DesktopEntries.applications.values || []
    for (var i = 0; i < entries.length; i++) {
      var exec = String(entries[i].execString || entries[i].command || "")
      if (exec.indexOf(needle) >= 0) return entries[i]
    }

    return null
  }

  function entryFor(cls) {
    var entry = null
    try { entry = DesktopEntries.heuristicLookup(cls) } catch (e) { entry = null }
    if (!entry) { try { entry = DesktopEntries.byId(cls) } catch (e2) { entry = null } }
    if (!entry) entry = webappEntry(cls)
    return entry
  }

  // "dev.zed.Zed" -> "Zed", "google-chrome" -> "Google Chrome"
  function appDisplayName(cls) {
    var entry = entryFor(cls)
    if (entry && entry.name) return String(entry.name)

    var segment = String(cls || "?").split(".").pop().replace(/[-_]/g, " ")
    return segment.replace(/(^|\s)\S/g, function (ch) { return ch.toUpperCase() })
  }

  function rowTitle(w) {
    var t = w.title || ""
    if (t === w.class || t === appDisplayName(w.class)) return ""
    return t
  }

  function iconFor(cls) {
    var entry = entryFor(cls)
    var name = entry && entry.icon ? String(entry.icon) : ""
    var path = name ? Quickshell.iconPath(name, true) : ""
    // The class is a name the window picked for itself: only a plain icon
    // name may go to the theme lookup, never a path or a URL.
    var plain = String(cls || "").toLowerCase()
    if (!path && /^[a-z0-9._@+-]{1,128}$/.test(plain)) path = Quickshell.iconPath(plain, true)
    if (!path) path = Quickshell.iconPath("application-x-executable", true)
    return path
  }

  // A tap shorter than this never shows the switcher at all (macOS-like);
  // the Alt release just commits the pending selection unseen.
  readonly property bool autoCommit: modifier !== "none" && !holdOpen

  Timer {
    id: revealTimer
    // Tuned so a human quick tap (Alt released ~200ms after the press)
    // switches without the switcher ever appearing; the GTK predecessor
    // hit a similar effective threshold through process-startup latency.
    // A picker (modifier "none") has nothing to commit on release, so it
    // doesn't have to wait that window out.
    interval: root.modifier === "none" ? 0 : 250
    onTriggered: root.revealed = true
  }

  // ── UI ─────────────────────────────────────────────────────────────
  PanelWindow {
    id: panel
    // Mapped as soon as the switcher opens so exclusive keyboard focus is
    // grabbed immediately — an Alt release during the show delay must reach
    // us. The card below stays invisible until the reveal timer fires.
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: root.pluginId
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    MouseArea { anchors.fill: parent; onClicked: root.dismiss() }

    Rectangle {
      id: card
      visible: root.revealed
      readonly property int cardWidth: root.variant === "bare" ? 560 : 600
      width: cardWidth
      height: content.height + 2
      anchors.centerIn: parent
      color: root.panel
      radius: Style.cornerRadius
      border.color: root.line
      border.width: 1

      MouseArea { anchors.fill: parent; onClicked: {} }


      Column {
        id: content
        x: 1
        y: 1
        width: card.cardWidth - 2

        // ── Prompt: ❯ caret + filter + count ──
        Item {
          width: parent.width
          height: promptGlyph.height + (root.variant === "bare" ? 24 : 30)

          Text {
            textFormat: Text.PlainText
            id: promptGlyph
            anchors.verticalCenter: parent.verticalCenter
            x: root.variant === "bare" ? 16 : 18
            text: "❯"
            color: root.themeAccent
            font.family: root.fontFamily
            font.pixelSize: 13
            font.weight: Font.Bold
          }

          // The filter "input": typed text with the caret at the insertion
          // point, and the placeholder as a separate layer that never moves
          // the caret.
          Item {
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: promptGlyph.right
            anchors.leftMargin: 10
            anchors.right: parent.right
            anchors.rightMargin: root.variant === "two-line" ? 70 : 16
            height: Math.max(typedText.implicitHeight, 15)
            clip: true

            Text {
              textFormat: Text.PlainText
              id: typedText
              anchors.verticalCenter: parent.verticalCenter
              text: root.filterText
              color: root.themeFg
              font.family: root.fontFamily
              font.pixelSize: 13
            }
            Text { // placeholder, offset past the resting caret
              textFormat: Text.PlainText
              visible: root.filterText === ""
              anchors.verticalCenter: parent.verticalCenter
              x: 4
              text: root.mode === "sameclass" && root.refClass !== ""
                ? "filter " + root.appDisplayName(root.refClass).toLowerCase() + " windows"
                : root.mode === "sameworkspace" ? "filter workspace windows"
                : "filter windows"
              color: root.dim2
              font.family: root.fontFamily
              font.pixelSize: 13
            }
            Rectangle { // caret
              x: root.filterText === "" ? 0 : typedText.contentWidth + 2
              width: 1
              height: 15
              anchors.verticalCenter: parent.verticalCenter
              color: root.themeAccent
              SequentialAnimation on opacity {
                running: root.opened && root.revealed
                loops: Animation.Infinite
                NumberAnimation { to: 0; duration: 530 }
                NumberAnimation { to: 1; duration: 530 }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.variant === "two-line"
            anchors.right: parent.right
            anchors.rightMargin: 18
            anchors.verticalCenter: parent.verticalCenter
            text: root.visibleWindows.length + "/" + root.windows.length
            color: root.dim2
            font.family: root.fontFamily
            font.pixelSize: 11
          }

          Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: 1
            color: root.line
          }
        }

        // ── List: one page of rows around the selection ──
        Item { width: 1; height: root.variant === "bare" ? 5 : 8 }

        Repeater {
          model: root.visibleRows

          delegate: Rectangle {
            id: row
            required property var modelData
            required property int index
            readonly property int listIndex: root.viewStart + index
            readonly property bool selected: listIndex === root.selectedIndex

            width: content.width
            height: root.variant === "bare" ? 30 : rowContent.height + 16
            color: selected ? root.selBg : "transparent"

            // 2px accent selection bar (two-line only, per the design)
            Rectangle {
              visible: root.variant === "two-line" && row.selected
              width: 2
              height: parent.height
              color: root.themeAccent
            }

            Row {
              id: rowContent
              anchors.verticalCenter: parent.verticalCenter
              x: root.variant === "bare" ? 16 : 13
              spacing: root.variant === "bare" ? 12 : 13

              // bare: jump number
              Text {
                textFormat: Text.PlainText
                visible: root.variant === "bare"
                anchors.verticalCenter: parent.verticalCenter
                text: row.index + 1
                color: row.selected ? root.themeAccent : root.dim2
                font.family: root.fontFamily
                font.pixelSize: 11
                font.weight: row.selected ? Font.Bold : Font.Normal
              }

              // two-line: icon
              IconImage {
                visible: root.variant === "two-line"
                anchors.verticalCenter: parent.verticalCenter
                width: 26
                height: 26
                source: root.variant === "two-line" ? root.iconFor(row.modelData.class) : ""
              }

              Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 3

                Row {
                  spacing: 12
                  Text {
                    textFormat: Text.PlainText
                    text: root.appDisplayName(row.modelData.class)
                    color: root.themeFg
                    font.family: root.fontFamily
                    font.pixelSize: 13
                    font.weight: Font.Medium
                  }
                  Text { // bare: inline title
                    textFormat: Text.PlainText
                    visible: root.variant === "bare" && text !== ""
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.rowTitle(row.modelData)
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: 13
                    font.weight: Font.Light
                    elide: Text.ElideRight
                    width: Math.min(implicitWidth, content.width - 220)
                  }
                }

                Text { // two-line: title on its own line
                  textFormat: Text.PlainText
                  visible: root.variant === "two-line" && text !== ""
                  text: root.rowTitle(row.modelData)
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: 11
                  font.weight: Font.Light
                  elide: Text.ElideRight
                  width: Math.min(implicitWidth, content.width - 120)
                }
              }
            }

            // workspace number, only when it carries information
            Text {
              textFormat: Text.PlainText
              visible: root.multiWorkspace
              anchors.right: parent.right
              anchors.rightMargin: root.variant === "bare" ? 16 : 18
              anchors.verticalCenter: parent.verticalCenter
              text: row.modelData.workspaceId
              color: row.selected ? root.themeAccent : root.dim2
              font.family: root.fontFamily
              font.pixelSize: 11
            }

            MouseArea {
              anchors.fill: parent
              onClicked: { root.select(row.listIndex); root.activate() }
            }
          }
        }

        Item { width: 1; height: root.variant === "bare" ? 5 : 8 }

        // ── Footer: key hints (two-line only) ──
        Item {
          visible: root.variant === "two-line"
          width: parent.width
          height: 35

          Rectangle { width: parent.width; height: 1; color: root.line }

          Row {
            anchors.verticalCenter: parent.verticalCenter
            x: 18
            spacing: 18

            Repeater {
              model: [["tab", "next"], [root.shiftPressReverses ? "⇧" : "⇧tab", "prev"], ["type", "search"], ["↵", "focus"], ["esc", "cancel"]]
              delegate: Row {
                required property var modelData
                spacing: 5
                Text {
                  textFormat: Text.PlainText
                  text: parent.modelData[0]
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: 10
                  font.weight: Font.Medium
                }
                Text {
                  textFormat: Text.PlainText
                  text: parent.modelData[1]
                  color: root.dim2
                  font.family: root.fontFamily
                  font.pixelSize: 10
                  font.weight: Font.Light
                }
              }
            }
          }
        }
      }
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function (event) { root.keyPressed(event) }
      Keys.onReleased: function (event) { root.keyReleased(event) }
    }
  }
}
