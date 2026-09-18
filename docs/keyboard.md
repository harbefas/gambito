# Keyboard

Every clickable control has a key, and buttons show it. In the app, `?` shows these tables. Keys are case-sensitive.

## Everywhere

| Key | Action |
|---|---|
| `i` | Type a move |
| `:` | Command line |
| `?` | Help |
| `Esc` | Cancel selection, input or confirmation; leave a page |
| `g` | Lobby |
| `n` | New local game |
| `w` | New window |
| `f` | Flip board |
| `C` | Challenges |
| `q` | Close this window |

## Lobby

| Key | Action |
|---|---|
| `s` / `c` | Find opponent / play computer |
| `l` | Sign in, or sign out (Enter confirms) |
| `t` / `o` / `z` / `p` | TV / openings / puzzles / profile |
| `j` `k`, Enter | Games in progress, then news |
| `x` | Delete the selected analysis board or puzzle |
| `v` / `y` / `u` | Puzzle of the day: show move / retry / open on the board |
| `b` / `Esc` | While signing in: open the browser again / cancel |

## Play screen

| Key | Action |
|---|---|
| `m` | Opponent or computer |
| `r` | Rated |
| `s` | Side |
| `1`–`8` | Computer level |
| Arrows or `hjkl`, Enter | Pick a time control or correspondence days, then play |
| `c` | Custom clock: `-` `+` minutes, `[` `]` increment |
| `Esc` | Close, or cancel the seek |

## Board

| Key | Action |
|---|---|
| `h` `j` `k` `l` / arrows | Move the cursor |
| Enter / Space | Select a square |
| `[` `]` | Previous / next move |
| `{` `}` | Start / live position |
| `e` | Engine on / off |
| `-` `+` / `d` | Decrease / increase depth / type a depth |
| `m` | Opening explorer on / off |
| `a` | Analysis board from here (branch) |
| `b` | Return to the source game |
| `x` | Delete analysis board |
| `r` | Load Lichess analysis |
| `v` `u` `y` | Puzzle hint / solution / retry |
| `n` | Next puzzle of this theme |
| `F` | FEN |
| `L` | Open on lichess.org |
| `D` `R` | Draw / resign |
| `c` | Chat with your opponent |
| `T` / `Y` | Request or accept / decline a takeback |
| `z` | Zen mode: board only |

## Pages

| Page | Keys |
|---|---|
| Challenges | `u` username, `t` time, `c` color, `v` rated, `s` send, `j` `k` select, `a` accept, `x` decline or cancel, `r` refresh |
| TV | `b` tournaments, `j` `k` channel, `o` or Enter open on board, `L` lichess.org, `z` zen |
| Tournaments (in TV) | `j` `k` select, Enter open, Backspace back, `r` refresh, `o` analysis copy, `L` lichess.org, `b` TV channels |
| Openings | Arrows or `hjkl` pick, Enter play, Backspace or `u` back, `b` start, `a` analyse, `m` database, `s` `r` filters, `1` `2` tabs |
| Puzzles | `[` `]` category, arrows or `hjkl` pick, Enter start, `d` difficulty |
| Profile | `1`–`4` tabs, `j` `k` select, Enter open, `s` `r` `o` filters, `x` delete board, `l` sign out |

## Commands

Type `:` and a command, then Enter.

| Command | Action |
|---|---|
| `:local` | New local game |
| `:open ID` | Open a Lichess game |
| `:play` | Online play options |
| `:seek 10 5 [rated]` | Seek an opponent |
| `:cancel` | Cancel the seek |
| `:ai 1-8` | Play the Lichess AI |
| `:challenges` | Send and answer invitations |
| `:challenge USER [MIN INC rated]` | Challenge a player |
| `:accept ID` / `:decline ID` / `:cancelchallenge ID` | Answer an invitation |
| `:chat [MESSAGE]` | Toggle chat or send a message |
| `:takeback [no]` | Request / accept / decline a takeback |
| `:draw` / `:resign` / `:confirm` | Offer or accept a draw / resign / confirm |
| `:analyse` | Branch from the position on screen |
| `:fen FEN` | Analyse a FEN position |
| `:source` | Return to the source game |
| `:lichess` | Load Lichess analysis |
| `:explorer` | Opening explorer on / off |
| `:depth N` | Analysis depth (1–245) |
| `:delete` | Delete analysis board |
| `:puzzle` | Puzzle of the day on the board |
| `:hint` / `:solution` / `:retry` | Puzzle help |
| `:next` | Next puzzle of this theme |
| `:games` / `:profile` / `:tv` / `:openings` / `:puzzles` | Go to a page |
| `:zen` | Board only |
| `:login` / `:logout` | Connect / sign out of Lichess |
| `:window` / `:quit` | New window / close |

## Move notation

| Input | Meaning |
|---|---|
| `e4` `Nf3` `O-O` | SAN (English piece letters) |
| `e2e4` | UCI |
| `e7e8q` | Promotion |
