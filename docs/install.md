# Install

## Requirements

- Rust 1.95 or newer
- [Quickshell](https://quickshell.org) with Qt Quick Controls
- The DejaVu Sans font (pieces are font glyphs)
- Optional: `stockfish` for local evaluation, `notify-send` for desktop notifications

On Arch Linux and Omarchy:

```sh
sudo pacman -S --needed rust quickshell stockfish ttf-dejavu libnotify
```

Gambito runs anywhere Quickshell runs. It is developed and tested on Hyprland.

## Try it from the repository

```sh
cargo build --release
./target/release/gambito open
```

`open` and `local` start the daemon when it is not running, and `gambito daemon` runs it in the foreground. Closing a window leaves the daemon running. Without an installed UI, `gambito open` uses the `ui/` folder of the checkout.

## Install for your user

```sh
cargo build --release
install -Dm755 target/release/gambito ~/.local/bin/gambito
install -Dm644 -t ~/.local/share/gambito/ui ui/*.qml
install -Dm644 packaging/gambito.service ~/.config/systemd/user/gambito.service
install -Dm644 packaging/gambito.desktop ~/.local/share/applications/gambito.desktop
install -Dm644 packaging/gambito.svg ~/.local/share/icons/hicolor/scalable/apps/gambito.svg
systemctl --user daemon-reload
systemctl --user enable --now gambito.service
```

After updating:

- **Binary:** restart the service with `systemctl --user restart gambito`.
- **UI:** copy `ui/*.qml` again, and delete any files that were removed from `ui/`. Quickshell loads the QML when it starts, so close every Gambito window before reopening.

## Open it

The desktop entry puts Gambito in any app launcher: the Omarchy menu, Walker, fuzzel, rofi or your Quickshell launcher.

Each `gambito open` adds a window to the running Gambito process, which costs a few MB rather than a new Quickshell instance. Windows use the app ID (window class) `gambito`, matching the desktop entry, so docks and taskbars show the icon, and launch-or-focus scripts and window rules can match on it.

**Omarchy.** Add a binding to `~/.config/hypr/bindings.lua`. `SUPER + ALT + C` is free in Omarchy's defaults, and this focuses Gambito when it is already open:

```lua
o.bind("SUPER + ALT + C", "Gambito", "omarchy-launch-or-focus Gambito 'gambito open'")
```

**Hyprland**, Lua config:

```lua
hl.bind("SUPER + ALT + C", hl.dsp.exec_cmd("gambito open"))
```

**Hyprland**, `hyprland.conf`:

```ini
bind = SUPER ALT, C, exec, gambito open
```

On other compositors, bind `gambito open` the same way.

To float Gambito or send it to a workspace, match the class. Hyprland, Lua config:

```lua
hl.window_rule({ name = "gambito", match = { class = "^gambito$" }, workspace = "5" })
```

## Sign in to Lichess

Press **Connect Lichess** (`l`) or run `:login` in a window. Gambito uses OAuth with PKCE in your browser and asks only for `board:play`, `challenge:read`, `challenge:write`, `puzzle:read` and `puzzle:write`. Sign out from the profile (`l`, then Enter) or with `:logout`.

To use a personal token instead, create one at <https://lichess.org/account/oauth/token/create> with the same scopes and pipe it in:

```sh
pass show lichess/gambito | gambito auth
```

The token is validated and saved with mode 0600 at `$XDG_CONFIG_HOME/gambito/token` (default `~/.config/gambito/token`). Keep tokens out of command-line arguments.

Accounts connected before a scope was added (for example `challenge:read`) must sign out and connect again.

## Theme

Gambito uses [Omarchy's `colors.toml` format](https://github.com/omacom/omarchy/blob/quattro/docs/theming.md#colorstoml) and follows theme changes live, without a restart. It uses the first palette it finds:

1. `~/.config/gambito/colors.toml`, your own palette
2. Omarchy 4's current theme, `~/.local/state/omarchy/current/theme/colors.toml`
3. Omarchy 3's current theme, `~/.config/omarchy/current/theme/colors.toml`
4. `~/.config/desktop/theme-<mode>.toml`, with the mode read from `~/.local/state/desktop/theme`
5. The built-in dark palette

On Omarchy there's nothing to set up: `omarchy-theme-set` recolors open Gambito windows.

On any other setup, write `~/.config/gambito/colors.toml`, by hand or from the template of whatever tool generates your colors (matugen, pywal, wallust, your shell's own theme script). Gambito reads these keys; any missing one falls back to the built-in palette:

```toml
background = "#1a1b26"   # window
foreground = "#a9b1d6"   # text; panels and borders are mixed from these two
accent     = "#7aa2f7"   # focus rings, keyboard cursor, popularity bars
muted      = "#414868"   # dark squares are mixed from muted and green
red        = "#f7768e"   # errors, resign, blunders
green      = "#9ece6a"   # dark squares, good moves, wins
yellow     = "#e0af68"   # last-move highlight
bright_green = "#9ece6a" # selected square
```

Colors may be written with or without `#`. Text in monospace (clocks, hints, the command line) uses fontconfig's `monospace` family, the font `omarchy-font-set` changes; set `font = "Family Name"` in the palette to pick another.

## Stockfish

Install `stockfish` on the daemon's `PATH`, or set `GAMBITO_STOCKFISH` to an engine executable before starting the daemon. Without a local engine, Gambito falls back to the Lichess cloud evaluation cache. An engine installed while the daemon runs is picked up on the next evaluation request.
