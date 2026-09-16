use crate::{
    game::{Game, now_ms},
    lichess::{Api, records},
};
use anyhow::{Context, Result, bail};
use futures_util::StreamExt;
use serde_json::{Value, json};
use shakmaty::Position;
use std::{collections::BTreeMap, sync::Arc, time::Duration};
use tokio::{
    io::AsyncWriteExt,
    net::{UnixListener, UnixStream},
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
}
pub struct App {
    state: Mutex<State>,
    api: RwLock<Option<Api>>,
    tx: broadcast::Sender<Value>,
    streams: Mutex<BTreeMap<String, JoinHandle<()>>>,
    account_task: Mutex<Option<JoinHandle<()>>>,
    seek_task: Mutex<Option<JoinHandle<()>>>,
    reload_lock: Mutex<()>,
}
impl App {
    fn snapshot(s: &State) -> Value {
        json!({"type":"state", "games": s.games.values().filter_map(|g| g.snapshot().ok()).collect::<Vec<_>>(),
            "account":s.account, "connection":s.connection, "seeking":s.seeking})
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
            .context("Configure a conta com gambito auth")
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
            .context("Token não configurado; execute gambito auth")?;
        let api = Api::new(token.trim().into())?;
        let account = api.get("/api/account").await?;
        if let Some(task) = self.account_task.lock().await.take() {
            task.abort();
        }
        if let Some(task) = self.seek_task.lock().await.take() {
            task.abort();
        }
        for (_, task) in std::mem::take(&mut *self.streams.lock().await) {
            task.abort();
        }
        *self.api.write().await = Some(api.clone());
        {
            let mut s = self.state.lock().await;
            s.games.retain(|_, g| !g.online);
            s.account = Some(account);
            s.seeking = false;
            s.connection = "connecting".into();
            self.publish(&s);
        }
        let app = self.clone();
        *self.account_task.lock().await = Some(tokio::spawn(async move {
            app.account_loop(api).await;
        }));
        Ok(())
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
        let mut s = self.state.lock().await;
        if event["type"] == "gameFull" {
            let variant = event["variant"]["key"].as_str().unwrap_or("standard");
            if variant != "standard" && variant != "fromPosition" {
                bail!("MVP suporta apenas xadrez padrão; variante: {variant}");
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
            .context("gameState recebido antes de gameFull")?;
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
        game.position()?;
        let ended = !matches!(game.status.as_str(), "started" | "created");
        s.games.insert(id.to_owned(), game);
        self.publish(&s);
        Ok(ended)
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

    async fn command(self: &Arc<Self>, req: Value) -> Result<Value> {
        let id = req["game"].as_str().unwrap_or("");
        match req["cmd"].as_str().unwrap_or("") {
            "status" => Ok(Self::snapshot(&*self.state.lock().await)),
            "list" => Ok(Self::snapshot(&*self.state.lock().await)["games"].clone()),
            "reload_auth" => {
                self.reload().await?;
                Ok(json!("Conta atualizada"))
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
            "open" => {
                if !self.state.lock().await.games.contains_key(id) {
                    self.open_online(id.to_owned()).await?;
                }
                Ok(json!({"game":id}))
            }
            "move" => {
                let notation = req["notation"].as_str().context("Lance ausente")?;
                let mut s = self.state.lock().await;
                let game = s.games.get_mut(id).context("Partida não encontrada")?;
                if !game.online {
                    let original = game.clone();
                    game.play_local(notation)?;
                    if let Err(e) = Self::save(&s) {
                        s.games.insert(id.into(), original);
                        return Err(e);
                    }
                    self.publish(&s);
                    return Ok(json!("Lance realizado"));
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
                    return Err(e.context("Não repita o lance até a ressincronização"));
                }
                Ok(json!("Lance enviado; aguardando estado do servidor"))
            }
            "export" => Ok(json!(
                self.state
                    .lock()
                    .await
                    .games
                    .get(id)
                    .context("Partida não encontrada")?
                    .pgn()?
            )),
            "resign" | "draw" => {
                let action = req["cmd"].as_str().unwrap();
                let mut s = self.state.lock().await;
                let game = s.games.get_mut(id).context("Partida não encontrada")?;
                if game.status != "started" {
                    bail!("Partida encerrada");
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
                    return Ok(json!("Partida encerrada"));
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
                Ok(json!("Pedido enviado"))
            }
            "seek" => {
                let minutes = req["minutes"].as_u64().unwrap_or(10);
                let increment = req["increment"].as_u64().unwrap_or(5);
                if !(1..=180).contains(&minutes) || increment > 180 {
                    bail!("Ritmo inválido: minutos 1–180, incremento 0–180");
                }
                let api = self.api().await?;
                let mut task = self.seek_task.lock().await;
                if task.as_ref().is_some_and(|t| !t.is_finished()) {
                    bail!("Já existe uma busca; use cancel");
                }
                {
                    let mut s = self.state.lock().await;
                    if s.connection != "online" {
                        bail!("Aguarde a conexão de eventos com Lichess");
                    }
                    s.seeking = true;
                    self.publish(&s);
                }
                let app = self.clone();
                let rated = req["rated"] == true;
                *task = Some(tokio::spawn(async move {
                    if let Err(e) = api.seek(minutes, increment, rated).await {
                        app.notice(e.to_string());
                    }
                    let mut s = app.state.lock().await;
                    s.seeking = false;
                    app.publish(&s);
                }));
                Ok(json!("Buscando adversário"))
            }
            "cancel" => {
                if let Some(t) = self.seek_task.lock().await.take() {
                    t.abort();
                }
                let mut s = self.state.lock().await;
                s.seeking = false;
                self.publish(&s);
                Ok(json!("Busca cancelada"))
            }
            "ai" => {
                let level = req["level"].as_u64().unwrap_or(1);
                if !(1..=8).contains(&level) {
                    bail!("Nível deve ser 1–8");
                }
                let v = self
                    .api()
                    .await?
                    .post(
                        "/api/challenge/ai",
                        &[
                            ("level", level.to_string()),
                            ("clock.limit", "600".into()),
                            ("clock.increment", "5".into()),
                            ("color", "white".into()),
                        ],
                    )
                    .await?;
                let id = v["id"].as_str().context("Lichess não retornou ID")?;
                self.open_online(id.to_owned()).await?;
                Ok(json!({"game":id}))
            }
            _ => bail!("Comando desconhecido"),
        }
    }
}

fn validate_id(id: &str) -> Result<()> {
    if id.len() != 8 || !id.bytes().all(|c| c.is_ascii_alphanumeric()) {
        bail!("Use o ID público da partida (8 caracteres)");
    }
    Ok(())
}

async fn client(app: Arc<App>, stream: UnixStream) -> Result<()> {
    let (read, mut write) = stream.into_split();
    let mut reader = FramedRead::new(read, LinesCodec::new_with_max_length(16_384));
    let mut events = app.tx.subscribe();
    let initial = App::snapshot(&*app.state.lock().await);
    write.write_all(format!("{initial}\n").as_bytes()).await?;
    loop {
        let response = tokio::select! {
            read = reader.next() => {
                let Some(line) = read else { return Ok(()); };
                let req: Result<Value, _> = serde_json::from_str(&line?);
                match req {
                    Ok(req) => { let id = req["request_id"].clone(); match app.command(req).await {
                        Ok(data) => json!({"type":"reply","request_id":id,"ok":true,"data":data}),
                        Err(e) => json!({"type":"reply","request_id":id,"ok":false,"error":format!("{e:#}")})
                    } },
                    Err(_) => json!({"type":"reply","ok":false,"error":"JSON inválido"}),
                }
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
    let parent = path.parent().context("Socket sem diretório")?;
    if !parent.exists() {
        crate::private_dir(parent)?;
    }
    use std::os::unix::fs::MetadataExt;
    if std::fs::metadata(parent)?.mode() & 0o077 != 0 {
        bail!(
            "O diretório do socket deve ser privado (0700): {}",
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
        .context("Já existe um daemon para este socket")?;
    if path.exists() {
        std::fs::remove_file(&path)?;
    }
    let listener = UnixListener::bind(&path)?;
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
    let saved = crate::data_dir().join("local.json");
    let games: Vec<Game> = if saved.exists() {
        serde_json::from_slice(&std::fs::read(saved)?)
            .context("Arquivo de partidas locais inválido; preservado para recuperação")?
    } else {
        vec![]
    };
    for g in &games {
        g.position().context("Partida persistida inválida")?;
    }
    let (tx, _) = broadcast::channel(128);
    let app = Arc::new(App {
        state: Mutex::new(State {
            games: games.into_iter().map(|g| (g.id.clone(), g)).collect(),
            account: None,
            connection: "offline".into(),
            seeking: false,
        }),
        api: RwLock::new(None),
        tx,
        streams: Mutex::new(BTreeMap::new()),
        account_task: Mutex::new(None),
        seek_task: Mutex::new(None),
        reload_lock: Mutex::new(()),
    });
    if crate::config_dir().join("token").exists() {
        let a = app.clone();
        tokio::spawn(async move {
            if let Err(e) = a.reload().await {
                eprintln!("Autenticação: {e:#}");
                a.notice(e.to_string());
            }
        });
    }
    eprintln!("Gambito escutando em {}", path.display());
    let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
    loop {
        tokio::select! {
            connection = listener.accept() => { let (stream, _) = connection?; let a = app.clone(); tokio::spawn(async move { if let Err(e) = client(a, stream).await { eprintln!("Cliente: {e}"); } }); },
            _ = tokio::signal::ctrl_c() => break,
            _ = term.recv() => break,
        }
    }
    std::fs::remove_file(path)?;
    drop(lock);
    Ok(())
}
