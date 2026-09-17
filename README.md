<div align="center">

# ♞ Gambito

**A keyboard-first Lichess client for tiling desktops.**
Rust daemon · Quickshell UI · Stockfish analysis

[Install](docs/install.md) · [Guide](docs/guide.md) · [Keyboard](docs/keyboard.md) · [CLI & protocol](docs/cli.md) · [Development](docs/development.md)

![Playing, analysing with Stockfish, a second tiled window and zen mode, all from the keyboard](docs/screenshots/demo.gif)

</div>

Gambito brings Lichess to your desktop the way the rest of your setup already works: every action has a key, windows tile cleanly at any size, and the UI is Quickshell, the same Qt Quick toolkit behind [Omarchy 4](https://omarchy.org) and many Hyprland rices. A small Rust daemon holds the games, streams from Lichess and runs Stockfish, so any number of windows (or scripts) can share the same game.

## Why Gambito

- **Keyboard first, mouse optional.** `hjkl` or SAN/UCI to move, `:` for a command line, `?` for every key. Every button shows its key.
- **Made for tiling.** Every page reflows from a full screen down to a narrow column, and scrolls instead of clipping; zen mode (`z`) shows just the board.
- **Quickshell native.** One Quickshell process hosts all windows, and the lobby uses about 50 MB. It sits in your launcher like any app.
- **Your theme, live.** Follows the current Omarchy theme out of the box. Any other Quickshell setup drives it with one `colors.toml` in the same format, from matugen, pywal or your own script.
- **A daemon like `emacs --daemon`.** `gambito open` attaches a window; closing it keeps your games, clocks and streams running. Open the same game in two windows, or drive it from the CLI.
- **Real analysis.** Local Stockfish up to depth 245 with live updates and a best-move arrow, Lichess server analysis with `?!` `?` `??` marks, opening explorer, and analysis boards with saved variations.
- **Fair play built in.** Engine, explorer and analysis are blocked by the daemon in your own live games.

## Features

| Play | Study | Watch |
|---|---|---|
| Seek opponents (Rapid, Classical, correspondence) | Stockfish evaluation with depth control | Lichess TV: every channel, live clocks |
| Lichess AI levels 1–8 | Lichess computer analysis per move | Open any TV game on your own board |
| Challenges, chat and takebacks | Opening explorer (Masters and Lichess) | Profile: ratings chart, history, accuracy |
| Local two-player games | Puzzle of the day and every puzzle theme | News from the Lichess blog |
| Desktop notifications | Analysis boards from any position or FEN | PGN export, NDJSON event stream |

<table>
<tr>
<td width="50%"><img src="docs/screenshots/lobby.png" alt="Lobby with Lichess TV, puzzle of the day and news"></td>
<td width="50%"><img src="docs/screenshots/tv.png" alt="Lichess TV with every channel"></td>
</tr>
<tr>
<td width="50%"><img src="docs/screenshots/openings.png" alt="Opening explorer with popular continuations"></td>
<td width="50%"><img src="docs/screenshots/tiling.png" alt="The lobby reflowing in narrow tiled panes"></td>
</tr>
</table>

## Quick start

On Arch Linux (including Omarchy):

```sh
sudo pacman -S --needed rust quickshell stockfish ttf-dejavu libnotify
git clone https://github.com/harbefas/gambito && cd gambito
cargo build --release
./target/release/gambito open
```

`gambito open` starts the daemon when needed and opens the lobby. Press **Connect Lichess** (`l`) to sign in through your browser; local games, TV, puzzles and news work without an account. To install it for your user (systemd service, launcher entry, Omarchy or Hyprland keybinding, theme), see [Install](docs/install.md).

## Keys you'll use first

| Key | Action | Key | Action |
|---|---|---|---|
| `s` / `c` | Find opponent / play computer | `e` | Engine on/off |
| `hjkl` + Enter | Move a piece | `i` | Type a move (`Nf3`, `e2e4`) |
| `[` `]` | Step through moves | `a` | Analysis board from here |
| `t` / `o` / `z` / `p` | TV / openings / puzzles / profile | `z` (on a board) | Zen mode |
| `w` | New window | `?` | All keys |

Full list: [docs/keyboard.md](docs/keyboard.md).

## From the terminal

```sh
gambito seek 15 10 --rated           # find an opponent
gambito move ABCDef12 Nf3            # play in any game
gambito challenge Friend --days 3    # correspondence challenge
gambito --json watch | jq .          # every state change as NDJSON
```

Windows and scripts talk to the same daemon over a Unix socket with one JSON object per line. See [CLI & protocol](docs/cli.md).

## Status

Gambito is young and developed on Hyprland. Standard chess only (no variants or premoves), and Bullet/Blitz seeks are hidden because Lichess does not pair third-party apps in those pools. [Known limitations](docs/development.md#current-limitations).

Gambito is not affiliated with Lichess. It uses the public [Lichess API](https://lichess.org/api) and draws pieces with system font glyphs; no Lichess assets are copied.

## License

[GPL-3.0-or-later](LICENSE).
