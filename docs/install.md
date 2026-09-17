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
systemctl --user daemon-reload
systemctl --user enable --now gambito.service
```

After updating:

- **Binary:** restart the service with `systemctl --user restart gambito`.
- **UI:** copy `ui/*.qml` again, and delete any files that were removed from `ui/`. Quickshell loads the QML when it starts, so close every Gambito window before reopening.

## Open it from a keybinding

Hyprland (Lua config):

```lua
hl.bind("SUPER + G", hl.dsp.exec_cmd(os.getenv("HOME") .. "/.local/bin/gambito open"))
```

Hyprland (`hyprland.conf`):

```ini
bind = SUPER, G, exec, ~/.local/bin/gambito open
```

Every call to `gambito open` adds a window to the running Gambito process. That's cheap: a new window costs a few MB, not a new Quickshell instance.

## Sign in to Lichess

Press **Connect Lichess** (`l`) or run `:login` in a window. Gambito uses OAuth with PKCE in your browser and asks only for `board:play`, `challenge:read`, `challenge:write`, `puzzle:read` and `puzzle:write`. Sign out from the profile (`l`, then Enter) or with `:logout`.

To use a personal token instead, create one at <https://lichess.org/account/oauth/token/create> with the same scopes and pipe it in:

```sh
pass show lichess/gambito | gambito auth
```

The token is validated and saved with mode 0600 at `$XDG_CONFIG_HOME/gambito/token` (default `~/.config/gambito/token`). Keep tokens out of command-line arguments.

Accounts connected before a scope was added (for example `challenge:read`) must sign out and connect again.

## Theme

The UI reads the current mode from `~/.local/state/desktop/theme` and colors from `~/.config/desktop/theme-<mode>.toml`, and follows changes live. Without these files it uses its built-in dark palette.

## Stockfish

Install `stockfish` on the daemon's `PATH`, or set `GAMBITO_STOCKFISH` to an engine executable before starting the daemon. Without a local engine, Gambito falls back to the Lichess cloud evaluation cache. An engine installed while the daemon runs is picked up on the next evaluation request.
