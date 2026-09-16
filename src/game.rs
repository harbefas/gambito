use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use shakmaty::{
    CastlingMode, Chess, EnPassantMode, Position, fen::Fen, san::SanPlus, uci::UciMove,
};

#[derive(Clone, Serialize, Deserialize, Debug)]
pub struct Game {
    pub id: String,
    pub online: bool,
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
            white: "Brancas · local".into(),
            black: "Pretas · local".into(),
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
        }
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

    pub fn normalize_move(&self, input: &str) -> Result<String> {
        if self.status != "started" && self.status != "created" {
            bail!("Esta partida já terminou");
        }
        if self.pending {
            bail!("Aguardando confirmação do lance anterior");
        }
        let pos = self.position()?;
        if self.online {
            if !self.connected {
                bail!("Reconectando ao Lichess; aguarde a sincronização");
            }
            let turn = if pos.turn().is_white() {
                "white"
            } else {
                "black"
            };
            if self.color.as_deref() != Some(turn) {
                bail!("É a vez do adversário");
            }
        }
        let input = input.trim().replace('0', "O");
        let m = if let Ok(uci) = input.parse::<UciMove>() {
            uci.to_move(&pos).context("Lance ilegal")?
        } else {
            input
                .parse::<SanPlus>()
                .context("Use SAN (Nf3) ou UCI (g1f3)")?
                .san
                .to_move(&pos)
                .context("Lance ilegal ou ambíguo")?
        };
        Ok(m.to_uci(CastlingMode::Standard).to_string())
    }

    pub fn play_local(&mut self, input: &str) -> Result<()> {
        let uci = self.normalize_move(input)?;
        self.moves.push(uci);
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
