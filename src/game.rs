use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use shakmaty::{
    CastlingMode, Chess, EnPassantMode, Position,
    fen::Fen,
    san::{San, SanPlus},
    uci::UciMove,
};

#[derive(Clone, Serialize, Deserialize, Debug)]
pub struct Game {
    pub id: String,
    pub online: bool,
    #[serde(default)]
    pub analysis: bool,
    #[serde(default)]
    pub analysis_source: Option<String>,
    #[serde(default)]
    pub analysis_ply: usize,
    pub white: String,
    pub black: String,
    pub color: Option<String>,
    pub initial_fen: String,
    pub moves: Vec<String>,
    pub status: String,
    pub winner: Option<String>,
    pub white_ms: Option<u64>,
    pub black_ms: Option<u64>,
    pub updated_ms: u64,
    pub connected: bool,
    pub pending: bool,
    pub draw_offer: Option<String>,
    #[serde(default)]
    pub takeback_offer: Option<String>,
    #[serde(default)]
    pub white_rating: Option<u64>,
    #[serde(default)]
    pub black_rating: Option<u64>,
    #[serde(default)]
    pub rated: bool,
    /// Lichess speed: bullet, blitz, rapid, classical, correspondence.
    #[serde(default)]
    pub speed: Option<String>,
    /// "10+5" or "3 days".
    #[serde(default)]
    pub time_control: Option<String>,
    /// Lichess server analysis (requested on lichess.org): `moves` has one entry per ply
    /// with eval and, for bad moves, best/variation/judgment; `white`/`black` summarise.
    #[serde(default)]
    pub lichess_analysis: Option<serde_json::Value>,
    /// Puzzle played on the board: {id, rating, plays, themes, solution (UCI), start, source}.
    /// `moves[..start]` is the game it came from; later moves must follow the solution, the
    /// opponent's replies are played automatically, and the status becomes "solved" at the end.
    #[serde(default)]
    pub puzzle: Option<serde_json::Value>,
}

pub fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

impl Game {
    pub fn local(id: String) -> Self {
        Self {
            id,
            online: false,
            analysis: false,
            analysis_source: None,
            analysis_ply: 0,
            white: "White".into(),
            black: "Black".into(),
            color: None,
            initial_fen: "startpos".into(),
            moves: vec![],
            status: "started".into(),
            winner: None,
            white_ms: None,
            black_ms: None,
            updated_ms: now_ms(),
            connected: true,
            pending: false,
            draw_offer: None,
            takeback_offer: None,
            white_rating: None,
            black_rating: None,
            rated: false,
            speed: None,
            time_control: None,
            lichess_analysis: None,
            puzzle: None,
        }
    }

    /// Lichess fair play: no engine or analysis help while you play. Spectated live games are
    /// fine; a game counts as yours by color or by player name (a game watched via TV has no color).
    pub fn engine_blocked(&self, username: Option<&str>) -> bool {
        self.online
            && matches!(self.status.as_str(), "started" | "created")
            && (self.color.is_some()
                || username.is_some_and(|u| {
                    self.white.eq_ignore_ascii_case(u) || self.black.eq_ignore_ascii_case(u)
                }))
    }

    pub fn analysis_branch(&self, id: String, ply: usize) -> Result<Self> {
        if self.engine_blocked(None) {
            bail!("Analysis is off during live Lichess games (fair play)");
        }
        if ply > self.moves.len() {
            bail!("Position is outside the game history");
        }
        let mut branch = Self::local(id);
        branch.analysis = true;
        branch.analysis_source = Some(self.id.clone());
        branch.analysis_ply = ply;
        branch.initial_fen = self.initial_fen.clone();
        branch.moves = self.moves[..ply].to_vec();
        branch.update_analysis_status()?;
        Ok(branch)
    }

    pub fn analysis_fen(id: String, fen: &str) -> Result<Self> {
        let mut branch = Self::local(id);
        branch.analysis = true;
        let pos: Chess = fen.parse::<Fen>()?.into_position(CastlingMode::Standard)?;
        branch.initial_fen = Fen::from_position(&pos, EnPassantMode::Legal).to_string();
        branch.update_analysis_status()?;
        Ok(branch)
    }

    fn update_analysis_status(&mut self) -> Result<()> {
        let pos = self.position()?;
        if pos.is_checkmate() {
            self.status = "mate".into();
            self.winner = Some(
                if pos.turn().is_white() {
                    "black"
                } else {
                    "white"
                }
                .into(),
            );
        } else if pos.is_stalemate() {
            self.status = "stalemate".into();
        }
        Ok(())
    }

    pub fn position(&self) -> Result<Chess> {
        let mut pos = self.initial_position()?;
        for uci in &self.moves {
            let m = uci.parse::<UciMove>()?.to_move(&pos)?;
            pos.play_unchecked(m);
        }
        Ok(pos)
    }

    fn initial_position(&self) -> Result<Chess> {
        if self.initial_fen == "startpos" {
            Ok(Chess::default())
        } else {
            Ok(self
                .initial_fen
                .parse::<Fen>()?
                .into_position(CastlingMode::Standard)?)
        }
    }

    /// Replays space-separated SAN (Lichess export format) and stores it as UCI.
    pub fn set_san_moves(&mut self, san: &str) -> Result<()> {
        let mut pos = self.initial_position()?;
        self.moves.clear();
        for token in san.split_whitespace() {
            let m = token
                .parse::<San>()
                .ok()
                .and_then(|s| s.to_move(&pos).ok())
                .with_context(|| format!("Invalid SAN in history: {token}"))?;
            self.moves
                .push(m.to_uci(CastlingMode::Standard).to_string());
            pos.play_unchecked(m);
        }
        Ok(())
    }

    /// FEN before the first move and after each move (index = plies played).
    pub fn fens(&self) -> Result<Vec<String>> {
        let mut pos = self.initial_position()?;
        let mut fens = vec![Fen::from_position(&pos, EnPassantMode::Legal).to_string()];
        for uci in &self.moves {
            let m = uci.parse::<UciMove>()?.to_move(&pos)?;
            pos.play_unchecked(m);
            fens.push(Fen::from_position(&pos, EnPassantMode::Legal).to_string());
        }
        Ok(fens)
    }

    pub fn normalize_move(&self, input: &str) -> Result<String> {
        if self.status != "started" && self.status != "created" {
            bail!("This game is over");
        }
        if self.pending {
            bail!("Waiting for the previous move to be confirmed");
        }
        let pos = self.position()?;
        if self.online {
            if !self.connected {
                bail!("Reconnecting to Lichess; wait for sync");
            }
            let turn = if pos.turn().is_white() {
                "white"
            } else {
                "black"
            };
            if self.color.as_deref() != Some(turn) {
                bail!("It is the opponent's turn");
            }
        }
        let input = input.trim().replace('0', "O");
        let m = if let Ok(uci) = input.parse::<UciMove>() {
            uci.to_move(&pos).context("Illegal move")?
        } else {
            input
                .parse::<SanPlus>()
                .context("Use SAN (Nf3) or UCI (g1f3)")?
                .san
                .to_move(&pos)
                .context("Illegal or ambiguous move")?
        };
        Ok(m.to_uci(CastlingMode::Standard).to_string())
    }

    fn puzzle_solution(&self) -> Vec<String> {
        self.puzzle
            .as_ref()
            .and_then(|p| p["solution"].as_array())
            .map(|moves| {
                moves
                    .iter()
                    .filter_map(|m| m.as_str().map(str::to_owned))
                    .collect()
            })
            .unwrap_or_default()
    }

    fn puzzle_start(&self) -> usize {
        self.puzzle
            .as_ref()
            .and_then(|p| p["start"].as_u64())
            .unwrap_or(0) as usize
    }

    /// Plays the next solution move (the solver's, then the opponent's reply); marks it solved at the end.
    fn puzzle_step(&mut self) -> Result<()> {
        let solution = self.puzzle_solution();
        let done = self.moves.len().saturating_sub(self.puzzle_start());
        if let Some(next) = solution.get(done) {
            let uci = self.normalize_move(next)?;
            self.moves.push(uci);
        }
        if self.moves.len() - self.puzzle_start() >= solution.len() {
            self.status = "solved".into();
        }
        Ok(())
    }

    pub fn puzzle_retry(&mut self) {
        let start = self.puzzle_start();
        self.moves.truncate(start);
        self.status = "started".into();
        self.updated_ms = now_ms();
    }

    /// (puzzle id, win) once solved and not yet reported to Lichess.
    pub fn puzzle_result(&self) -> Option<(String, bool)> {
        let puzzle = self.puzzle.as_ref()?;
        if self.status != "solved" || puzzle["submitted"] == true {
            return None;
        }
        Some((puzzle["id"].as_str()?.to_owned(), puzzle["failed"] != true))
    }

    pub fn puzzle_reveal(&mut self) -> Result<()> {
        if let Some(puzzle) = self.puzzle.as_mut() {
            puzzle["failed"] = true.into();
        }
        while self.status == "started"
            && self.moves.len() - self.puzzle_start() < self.puzzle_solution().len()
        {
            self.puzzle_step()?;
        }
        self.updated_ms = now_ms();
        Ok(())
    }

    pub fn play_local(&mut self, input: &str) -> Result<()> {
        let uci = self.normalize_move(input)?;
        if self.puzzle.is_some() {
            let solution = self.puzzle_solution();
            let expected = solution
                .get(self.moves.len() - self.puzzle_start())
                .context("Puzzle already solved")?;
            if self.normalize_move(expected)? != uci {
                // Lichess scores the first attempt: any mistake makes it a loss, even if solved later.
                if let Some(puzzle) = self.puzzle.as_mut() {
                    puzzle["failed"] = true.into();
                }
                bail!("Not the move. Try again");
            }
            self.puzzle_step()?;
            if self.status == "started" {
                self.puzzle_step()?;
            }
            self.updated_ms = now_ms();
            return Ok(());
        }
        self.moves.push(uci);
        if self.analysis {
            self.update_analysis_status()?;
            self.updated_ms = now_ms();
            return Ok(());
        }
        let pos = self.position()?;
        if pos.is_checkmate() {
            self.status = "mate".into();
            self.winner = Some(
                if pos.turn().is_white() {
                    "black"
                } else {
                    "white"
                }
                .into(),
            );
        } else if pos.is_stalemate()
            || pos.is_insufficient_material()
            || pos.halfmoves() >= 150
            || self.repetitions()? >= 5
        {
            self.status = "draw".into();
        }
        self.updated_ms = now_ms();
        Ok(())
    }

    fn repetitions(&self) -> Result<usize> {
        // Counters are not part of position identity; legal en passant rights are.
        let key = |p: &Chess| {
            Fen::from_position(p, EnPassantMode::Legal)
                .to_string()
                .split_whitespace()
                .take(4)
                .collect::<Vec<_>>()
                .join(" ")
        };
        let target = key(&self.position()?);
        let mut pos = self.initial_position()?;
        let mut count = usize::from(key(&pos) == target);
        for uci in &self.moves {
            let m = uci.parse::<UciMove>()?.to_move(&pos)?;
            pos.play_unchecked(m);
            count += usize::from(key(&pos) == target);
        }
        Ok(count)
    }

    pub fn snapshot(&self) -> Result<serde_json::Value> {
        let mut pos = self.initial_position()?;
        let mut sans = vec![];
        for uci in &self.moves {
            let m = uci.parse::<UciMove>()?.to_move(&pos)?;
            sans.push(SanPlus::from_move(pos.clone(), m).to_string());
            pos.play_unchecked(m);
        }
        let mut value = serde_json::to_value(self)?;
        value["fen"] = Fen::from_position(&pos, EnPassantMode::Legal)
            .to_string()
            .into();
        value["turn"] = (if pos.turn().is_white() {
            "white"
        } else {
            "black"
        })
        .into();
        value["san"] = serde_json::json!(sans);
        value["check"] = pos.is_check().into();
        value["legal"] = serde_json::json!(
            pos.legal_moves()
                .iter()
                .map(|m| m.to_uci(CastlingMode::Standard).to_string())
                .collect::<Vec<_>>()
        );
        Ok(value)
    }

    pub fn pgn(&self) -> Result<String> {
        let snap = self.snapshot()?;
        let result = match self.winner.as_deref() {
            Some("white") => "1-0",
            Some("black") => "0-1",
            _ if self.status == "draw" || self.status == "stalemate" => "1/2-1/2",
            _ => "*",
        };
        let escape = |s: &str| {
            s.replace('\\', "\\\\")
                .replace('"', "\\\"")
                .replace(['\n', '\r'], " ")
        };
        let mut out = format!(
            "[Event \"Gambito\"]\n[White \"{}\"]\n[Black \"{}\"]\n[Result \"{}\"]\n",
            escape(&self.white),
            escape(&self.black),
            result
        );
        if self.initial_fen != "startpos" {
            out += &format!("[SetUp \"1\"]\n[FEN \"{}\"]\n", escape(&self.initial_fen));
        }
        out.push('\n');
        let initial = self.initial_position()?;
        let mut number = initial.fullmoves().get();
        let mut white = initial.turn().is_white();
        for (i, san) in snap["san"].as_array().unwrap().iter().enumerate() {
            if white {
                out += &format!("{number}. ");
            } else if i == 0 {
                out += &format!("{number}... ");
            }
            out += san.as_str().unwrap();
            out.push(' ');
            if !white {
                number += 1;
            }
            white = !white;
        }
        out += result;
        out.push('\n');
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn analysis_branches_preserve_source_and_support_finished_games() {
        let mut source = Game::local("source".into());
        source.play_local("e4").unwrap();
        source.play_local("e5").unwrap();
        source.status = "resign".into();
        source.winner = Some("black".into());
        let mut branch = source.analysis_branch("branch".into(), 1).unwrap();
        branch.play_local("c5").unwrap();
        assert_eq!(source.moves, ["e2e4", "e7e5"]);
        assert_eq!(branch.moves, ["e2e4", "c7c5"]);
        assert!(branch.analysis && !branch.online);
        assert_eq!(branch.status, "started");
        assert!(branch.winner.is_none());
        source.online = true;
        source.status = "started".into();
        // Spectating a live game allows analysis; playing it (by color or by name) does not.
        assert!(source.analysis_branch("watched".into(), 0).is_ok());
        assert!(!source.engine_blocked(Some("someone")));
        assert!(source.engine_blocked(Some("white")));
        source.color = Some("white".into());
        assert!(source.analysis_branch("blocked".into(), 0).is_err());
        let mate = Game::analysis_fen("mate".into(), "7k/6Q1/5K2/8/8/8/8/8 b - - 0 1").unwrap();
        assert_eq!(mate.status, "mate");
        let mut promotion =
            Game::analysis_fen("promotion".into(), "7k/P7/8/8/8/8/8/7K w - - 0 1").unwrap();
        promotion.play_local("a8=Q+").unwrap();
        assert_eq!(promotion.moves, ["a7a8q"]);
    }

    #[test]
    fn puzzle_follows_solution_with_automatic_replies() {
        let mut game = Game::local("puzzle".into());
        game.initial_fen = "6k1/5ppp/8/8/8/8/5PPP/R5K1 w - - 0 1".into();
        game.puzzle = Some(serde_json::json!({"id": "p", "solution": ["a1a8"]}));
        assert!(
            game.play_local("Ra7")
                .unwrap_err()
                .to_string()
                .contains("Not the move")
        );
        assert!(game.moves.is_empty() && game.status == "started");
        game.play_local("Ra8#").unwrap();
        assert_eq!((game.moves.len(), game.status.as_str()), (1, "solved"));
        assert_eq!(game.puzzle_result(), Some(("p".into(), false))); // the wrong first try counts
        let mut clean = Game::local("clean".into());
        clean.initial_fen = game.initial_fen.clone();
        clean.puzzle = Some(serde_json::json!({"id": "c", "solution": ["a1a8"]}));
        clean.play_local("Ra8#").unwrap();
        assert_eq!(clean.puzzle_result(), Some(("c".into(), true)));
        clean.puzzle.as_mut().unwrap()["submitted"] = true.into();
        assert!(clean.puzzle_result().is_none());

        // Source game moves come first; the solution continues from `start`.
        let mut long = Game::local("long".into());
        long.moves = vec!["d2d4".into()];
        long.puzzle =
            Some(serde_json::json!({"id": "l", "start": 1, "solution": ["e7e5", "d4e5", "d7d6"]}));
        long.color = Some("black".into());
        long.play_local("e5").unwrap();
        assert_eq!(long.moves, ["d2d4", "e7e5", "d4e5"]); // opponent's reply played automatically
        assert!(long.puzzle_result().is_none()); // not solved yet
        long.puzzle_retry();
        assert_eq!(long.moves, ["d2d4"]);
        long.puzzle_reveal().unwrap();
        assert_eq!((long.moves.len(), long.status.as_str()), (4, "solved"));
        assert_eq!(long.puzzle_result(), Some(("l".into(), false))); // viewing the solution is a loss
        assert!(long.play_local("d4").is_err());
    }

    #[test]
    fn history_san_becomes_uci() {
        let mut g = Game::local("test".into());
        g.set_san_moves("e4 e5 Bc4 Nc6 Qh5 Nf6 Qxf7# ").unwrap();
        assert_eq!(g.moves.last().unwrap(), "h5f7");
        let fens = g.fens().unwrap();
        assert_eq!(fens.len(), 8);
        assert!(fens[1].starts_with("rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b"));
        assert!(g.set_san_moves("e4 e4").is_err());
    }
    #[test]
    fn automatic_fivefold_draw() {
        let mut g = Game::local("test".into());
        for _ in 0..4 {
            for m in ["Nf3", "Nf6", "Ng1", "Ng8"] {
                g.play_local(m).unwrap();
            }
        }
        assert_eq!(g.status, "draw");
    }
    #[test]
    fn rules_and_mate() {
        let mut g = Game::local("test".into());
        assert!(g.play_local("e5").is_err());
        for m in ["f3", "e7e5", "g4", "Qh4#"] {
            g.play_local(m).unwrap();
        }
        assert_eq!(g.status, "mate");
        assert_eq!(g.winner.as_deref(), Some("black"));
        assert!(g.play_local("a3").is_err());
        assert!(g.pgn().unwrap().contains("1. f3 e5 2. g4 Qh4# 0-1"));
    }
    #[test]
    fn special_moves() {
        let mut g = Game::local("test".into());
        for m in ["e4", "a6", "e5", "d5", "exd6"] {
            g.play_local(m).unwrap();
        }
        assert_eq!(
            g.position().unwrap().board().piece_at(shakmaty::Square::D5),
            None
        );
        let mut g = Game::local("test".into());
        for m in ["e4", "e5", "Nf3", "Nc6", "Bc4", "Nf6", "O-O"] {
            g.play_local(m).unwrap();
        }
        assert!(
            g.snapshot().unwrap()["fen"]
                .as_str()
                .unwrap()
                .contains("RNBQ1RK1")
        );
        g.initial_fen = "7k/P7/8/8/8/8/8/7K w - - 0 1".into();
        g.moves.clear();
        g.play_local("a7a8n").unwrap();
        assert_eq!(g.moves[0], "a7a8n");
    }
    #[test]
    fn online_turn_and_pending() {
        let mut g = Game::local("test".into());
        g.online = true;
        g.color = Some("black".into());
        assert!(g.normalize_move("e4").is_err());
        g.color = Some("white".into());
        assert_eq!(g.normalize_move("e4").unwrap(), "e2e4");
        g.pending = true;
        assert!(g.normalize_move("e4").is_err());
    }
}
