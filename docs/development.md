# Development

## Architecture

```
┌──────────────────── Qt Quick host ─────────────────┐
│  gambito-qt ── GambitoWindow ×N ── views (Loader)  │      gambito CLI
└───────────────────────┬────────────────────────────┘          │
                        │ JSON lines over a Unix socket          │
                ┌───────┴─────────────────────────────────────────┴──┐
                │ gambito daemon (Rust, tokio)                       │
                │  game.rs    rules (shakmaty), clocks, PGN          │
                │  server.rs  connections, state, caches, commands   │
                │  lichess.rs Board API, streams, OAuth, explorer    │
                │  engine.rs  Stockfish over UCI, cloud eval         │
                └───────────────┬───────────────────────┬────────────┘
                           lichess.org             stockfish
```

- **Daemon** (`src/`): owns every game, sends `state` to all connections and answers commands per connection with `request_id`. `main.rs` holds the CLI, paths and socket client.
- **UI** (`ui/`): a standalone Qt Quick host creates windows from `GambitoWindow.qml`; `gambito open` starts `gambito-qt` and passes an optional game id. The process exits when the last window closes.
- **Window** (`GambitoWindow.qml`): socket, keys, command bar and help. Pages are `Loader`s, active only while shown: `LobbyView`, `BoardView`, `ProfileView`, `TvView`, `OpeningsView`, `PuzzlesView`, `ChallengesView`.
- **Shared components:** `ActionButton`, `ThemedTextField`, `ThemedComboBox`, `GameRow`, `MiniBoard`, `TvBoard`, `ResultBar`, `ChatPanel`, `PlayScreen`.

### Qt host

The `standalone/` directory contains the CMake host for the Qt Quick UI. It
reuses the Rust daemon and Unix socket protocol and provides a small
`QQmlApplicationEngine` host plus Qt `QLocalSocket` and file-watcher bridges.
Build it with:

```sh
cmake -S standalone -B target/qt-build -DCMAKE_BUILD_TYPE=Release
cmake --build target/qt-build -j2
```

The host supports multiple windows, live theme files and desktop installation.

## Memory

Measured per process (anonymous memory): lobby ~52 MB, board ~72 MB, openings ~63 MB; the state broadcast is ~5 KB. What keeps it there:

- **One process:** a single Qt host for all windows.
- **Loaded on demand:** pages load only while shown.
- **Lighter drawing:** arrows drawn with `QtQuick.Shapes`; the software renderer is the default (about 30 MB less per window than GL).
- **Small state:** move history stays out of the broadcast state.
- **Lean mini boards:** a mini board is ~70 objects (32 dark squares and the occupied pieces).

Animations measured at 0 MB and were kept.

## Tests

```sh
cargo build                    # the Python tests use target/debug/gambito
cargo test
cargo clippy --all-targets -- -D warnings
python3 tests/integration.py   # daemon against a fake Lichess server and fake Stockfish
python3 tests/ui.py            # offscreen Qt Quick with QtTest keyboard events
python3 tests/engine-depth.py
shellcheck tests/fake-stockfish.sh && shfmt -d tests/fake-stockfish.sh
```

- **No real accounts:** tests never challenge or play against real accounts.
- **Loopback API only:** `GAMBITO_API_URL` and `GAMBITO_EXPLORER_URL` accept loopback addresses only.
- **Screenshots:** UI tests write `screenshot-*.png` in the repository root (ignored by git) for visual checks.

Pitfalls:

- **Silent QtTest failures:** add `console.log` checkpoints to find the failing check.
- **Layout feedback loops:** a size must never depend on a child whose size depends on it. The UI freezes at 100% CPU with no log output. Size boards from the pane, never from content heights.
- **Tab:** Tab never reaches Qt Quick `Keys` handlers (it moves focus), so it can't be a shortcut.

## Current limitations

- **Standard chess only:** no variants, premoves or studies.
- **Seek pools:** Bullet and Blitz seeks aren't offered, because Lichess doesn't pair third-party apps there. Challenges support Blitz and slower.
- **Rewinding is read-only:** use analysis boards to play alternatives. PGN export contains the selected line, not the whole variation tree.
- **Local games** have no clocks and no threefold or 50-move claim (use `:draw`). Computer opponents are the Lichess AI.
- **Online moves** wait for server confirmation; timed-out moves are not replayed.
- **Missing on Lichess's side:** opening descriptions and popularity charts have no API. News shows titles only, because blog thumbnails are WebP, which this Qt build can't decode.
- **No editors:** there's no theme or shortcut editor.
- **Test coverage:** Lichess integration is tested against a simulated server.
