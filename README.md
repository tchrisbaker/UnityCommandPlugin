# Unity Commander

An [Omarchy](https://omarchy.org/) bar plugin for browsing and running Unity CLI commands (the `tcb::` namespace by default, or every command the connected Editor/Player exposes) from a searchable panel — no terminal required.

## Features

- **Fuzzy search** across commands, keyboard-driven (arrow keys + Enter) or by click
- **Toggle** between "tcb:: commands only" and every command available; always resets to tcb:: on open
- **Auto-generated parameter forms**: checkboxes for booleans, fuzzy-searchable dropdowns for `unit`/`*manager*` parameters (refreshed live from the connected Editor each time you open the dropdown, with a way to clear the selection), number steppers (with an explicit "Clear" for optional ones), text fields for everything else — required vs. optional is called out on every field
- **Run** a command and get the result back as a readable, foldable view (long lists collapse to just their first item's title, click to expand) — or flip to raw JSON
- **Copy command**: puts the exact `unity cmd ...` invocation, with your current parameter values, on the clipboard
- Clearly separates **"Unity isn't running / not reachable"** from **"command executed but returned an error"** — they need different reactions
- Follows the active Omarchy theme's colors; font size is adjustable (small/medium/large)

## Requirements

- [Omarchy](https://omarchy.org/)
- The [`unity` CLI](https://docs.unity.com/cli/) on `PATH`, able to reach a running Unity Editor or Player with the Pipeline package

## Install

```sh
omarchy plugin add https://github.com/tchrisbaker/UnityCommandPlugin.git --enable
```

Or manually:

```sh
git clone https://github.com/tchrisbaker/UnityCommandPlugin.git ~/.config/omarchy/plugins/chris.unity-commander
omarchy plugin enable chris.unity-commander
```

## Usage

Click the **UC** chip in the bar (or `omarchy-shell shell toggle chris.unity-commander`). Search for a command, fill in its parameters, hit **Run command**.

## Files

| File | Purpose |
|---|---|
| `manifest.json` | Plugin metadata + version |
| `BarWidget.qml` | The "UC" bar chip |
| `Window.qml` | The app itself: command list + parameter form + results |
| `ResultRowView.qml` | One row of the human-readable results view (recursive, foldable) |
| `Model.js` | All non-UI logic: fuzzy search, CLI arg building, response parsing, JSON→rows |

No build step — edit a file and save; the running bar picks it up automatically. See `manifest.json`'s `version` before making changes, and bump `root.appVersion` in `Window.qml` alongside it.

## License

MIT
