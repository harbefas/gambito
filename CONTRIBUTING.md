# Contributing

Thanks for trying Gambito. Bug reports and small fixes are the most useful thing right now.

**Never paste a Lichess token** into an issue, a log or a screenshot. Tokens live in `~/.config/gambito/token`. If one leaks, revoke it at <https://lichess.org/account/oauth/token>.

## Reporting a bug

Open an issue with the version (`gambito --version` or the commit), your distro and compositor, and the steps. The daemon log usually says what happened:

```sh
systemctl --user status gambito     # when installed as a service
journalctl --user -u gambito -n 50
gambito daemon                      # or run it in the foreground
```

For anything visual, a screenshot beats a description. The UI loads its QML at startup, so after updating it, close every window before reopening.

## Working on the code

```sh
cargo build                    # the Python tests use target/debug/gambito
cargo test
cargo clippy --all-targets -- -D warnings
python3 tests/integration.py   # daemon against a fake Lichess and fake Stockfish
python3 tests/ui.py            # offscreen Quickshell with QtTest keyboard events
```

Tests never touch a real account: the fake Lichess server is loopback-only, and `GAMBITO_API_URL` refuses anything else. [docs/development.md](docs/development.md) has the architecture, the memory numbers and the pitfalls worth knowing before touching QML.

## What Gambito tries to be

- **Every control has a key, and the button shows it.** A new button without a hint is an incomplete feature.
- **It has to work in a tiled pane.** Pages reflow and scroll; they never clip. Size anything from the pane, never from a child whose size depends on it — that freezes the UI at 100% CPU with no error.
- **Small and boring beats clever.** The lobby sits at ~50 MB, and state stays out of the broadcast when it can.
- **Fair play is not optional.** The engine, explorer and analysis stay blocked in your own live games, in the daemon as well as the UI.
- **Lichess's API terms apply.** No automated play, no engine assistance, and nothing that hammers the API.

## Pull requests

Keep them focused, and run the checks above. Commit messages are in English, in the imperative: "Fix the lobby freezing while signed out". Explain *why* in the body when the change isn't obvious. New behaviour deserves a test, and a UI change deserves a screenshot in the PR.
