//! Round feeds are owned by a client connection, never saved as playable games.
use crate::{
    lichess::Api,
    server::{broadcast_game, pgn_sans},
};
use anyhow::{Context, Result, bail};
use futures_util::StreamExt;
use serde_json::{Value, json};
use std::time::Duration;

fn tag<'a>(pgn: &'a str, name: &str) -> Option<&'a str> {
    let prefix = format!("[{name} \"");
    pgn.lines()
        .find_map(|l| l.trim().strip_prefix(&prefix)?.strip_suffix("\"]"))
}

fn update(pgn: &str, round: &str) -> Result<Value> {
    let url = tag(pgn, "GameURL")
        .or_else(|| tag(pgn, "Site"))
        .context("Missing broadcast game URL")?;
    let url: reqwest::Url = url.parse()?;
    let parts: Vec<_> = url.path_segments().context("Missing game path")?.collect();
    let chapter = *parts.last().context("Missing chapter")?;
    if parts.len() < 2
        || parts[parts.len() - 2] != round
        || chapter.len() != 8
        || !chapter.bytes().all(|b| b.is_ascii_alphanumeric())
    {
        bail!("Broadcast game does not belong to this round");
    }
    let game = broadcast_game(pgn)?;
    let snapshot = game.snapshot()?;
    let result = tag(pgn, "Result").unwrap_or("*");
    let status = if matches!(result, "1-0" | "0-1" | "1/2-1/2") {
        "finished"
    } else if game.moves.is_empty() {
        "waiting"
    } else {
        "playing"
    };
    // Keep the source's last reported clocks; do not invent elapsed time for delayed OTB feeds.
    let mut clocks: [Option<u64>; 2] = [None, None];
    let mut variation = 0usize;
    let mut comment = None;
    let mut mainline = String::new();
    for (i, c) in pgn.char_indices() {
        if let Some(start) = comment {
            if c == '}' {
                if variation == 0 {
                    let text = &pgn[start..i];
                    if let Some(clock) = text
                        .split("[%clk ")
                        .nth(1)
                        .and_then(|v| v.split(']').next())
                    {
                        let fields: Vec<_> = clock.trim().split(':').collect();
                        if fields.len() == 3 {
                            let seconds = fields
                                .iter()
                                .try_fold(0.0, |n, f| f.parse::<f64>().ok().map(|v| n * 60.0 + v));
                            let ply = pgn_sans(&mainline).split_whitespace().count();
                            if ply > 0
                                && let Some(seconds) =
                                    seconds.filter(|v| v.is_finite() && *v >= 0.0)
                            {
                                let offset = usize::from(
                                    game.initial_fen.split_whitespace().nth(1) == Some("b"),
                                );
                                clocks[(ply - 1 + offset) % 2] = Some((seconds * 100.0) as u64);
                            }
                        }
                    }
                }
                comment = None;
                mainline.push(' ');
            }
        } else {
            match c {
                '{' => comment = Some(i + 1),
                '(' => variation += 1,
                ')' => variation = variation.saturating_sub(1),
                _ if variation == 0 => mainline.push(c),
                _ => {}
            }
        }
    }
    Ok(
        json!({"id": chapter, "name": format!("{} – {}", game.white, game.black),
        "fen": snapshot["fen"], "lastMove": game.moves.last(), "status": result, "state": status,
        "players": [
            {"name": game.white, "title": tag(pgn, "WhiteTitle"), "rating": game.white_rating, "clock": clocks[0]},
            {"name": game.black, "title": tag(pgn, "BlackTitle"), "rating": game.black_rating, "clock": clocks[1]}],
        "history": snapshot}),
    )
}

// Lichess separates games by a blank line after movetext. Buffer bytes until complete
// lines so a network chunk may split a UTF-8 character, a tag, or the delimiter.
#[derive(Default)]
struct Decoder {
    bytes: Vec<u8>,
    pgn: String,
    movetext: bool,
}
impl Decoder {
    fn push(&mut self, chunk: &[u8]) -> Result<Vec<String>> {
        self.bytes.extend_from_slice(chunk);
        if self.bytes.len() + self.pgn.len() > 2_000_000 {
            bail!("Broadcast PGN exceeds size limit");
        }
        let mut games = Vec::new();
        while let Some(end) = self.bytes.iter().position(|b| *b == b'\n') {
            let raw: Vec<_> = self.bytes.drain(..=end).collect();
            let line = std::str::from_utf8(&raw)?.trim();
            if line.is_empty() {
                if self.movetext {
                    games.push(std::mem::take(&mut self.pgn));
                    self.movetext = false;
                }
            } else {
                self.movetext |= !line.starts_with('[');
                self.pgn.push_str(line);
                self.pgn.push('\n');
            }
        }
        Ok(games)
    }
}

pub async fn feed(
    api: Api,
    events: tokio::sync::mpsc::Sender<Value>,
    round: String,
    subscription: Value,
) -> Result<()> {
    loop {
        let result: Result<()> = async {
            let response = tokio::time::timeout(Duration::from_secs(25), api.broadcast_stream(&round)).await??;
            events.send(json!({"type":"broadcast", "round":round, "subscription":subscription, "connected":true})).await?;
            let mut stream = response.bytes_stream();
            let mut decoder = Decoder::default();
            while let Some(chunk) = tokio::time::timeout(Duration::from_secs(90), stream.next()).await.context("Broadcast connection timed out")? {
                for pgn in decoder.push(&chunk?)? {
                    match update(&pgn, &round) {
                        Ok(game) => events.send(json!({"type":"broadcast", "round":round, "subscription":subscription, "game":game})).await?,
                        Err(e) => events.send(json!({"type":"broadcast", "round":round, "subscription":subscription, "warning":format!("Unable to read one game: {e:#}")})).await?,
                    }
                }
            }
            bail!("Broadcast disconnected; reconnecting")
        }.await;
        if events.is_closed() {
            return Ok(());
        }
        let error = format!("{:#}", result.unwrap_err());
        eprintln!("Broadcast {round}: {error}");
        let message = if error.contains("Lichess permission")
            || error.contains("Auth/permission")
            || error.contains("429")
        {
            error.as_str()
        } else {
            "Connection lost; reconnecting in one minute"
        };
        events.send(json!({"type":"broadcast", "round":round, "subscription":subscription, "connected":false, "error":message})).await?;
        tokio::time::sleep(Duration::from_secs(60)).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    const PGN: &str = "[White \"José\"]\n[Black \"Beta\"]\n[GameURL \"https://lichess.org/broadcast/t/r/round001/chapter1\"]\n[Result \"*\"]\n\n1. e4 {[%clk 1:30:00]} e5 {[%clk 1:29:59.5]} 2. Nf3 (2. Bc4 {[%clk 0:01:00]}) *\n\n";
    #[test]
    fn fragmented_round_and_clocks() {
        let mut decoder = Decoder::default();
        let mut games = vec![];
        for b in PGN.as_bytes() {
            games.extend(decoder.push(&[*b]).unwrap());
        }
        assert_eq!(games.len(), 1);
        let v = update(&games[0], "round001").unwrap();
        assert_eq!(v["players"][0]["name"], "José");
        assert_eq!(v["players"][0]["clock"], 540000);
        assert_eq!(v["players"][1]["clock"], 539950);
        assert_eq!(v["state"], "playing");
        assert_eq!(v["lastMove"], "g1f3");
        assert_eq!(v["history"]["san"].as_array().unwrap().len(), 3);
        assert!(update(PGN, "other001").is_err());
    }
    #[test]
    fn initial_games_results_and_waiting() {
        let mut decoder = Decoder::default();
        assert_eq!(
            decoder
                .push(format!("\n{PGN}{PGN}").replace('\n', "\r\n").as_bytes())
                .unwrap()
                .len(),
            2
        );
        let finished = PGN.replace("[Result \"*\"]", "[Result \"1-0\"]");
        assert_eq!(update(&finished, "round001").unwrap()["state"], "finished");
        let waiting = PGN.split("\n\n").next().unwrap().to_owned() + "\n\n*\n\n";
        assert_eq!(update(&waiting, "round001").unwrap()["state"], "waiting");
        assert!(update(&PGN.replace("1. e4", "1. e5"), "round001").is_err());
    }
}
