# CLI and protocol

## CLI

The CLI talks to the same daemon as the windows, so anything you do here shows up in open windows immediately. Add `--json` to any command for machine-readable output.

```sh
gambito open [GAME]                    # window with the lobby, or a game
gambito local                          # new local two-player game
gambito list                           # games known to the daemon
gambito status

gambito seek 10 5                      # casual by default
gambito seek 15 10 --rated
gambito cancel
gambito ai 3                           # Lichess AI, level 1-8

gambito move GAME Nf3                  # SAN or UCI
gambito draw GAME
gambito resign GAME
gambito export GAME > game.pgn
gambito watch                          # continuous NDJSON

gambito challenges
gambito challenge Friend --minutes 3 --increment 2 --color random
gambito challenge Friend --days 3 --rated
gambito accept CHALLENGE_ID
gambito decline CHALLENGE_ID
gambito cancel-challenge CHALLENGE_ID

gambito chat GAME                      # read the chat
gambito chat GAME "Good game!"
gambito takeback GAME                  # request or accept
gambito takeback GAME --decline

gambito auth < token.txt               # save a personal token
gambito daemon                         # run the daemon in the foreground
```

`open` and `local` start the daemon when it isn't running. Correspondence and color options for seeks are available in the UI, not as CLI flags.

## Protocol

The daemon listens on `$XDG_RUNTIME_DIR/gambito/socket`. Each line is a UTF-8 JSON object.

- **On connect:** clients receive `{"type": "state", ...}` with every game, and a new snapshot on each change.
- **Commands:** carry a `cmd` and an optional `request_id`:

  ```json
  {"cmd": "move", "game": "ABCDef12", "notation": "e4", "request_id": "42"}
  ```

- **Replies:** `{"type": "reply", "request_id": "42", "ok": true, "data": ...}`, or `"ok": false` with an `error` string.
- **Notices:** operational events use `{"type": "notice", ...}`.

**Evaluation.** `eval` accepts `"depth": 30` (1–245). With `"stream": true`, the requesting connection receives `{"type": "eval", ...}` events with the same `request_id` before the final reply. Each carries the game ID (`for`), ply, score, depth, target depth and principal variation. `cancel_eval` stops that connection's search, and a new `eval` request replaces it. Clients should discard updates for superseded requests.

The daemon never executes shell commands from the protocol.

## Environment

| Variable | Effect |
|---|---|
| `GAMBITO_SOCKET` | Use another socket path (its directory must be mode 0700) |
| `GAMBITO_GAME` | Initial game id for the Qt host |
| `GAMBITO_STOCKFISH` | Engine executable (default `stockfish` on `PATH`) |
| `QT_QUICK_BACKEND` | `gambito open` defaults to `software`, which saves about 30 MB per window; set it to override |
| `GAMBITO_API_URL` | Loopback-only Lichess API for tests |

## Files

| Path | Contents |
|---|---|
| `$XDG_CONFIG_HOME/gambito/token` | Lichess token, mode 0600 |
| `$XDG_DATA_HOME/gambito/` | Local games, analysis boards, installed UI |
| `$XDG_RUNTIME_DIR/gambito/socket` | Daemon socket |
