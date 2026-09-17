use crate::{
    game::{Game, now_ms},
    lichess::{Api, records},
};
use anyhow::{Context, Result, anyhow, bail};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use futures_util::StreamExt;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use shakmaty::Position;
use std::{collections::BTreeMap, sync::Arc, time::Duration};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, UnixListener, UnixStream},
    sync::{Mutex, RwLock, broadcast},
    task::JoinHandle,
};
use tokio_util::codec::{FramedRead, LinesCodec};

struct AbortTask(JoinHandle<Result<()>>);
impl Drop for AbortTask {
    fn drop(&mut self) {
        self.0.abort();
    }
}

struct State {
    games: BTreeMap<String, Game>,
    account: Option<Value>,
    connection: String,
    seeking: bool,
    logging_in: bool,
    challenges: BTreeMap<String, Value>,
}
pub struct App {
    state: Mutex<State>,
    api: RwLock<Option<Api>>,
    tx: broadcast::Sender<Value>,
    streams: Mutex<BTreeMap<String, JoinHandle<()>>>,
    account_task: Mutex<Option<JoinHandle<()>>>,
    seek_task: Mutex<Option<JoinHandle<()>>>,
    login_task: Mutex<Option<JoinHandle<()>>>,
    reload_lock: Mutex<()>,
    engine: crate::engine::Engine,
    /// Windows watching each spectated game: the stream stops when the last one leaves.
    watchers: Mutex<BTreeMap<String, usize>>,
    /// Finished games from profile history pages, moved into the shared state only when opened.
    history: Mutex<BTreeMap<String, Game>>,
    /// Lichess API responses by path (profile, puzzle, blog), each with its own lifetime.
    profile_cache: Mutex<BTreeMap<String, (std::time::Instant, Value)>>,
}

const PROFILE_TTL: Duration = Duration::from_secs(300);
const PUZZLE_TTL: Duration = Duration::from_secs(3600);
const BLOG_TTL: Duration = Duration::from_secs(1800);
const TV_CHANNELS_TTL: Duration = Duration::from_secs(15);
const CROSSTABLE_TTL: Duration = Duration::from_secs(60);
const EXPLORER_TTL: Duration = Duration::from_secs(600);

/// Lichess identifiers placed in URL paths (TV channels, usernames).
fn validate_name(name: &str) -> Result<&str> {
    if name.is_empty()
        || name.len() > 30
        || !name
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || c == b'_' || c == b'-')
    {
        bail!("Invalid name: {name}");
    }
    Ok(name)
}
const PERFS: [&str; 7] = [
    "ultraBullet",
    "bullet",
    "blitz",
    "rapid",
    "classical",
    "correspondence",
    "puzzle",
];
impl App {
    fn snapshot(s: &State) -> Value {
        json!({"type":"state", "games": s.games.values().filter_map(|g| g.snapshot().ok()).collect::<Vec<_>>(),
            "account":s.account, "connection":s.connection, "seeking":s.seeking, "logging_in":s.logging_in, "challenges":s.challenges.values().collect::<Vec<_>>()})
    }
    fn publish(&self, s: &State) {
        let _ = self.tx.send(Self::snapshot(s));
    }
    fn notice(&self, text: String) {
        let _ = self.tx.send(json!({"type":"notice","message":text}));
    }
    async fn api(&self) -> Result<Api> {
        self.api
            .read()
            .await
            .clone()
            .context("Set up the account with gambito auth")
    }
    fn save(s: &State) -> Result<()> {
        crate::private_dir(&crate::data_dir())?;
        let path = crate::data_dir().join("local.json");
        let tmp = path.with_extension("tmp");
        let games: Vec<_> = s.games.values().filter(|g| !g.online).collect();
        std::fs::write(&tmp, serde_json::to_vec(&games)?)?;
        std::fs::rename(tmp, path)?;
        Ok(())
    }

    async fn reload(self: &Arc<Self>) -> Result<()> {
        let _reload_guard = self.reload_lock.lock().await;
        let token = std::fs::read_to_string(crate::config_dir().join("token"))
            .context("No token configured; run gambito auth")?;
        let api = Api::new(token.trim().into())?;
        let account = api.get("/api/account").await?;
        self.stop_online().await;
        *self.api.write().await = Some(api.clone());
        {
            let mut s = self.state.lock().await;
            s.games.retain(|_, g| !g.online);
            s.challenges.clear();
            s.account = Some(account);
            s.seeking = false;
            s.connection = "connecting".into();
            self.publish(&s);
        }
        self.history.lock().await.clear();
        self.profile_cache.lock().await.clear();
        let app = self.clone();
        *self.account_task.lock().await = Some(tokio::spawn(async move {
            app.account_loop(api).await;
        }));
        Ok(())
    }

    fn username(s: &State) -> Result<String> {
        Ok(s.account
            .as_ref()
            .and_then(|a| a["username"].as_str())
            .context("Connect Lichess to see your profile")?
            .to_owned())
    }

    /// Account API when signed in, anonymous otherwise (public endpoints).
    async fn any_api(&self) -> Result<Api> {
        match self.api.read().await.clone() {
            Some(api) => Ok(api),
            None => Api::new(String::new()),
        }
    }

    async fn cached_get(&self, path: &str) -> Result<Value> {
        self.cached(path, PROFILE_TTL, async {
            self.any_api().await?.get(path).await
        })
        .await
    }

    async fn cached(
        &self,
        key: &str,
        ttl: Duration,
        fetch: impl Future<Output = Result<Value>>,
    ) -> Result<Value> {
        if let Some((at, value)) = self.profile_cache.lock().await.get(key)
            && at.elapsed() < ttl
        {
            return Ok(value.clone());
        }
        let value = fetch.await?;
        self.profile_cache
            .lock()
            .await
            .insert(key.to_owned(), (std::time::Instant::now(), value.clone()));
        Ok(value)
    }

    /// Daily puzzle with every position precomputed, so the UI only compares moves.
    async fn puzzle(&self) -> Result<Value> {
        self.cached("puzzle", PUZZLE_TTL, async {
            prepare_puzzle(&self.any_api().await?.get("/api/puzzle/daily").await?)
        })
        .await
    }

    /// Reports a solved puzzle to Lichess (puzzle:write) so it counts toward the puzzle rating, once.
    /// Without an account, or with a token lacking the scope, the result simply stays local.
    fn submit_puzzle(self: &Arc<Self>, id: &str, (puzzle_id, win): (String, bool)) {
        let app = self.clone();
        let id = id.to_owned();
        tokio::spawn(async move {
            let Some(api) = app.api.read().await.clone() else {
                return;
            };
            let angle = {
                let s = app.state.lock().await;
                s.games
                    .get(&id)
                    .and_then(|g| g.puzzle.as_ref())
                    .and_then(|p| p["angle"].as_str())
                    .unwrap_or("mix")
                    .to_owned()
            };
            let body = json!({"solutions": [{"id": puzzle_id, "win": win, "rated": true}]});
            match api
                .post_json(&format!("/api/puzzle/batch/{angle}"), &body)
                .await
            {
                Ok(reply) => {
                    let mut s = app.state.lock().await;
                    if let Some(puzzle) = s.games.get_mut(&id).and_then(|g| g.puzzle.as_mut()) {
                        puzzle["submitted"] = true.into();
                        puzzle["win"] = win.into();
                        let round = reply["rounds"]
                            .as_array()
                            .and_then(|r| r.iter().find(|r| r["id"] == puzzle_id.as_str()));
                        puzzle["rating_diff"] =
                            round.map_or(Value::Null, |r| r["ratingDiff"].clone());
                    }
                    let _ = Self::save(&s);
                    app.publish(&s);
                }
                Err(e) => app.notice(format!("Puzzle result not sent: {e:#}")),
            }
        });
    }

    /// Adds a Lichess puzzle as a board game: the source game's moves, then the solution to find.
    /// `angle` (a theme or opening key) marks a themed puzzle, so the panel can offer the next one.
    async fn open_puzzle(&self, puzzle: &Value, angle: Option<&str>) -> Result<String> {
        let new_id = format!(
            "puzzle-{}",
            validate_name(puzzle["id"].as_str().context("Puzzle has no id")?)?
        );
        let mut s = self.state.lock().await;
        if !s.games.contains_key(&new_id) {
            if angle.is_some() {
                // Solved themed puzzles are replaced by the next one instead of piling up.
                s.games.retain(|_, g| {
                    !(g.status == "solved"
                        && g.puzzle.as_ref().is_some_and(|p| !p["angle"].is_null()))
                });
            }
            let position = puzzle["fens"][0]
                .as_str()
                .context("Puzzle has no position")?;
            let solver = if position.split_whitespace().nth(1) == Some("b") {
                "black"
            } else {
                "white"
            };
            let mut game = Game::local(new_id.clone());
            game.moves = serde_json::from_value(puzzle["history"].clone())?;
            game.color = Some(solver.into());
            let name = |side: &str| {
                puzzle["source"]["players"]
                    .as_array()
                    .and_then(|players| players.iter().find(|p| p["color"] == side))
                    .map(|p| {
                        (
                            p["name"].as_str().unwrap_or("?").to_owned(),
                            p["rating"].as_u64(),
                        )
                    })
            };
            for side in ["white", "black"] {
                let (player, rating) = name(side).unwrap_or(("?".into(), None));
                if side == "white" {
                    (game.white, game.white_rating) = (player, rating);
                } else {
                    (game.black, game.black_rating) = (player, rating);
                }
            }
            game.puzzle = Some(
                json!({"id": puzzle["id"], "rating": puzzle["rating"], "plays": puzzle["plays"], "themes": puzzle["themes"],
                                     "solution": puzzle["solution"], "start": game.moves.len(), "source": puzzle["source"], "angle": angle}),
            );
            s.games.insert(new_id.clone(), game);
            Self::save(&s)?;
            self.publish(&s);
        }
        Ok(new_id)
    }
}

/// Positions and metadata for a Lichess puzzle reply (daily or next), so clients only compare moves.
fn prepare_puzzle(daily: &Value) -> Result<Value> {
    let mut game = Game::local("puzzle".into());
    game.set_san_moves(
        daily["game"]["pgn"]
            .as_str()
            .context("Puzzle has no game")?,
    )?;
    let start = game.moves.len();
    let solution: Vec<String> = daily["puzzle"]["solution"]
        .as_array()
        .context("Puzzle has no solution")?
        .iter()
        .filter_map(|m| m.as_str().map(str::to_owned))
        .collect();
    for uci in &solution {
        let normalized = game.normalize_move(uci)?;
        game.moves.push(normalized);
    }
    let fens = game.fens()?;
    let snapshot = game.snapshot()?;
    Ok(json!({
        "id": daily["puzzle"]["id"], "rating": daily["puzzle"]["rating"], "plays": daily["puzzle"]["plays"],
        "themes": daily["puzzle"]["themes"], "solution": solution,
        "fens": fens[start..], "history": game.moves[..start], "last_move": start.checked_sub(1).map(|i| game.moves[i].clone()),
        "sans": snapshot["san"].as_array().map(|s| s[start..].to_vec()),
        "source": {"id": daily["game"]["id"], "clock": daily["game"]["clock"], "perf": daily["game"]["perf"]["name"], "rated": daily["game"]["rated"], "players": daily["game"]["players"]},
    }))
}

impl App {
    async fn blog(&self) -> Result<Value> {
        self.cached("blog", BLOG_TTL, async {
            let api = self.any_api().await?;
            let (official, community) = tokio::try_join!(api.get_text("/@/Lichess/blog.atom"), api.get_text("/blog/community.atom"))?;
            Ok(json!({"official": atom_entries(&official, 3), "community": atom_entries(&community, 8)}))
        })
        .await
    }

    /// One page of finished games, newest first. Games are kept aside and only enter the
    /// shared state (broadcast to every window) when opened.
    async fn history_page(&self, req: &Value) -> Result<Value> {
        let username = Self::username(&*self.state.lock().await)?;
        let max = req["max"].as_u64().unwrap_or(30).clamp(1, 100);
        let mut path = format!(
            "/api/games/user/{username}?max={max}&ongoing=false&finished=true&moves=true&tags=false&clocks=false&evals=true&accuracy=true&opening=false"
        );
        if let Some(until) = req["until"].as_u64() {
            path += &format!("&until={until}");
        }
        if let Some(perf) = req["perf"].as_str() {
            if !PERFS.contains(&perf) {
                bail!("Unknown speed: {perf}");
            }
            path += &format!("&perfType={perf}");
        }
        if let Some(rated) = req["rated"].as_bool() {
            path += &format!("&rated={rated}");
        }
        let response = self.api().await?.stream(&path).await?;
        let (tx, mut rx) = tokio::sync::mpsc::channel(64);
        let pump = AbortTask(tokio::spawn(records(response, tx)));
        let (mut rows, mut count, mut oldest) = (vec![], 0, None::<u64>);
        let mut history = self.history.lock().await;
        while let Some(record) = rx.recv().await {
            count += 1;
            if let Some(created) = record["createdAt"].as_u64() {
                oldest = Some(oldest.map_or(created, |o| o.min(created)));
            }
            if let Some(game) = history_game(&record, &username) {
                let accuracy = |side: &str| record["players"][side]["analysis"]["accuracy"].clone();
                rows.push(json!({
                    "id": game.id, "white": game.white, "black": game.black,
                    "white_rating": game.white_rating, "black_rating": game.black_rating,
                    "rated": game.rated, "speed": game.speed, "time_control": game.time_control,
                    "status": game.status, "winner": game.winner, "color": game.color,
                    "updated_ms": game.updated_ms, "plies": game.moves.len(),
                    "accuracy": {"white": accuracy("white"), "black": accuracy("black")},
                }));
                history.insert(game.id.clone(), game);
            }
        }
        drop(pump);
        // A full page may have more games before the oldest one.
        let next = if count == max {
            oldest.map(|o| o.saturating_sub(1))
        } else {
            None
        };
        Ok(json!({"games": rows, "next_until": next}))
    }

    async fn stop_online(&self) {
        if let Some(task) = self.account_task.lock().await.take() {
            task.abort();
        }
        if let Some(task) = self.seek_task.lock().await.take() {
            task.abort();
        }
        for (_, task) in std::mem::take(&mut *self.streams.lock().await) {
            task.abort();
        }
    }

    async fn logout(&self) -> Result<()> {
        let _reload_guard = self.reload_lock.lock().await;
        match std::fs::remove_file(crate::config_dir().join("token")) {
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => return Err(e.into()),
            _ => {}
        }
        self.stop_online().await;
        *self.api.write().await = None;
        let mut s = self.state.lock().await;
        s.games.retain(|_, g| !g.online);
        s.challenges.clear();
        s.account = None;
        s.seeking = false;
        s.connection = "offline".into();
        self.publish(&s);
        Ok(())
    }

    /// Starts Lichess OAuth (PKCE, no client secret) and returns the URL to open in a browser.
    /// A one-shot listener on 127.0.0.1 receives the redirect.
    async fn start_login(self: &Arc<Self>) -> Result<String> {
        let api = Api::new(String::new())?;
        let verifier = random_token()?;
        let state = random_token()?;
        let challenge = URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()));
        let listener = TcpListener::bind("127.0.0.1:0").await?;
        let redirect = format!("http://127.0.0.1:{}/", listener.local_addr()?.port());
        let url = reqwest::Url::parse_with_params(
            &format!("{}/oauth", api.base()),
            [
                ("response_type", "code"),
                ("client_id", crate::OAUTH_CLIENT_ID),
                ("redirect_uri", &redirect),
                ("code_challenge_method", "S256"),
                ("code_challenge", &challenge),
                (
                    "scope",
                    "board:play challenge:read challenge:write puzzle:read puzzle:write",
                ),
                ("state", &state),
            ],
        )?;
        self.cancel_login().await;
        {
            let mut s = self.state.lock().await;
            s.logging_in = true;
            self.publish(&s);
        }
        let app = self.clone();
        *self.login_task.lock().await = Some(tokio::spawn(async move {
            let result = tokio::time::timeout(
                Duration::from_secs(300),
                app.clone()
                    .finish_login(listener, api, verifier, state, redirect),
            )
            .await
            .map_err(|_| anyhow!("timed out waiting for approval"))
            .and_then(|r| r);
            {
                let mut s = app.state.lock().await;
                s.logging_in = false;
                app.publish(&s);
            }
            if let Err(e) = result {
                app.notice(format!("Lichess login failed: {e:#}"));
            }
        }));
        Ok(url.into())
    }

    async fn cancel_login(&self) {
        if let Some(task) = self.login_task.lock().await.take() {
            task.abort();
        }
        let mut s = self.state.lock().await;
        if s.logging_in {
            s.logging_in = false;
            self.publish(&s);
        }
    }

    async fn finish_login(
        self: Arc<Self>,
        listener: TcpListener,
        api: Api,
        verifier: String,
        state: String,
        redirect: String,
    ) -> Result<()> {
        loop {
            let (mut stream, _) = listener.accept().await?;
            let mut buf = vec![0u8; 8192];
            let n = stream.read(&mut buf).await?;
            let head = String::from_utf8_lossy(&buf[..n]);
            let target = head.split_whitespace().nth(1).unwrap_or("/");
            let params: BTreeMap<String, String> =
                reqwest::Url::parse(&format!("http://127.0.0.1{target}"))?
                    .query_pairs()
                    .into_owned()
                    .collect();
            // Ignore stray requests (favicon, reloads) that don't carry our state.
            if params.get("state") != Some(&state) {
                let _ = stream
                    .write_all(b"HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n")
                    .await;
                continue;
            }
            let result = async {
                if let Some(error) = params.get("error") {
                    bail!("{}", params.get("error_description").unwrap_or(error));
                }
                let code = params.get("code").context("Lichess sent no code")?;
                let token = api.exchange_code(code, &verifier, &redirect).await?;
                crate::save_token(&token)?;
                self.reload().await
            }
            .await;
            let message = match &result {
                Ok(()) => "Gambito is connected to Lichess. You can close this tab.".to_owned(),
                Err(e) => format!("Gambito could not connect: {e:#}"),
            };
            let page = format!(
                "<!doctype html><meta charset=utf-8><title>Gambito</title><body style=\"font:16px system-ui;display:grid;place-items:center;height:90vh\"><p>{}</p>",
                message.replace('<', "&lt;")
            );
            let _ = stream
                .write_all(format!("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{page}", page.len()).as_bytes())
                .await;
            return result;
        }
    }

    async fn refresh_challenges(&self, api: &Api) -> Result<()> {
        let response = api.get("/api/challenge").await?;
        let mut challenges = BTreeMap::new();
        for direction in ["in", "out"] {
            if let Some(items) = response[direction].as_array() {
                for item in items {
                    if let Some(id) = item["id"].as_str() {
                        let mut item = item.clone();
                        item["direction"] = direction.into();
                        challenges.insert(id.to_owned(), item);
                    }
                }
            }
        }
        let mut s = self.state.lock().await;
        s.challenges = challenges;
        self.publish(&s);
        Ok(())
    }

    async fn challenge_event(&self, event: &Value) {
        let Some(id) = event["challenge"]["id"]
            .as_str()
            .or_else(|| event["game"]["id"].as_str())
        else {
            return;
        };
        let mut s = self.state.lock().await;
        if event["type"] == "challenge" {
            let mut challenge = event["challenge"].clone();
            let outgoing = s
                .account
                .as_ref()
                .is_some_and(|a| a["id"] == challenge["challenger"]["id"]);
            challenge["direction"] = if outgoing { "out" } else { "in" }.into();
            s.challenges.insert(id.to_owned(), challenge);
        } else {
            s.challenges.remove(id);
        }
        self.publish(&s);
    }

    async fn account_loop(self: Arc<Self>, api: Api) {
        let mut delay = 2;
        loop {
            let result = async {
                let response = api.stream("/api/stream/event").await?;
                {
                    let mut s = self.state.lock().await;
                    s.connection = "online".into();
                    self.publish(&s);
                }
                let (tx, mut rx) = tokio::sync::mpsc::channel(64);
                let mut pump = AbortTask(tokio::spawn(records(response, tx)));
                if let Err(e) = self.refresh_challenges(&api).await {
                    self.notice(format!("Challenges unavailable: {e:#}"));
                }
                // Refresh after every reconnect, so a missed gameStart cannot lose a game.
                if let Ok(current) = api.get("/api/account/playing").await
                    && let Some(games) = current["nowPlaying"].as_array()
                {
                    for g in games {
                        if let Some(id) = g["gameId"].as_str() {
                            self.open_online(id.to_owned()).await?;
                        }
                    }
                }
                delay = 2;
                while let Some(event) = rx.recv().await {
                    if matches!(
                        event["type"].as_str(),
                        Some("challenge" | "challengeCanceled" | "challengeDeclined" | "gameStart")
                    ) {
                        self.challenge_event(&event).await;
                    }
                    if event["type"] == "gameStart"
                        && let Some(id) = event["game"]["id"].as_str()
                    {
                        self.open_online(id.to_owned()).await?;
                    }
                }
                (&mut pump.0).await??;
                Ok::<_, anyhow::Error>(())
            }
            .await;
            {
                let mut s = self.state.lock().await;
                s.connection = "reconnecting".into();
                self.publish(&s);
            }
            if let Err(e) = result {
                self.notice(e.to_string());
                if e.to_string().contains("429") {
                    delay = 60;
                }
            }
            tokio::time::sleep(Duration::from_secs(delay)).await;
            delay = (delay * 2).min(60);
        }
    }

    async fn open_online(self: &Arc<Self>, id: String) -> Result<()> {
        validate_id(&id)?;
        let api = self.api().await?;
        let mut streams = self.streams.lock().await;
        if streams.contains_key(&id) {
            return Ok(());
        }
        let app = self.clone();
        let key = id.clone();
        streams.insert(
            key,
            tokio::spawn(async move {
                app.game_loop(api, id).await;
            }),
        );
        Ok(())
    }

    async fn apply_event(&self, id: &str, event: &Value) -> Result<bool> {
        if event["type"] == "chatLine" {
            if event["room"] == "player" {
                let _ = self.tx.send(json!({"type":"chat", "game":id, "line": {
                    "user":event["username"], "text":event["text"]
                }}));
            }
            return Ok(false);
        }
        let mut s = self.state.lock().await;
        let previous = s.games.get(id).cloned();
        if event["type"] == "gameFull" {
            let variant = event["variant"]["key"].as_str().unwrap_or("standard");
            if variant != "standard" && variant != "fromPosition" {
                bail!("Only standard chess is supported; variant: {variant}");
            }
            let account_id = s
                .account
                .as_ref()
                .and_then(|a| a["id"].as_str())
                .unwrap_or("")
                .to_owned();
            let name = |side: &str| -> String {
                event[side]["name"]
                    .as_str()
                    .map(str::to_owned)
                    .unwrap_or_else(|| format!("Stockfish {}", event[side]["aiLevel"]))
            };
            let mut game = Game::local(id.to_owned());
            game.online = true;
            game.white = name("white");
            game.black = name("black");
            game.color = if event["white"]["id"].as_str() == Some(&account_id) {
                Some("white".into())
            } else if event["black"]["id"].as_str() == Some(&account_id) {
                Some("black".into())
            } else {
                None
            };
            game.initial_fen = event["initialFen"].as_str().unwrap_or("startpos").into();
            game.white_rating = event["white"]["rating"].as_u64();
            game.black_rating = event["black"]["rating"].as_u64();
            game.rated = event["rated"] == true;
            game.speed = event["speed"].as_str().map(str::to_owned);
            game.time_control = time_control(event);
            game.lichess_analysis = previous.as_ref().and_then(|g| g.lichess_analysis.clone());
            s.games.insert(id.to_owned(), game);
        }
        if event["type"] != "gameFull" && event["type"] != "gameState" {
            return Ok(false);
        }
        let e = if event["type"] == "gameFull" {
            &event["state"]
        } else {
            event
        };
        let old = s
            .games
            .get(id)
            .context("gameState received before gameFull")?;
        let mut game = old.clone();
        game.moves = e["moves"]
            .as_str()
            .unwrap_or("")
            .split_whitespace()
            .map(str::to_owned)
            .collect();
        game.status = e["status"].as_str().unwrap_or("started").into();
        game.winner = e["winner"].as_str().map(str::to_owned);
        game.white_ms = e["wtime"].as_u64();
        game.black_ms = e["btime"].as_u64();
        game.updated_ms = now_ms();
        game.connected = true;
        game.pending = old.pending && game.moves == old.moves && event["type"] != "gameFull";
        game.draw_offer = if e["wdraw"] == true {
            Some("white".into())
        } else if e["bdraw"] == true {
            Some("black".into())
        } else {
            None
        };
        game.takeback_offer = if e["wtakeback"] == true {
            Some("white".into())
        } else if e["btakeback"] == true {
            Some("black".into())
        } else {
            None
        };
        game.position()?;
        let ended = !matches!(game.status.as_str(), "started" | "created");
        if let Some((title, body)) = notification(previous.as_ref(), &game) {
            notify(id, title, body);
        }
        s.games.insert(id.to_owned(), game);
        self.publish(&s);
        Ok(ended)
    }

    /// Spectates any Lichess game (Lichess TV). The public stream replays every move and then
    /// continues live; each burst of queued events is applied under one lock and published once.
    async fn watch_loop(self: Arc<Self>, id: String) {
        loop {
            let result: Result<bool> = async {
                let path = format!("/api/stream/game/{id}");
                let response = self.any_api().await?.stream(&path).await?;
                let (tx, mut rx) = tokio::sync::mpsc::channel(256);
                let _pump = AbortTask(tokio::spawn(records(response, tx)));
                while let Some(first) = rx.recv().await {
                    let mut s = self.state.lock().await;
                    let mut finished = apply_watch_event(&mut s.games, &id, &first)?;
                    while let Ok(event) = rx.try_recv() {
                        finished |= apply_watch_event(&mut s.games, &id, &event)?;
                    }
                    self.publish(&s);
                    if finished {
                        return Ok(true);
                    }
                }
                Ok(false)
            }
            .await;
            if matches!(result, Ok(true)) {
                break;
            }
            // The stream also closes when the game ends; the export has the final result.
            let export = async {
                let path =
                    format!("/game/export/{id}?moves=false&clocks=false&evals=false&opening=false");
                self.any_api().await?.get(&path).await
            }
            .await;
            let mut s = self.state.lock().await;
            if let (Ok(export), Some(game)) = (&export, s.games.get_mut(&id))
                && let Some(status) = export["status"]
                    .as_str()
                    .filter(|st| !matches!(*st, "started" | "created"))
            {
                game.status = status.into();
                game.winner = export["winner"].as_str().map(str::to_owned);
                self.publish(&s);
                break;
            }
            // Only a game already on screen needs the disconnected state; otherwise don't wake every window.
            if let Some(game) = s.games.get_mut(&id) {
                game.connected = false;
                self.publish(&s);
            }
            drop(s);
            if let Err(e) = result {
                self.notice(format!("{id}: {e:#}"));
            }
            tokio::time::sleep(Duration::from_secs(5)).await;
        }
        self.streams.lock().await.remove(&id);
    }

    async fn game_loop(self: Arc<Self>, api: Api, id: String) {
        let mut delay = 2;
        loop {
            let result = async {
                let response = api.stream(&format!("/api/board/game/stream/{id}")).await?;
                let (tx, mut rx) = tokio::sync::mpsc::channel(64);
                let mut pump = AbortTask(tokio::spawn(records(response, tx)));
                delay = 2;
                while let Some(event) = rx.recv().await {
                    match self.apply_event(&id, &event).await {
                        Ok(true) => {
                            pump.0.abort();
                            return Ok(true);
                        }
                        Ok(false) => (),
                        Err(e) => {
                            pump.0.abort();
                            return Err(e);
                        }
                    }
                }
                (&mut pump.0).await??;
                Ok::<_, anyhow::Error>(false)
            }
            .await;
            if matches!(result, Ok(true)) {
                return;
            }
            {
                let mut s = self.state.lock().await;
                if let Some(g) = s.games.get_mut(&id) {
                    g.connected = false;
                    g.pending = false;
                }
                self.publish(&s);
            }
            if let Err(e) = result {
                self.notice(format!("{id}: {e}"));
                if e.to_string().contains("429") {
                    delay = 60;
                }
            }
            tokio::time::sleep(Duration::from_secs(delay)).await;
            delay = (delay * 2).min(60);
        }
    }

    async fn command(
        self: &Arc<Self>,
        req: Value,
        progress: tokio::sync::watch::Sender<Option<Value>>,
    ) -> Result<Value> {
        let id = req["game"].as_str().unwrap_or("");
        match req["cmd"].as_str().unwrap_or("") {
            "status" => Ok(Self::snapshot(&*self.state.lock().await)),
            "list" => Ok(Self::snapshot(&*self.state.lock().await)["games"].clone()),
            "login" => Ok(json!({"url": self.start_login().await?})),
            "cancel_login" => {
                self.cancel_login().await;
                Ok(json!("Login cancelled"))
            }
            "logout" => {
                self.logout().await?;
                Ok(json!("Signed out of Lichess"))
            }
            "reload_auth" => {
                self.reload().await?;
                Ok(json!("Account updated"))
            }
            "local" => {
                let mut s = self.state.lock().await;
                let mut n = now_ms();
                while s.games.contains_key(&format!("local-{n}")) {
                    n += 1;
                }
                let id = format!("local-{n}");
                s.games.insert(id.clone(), Game::local(id.clone()));
                if let Err(e) = Self::save(&s) {
                    s.games.remove(&id);
                    return Err(e);
                }
                self.publish(&s);
                Ok(json!({"game":id}))
            }
            "analyse" => {
                let mut s = self.state.lock().await;
                let mut n = now_ms();
                while s.games.contains_key(&format!("analysis-{n}")) {
                    n += 1;
                }
                let new_id = format!("analysis-{n}");
                // Check the source before accepting a FEN override, too.
                let username = s.account.as_ref().and_then(|a| a["username"].as_str());
                if s.games
                    .get(id)
                    .is_some_and(|source| source.engine_blocked(username))
                {
                    bail!("Analysis is off during live Lichess games (fair play)");
                }
                let branch = if let Some(line) = req["line"].as_array() {
                    // An opening line from the openings page.
                    let mut game = Game::local(new_id.clone());
                    game.analysis = true;
                    for uci in line {
                        let uci =
                            game.normalize_move(uci.as_str().context("Invalid move in line")?)?;
                        game.moves.push(uci);
                    }
                    game
                } else if let Some(master) = req["master"].as_str() {
                    // A masters example game: its PGN comes from the explorer host.
                    validate_id(master)?;
                    drop(s);
                    let api = self
                        .api()
                        .await
                        .context("Connect Lichess to open masters games")?;
                    let pgn = api.explorer_text(&format!("/masters/pgn/{master}")).await?;
                    s = self.state.lock().await;
                    let mut game = Game::local(new_id.clone());
                    game.analysis = true;
                    let tag = |name: &str| {
                        pgn.lines().find_map(|l| {
                            l.strip_prefix(&format!("[{name} \""))
                                .and_then(|v| v.strip_suffix("\"]"))
                                .map(str::to_owned)
                        })
                    };
                    game.white = tag("White").unwrap_or_else(|| "White".into());
                    game.black = tag("Black").unwrap_or_else(|| "Black".into());
                    game.white_rating = tag("WhiteElo").and_then(|r| r.parse().ok());
                    game.black_rating = tag("BlackElo").and_then(|r| r.parse().ok());
                    game.set_san_moves(&pgn_sans(&pgn))?;
                    game
                } else if let Some(fen) = req["fen"].as_str() {
                    Game::analysis_fen(new_id.clone(), fen)?
                } else {
                    let source = s.games.get(id).context("Game not found")?;
                    let ply = match req.get("ply") {
                        None => source.moves.len(),
                        Some(value) => {
                            usize::try_from(value.as_u64().context("Invalid analysis position")?)?
                        }
                    };
                    source.analysis_branch(new_id.clone(), ply)?
                };
                s.games.insert(new_id.clone(), branch);
                if let Err(e) = Self::save(&s) {
                    s.games.remove(&new_id);
                    return Err(e);
                }
                self.publish(&s);
                Ok(json!({"game":new_id}))
            }
            "delete" => {
                let mut s = self.state.lock().await;
                let target = s.games.get(id).context("Game not found")?;
                if !target.analysis && target.puzzle.is_none() {
                    bail!("Only analysis boards and puzzles can be deleted");
                }
                // Branches of a deleted board would lose their source, so they go too.
                let mut doomed = vec![id.to_owned()];
                let mut i = 0;
                while i < doomed.len() {
                    let parent = doomed[i].clone();
                    doomed.extend(
                        s.games
                            .values()
                            .filter(|g| g.analysis_source.as_deref() == Some(parent.as_str()))
                            .map(|g| g.id.clone()),
                    );
                    i += 1;
                }
                let removed: Vec<Game> = doomed.iter().filter_map(|d| s.games.remove(d)).collect();
                if let Err(e) = Self::save(&s) {
                    s.games
                        .extend(removed.into_iter().map(|g| (g.id.clone(), g)));
                    return Err(e);
                }
                self.publish(&s);
                Ok(json!(match removed.len() {
                    1 => "Variation deleted".to_owned(),
                    n => format!("Variation and {} branches deleted", n - 1),
                }))
            }
            "open" => {
                let mut s = self.state.lock().await;
                if !s.games.contains_key(id) {
                    if let Some(game) = self.history.lock().await.get(id).cloned() {
                        s.games.insert(id.to_owned(), game);
                        self.publish(&s);
                    } else {
                        drop(s);
                        self.open_online(id.to_owned()).await?;
                    }
                }
                Ok(json!({"game":id}))
            }
            "watch" => {
                validate_id(id)?;
                *self.watchers.lock().await.entry(id.to_owned()).or_insert(0) += 1;
                if !self.state.lock().await.games.contains_key(id) {
                    let mut streams = self.streams.lock().await;
                    if !streams.contains_key(id) {
                        let app = self.clone();
                        let game = id.to_owned();
                        streams.insert(
                            id.to_owned(),
                            tokio::spawn(async move { app.watch_loop(game).await }),
                        );
                    }
                }
                Ok(json!({"game": id}))
            }
            "unwatch" => {
                let mut s = self.state.lock().await;
                // Also stops a watch whose stream never delivered the game; your own games are never touched.
                let watched = match s.games.get(id) {
                    Some(g) => g.online && g.color.is_none(),
                    None => true,
                };
                // Another window still watching keeps the game and its stream.
                let remaining = {
                    let mut watchers = self.watchers.lock().await;
                    let count = watchers.get(id).copied().unwrap_or(0).saturating_sub(1);
                    if count == 0 {
                        watchers.remove(id);
                    } else {
                        watchers.insert(id.to_owned(), count);
                    }
                    count
                };
                if watched && remaining == 0 {
                    if let Some(task) = self.streams.lock().await.remove(id) {
                        task.abort();
                    }
                    if s.games.remove(id).is_some() {
                        self.publish(&s);
                    }
                }
                Ok(Value::Null)
            }
            "profile" => {
                let username = Self::username(&*self.state.lock().await)?;
                let ratings_path = format!("/api/user/{username}/rating-history");
                let activity_path = format!("/api/user/{username}/activity");
                let (account, ratings, activity) = tokio::try_join!(
                    self.cached_get("/api/account"),
                    self.cached_get(&ratings_path),
                    self.cached_get(&activity_path),
                )?;
                Ok(
                    json!({"profile": {"account": account, "ratings": ratings, "activity": activity}}),
                )
            }
            "perf" => {
                let username = Self::username(&*self.state.lock().await)?;
                let perf = req["perf"]
                    .as_str()
                    .filter(|p| PERFS.contains(p))
                    .context("Unknown speed")?;
                Ok(
                    json!({"perf": self.cached_get(&format!("/api/user/{username}/perf/{perf}")).await?}),
                )
            }
            "history" => Ok(json!({"history": self.history_page(&req).await?})),
            "puzzle" => Ok(json!({"puzzle": self.puzzle().await?})),
            "explorer" => {
                let db = req["db"].as_str().unwrap_or("masters");
                if !matches!(db, "masters" | "lichess") {
                    bail!("Explorer database must be masters or lichess");
                }
                // A game position (panel on the board), or a line of UCI moves (openings page).
                let fen = if let Some(line) = req["line"].as_array() {
                    let mut game = Game::local("line".into());
                    for uci in line {
                        let uci =
                            game.normalize_move(uci.as_str().context("Invalid move in line")?)?;
                        game.moves.push(uci);
                    }
                    game.fens()?.pop().context("Empty line")?
                } else {
                    let s = self.state.lock().await;
                    let game = s.games.get(id).context("Game not found")?;
                    let fens = game.fens()?;
                    let ply = req["ply"]
                        .as_u64()
                        .map_or(fens.len() - 1, |p| (p as usize).min(fens.len() - 1));
                    fens[ply].clone()
                };
                let api = self
                    .api()
                    .await
                    .context("Connect Lichess to use the opening explorer")?;
                let games = if req["games"] == true { 8 } else { 0 };
                let mut path = format!(
                    "/{db}?fen={}&moves=12&topGames={games}&recentGames={}",
                    fen.replace(' ', "%20").replace('/', "%2F"),
                    if db == "lichess" { games } else { 0 }
                );
                if db == "lichess" {
                    for key in ["speeds", "ratings"] {
                        if let Some(values) = req[key].as_array() {
                            let list: Vec<String> = values
                                .iter()
                                .filter_map(|v| {
                                    v.as_str()
                                        .map(str::to_owned)
                                        .or_else(|| v.as_u64().map(|n| n.to_string()))
                                })
                                .collect();
                            if list.iter().any(|v| {
                                v.is_empty() || !v.bytes().all(|c| c.is_ascii_alphanumeric())
                            }) {
                                bail!("Invalid explorer filter");
                            }
                            path += &format!("&{key}={}", list.join(","));
                        }
                    }
                }
                {
                    // Bounded: positions accumulate while browsing.
                    let mut cache = self.profile_cache.lock().await;
                    if cache.len() > 500 {
                        cache.retain(|key, _| {
                            !key.starts_with("/masters") && !key.starts_with("/lichess")
                        });
                    }
                }
                let mut data = self
                    .cached(&path, EXPLORER_TTL, async { api.explorer(&path).await })
                    .await?;
                // Position after each continuation, so the UI can draw it without chess rules.
                let pos: shakmaty::Chess = fen
                    .parse::<shakmaty::fen::Fen>()?
                    .into_position(shakmaty::CastlingMode::Standard)?;
                if let Some(moves) = data["moves"].as_array_mut() {
                    for m in moves {
                        let next = m["uci"]
                            .as_str()
                            .and_then(|u| u.parse::<shakmaty::uci::UciMove>().ok())
                            .and_then(|u| u.to_move(&pos).ok())
                            .map(|mv| {
                                let mut after = pos.clone();
                                after.play_unchecked(mv);
                                shakmaty::fen::Fen::from_position(
                                    &after,
                                    shakmaty::EnPassantMode::Legal,
                                )
                                .to_string()
                            });
                        m["fen"] = json!(next);
                    }
                }
                Ok(json!({"explorer": data, "fen": fen, "db": db}))
            }
            "tv_channels" => {
                let channels = self
                    .cached("tv_channels", TV_CHANNELS_TTL, async {
                        self.any_api().await?.get("/api/tv/channels").await
                    })
                    .await?;
                Ok(json!({"tv_channels": channels}))
            }
            "crosstable" => {
                let a = validate_name(req["a"].as_str().unwrap_or(""))?;
                let b = validate_name(req["b"].as_str().unwrap_or(""))?;
                let path = format!("/api/crosstable/{a}/{b}");
                let table = self
                    .cached(&path, CROSSTABLE_TTL, async {
                        self.any_api().await?.get(&path).await
                    })
                    .await?;
                Ok(json!({"crosstable": table}))
            }
            "puzzle_open" => {
                let puzzle = self.puzzle().await?;
                Ok(json!({"game": self.open_puzzle(&puzzle, None).await?}))
            }
            "puzzle_next" => {
                let angle = validate_name(req["angle"].as_str().unwrap_or("mix"))?;
                let difficulty = req["difficulty"].as_str().unwrap_or("normal");
                if !matches!(
                    difficulty,
                    "easiest" | "easier" | "normal" | "harder" | "hardest"
                ) {
                    bail!("Unknown difficulty: {difficulty}");
                }
                // With the account (puzzle:read) Lichess picks puzzles for your puzzle rating; tokens from
                // before that scope was requested fall back to anonymous puzzles.
                let path = format!("/api/puzzle/next?angle={angle}&difficulty={difficulty}");
                let authed = match self.api.read().await.clone() {
                    Some(api) => api.get(&path).await.ok(),
                    None => None,
                };
                let raw = match authed {
                    Some(raw) => raw,
                    None => Api::new(String::new())?.get(&path).await?,
                };
                let puzzle = prepare_puzzle(&raw)?;
                Ok(json!({"game": self.open_puzzle(&puzzle, Some(angle)).await?}))
            }
            "puzzle_dashboard" => {
                let api = self
                    .api()
                    .await
                    .context("Connect Lichess to see your puzzle stats")?;
                // Lichess answers 404 when no puzzle was played in the window: widen it before giving up.
                let mut dashboard = Value::Null;
                for days in [30, 90, 365] {
                    let path = format!("/api/puzzle/dashboard/{days}");
                    match self
                        .cached(&path, PROFILE_TTL, async { api.get(&path).await })
                        .await
                    {
                        Ok(found) => {
                            dashboard = found;
                            break;
                        }
                        Err(e) if e.to_string().contains("404") => continue,
                        Err(e) => return Err(e),
                    }
                }
                let response = api.stream("/api/puzzle/activity?max=50").await?;
                let (tx, mut rx) = tokio::sync::mpsc::channel(64);
                let pump = AbortTask(tokio::spawn(records(response, tx)));
                let mut activity = vec![];
                while let Some(record) = rx.recv().await {
                    activity.push(record);
                }
                drop(pump);
                Ok(json!({"puzzle_dashboard": {"dashboard": dashboard, "activity": activity}}))
            }
            "puzzle_themes" => {
                let themes = self
                    .cached("puzzle_themes", PUZZLE_TTL, async {
                        let api = Api::new(String::new())?;
                        let (themes, openings) = tokio::try_join!(
                            api.get("/training/themes"),
                            api.get("/training/openings")
                        )?;
                        Ok(json!({"themes": themes["themes"], "openings": openings["openings"]}))
                    })
                    .await?;
                Ok(json!({"puzzle_themes": themes}))
            }
            "puzzle_retry" | "puzzle_solution" => {
                let mut s = self.state.lock().await;
                let game = s
                    .games
                    .get_mut(id)
                    .filter(|g| g.puzzle.is_some())
                    .context("Not a puzzle")?;
                if req["cmd"] == "puzzle_retry" {
                    game.puzzle_retry();
                } else {
                    game.puzzle_reveal()?;
                }
                let result = game.puzzle_result();
                Self::save(&s)?;
                self.publish(&s);
                if let Some(result) = result {
                    self.submit_puzzle(id, result);
                }
                Ok(Value::Null)
            }
            "blog" => Ok(json!({"blog": self.blog().await?})),
            "move" => {
                let notation = req["notation"].as_str().context("Missing move")?;
                let mut s = self.state.lock().await;
                let game = s.games.get_mut(id).context("Game not found")?;
                if !game.online {
                    let original = game.clone();
                    game.play_local(notation)?;
                    let result = game.puzzle_result();
                    if let Err(e) = Self::save(&s) {
                        s.games.insert(id.into(), original);
                        return Err(e);
                    }
                    self.publish(&s);
                    if let Some(result) = result {
                        self.submit_puzzle(id, result);
                    }
                    return Ok(json!("Move played"));
                }
                if game.color.is_none() {
                    bail!("You are watching this game");
                }
                let uci = game.normalize_move(notation)?;
                game.pending = true;
                self.publish(&s);
                drop(s);
                let result = self
                    .api()
                    .await?
                    .post(&format!("/api/board/game/{id}/move/{uci}"), &[])
                    .await;
                let app = self.clone();
                let game_id = id.to_owned();
                tokio::spawn(async move {
                    tokio::time::sleep(Duration::from_secs(5)).await;
                    let needs_sync = app
                        .state
                        .lock()
                        .await
                        .games
                        .get(&game_id)
                        .is_some_and(|g| g.pending || !g.connected);
                    if needs_sync {
                        if let Some(t) = app.streams.lock().await.remove(&game_id) {
                            t.abort();
                        }
                        let _ = app.open_online(game_id).await;
                    }
                });
                if let Err(e) = result {
                    let mut s = self.state.lock().await;
                    if let Some(g) = s.games.get_mut(id) {
                        g.pending = false;
                        g.connected = false;
                    }
                    self.publish(&s);
                    return Err(e.context("Do not repeat the move until resync"));
                }
                Ok(json!("Move sent; waiting for server state"))
            }
            "eval" => {
                let depth = match req.get("depth") {
                    None => 30,
                    Some(value) => value
                        .as_u64()
                        .filter(|d| (1..=245).contains(d))
                        .context("Depth must be an integer from 1 to 245")?,
                };
                let (fen, ply) = {
                    let s = self.state.lock().await;
                    let game = s.games.get(id).context("Game not found")?;
                    // Lichess fair play: no engine help in your own ongoing online games.
                    if game.puzzle.is_some() && game.status == "started" {
                        bail!("Engine is off until the puzzle is solved");
                    }
                    if game.engine_blocked(s.account.as_ref().and_then(|a| a["username"].as_str()))
                    {
                        bail!("Engine is off during live Lichess games (fair play)");
                    }
                    let fens = game.fens()?;
                    let ply = req["ply"]
                        .as_u64()
                        .map_or(fens.len() - 1, |p| (p as usize).min(fens.len() - 1));
                    (fens[ply].clone(), ply)
                };
                let api = self.api.read().await.clone();
                let mut eval = self.engine.eval(&fen, api, depth, |mut eval| {
                    if req["stream"] == true {
                        eval["for"] = id.into();
                        eval["ply"] = ply.into();
                        progress.send_replace(Some(json!({"type": "eval", "request_id": req["request_id"], "eval": eval})));
                    }
                }).await?;
                eval["for"] = id.into();
                eval["ply"] = ply.into();
                Ok(json!({ "eval": eval }))
            }
            "lichess_analysis" => {
                validate_id(id)?;
                {
                    let s = self.state.lock().await;
                    let game = s.games.get(id).context("Game not found")?;
                    if !game.online || matches!(game.status.as_str(), "started" | "created") {
                        bail!("Lichess analysis is only available for finished Lichess games");
                    }
                }
                let api = match self.api.read().await.clone() {
                    Some(api) => api,
                    None => Api::new(String::new())?,
                };
                let record = api
                    .get(&format!("/game/export/{id}?evals=true&accuracy=true&moves=false&tags=false&clocks=false&opening=false"))
                    .await?;
                let analysis = lichess_analysis(&record);
                let found = analysis.is_some();
                let mut s = self.state.lock().await;
                s.games
                    .get_mut(id)
                    .context("Game not found")?
                    .lichess_analysis = analysis;
                self.publish(&s);
                Ok(json!(if found {
                    "Lichess analysis loaded"
                } else {
                    "No Lichess analysis yet: request it on lichess.org, then load again"
                }))
            }
            "positions" => {
                let s = self.state.lock().await;
                let game = s.games.get(id).context("Game not found")?;
                Ok(json!({"positions": game.fens()?, "for": id, "plies": game.moves.len()}))
            }
            "export" => Ok(json!(
                self.state
                    .lock()
                    .await
                    .games
                    .get(id)
                    .context("Game not found")?
                    .pgn()?
            )),
            "resign" | "draw" => {
                let action = req["cmd"].as_str().unwrap();
                let mut s = self.state.lock().await;
                let game = s.games.get_mut(id).context("Game not found")?;
                if game.status != "started" {
                    bail!("Game over");
                }
                if !game.online {
                    let original = game.clone();
                    if action == "resign" {
                        game.winner = Some(
                            if game.position()?.turn().is_white() {
                                "black"
                            } else {
                                "white"
                            }
                            .into(),
                        );
                        game.status = "resign".into();
                    } else {
                        game.status = "draw".into();
                    }
                    if let Err(e) = Self::save(&s) {
                        s.games.insert(id.into(), original);
                        return Err(e);
                    }
                    self.publish(&s);
                    return Ok(json!("Game over"));
                }
                drop(s);
                let endpoint = if action == "draw" {
                    "draw/yes"
                } else {
                    "resign"
                };
                self.api()
                    .await?
                    .post(&format!("/api/board/game/{id}/{endpoint}"), &[])
                    .await?;
                Ok(json!("Request sent"))
            }
            "challenges" => {
                self.refresh_challenges(&self.api().await?).await?;
                Ok(json!("Challenges refreshed"))
            }
            "challenge" => {
                let username =
                    validate_name(req["username"].as_str().context("Username required")?)?;
                let color = req["color"].as_str().unwrap_or("random");
                if !matches!(color, "white" | "black" | "random") {
                    bail!("Invalid color");
                }
                let mut form = time_form(&req, "clock.limit", "clock.increment", |m| {
                    (m * 60).to_string()
                })?;
                if req["days"].is_null() {
                    let minutes = req["minutes"].as_u64().unwrap_or(10);
                    let increment = req["increment"].as_u64().unwrap_or(5);
                    if increment > 60 || minutes * 60 + increment * 40 < 180 {
                        bail!(
                            "Board API challenges require Blitz or slower (at least 3 minutes estimated); increment 0–60"
                        );
                    }
                }
                form.extend([
                    ("color", color.to_owned()),
                    ("rated", (req["rated"] == true).to_string()),
                    ("variant", "standard".into()),
                ]);
                let response = self
                    .api()
                    .await?
                    .post(&format!("/api/challenge/{username}"), &form)
                    .await?;
                // Some servers wrap the challenge; the public schema also permits the bare object.
                let mut challenge = response.get("challenge").unwrap_or(&response).clone();
                let id = challenge["id"]
                    .as_str()
                    .context("Lichess returned no challenge ID")?
                    .to_owned();
                challenge["direction"] = "out".into();
                let mut s = self.state.lock().await;
                s.challenges.insert(id, challenge);
                self.publish(&s);
                Ok(json!(
                    "Challenge sent. Real-time invitations expire after 20 seconds."
                ))
            }
            "challenge_accept" | "challenge_decline" | "challenge_cancel" => {
                let id = req["challenge"].as_str().context("Challenge ID required")?;
                validate_id(id)?;
                let action = req["cmd"]
                    .as_str()
                    .unwrap()
                    .trim_start_matches("challenge_");
                {
                    let s = self.state.lock().await;
                    let challenge = s
                        .challenges
                        .get(id)
                        .context("Challenge is no longer available; refresh challenges")?;
                    if (action == "cancel") != (challenge["direction"] == "out") {
                        bail!("Invalid challenge direction");
                    }
                    if action == "accept"
                        && (challenge["variant"]["key"] != "standard"
                            || matches!(
                                challenge["speed"].as_str(),
                                Some("bullet" | "ultraBullet")
                            ))
                    {
                        bail!("Only standard chess, Blitz or slower, is supported");
                    }
                }
                self.api()
                    .await?
                    .post(&format!("/api/challenge/{id}/{action}"), &[])
                    .await?;
                let mut s = self.state.lock().await;
                s.challenges.remove(id);
                self.publish(&s);
                Ok(json!("Challenge response sent"))
            }
            "chat_history" | "chat" | "takeback" => {
                let id = req["game"].as_str().context("Game ID required")?;
                validate_id(id)?;
                let cmd = req["cmd"].as_str().unwrap();
                {
                    let s = self.state.lock().await;
                    let game = s.games.get(id).context("Game not found")?;
                    if !game.online || game.color.is_none() {
                        bail!("This action requires your own Lichess game");
                    }
                    if cmd == "takeback" && !matches!(game.status.as_str(), "started" | "created") {
                        bail!("Game is over");
                    }
                }
                let api = self.api().await?;
                if cmd == "chat_history" {
                    let lines = api.get(&format!("/api/board/game/{id}/chat")).await?;
                    let lines = lines.as_array().context("Invalid chat history")?;
                    return Ok(
                        json!({"for":id, "lines": &lines[lines.len().saturating_sub(100)..]}),
                    );
                }
                if cmd == "chat" {
                    let text = req["text"].as_str().unwrap_or("").trim();
                    if text.is_empty() || text.chars().count() > 140 || text.contains(['\n', '\r'])
                    {
                        bail!("Chat messages must be 1–140 characters on one line");
                    }
                    api.post(
                        &format!("/api/board/game/{id}/chat"),
                        &[("room", "player".into()), ("text", text.into())],
                    )
                    .await?;
                    return Ok(json!("Message sent"));
                }
                let accept = req["accept"]
                    .as_bool()
                    .context("Takeback requires accept: true or false")?;
                let action = if accept { "yes" } else { "no" };
                api.post(&format!("/api/board/game/{id}/takeback/{action}"), &[])
                    .await?;
                Ok(json!("Takeback response sent"))
            }
            "seek" => {
                let rated = req["rated"] == true;
                let mut form = vec![("rated", rated.to_string()), ("variant", "standard".into())];
                let correspondence = req["days"].is_u64();
                form.extend(time_form(&req, "time", "increment", |m| m.to_string())?);
                let api = self.api().await?;
                let mut task = self.seek_task.lock().await;
                if task.as_ref().is_some_and(|t| !t.is_finished()) {
                    bail!("A seek is already running; use cancel");
                }
                {
                    let mut s = self.state.lock().await;
                    if s.connection != "online" {
                        bail!("Wait for the Lichess event stream to connect");
                    }
                    s.seeking = true;
                    self.publish(&s);
                }
                let app = self.clone();
                *task = Some(tokio::spawn(async move {
                    if let Err(e) = api.seek(&form).await {
                        app.notice(e.to_string());
                    }
                    let mut s = app.state.lock().await;
                    s.seeking = false;
                    app.publish(&s);
                }));
                Ok(json!(if correspondence {
                    "Correspondence seek posted; you'll be notified when someone joins"
                } else {
                    "Seeking opponent"
                }))
            }
            "cancel" => {
                if let Some(t) = self.seek_task.lock().await.take() {
                    t.abort();
                }
                let mut s = self.state.lock().await;
                s.seeking = false;
                self.publish(&s);
                Ok(json!("Seek cancelled"))
            }
            "ai" => {
                let level = req["level"].as_u64().unwrap_or(1);
                if !(1..=8).contains(&level) {
                    bail!("Level must be 1–8");
                }
                let color = req["color"].as_str().unwrap_or("random");
                if !matches!(color, "white" | "black" | "random") {
                    bail!("Color must be white, black or random");
                }
                let mut form = vec![("level", level.to_string()), ("color", color.to_owned())];
                if req["minutes"].is_null() && req["days"].is_null() {
                    form.extend([
                        ("clock.limit", "600".to_owned()),
                        ("clock.increment", "5".to_owned()),
                    ]);
                } else {
                    form.extend(time_form(&req, "clock.limit", "clock.increment", |m| {
                        (m * 60).to_string()
                    })?);
                }
                let v = self.api().await?.post("/api/challenge/ai", &form).await?;
                let id = v["id"].as_str().context("Lichess returned no ID")?;
                self.open_online(id.to_owned()).await?;
                Ok(json!({"game":id}))
            }
            _ => bail!("Unknown command"),
        }
    }
}

/// Form fields for either a real-time clock (minutes/increment) or correspondence (days).
fn time_form(
    req: &Value,
    limit_key: &'static str,
    increment_key: &'static str,
    limit: impl Fn(u64) -> String,
) -> Result<Vec<(&'static str, String)>> {
    if let Some(days) = req["days"].as_u64() {
        if ![1, 2, 3, 5, 7, 10, 14].contains(&days) {
            bail!("Days per move must be 1, 2, 3, 5, 7, 10 or 14");
        }
        return Ok(vec![("days", days.to_string())]);
    }
    let minutes = req["minutes"].as_u64().unwrap_or(10);
    let increment = req["increment"].as_u64().unwrap_or(5);
    if !(1..=180).contains(&minutes) || increment > 180 {
        bail!("Invalid time control: minutes 1–180, increment 0–180");
    }
    Ok(vec![
        (limit_key, limit(minutes)),
        (increment_key, increment.to_string()),
    ])
}

fn time_control(event: &Value) -> Option<String> {
    if let Some(days) = event["daysPerTurn"].as_u64() {
        return Some(format_days(days));
    }
    let clock = event["clock"].as_object()?;
    Some(format_clock(
        clock.get("initial")?.as_u64()?,
        clock.get("increment")?.as_u64()? / 1000,
    ))
}

fn format_days(days: u64) -> String {
    format!("{days} day{}", if days == 1 { "" } else { "s" })
}

fn format_clock(initial_ms: u64, increment: u64) -> String {
    let minutes = match initial_ms as f64 / 60000.0 {
        0.25 => "¼".to_owned(),
        0.5 => "½".to_owned(),
        0.75 => "¾".to_owned(),
        m => format!("{m}"),
    };
    format!("{minutes}+{increment}")
}

/// One record of /api/games/user (clock values in seconds, moves in SAN).
fn history_game(record: &Value, username: &str) -> Option<Game> {
    let variant = record["variant"].as_str().unwrap_or("standard");
    if variant != "standard" && variant != "fromPosition" {
        return None;
    }
    let id = record["id"].as_str()?;
    validate_id(id).ok()?;
    let player = |side: &str| {
        let p = &record["players"][side];
        p["user"]["name"]
            .as_str()
            .map(str::to_owned)
            .unwrap_or_else(|| format!("Stockfish {}", p["aiLevel"]))
    };
    let mut game = Game::local(id.to_owned());
    game.online = true;
    game.white = player("white");
    game.black = player("black");
    game.color = ["white", "black"]
        .into_iter()
        .find(|side| game_player_is(record, side, username))
        .map(str::to_owned);
    game.initial_fen = record["initialFen"].as_str().unwrap_or("startpos").into();
    game.status = record["status"].as_str()?.into();
    game.winner = record["winner"].as_str().map(str::to_owned);
    game.white_rating = record["players"]["white"]["rating"].as_u64();
    game.black_rating = record["players"]["black"]["rating"].as_u64();
    game.rated = record["rated"] == true;
    game.speed = record["speed"].as_str().map(str::to_owned);
    game.time_control = record["daysPerTurn"].as_u64().map(format_days).or_else(|| {
        let clock = &record["clock"];
        Some(format_clock(
            clock["initial"].as_u64()? * 1000,
            clock["increment"].as_u64()?,
        ))
    });
    game.lichess_analysis = lichess_analysis(record);
    game.updated_ms = record["lastMoveAt"].as_u64().unwrap_or(0);
    game.set_san_moves(record["moves"].as_str().unwrap_or(""))
        .ok()?;
    Some(game)
}

/// Server analysis from a Lichess game export requested with evals and accuracy.
fn lichess_analysis(record: &Value) -> Option<Value> {
    let moves = record["analysis"].as_array().filter(|m| !m.is_empty())?;
    Some(
        json!({"moves": moves, "white": record["players"]["white"]["analysis"],
                "black": record["players"]["black"]["analysis"]}),
    )
}

/// Applies one public game-stream event; true once the game is over. A game-info event (sent first
/// on every connection, before the stream replays all moves) resets the game.
fn apply_watch_event(games: &mut BTreeMap<String, Game>, id: &str, event: &Value) -> Result<bool> {
    if event["players"].is_object() {
        let player = |side: &str| {
            let p = &event["players"][side];
            p["user"]["name"]
                .as_str()
                .map(str::to_owned)
                .unwrap_or_else(|| match p["aiLevel"].as_u64() {
                    Some(level) => format!("Stockfish level {level}"),
                    None => "Anonymous".into(),
                })
        };
        let mut game = Game::local(id.to_owned());
        game.online = true;
        game.white = player("white");
        game.black = player("black");
        game.white_rating = event["players"]["white"]["rating"].as_u64();
        game.black_rating = event["players"]["black"]["rating"].as_u64();
        game.rated = event["rated"] == true;
        game.speed = event["speed"].as_str().map(str::to_owned);
        game.initial_fen = event["initialFen"].as_str().unwrap_or("startpos").into();
        if let Some(status) = event["status"]["name"]
            .as_str()
            .or(event["status"].as_str())
        {
            game.status = status.into();
        }
        game.winner = event["winner"].as_str().map(str::to_owned);
        let over = !matches!(game.status.as_str(), "started" | "created");
        // Game info again at the end carries the result: keep the moves already played.
        // At the start of a (re)connection it precedes a full replay, so the moves reset.
        if over && let Some(existing) = games.get_mut(id) {
            existing.status = game.status;
            existing.winner = game.winner;
            return Ok(true);
        }
        games.insert(id.to_owned(), game);
        return Ok(over);
    }
    let Some(game) = games.get_mut(id) else {
        return Ok(false);
    };
    if let Some(lm) = event["lm"].as_str() {
        // Not normalize_move: that enforces the player's own turn, and a spectator has none.
        let m = lm
            .parse::<shakmaty::uci::UciMove>()
            .ok()
            .and_then(|uci| uci.to_move(&game.position().ok()?).ok())
            .context("Watched game out of sync")?;
        game.moves
            .push(m.to_uci(shakmaty::CastlingMode::Standard).to_string());
    } else if game.moves.is_empty()
        && let Some(fen) = event["fen"].as_str()
    {
        game.initial_fen = fen.into();
    }
    if let (Some(white), Some(black)) = (event["wc"].as_u64(), event["bc"].as_u64()) {
        game.white_ms = Some(white * 1000);
        game.black_ms = Some(black * 1000);
    }
    game.connected = true;
    game.updated_ms = now_ms();
    Ok(false)
}

/// SAN tokens of a PGN movetext: no tags, comments, variations, move numbers or result.
fn pgn_sans(pgn: &str) -> String {
    let movetext: String = pgn
        .lines()
        .filter(|l| !l.starts_with('['))
        .collect::<Vec<_>>()
        .join(" ");
    let (mut depth, mut clean) = (0, String::new());
    for c in movetext.chars() {
        match c {
            '{' | '(' => depth += 1,
            '}' | ')' => depth -= 1,
            _ if depth == 0 => clean.push(c),
            _ => {}
        }
    }
    clean
        .split_whitespace()
        .filter(|t| {
            !t.ends_with('.')
                && !t.starts_with('$')
                && !matches!(*t, "1-0" | "0-1" | "1/2-1/2" | "*")
        })
        .map(|t| t.rsplit('.').next().unwrap_or(t))
        .filter(|t| !t.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
}

/// Title, author, date and link of the newest Atom entries (Lichess feeds: one line per element).
fn atom_entries(feed: &str, limit: usize) -> Vec<Value> {
    let between = |text: &str, open: &str, close: &str| -> Option<String> {
        let start = text.find(open)? + open.len();
        let end = text[start..].find(close)? + start;
        Some(text[start..end].to_owned())
    };
    let unescape = |s: String| {
        s.replace("&lt;", "<")
            .replace("&gt;", ">")
            .replace("&quot;", "\"")
            .replace("&#39;", "'")
            .replace("&apos;", "'")
            .replace("&amp;", "&")
    };
    feed.split("<entry>")
        .skip(1)
        .take(limit)
        .filter_map(|entry| {
            Some(json!({
                "title": unescape(between(entry, "<title>", "</title>")?),
                "author": between(entry, "<name>", "</name>").map(unescape),
                "published": between(entry, "<published>", "</published>"),
                "url": unescape(between(entry, "<link rel=\"alternate\" type=\"text/html\" href=\"", "\"")?),
            }))
        })
        .collect()
}

fn game_player_is(record: &Value, side: &str, username: &str) -> bool {
    record["players"][side]["user"]["name"]
        .as_str()
        .is_some_and(|name| name.eq_ignore_ascii_case(username))
}

/// Desktop notification for what happened since the previous state of an online game.
fn notification(previous: Option<&Game>, game: &Game) -> Option<(String, String)> {
    let me = game.color.as_deref()?;
    let opponent = if me == "white" {
        &game.black
    } else {
        &game.white
    };
    let active = |g: &Game| matches!(g.status.as_str(), "started" | "created");
    let summary = format!("{} vs {}", game.white, game.black);
    let Some(previous) = previous else {
        return (active(game) && game.moves.is_empty()).then(|| {
            let control = game.time_control.as_deref().unwrap_or("");
            (
                format!("Game started vs {opponent}"),
                format!("{summary} · {control}"),
            )
        });
    };
    if active(previous) && !active(game) {
        let result = match game.winner.as_deref() {
            Some(w) if w == me => "You won",
            Some(_) => "You lost",
            None => "Game drawn",
        };
        return Some((format!("{result} vs {opponent}"), summary));
    }
    if game.moves.len() > previous.moves.len() {
        let snapshot = game.snapshot().ok()?;
        if snapshot["turn"] == me {
            let san = snapshot["san"].as_array()?.last()?.as_str()?.to_owned();
            return Some((
                format!("{opponent} played {san}"),
                format!("Your turn · {summary}"),
            ));
        }
    }
    let opponent_color = if me == "white" { "black" } else { "white" };
    if game.draw_offer.as_deref() == Some(opponent_color) && previous.draw_offer != game.draw_offer
    {
        return Some((format!("{opponent} offers a draw"), summary));
    }
    None
}

/// notify-send with an "Open game" action. GAMBITO_NOTIFY_CMD overrides the command; empty disables.
fn notify(id: &str, title: String, body: String) {
    let program = std::env::var("GAMBITO_NOTIFY_CMD").unwrap_or_else(|_| "notify-send".into());
    if program.is_empty() {
        return;
    }
    let id = id.to_owned();
    tokio::spawn(async move {
        let output = tokio::process::Command::new(program)
            .args([
                "--app-name=Gambito",
                "--action=open=Open game",
                &title,
                &body,
            ])
            .output()
            .await;
        if let Ok(output) = output
            && String::from_utf8_lossy(&output.stdout).trim() == "open"
            && let Ok(exe) = std::env::current_exe()
        {
            let _ = tokio::process::Command::new(exe)
                .args(["open", &id])
                .spawn();
        }
    });
}

fn validate_id(id: &str) -> Result<()> {
    if id.len() != 8 || !id.bytes().all(|c| c.is_ascii_alphanumeric()) {
        bail!("Use the public game ID (8 characters)");
    }
    Ok(())
}

/// Forwards Lichess TV (featured game, then its moves) to one client, reconnecting when the feed ends.
async fn tv_feed(
    app: Arc<App>,
    events: tokio::sync::mpsc::Sender<Value>,
    path: String,
) -> Result<()> {
    loop {
        let result: Result<()> = async {
            let response = app.any_api().await?.stream(&path).await?;
            let (tx, mut rx) = tokio::sync::mpsc::channel(16);
            let _pump = AbortTask(tokio::spawn(records(response, tx)));
            while let Some(record) = rx.recv().await {
                events.send(json!({"type": "tv", "event": record})).await?;
            }
            Ok(())
        }
        .await;
        if let Err(e) = result {
            if events.is_closed() {
                return Ok(());
            }
            let _ = events
                .send(json!({"type": "tv", "error": format!("{e:#}")}))
                .await;
        }
        tokio::time::sleep(Duration::from_secs(5)).await;
    }
}

async fn client(app: Arc<App>, stream: UnixStream) -> Result<()> {
    let (read, mut write) = stream.into_split();
    let mut reader = FramedRead::new(read, LinesCodec::new_with_max_length(16_384));
    let mut events = app.tx.subscribe();
    let (progress_tx, mut progress_rx) = tokio::sync::watch::channel(None::<Value>);
    let (reply_tx, mut reply_rx) = tokio::sync::mpsc::channel(16);
    let mut analysis: Option<(Value, AbortTask)> = None;
    // Lichess TV feed for this connection's lobby; dropping it closes the HTTP stream.
    let mut _tv: Option<AbortTask> = None;
    let initial = App::snapshot(&*app.state.lock().await);
    write.write_all(format!("{initial}\n").as_bytes()).await?;
    loop {
        let response = tokio::select! {
            read = reader.next() => {
                let Some(line) = read else { return Ok(()); };
                let req: Result<Value, _> = serde_json::from_str(&line?);
                match req {
                    Ok(req) => {
                        let id = req["request_id"].clone();
                        if matches!(req["cmd"].as_str(), Some("tv_watch" | "tv_stop")) {
                            // One feed per connection: watching another channel replaces the previous stream.
                            let path = match req["channel"].as_str() {
                                None => Ok("/api/tv/feed".to_owned()),
                                Some(channel) => validate_name(channel).map(|c| format!("/api/tv/{c}/feed")),
                            };
                            match path {
                                Err(e) => json!({"type":"reply", "request_id":id, "ok":false, "error":format!("{e:#}")}),
                                Ok(path) => {
                                    _tv = (req["cmd"] == "tv_watch").then(|| AbortTask(tokio::spawn(tv_feed(app.clone(), reply_tx.clone(), path))));
                                    json!({"type":"reply", "request_id":id, "ok":true, "data":null})
                                }
                            }
                        } else if matches!(req["cmd"].as_str(), Some("eval" | "cancel_eval")) {
                            if let Some((old_id, task)) = analysis.take() {
                                let finished = task.0.is_finished();
                                drop(task);
                                if !finished {
                                    let cancelled = json!({"type":"reply", "request_id":old_id, "ok":false, "error":"Analysis cancelled"});
                                    tokio::time::timeout(Duration::from_secs(5), write.write_all(format!("{cancelled}\n").as_bytes())).await??;
                                }
                            }
                            progress_tx.send_replace(None);
                            if req["cmd"] == "cancel_eval" {
                                json!({"type":"reply", "request_id":id, "ok":true, "data":null})
                            } else {
                                let app = app.clone();
                                let progress = progress_tx.clone();
                                let replies = reply_tx.clone();
                                let request_id = id.clone();
                                analysis = Some((id, AbortTask(tokio::spawn(async move {
                                    let reply = match app.command(req, progress).await {
                                        Ok(data) => json!({"type":"reply", "request_id":request_id, "ok":true, "data":data}),
                                        Err(e) => json!({"type":"reply", "request_id":request_id, "ok":false, "error":format!("{e:#}")}),
                                    };
                                    let _ = replies.send(reply).await;
                                    Ok(())
                                }))));
                                continue;
                            }
                        } else {
                            match app.command(req, progress_tx.clone()).await {
                                Ok(data) => json!({"type":"reply","request_id":id,"ok":true,"data":data}),
                                Err(e) => json!({"type":"reply","request_id":id,"ok":false,"error":format!("{e:#}")}),
                            }
                        }
                    },
                    Err(_) => json!({"type":"reply","ok":false,"error":"Invalid JSON"}),
                }
            },
            Some(reply) = reply_rx.recv() => reply,
            Ok(()) = progress_rx.changed() => {
                let update = progress_rx.borrow_and_update().clone();
                match update { Some(update) => update, None => continue }
            },
            event = events.recv() => match event {
                Ok(e) => e,
                Err(broadcast::error::RecvError::Lagged(_)) => App::snapshot(&*app.state.lock().await),
                Err(_) => return Ok(()),
            }
        };
        tokio::time::timeout(
            Duration::from_secs(5),
            write.write_all(format!("{response}\n").as_bytes()),
        )
        .await??;
    }
}

pub async fn run() -> Result<()> {
    let path = crate::socket_path()?;
    let parent = path.parent().context("Socket has no parent directory")?;
    if !parent.exists() {
        crate::private_dir(parent)?;
    }
    use std::os::unix::fs::MetadataExt;
    if std::fs::metadata(parent)?.mode() & 0o077 != 0 {
        bail!(
            "Socket directory must be private (0700): {}",
            parent.display()
        );
    }
    // Lock the directory's stable lockfile before replacing a stale socket.
    let lock = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(path.with_extension("lock"))?;
    lock.try_lock()
        .context("A daemon is already running on this socket")?;
    if path.exists() {
        std::fs::remove_file(&path)?;
    }
    let listener = UnixListener::bind(&path)?;
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
    let saved = crate::data_dir().join("local.json");
    let games: Vec<Game> = if saved.exists() {
        serde_json::from_slice(&std::fs::read(saved)?)
            .context("Invalid local games file; kept for recovery")?
    } else {
        vec![]
    };
    for g in &games {
        g.position().context("Invalid saved game")?;
    }
    let (tx, _) = broadcast::channel(128);
    let app = Arc::new(App {
        state: Mutex::new(State {
            games: games.into_iter().map(|g| (g.id.clone(), g)).collect(),
            account: None,
            connection: "offline".into(),
            seeking: false,
            logging_in: false,
            challenges: BTreeMap::new(),
        }),
        api: RwLock::new(None),
        tx,
        streams: Mutex::new(BTreeMap::new()),
        account_task: Mutex::new(None),
        seek_task: Mutex::new(None),
        login_task: Mutex::new(None),
        reload_lock: Mutex::new(()),
        engine: Default::default(),
        history: Mutex::new(BTreeMap::new()),
        watchers: Mutex::new(BTreeMap::new()),
        profile_cache: Mutex::new(BTreeMap::new()),
    });
    if crate::config_dir().join("token").exists() {
        let a = app.clone();
        tokio::spawn(async move {
            if let Err(e) = a.reload().await {
                eprintln!("Auth: {e:#}");
                a.notice(e.to_string());
            }
        });
    }
    eprintln!("Gambito listening on {}", path.display());
    let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
    loop {
        tokio::select! {
            connection = listener.accept() => { let (stream, _) = connection?; let a = app.clone(); tokio::spawn(async move { if let Err(e) = client(a, stream).await { eprintln!("Client: {e}"); } }); },
            _ = tokio::signal::ctrl_c() => break,
            _ = term.recv() => break,
        }
    }
    std::fs::remove_file(path)?;
    drop(lock);
    Ok(())
}

fn random_token() -> Result<String> {
    let mut bytes = [0u8; 32];
    std::io::Read::read_exact(&mut std::fs::File::open("/dev/urandom")?, &mut bytes)?;
    Ok(URL_SAFE_NO_PAD.encode(bytes))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn pgn_movetext_to_sans() {
        let pgn = "[Event \"x\"]\n[White \"Carlsen, M.\"]\n\n1. e4 {book} e5 2. Nf3 (2. Bc4 Nf6) 2... Nc6 $1 3.Bb5 1/2-1/2";
        assert_eq!(pgn_sans(pgn), "e4 e5 Nf3 Nc6 Bb5");
    }

    #[test]
    fn atom_entries_unescape_and_limit() {
        let feed = r#"<feed><title>Blogs</title><entry><id>1</id><published>2026-09-16T21:53:15Z</published><link rel="alternate" type="text/html" href="https://lichess.org/@/a/blog/x?a=1&amp;b=2" /><title>Rounds &amp; &quot;draws&quot;</title><author><name>sgis</name></author></entry><entry><title>Second</title><link rel="alternate" type="text/html" href="https://lichess.org/b" /></entry></feed>"#;
        let entries = atom_entries(feed, 5);
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0]["title"], "Rounds & \"draws\"");
        assert_eq!(entries[0]["url"], "https://lichess.org/@/a/blog/x?a=1&b=2");
        assert_eq!(
            (entries[0]["author"].as_str(), entries[1]["author"].as_str()),
            (Some("sgis"), None)
        );
        assert_eq!(atom_entries(feed, 1).len(), 1);
    }
}
