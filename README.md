# Alt-Tab Switcher for Omarchy

A macOS-style Alt-Tab window switcher, running inside the Omarchy shell
(`omarchy-shell`) as a plugin. This fork of
[Lukasz Wojtaszek’s Alt-Tab Switcher](https://github.com/luwojtaszek/omarchy-alt-tab)
adds Ctrl release selection, Shift-alone cycling and reliable cross-workspace
focus history. Set up shortcuts with the optional xremap helper or the
manual examples below.

| Tokyo Night | macOS Light |
|---|---|
| ![Alt-Tab Switcher on Tokyo Night](preview.png) | ![Alt-Tab Switcher on macOS Light](preview-light.png) |

The switcher takes its colors from whatever Omarchy theme is active — the
shots above are the stock Tokyo Night and macOS Light, untouched.

- **MRU order** — windows listed by most-recently-used; the first `Alt+Tab`
  selects your previous window, including across workspaces. Each window
  gets its own row; windows are not grouped by app.
- **Release the modifier to switch** — hold Alt and cycle with Tab; releasing Alt
  focuses the selection. A quick tap switches to the previous window without
  the switcher ever appearing.
- **Shift alone to reverse** — while holding the switch modifier, each
  Shift press moves back one window (until you start searching).
- **Type to filter** — just start typing while the switcher is open; it
  latches into sticky mode (Enter focuses, Escape cancels).
- **Theme-native** — the palette maps live onto your active Omarchy theme
  (background / foreground / accent / muted from `colors.toml`). Light and
  dark themes both work; nothing is hard-coded. The card also follows
  Omarchy/Hyprland corner rounding, including square stock themes.
- **Two looks** — `two-line` (default: app icon, window title on its own
  line, key-hint footer) and `bare` (compact rows with `alt+<n>` jump
  numbers that focus a window directly).

## Install

Requires Omarchy with Lua Hyprland configuration. Install the plugin, then
set up bindings as shown below. The running plugin does not register
shortcuts or write configuration files automatically.

```bash
omarchy plugin add https://github.com/allpan3/omarchy-alt-tab.git --enable
```

## Update

```bash
omarchy plugin update allpan3.omarchy-alt-tab
```

The shell keeps the QML it has already loaded until it restarts, so follow
an update with `omarchy restart shell` (or log out and back in) to get the
new version.

## Remove

Remove or comment out your switcher bindings and the `input.lua` loader
before removing the plugin, so Hyprland does not load a missing file.
If you used the xremap helper, run `bash apply-binds.sh --remove --apply`
from the plugin directory before removing it. Remove any manual xremap
bindings yourself, and reload xremap if it does not watch its configuration.

```bash
hyprctl reload
hyprctl configerrors
omarchy plugin remove allpan3.omarchy-alt-tab
```

## Keybindings

**Optional xremap installer** — requires xremap and Python with PyYAML
(`python-yaml` on Arch), plus an existing block-style `keymap:` list.
It installs Alt+Tab / Alt+Shift+Tab and Alt+grave / Alt+Shift+grave:

```bash
cd ~/.config/omarchy/plugins/allpan3.omarchy-alt-tab
bash apply-binds.sh                   # preview only
bash apply-binds.sh --apply           # back up and install
```

Use `--modifier Control_R` on either command for right-Ctrl shortcuts.
Use `--config /path/to/config.yml` for a different xremap configuration.
After installation, edit the xremap block directly. Running the helper
again preserves your edits; conflicting existing shortcuts are refused
(conservatively treating left/right variants as conflicts).
To remove only its marked block, preview with `bash apply-binds.sh --remove`,
then add `--apply`. Unmarked manual bindings are never removed.

The helper edits only xremap. For Shift-alone cycling, also add the
`input.lua` loader shown below. Reload xremap if it does not watch its
configuration. There is no `settings.json` or background synchronization.

**Manual bindings** — Alt is the default modifier. Add these bindings to
`~/.config/hypr/bindings.lua`. The two `hl.unbind` calls replace Omarchy's
stock Alt+Tab next/previous-window bindings:

```lua
local switcherId = "allpan3.omarchy-alt-tab"
local switcher = "omarchy-shell shell summon " .. switcherId
hl.unbind("ALT + TAB")
hl.unbind("ALT + SHIFT + TAB")
o.bind("ALT + TAB", "Window switcher", switcher .. [[ '{"dir":"next"}']])
o.bind("ALT + SHIFT + TAB", "Window switcher (back)", switcher .. [[ '{"dir":"prev"}']])
o.bind("ALT + GRAVE", "Same-app switcher", switcher .. [[ '{"mode":"sameclass"}']])
o.bind("ALT + SHIFT + GRAVE", "Same-app switcher (back)", switcher .. [[ '{"mode":"sameclass","dir":"prev"}']])

-- Enables Shift alone to move back while the switch modifier is held.
assert(loadfile(os.getenv("HOME") .. "/.config/omarchy/plugins/" .. switcherId .. "/input.lua"))(switcherId)
```

Run `hyprctl reload` and check `hyprctl configerrors` after editing.
Tab switches all windows across workspaces; grave switches windows of the
current app. Special/scratchpad workspaces are excluded.

### Making them yours

Change the binding and its payload's `modifier` together: `alt` (default),
`ctrl` or `super`. Use `none` for a picker that stays open until Enter/Escape.
Set `shiftPressReverses` to `false` to disable Shift-alone cycling, or
`variant` to `bare` for compact rows. All options are passed directly in
the summon command; there is no separate settings file.

For left/right-specific shortcuts, use xremap instead of Hyprland bindings.
For example, add this entry to your existing `keymap` list in
`~/.config/xremap/config.yml` to use right Ctrl:

```yaml
keymap:
  - name: Window switcher
    exact_match: true
    remap:
      Control_R-Tab:
        launch: [omarchy-shell, shell, summon, allpan3.omarchy-alt-tab, '{"modifier":"ctrl"}']
      Control_R-Shift-Tab:
        launch: [omarchy-shell, shell, summon, allpan3.omarchy-alt-tab, '{"modifier":"ctrl","dir":"prev"}']
      Control_R-Grave:
        launch: [omarchy-shell, shell, summon, allpan3.omarchy-alt-tab, '{"modifier":"ctrl","mode":"sameclass"}']
      Control_R-Shift-Grave:
        launch: [omarchy-shell, shell, summon, allpan3.omarchy-alt-tab, '{"modifier":"ctrl","mode":"sameclass","dir":"prev"}']
```

Keep the `input.lua` loader in your Hyprland config for Shift-alone cycling.
Reload xremap if it does not watch its configuration. Left-Ctrl shortcuts
remain available with this example.

## Keys (while open)

| Key | Action |
|---|---|
| `Alt+Tab` / `Tab` / `↓` / `` ` `` | next window |
| `Alt+Shift+Tab` / `⇧Tab` / `↑` | previous window |
| `Shift` alone while holding the switch modifier | previous window (when enabled and not searching) |
| release the switch modifier | focus selection (unless you typed a filter) |
| type text | filter windows; switcher stays open |
| `1`–`9` | focus the n-th row on screen directly (`bare` variant) |
| `↵` | focus selection |
| `Esc` / click outside | cancel |

After typing starts a filter, release the switch modifier to continue typing normally.
In Ctrl mode, `Ctrl+Insert` and `Shift+Insert` are interpreted as search
letters C and V for compatibility with copy/paste remaps. Other global
remaps still apply; for example, release Ctrl_R before typing a space if
`Ctrl_R+Space` switches your input source.

The card shows up to 20 rows at a time; with more windows than that it
pages along as you cycle, and the counter in the corner keeps the full
tally. Typing a filter is the quick way to reach a window far down the list.

## Options

Options are passed in the summon payload:

| Key | Values | Default | |
|---|---|---|---|
| `dir` | `next`, `prev` | `next` | initial / repeated cycle direction |
| `variant` | `two-line`, `bare` | `two-line` | visual style |
| `mode` | `all`, `sameclass`, `sameworkspace` | `all` | which windows to list |
| `modifier` | `ctrl`, `alt`, `super`, `none` | `alt` | which key's release commits; `none` = picker, Enter/Escape only |
| `shiftPressReverses` | `true`, `false` | `true` | Shift alone cycles backward before searching; requires `input.lua` |
| `hold` | `true`, `false` | `false` | stay open regardless of the modifier state (screenshots, demos, debugging) |

`sameclass` lists only windows of the active window's app — bind it to
``Alt+` `` for the macOS ``Cmd+` `` feel. `sameworkspace` lists only the
active window's workspace. The mode is locked in by the summon that opens
the switcher; repeated summons just cycle.

```lua
o.bind("ALT + GRAVE", "Same-app switcher",
  "omarchy-shell shell summon allpan3.omarchy-alt-tab '{\"dir\":\"next\",\"mode\":\"sameclass\"}'")
```

Example — the `bare` variant:

```
omarchy-shell shell summon allpan3.omarchy-alt-tab '{"dir":"next","variant":"bare"}'
```

## How it works, dependencies, privileges

The switcher is a `menu`-kind plugin: a fullscreen layer surface with
exclusive keyboard focus, summoned into the long-running `omarchy-shell`
process. Repeated shortcut presses arrive as repeated summons (xremap or
a manual Hyprland bind consumes the key) and cycle the selection. The
configured modifier’s release commits the selection.

- Window list: the shell's own Hyprland model (`Hyprland.toplevels`), the
  same one the first-party bar and other plugins read. MRU order comes from the focus history the
  plugin's service keeps from the compositor's `activewindowv2` events,
  seeded from the compositor's own focus history for windows it has not
  seen focused yet. Focus events in a workspace-transition burst are
  coalesced so an intermediate window does not replace the previous window
  in the history. Pending focus is flushed before the next picker opens.
- Focusing: a Hyprland `focuswindow` dispatch. Both classic and Lua-config
  Hyprland dispatch syntax are supported (the shell reports which one is
  in use).
- Keybindings: defined in Hyprland or xremap, with an optional one-time
  xremap installer (`apply-binds.sh`).
  The popup uses `hyprctl` and coreutils `timeout`; Shift-alone cycling uses
  the `input.lua` observer loaded in your Hyprland configuration.
- No additional daemon or root access is needed by the plugin. It runs
  unsandboxed inside the shell process with your user permissions, like
  every Omarchy shell plugin. xremap retains its own input-access requirements.
- Committing on release uses Qt key events plus a read-only Hyprland Lua
  modifier-state query every 80 ms while cycling, bounded by a one-second
  timeout. This covers releases before the popup receives keyboard focus
  and avoids committing on a temporary Ctrl release from remapping. Queries
  stop when the popup closes or search begins. Failed queries leave the
  picker open for Enter/Escape. The plugin does not read evdev devices.
- Shift-alone cycling observes press/release edges through Hyprland's Lua
  keyboard events. Each new press moves once, without cycling again for
  key repeats or duplicate Qt events.
- Typography follows the Omarchy brand font: JetBrains Mono. With only the
  stock `ttf-jetbrains-mono-nerd-basic` installed the Light/Medium weights
  render as Regular; install `ttf-jetbrains-mono` for the full effect.

## Security notes

What the plugin treats as untrusted, and what it does about it:

- **Window titles and classes** are chosen by the application that owns the
  window (a web page sets its browser window's title). Every `Text` element
  renders as `Text.PlainText`, so markup in a title is just characters. From
  each window the switcher copies exactly seven fields — address, class,
  title, workspace id, active flag and two ordering keys — clipped to 256
  characters, keeps at most 256 windows and renders at most 20 rows. The
  class goes to the icon-theme lookup only if it is a plain icon name (no
  path, no URL). The address is checked against `^[0-9a-f]{1,16}$` right
  where it is spliced into the focus dispatch.
- **Subprocesses** for modifier checks use an argv array with fixed modifier
  names and a one-second timeout. The Shift observer's IPC command contains
  only fixed modifier names and the validated manifest ID, never window
  titles or other application text.
- **The summon payload** is JSON from whoever can run `omarchy-shell` as
  you; only the keys and values in the Options table are honored, everything
  else is ignored.

`node tests/window-model.test.js` covers the window-list logic;
`node tests/focus-history.test.cjs` covers workspace-transition ordering.
`node tests/keyboard.test.cjs` and `lua tests/input.test.lua input.lua` check
release handling, search and repeated Shift presses.
`python3 tests/test_apply_binds.py` checks installer previews, backups,
removal, conflicts and preservation of manual edits using the xremap parser.

## License

MIT
