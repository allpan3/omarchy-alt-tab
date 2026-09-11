import Quickshell.Hyprland
import QtQuick
import "WindowModel.js" as WindowModel

// Focus history for the window switcher.
Item {
  id: root

  property var shell: null
  property var manifest: null

  Component.onCompleted: Hyprland.refreshToplevels()

  // ── Focus history ──────────────────────────────────────────────────
  // Window addresses (hex without 0x, the form Hyprland's events and
  // Quickshell's HyprlandToplevel.address share), most recently focused
  // first. Bounded: entries leave on closewindow, and the list never grows
  // past historyLimit (WindowModel.noteFocus drops the oldest).
  property var history: []
  readonly property int historyLimit: 512
  property string pendingFocus: ""

  // A workspace transition can report its former focused window, then the
  // intended target in the same burst. Recording both makes that intermediate
  // window look like the previous app. Keep only the final focus for the frame.
  function queueFocus(address) {
    if (!WindowModel.isAddress(address)) return
    pendingFocus = address
    focusSettle.restart()
  }

  function flushFocus() {
    if (!pendingFocus) return
    history = WindowModel.noteFocus(history, pendingFocus, historyLimit)
    pendingFocus = ""
    focusSettle.stop()
  }

  function forgetWindow(address) {
    if (pendingFocus === address) pendingFocus = ""
    history = WindowModel.forget(history, address)
  }

  Timer {
    id: focusSettle
    interval: 16
    onTriggered: root.flushFocus()
  }

  // 0 = focused most recently, -1 = never seen focused by this service.
  function historyRank(address) {
    // A quick next invocation need not wait for the timer to see the latest
    // completed focus burst. All rows then use this same committed history.
    flushFocus()
    return history.indexOf(String(address))
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event.name === "activewindowv2") root.queueFocus(event.data)
      else if (event.name === "closewindow") root.forgetWindow(event.data)
    }
  }
}
