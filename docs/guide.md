# Guide

Every action below has a key; [keyboard.md](keyboard.md) lists them all, and `?` shows them in the app.

- [Windows and the daemon](#windows-and-the-daemon)
- [Lobby](#lobby)
- [Playing](#playing)
- [Challenges, chat and takebacks](#challenges-chat-and-takebacks)
- [Analysis](#analysis)
- [Openings](#openings)
- [Puzzles](#puzzles)
- [Lichess TV](#lichess-tv)
- [Profile](#profile)

## Windows and the daemon

The daemon owns games, clocks, Lichess streams and the engine. Windows are views: `w` opens another window on the current game, and windows of the same game share moves while keeping their own selection, orientation and focus. `q` closes a window; the daemon and your games keep running.

A single Quickshell process hosts every window. Views (lobby, board, profile, TV, openings, puzzles) load only while shown, which keeps the lobby at about 50 MB and a board at about 70 MB.

## Lobby

The lobby adapts to its pane: full width shows TV, the puzzle of the day and a side column; narrower panes put the lists below the boards or stack everything in one scrolling column.

- **Tiles:** new local game (`n`), find opponent (`s`), play computer (`c`), open a game by ID (`:open ID`).
- **Lichess TV:** the featured game with titles, ratings and running clocks. Click it to watch on Gambito's board, or open the TV page with `t`.
- **Puzzle of the day:** solve it in place: click a piece, then its target. `v` shows the move, `y` retries, `u` opens it on the full board.
- **In progress and news:** `j`/`k` move through your games and then the Lichess blog; Enter opens the game or the post.

None of these need an account; playing online does.

## Playing

**Moves.** Move the cursor with `hjkl` or the arrows and select with Enter or Space, or press `i` and type SAN or UCI (`Nf3`, `O-O`, `e2e4`, `e7e8q`). Promotions open a piece picker. `[` `]` step through the moves and Home/End jump to the start or the live position; the mouse wheel and move list also rewind. Moves can't be played while viewing an earlier position.

**Online.** `s` opens the opponent screen: Rapid, Classical and correspondence, casual or rated, with your color. Bullet and Blitz are hidden there, because Lichess does not pair third-party apps in those seek pools. `c` challenges the Lichess AI at levels 1–8 with any time control. Online moves wait for the server's confirmation. `D` offers or accepts a draw and `R` resigns; both ask for Enter.

**Local.** `n` starts a two-player game on one board, without clocks. Local games are saved and can be exported as PGN.

**Notifications.** Game starts, opponent moves, draw offers and results show as desktop notifications via `notify-send`.

**Zen mode.** On a board, `z` hides the side panel and command bar, for small tiled panes. Keys keep working, and `i` or `:` brings the command bar back while you type.

## Challenges, chat and takebacks

`C` opens challenges from anywhere: send one to a player (Blitz, Rapid, Classical or correspondence; casual or rated; color) and accept, decline or cancel pending invitations. On that screen, `u` focuses the username, `t` cycles the time control, `c` the color, `v` toggles rated and `s` sends. `j`/`k` select an invitation, `a` accepts, `x` declines or cancels and `r` refreshes. Real-time invitations expire after 20 seconds.

In your own online game, `c` switches the side panel between the move list and chat with your opponent. Enter sends, Esc returns focus to the board, and a failed send keeps your draft. The panel keeps the last 100 messages, shown as plain text.

`T` requests a takeback or accepts your opponent's; `Y` declines. The board changes only when Lichess confirms.

## Analysis

**Stockfish.** `e` toggles the evaluation bar, score, principal variation and a best-move arrow. Scores are from White's side. The search streams updates up to the target depth (1–245, default 30), with no time limit: `-` and `+` change the depth, `d` types it. Changing position or turning the engine off cancels the search. Without a local engine, Gambito uses the Lichess cloud evaluation cache, which has a fixed depth.

**Lichess computer analysis.** Finished Lichess games show the analysis Lichess already has: per-move evaluations, `?!` inaccuracies, `?` mistakes and `??` blunders with comments and the better line, arrows for the played and best moves, and each side's accuracy. Gambito doesn't request analysis (the API has no endpoint for it): request it on lichess.org (`L`), then press `r` to load it.

**Analysis boards.** `a` creates a saved analysis board from the position on screen, whether that's the live position or a rewound move in a local or finished game. To branch, rewind an analysis board and press `a` again; variations are listed under the source board. Backspace returns to the source and `x` deletes a board and its branches (with confirmation). `:fen FEN` or the *FEN* button starts from any position. PGN export contains the selected line.

**Book.** `m` shows the opening explorer for the position on the board. Clicking a move plays it; on a finished game it branches an analysis board first.

**Fair play.** The daemon blocks the engine, explorer and analysis boards in your own live online games, including while rewinding. Other players' live games (TV, for example) can be analysed.

## Openings

`o` opens the opening explorer (requires a Lichess account). It shows the current position with its name, ECO code, game count and results, then popular continuations as boards. Arrows or `hjkl` pick a card, Enter plays it, Backspace goes back one move (or to the lobby from the starting position), Home returns to the start and `a` opens the line as an analysis board.

`m` switches between the Masters and Lichess databases; with Lichess, `s` and `r` cycle the speed and rating filters. `2` lists example games: Masters games open as analysis boards, Lichess games open for watching.

## Study

`d` opens the local study library. It keeps notebooks and chapters in `studies.json`, so your notes work offline and remain yours. Press `e` to add a small starter set, then select a chapter with `j`/`k` and Enter. A chapter stores a move tree, comments, board marks, a training side and review cards. Add a move with `m`, or open a position as a normal analysis board with `a`.

Press `S` on a finished game to save it as a chapter. If Lichess analysis is loaded, positions marked as mistakes get their better line and become review candidates. The chapter export uses PGN, including comments, variations, NAGs and standard board annotations, so it can move between Gambito and other chess tools.

Cards use a small spaced-review queue. `s` starts a 20-minute session; `r` opens a card, Enter submits a move, and `1`/`3` grade it Again or Good. A different move is reported as different from the stored line, which lets you explore alternatives without labeling them as blunders.

## Puzzles

`z` opens the puzzle themes in Lichess's categories (Recommended, Phases, Motifs, Advanced, Mates, Mate themes, Special moves, Goals, Lengths, Origin, and By opening). `[` `]` switch category, arrows or `hjkl` pick a theme, `d` cycles the difficulty and Enter opens the next puzzle on the board.

On the board, the opponent's replies play automatically and wrong moves are refused. `v` shows a hint, `u` the solution and `y` restarts. Rating, themes and the engine stay hidden until the puzzle is solved. `n` continues with the next puzzle of the theme.

When you're signed in, puzzles come from your account and each result is sent to Lichess once, so it counts toward your puzzle rating. A puzzle solved with no mistakes counts as a win; a wrong move or showing the solution counts as a loss.

## Lichess TV

`t` opens every TV channel: Top rated, Bullet, Blitz, Rapid, Classical, UltraBullet, Bot and Computer. You get a large live board, the players' head-to-head score and the move list. `j`/`k` switch channels, Enter opens the game on Gambito's own board (as a spectator; the engine and analysis boards work), and `L` opens it on lichess.org. The stream replays the game from the start and continues live to the result.

### Tournament broadcasts

In TV, press `b` or click **Tournaments** to browse live and recent events. Use `j`/`k` and Enter to open a tournament, round, then game; Backspace goes up one level. Backspace from the tournament list returns to TV channels. Broadcasts remain separate from your games.

A live round stream updates boards, move histories, clocks and results as Lichess receives them. The round shows counts of games in progress, finished, and awaiting their first move. Filter with `1` (all), `2` (in progress), `3` (finished), or `4` (not started). The selected board stays open even if its result removes it from the current filter.

The connection indicator and last-update age distinguish a quiet board from a disconnected feed. Clocks show the source's last reported reading; missing clocks appear as a dash. The event may impose a broadcast delay. `r` refreshes and reconnects a failed stream; `L` opens the current event or game on Lichess. Disconnections preserve the boards and retry after a minute. Leaving the round closes its stream.

Press `a` or click **Open analysis copy** to create a local analysis board with the game's main line. This is a snapshot; it does not continue following the broadcast. Standard chess and standard positions are supported.

Tournament details use Lichess's `study:read` permission. If Lichess reports a missing permission, sign out and connect again to grant it. The tournament directory itself is public.

## Profile

`p` opens your profile: member since, play time and results, ratings per speed with a history chart and stats (peak, lowest, best win, worst loss, streaks).

- **Games (`1`):** full Lichess history, loaded as you scroll, with your accuracy when analysis exists. `s`, `r` and `o` cycle the speed, rated and result filters.
- **Boards (`2`):** analysis boards, puzzles and finished local games; `x` deletes one.
- **Activity (`3`):** recent Lichess activity.
- **Puzzles (`4`):** puzzle rating, the dashboard for the last 30 days (widening to 90 or 365 when empty), recent results and your weakest themes first. Enter practises one.

`C` or *Challenges* opens invitations, and `l` signs out after you confirm with Enter. Profile data is cached by the daemon for five minutes.
