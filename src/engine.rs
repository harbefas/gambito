//! Position evaluation: local Stockfish over UCI when installed, else the Lichess cloud-eval cache.
//! Scores are always from White's point of view.
use crate::lichess::Api;
use anyhow::{Context, Result};
use serde_json::{Value, json};
use shakmaty::{CastlingMode, Chess, Position, fen::Fen, san::SanPlus, uci::UciMove};
use std::{
    collections::HashMap,
    process::Stdio,
    time::{Duration, Instant},
};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader, Lines},
    process::{Child, ChildStdin, ChildStdout},
    sync::Mutex,
};

struct Stockfish {
    _child: Child,
    stdin: ChildStdin,
    lines: Lines<BufReader<ChildStdout>>,
    name: String,
}

impl Stockfish {
    async fn spawn() -> Option<Result<Self>> {
        let program = std::env::var("GAMBITO_STOCKFISH").unwrap_or_else(|_| "stockfish".into());
        let mut child = tokio::process::Command::new(program)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .spawn()
            .ok()?;
        let stdin = child.stdin.take()?;
        let lines = BufReader::new(child.stdout.take()?).lines();
        let mut engine = Self {
            _child: child,
            stdin,
            lines,
            name: "Stockfish".into(),
        };
        Some(engine.handshake().await.map(|()| engine))
    }

    async fn handshake(&mut self) -> Result<()> {
        self.send("uci").await?;
        loop {
            let line = self.next().await?;
            if let Some(name) = line.strip_prefix("id name ") {
                self.name = name.to_owned();
            }
            if line == "uciok" {
                break;
            }
        }
        self.send("setoption name Threads value 2").await?;
        self.send("isready").await?;
        while self.next().await? != "readyok" {}
        Ok(())
    }

    async fn send(&mut self, command: &str) -> Result<()> {
        self.stdin
            .write_all(format!("{command}\n").as_bytes())
            .await?;
        self.stdin.flush().await?;
        Ok(())
    }

    async fn next(&mut self) -> Result<String> {
        tokio::time::timeout(Duration::from_secs(10), self.lines.next_line())
            .await
            .context("Stockfish timed out")??
            .context("Stockfish exited")
    }

    async fn search(
        &mut self,
        fen: &str,
        depth: u64,
        mut progress: impl FnMut(&str),
    ) -> Result<String> {
        self.send(&format!("position fen {fen}")).await?;
        self.send(&format!("go depth {depth}")).await?;
        let mut last = None;
        loop {
            // A deep iteration can be silent for arbitrarily long. Only the
            // initial handshake has a timeout; analysis ends at depth or cancel.
            let line = self.lines.next_line().await?.context("Stockfish exited")?;
            if line.starts_with("bestmove") {
                return last.context("Stockfish returned no evaluation");
            }
            if line.starts_with("info ") && line.contains(" score ") && line.contains(" pv ") {
                progress(&line);
                last = Some(line);
            }
        }
    }
}

const LOCAL_RETRY_INTERVAL: Duration = Duration::from_secs(5);

#[derive(Default)]
pub struct Engine {
    local: Mutex<Option<Stockfish>>,
    missing_local: Mutex<Option<Instant>>,
    cache: Mutex<HashMap<(String, u64), (Instant, Value)>>,
}

impl Engine {
    pub async fn eval(
        &self,
        fen: &str,
        api: Option<Api>,
        depth: u64,
        mut progress: impl FnMut(Value),
    ) -> Result<Value> {
        let cache_key = (fen.to_owned(), depth);
        if let Some((stored, cached)) = self.cache.lock().await.get(&cache_key) {
            // Cloud results must expire so installing Stockfish also upgrades a
            // position that was already evaluated by the cloud fallback.
            if cached["source"] != "Lichess cloud" || stored.elapsed() < LOCAL_RETRY_INTERVAL {
                return Ok(cached.clone());
            }
        }
        let pos: Chess = fen.parse::<Fen>()?.into_position(CastlingMode::Standard)?;
        let result = if pos.legal_moves().is_empty() {
            let mate = pos.is_check();
            json!({"cp": if mate { Value::Null } else { json!(0) }, "mate": if mate { json!(0) } else { Value::Null },
                   "depth": 0, "pv": [], "source": "final position"})
        } else if let Some(local) = self.local(fen, &pos, depth, &mut progress).await {
            local?
        } else {
            // Keep a usable cloud result if local detection still fails, without
            // another network request. Its age keeps future detection enabled.
            if let Some((_, cached)) = self.cache.lock().await.get(&cache_key) {
                return Ok(cached.clone());
            }
            let api = match api {
                Some(api) => api,
                None => Api::new(String::new())?,
            };
            let cloud = api.cloud_eval(fen).await?.context(
                "No cloud evaluation for this position. Install Stockfish to analyse any position.",
            )?;
            let pv = &cloud["pvs"][0];
            let moves = pv["moves"].as_str().unwrap_or("");
            json!({"cp": pv["cp"], "mate": pv["mate"], "depth": cloud["depth"],
                   "pv": san_line(&pos, moves.split_whitespace()),
                   "best": best_move(&pos, moves.split_whitespace().next()),
                   "source": "Lichess cloud"})
        };
        self.cache
            .lock()
            .await
            .insert(cache_key, (Instant::now(), result.clone()));
        Ok(result)
    }

    /// None when no local engine is available.
    async fn local(
        &self,
        fen: &str,
        pos: &Chess,
        depth: u64,
        mut progress: impl FnMut(Value),
    ) -> Option<Result<Value>> {
        let mut guard = self.local.lock().await;
        if guard.is_none() {
            if self
                .missing_local
                .lock()
                .await
                .is_some_and(|last| last.elapsed() < LOCAL_RETRY_INTERVAL)
            {
                return None;
            }
            match Stockfish::spawn().await {
                None => {
                    *self.missing_local.lock().await = Some(Instant::now());
                    return None;
                }
                Some(Err(e)) => return Some(Err(e)),
                Some(Ok(engine)) => {
                    *self.missing_local.lock().await = None;
                    *guard = Some(engine);
                }
            }
        }
        // Own the process during a search: cancellation (for example a client
        // disconnect during a progress write) drops it instead of reusing a
        // process with unread output from the previous position.
        let mut engine = guard.take()?;
        let name = engine.name.clone();
        let result = engine
            .search(fen, depth, |line| {
                let mut value = parse_info(line, pos, &name);
                value["target_depth"] = depth.into();
                progress(value);
            })
            .await;
        if result.is_ok() {
            *guard = Some(engine);
        }
        Some(result.map(|line| {
            let mut value = parse_info(&line, pos, &name);
            value["target_depth"] = depth.into();
            value
        }))
    }
}

/// Legal first move of a principal variation, in UCI (for board arrows).
fn best_move(pos: &Chess, uci: Option<&str>) -> Option<String> {
    let m = uci?.parse::<UciMove>().ok()?.to_move(pos).ok()?;
    Some(m.to_uci(CastlingMode::Standard).to_string())
}

/// Parses a UCI `info` line; the engine scores from the side to move.
fn parse_info(line: &str, pos: &Chess, source: &str) -> Value {
    let tokens: Vec<&str> = line.split_whitespace().collect();
    let after = |key: &str| tokens.iter().position(|t| *t == key).map(|i| i + 1);
    let sign = if pos.turn().is_white() { 1 } else { -1 };
    let number = |i: Option<usize>| i.and_then(|i| tokens.get(i)?.parse::<i64>().ok());
    let score = after("score");
    let kind = score.and_then(|i| tokens.get(i).copied());
    let value = number(score.map(|i| i + 1)).map(|v| v * sign);
    let pv = after("pv").map(|i| &tokens[i..]).unwrap_or(&[]);
    json!({
        "cp": if kind == Some("cp") { json!(value) } else { Value::Null },
        "mate": if kind == Some("mate") { json!(value) } else { Value::Null },
        "depth": number(after("depth")),
        "pv": san_line(pos, pv.iter().copied()),
        "best": best_move(pos, pv.first().copied()),
        "source": source,
    })
}

fn san_line<'a>(pos: &Chess, moves: impl Iterator<Item = &'a str>) -> Vec<String> {
    let mut pos = pos.clone();
    let mut line = vec![];
    for uci in moves.take(10) {
        let Some(m) = uci
            .parse::<UciMove>()
            .ok()
            .and_then(|u| u.to_move(&pos).ok())
        else {
            break;
        };
        line.push(SanPlus::from_move(pos.clone(), m).to_string());
        pos.play_unchecked(m);
    }
    line
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn scores_from_white_point_of_view() {
        let pos: Chess = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1"
            .parse::<Fen>()
            .unwrap()
            .into_position(CastlingMode::Standard)
            .unwrap();
        let v = parse_info(
            "info depth 20 score cp 35 nodes 9 pv e7e5 g1f3 zz",
            &pos,
            "SF",
        );
        assert_eq!(v["cp"], -35);
        assert_eq!(v["depth"], 20);
        assert_eq!(v["pv"], json!(["e5", "Nf3"]));
        assert_eq!(v["best"], "e7e5");
        let m = parse_info("info depth 5 score mate 3 pv e7e5", &pos, "SF");
        assert_eq!(
            (m["mate"].clone(), m["cp"].clone()),
            (json!(-3), Value::Null)
        );
    }
}
