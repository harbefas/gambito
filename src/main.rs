mod broadcast;
mod engine;
mod game;
mod lichess;
mod server;
mod study;
mod update;

use anyhow::{Context, Result, bail};
use clap::{Parser, Subcommand};
use serde_json::{Value, json};
use std::{io::Read, os::unix::fs::PermissionsExt, path::PathBuf};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    net::UnixStream,
};

#[derive(Parser)]
#[command(version, about = "Chess in independent windows, with a shared daemon")]
struct Args {
    #[arg(long, global = true, help = "JSON output for scripts")]
    json: bool,
    #[command(subcommand)]
    command: Command,
}
#[derive(Subcommand)]
enum Command {
    Daemon,
    /// Download and install the latest published release
    Update,
    /// Read token from stdin, validate on Lichess, save with mode 0600
    Auth,
    List,
    /// Create a local game for two players on this machine
    Local,
    /// Open a window; without ID opens the game list
    Open {
        game: Option<String>,
    },
    Move {
        game: String,
        notation: String,
    },
    /// Seek an opponent (minutes, increment); casual by default
    Seek {
        #[arg(default_value_t = 10)]
        minutes: u32,
        #[arg(default_value_t = 5)]
        increment: u32,
        #[arg(long)]
        rated: bool,
    },
    /// List pending invitations
    Challenges,
    /// Challenge a player (Blitz or slower)
    Challenge {
        username: String,
        #[arg(long, default_value_t = 10)]
        minutes: u32,
        #[arg(long, default_value_t = 5)]
        increment: u32,
        #[arg(long)]
        days: Option<u8>,
        #[arg(long, default_value = "random")]
        color: String,
        #[arg(long)]
        rated: bool,
    },
    Accept {
        challenge: String,
    },
    Decline {
        challenge: String,
    },
    CancelChallenge {
        challenge: String,
    },
    /// Send a player-chat message; omit text to read the history
    Chat {
        game: String,
        text: Option<String>,
    },
    /// Request or accept a takeback, or decline with --decline
    Takeback {
        game: String,
        #[arg(long)]
        decline: bool,
    },
    Cancel,
    /// Challenge the Lichess AI (level 1 to 8)
    Ai {
        #[arg(default_value_t = 1)]
        level: u8,
    },
    /// Resign a game
    Resign {
        game: String,
        #[arg(long)]
        yes: bool,
    },
    /// Offer/accept a draw
    Draw {
        game: String,
    },
    Export {
        game: String,
    },
    Watch,
    Status,
}

pub fn config_dir() -> PathBuf {
    std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(std::env::var_os("HOME").unwrap()).join(".config"))
        .join("gambito")
}
pub fn data_dir() -> PathBuf {
    std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(std::env::var_os("HOME").unwrap()).join(".local/share"))
        .join("gambito")
}
pub fn socket_path() -> Result<PathBuf> {
    if let Some(p) = std::env::var_os("GAMBITO_SOCKET") {
        return Ok(p.into());
    }
    Ok(PathBuf::from(
        std::env::var_os("XDG_RUNTIME_DIR")
            .context("XDG_RUNTIME_DIR missing; set GAMBITO_SOCKET")?,
    )
    .join("gambito/socket"))
}
pub const OAUTH_CLIENT_ID: &str = "gambito";

pub fn save_token(token: &str) -> Result<()> {
    use std::os::unix::fs::OpenOptionsExt;
    private_dir(&config_dir())?;
    let path = config_dir().join("token");
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&path)?;
    std::io::Write::write_all(&mut file, token.as_bytes())?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    Ok(())
}
pub fn private_dir(path: &std::path::Path) -> Result<()> {
    std::fs::create_dir_all(path)?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))?;
    Ok(())
}

pub async fn request(value: Value) -> Result<Value> {
    let mut stream = UnixStream::connect(socket_path()?)
        .await
        .context("Daemon unavailable. Run: gambito daemon")?;
    stream.write_all(format!("{}\n", value).as_bytes()).await?;
    let mut lines = BufReader::new(stream).lines();
    loop {
        let line = tokio::time::timeout(std::time::Duration::from_secs(40), lines.next_line())
            .await??
            .context("Daemon disconnected")?;
        let v: Value = serde_json::from_str(&line)?;
        if v["type"] == "reply" {
            if v["ok"] == false {
                bail!("{}", v["error"].as_str().unwrap_or("Erro"));
            }
            return Ok(v["data"].clone());
        }
    }
}

async fn ensure_daemon() -> Result<()> {
    if UnixStream::connect(socket_path()?).await.is_ok() {
        return Ok(());
    }
    private_dir(&data_dir())?;
    let log = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(data_dir().join("daemon.log"))?;
    std::process::Command::new(std::env::current_exe()?)
        .arg("daemon")
        .stdin(std::process::Stdio::null())
        .stdout(log.try_clone()?)
        .stderr(log)
        .spawn()?;
    for _ in 0..60 {
        if UnixStream::connect(socket_path()?).await.is_ok() {
            return Ok(());
        }
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
    bail!(
        "Daemon did not start; see {}/daemon.log",
        data_dir().display()
    )
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();
    let cmd = match args.command {
        Command::Daemon => return server::run().await,
        Command::Update => return update::run().await,
        Command::Auth => {
            eprintln!(
                "Lichess token with board:play and challenge:write; paste and finish with Ctrl-D:"
            );
            let mut token = String::new();
            std::io::stdin().read_to_string(&mut token)?;
            let token = token.trim();
            if token.is_empty() {
                bail!("Empty token");
            }
            let api = lichess::Api::new(token.to_owned())?;
            let account = api.get("/api/account").await?;
            save_token(token)?;
            ensure_daemon().await?;
            request(json!({"cmd":"reload_auth"})).await?;
            println!(
                "Connected as {}",
                account["username"].as_str().unwrap_or("user")
            );
            return Ok(());
        }
        Command::Open { game } => {
            ensure_daemon().await?;
            if let Some(id) = &game {
                request(json!({"cmd":"open", "game":id})).await?;
            }
            let ui = std::env::var_os("GAMBITO_UI")
                .map(PathBuf::from)
                .unwrap_or_else(|| {
                    let installed = data_dir().join("ui");
                    if installed.exists() {
                        installed
                    } else {
                        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("ui")
                    }
                });
            // Reuse a running UI process: another window costs a few MB instead of a new
            // ~250 MB Quickshell instance. Exit status is non-zero when none is running.
            let mut ipc = std::process::Command::new("quickshell");
            ipc.args(["ipc", "--path"])
                .arg(&ui)
                .args(["call", "gambito"]);
            match &game {
                Some(id) => ipc.args(["open", id]),
                None => ipc.arg("lobby"),
            };
            let reused = ipc
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .status()
                .is_ok_and(|status| status.success());
            if reused {
                println!("Window opened in the running UI");
                return Ok(());
            }
            let mut command = std::process::Command::new("quickshell");
            // CPU rendering saves ~30 MB per UI process (no GL context); a mostly static
            // board does not need the GPU. Set QT_QUICK_BACKEND to override.
            if std::env::var_os("QT_QUICK_BACKEND").is_none() {
                command.env("QT_QUICK_BACKEND", "software");
            }
            let child = command
                .arg("--daemonize")
                .arg("--path")
                .arg(ui)
                .env("GAMBITO_SOCKET", socket_path()?)
                .env("GAMBITO_GAME", game.unwrap_or_default())
                .spawn()
                .context("Could not start Quickshell")?;
            println!("Window started (PID {})", child.id());
            return Ok(());
        }
        Command::Watch => {
            let stream = UnixStream::connect(socket_path()?).await?;
            let mut lines = BufReader::new(stream).lines();
            while let Some(line) = lines.next_line().await? {
                println!("{line}");
            }
            return Ok(());
        }
        Command::List => json!({"cmd":"list"}),
        Command::Local => {
            ensure_daemon().await?;
            json!({"cmd":"local"})
        }
        Command::Status => json!({"cmd":"status"}),
        Command::Move { game, notation } => json!({"cmd":"move","game":game,"notation":notation}),
        Command::Seek {
            minutes,
            increment,
            rated,
        } => json!({"cmd":"seek","minutes":minutes,"increment":increment,"rated":rated}),
        Command::Challenges => {
            request(json!({"cmd":"challenges"})).await?;
            let state = request(json!({"cmd":"status"})).await?;
            println!("{}", state["challenges"]);
            return Ok(());
        }
        Command::Challenge {
            username,
            minutes,
            increment,
            days,
            color,
            rated,
        } => {
            json!({"cmd":"challenge", "username":username, "minutes":minutes, "increment":increment, "days":days, "color":color, "rated":rated})
        }
        Command::Accept { challenge } => json!({"cmd":"challenge_accept", "challenge":challenge}),
        Command::Decline { challenge } => json!({"cmd":"challenge_decline", "challenge":challenge}),
        Command::CancelChallenge { challenge } => {
            json!({"cmd":"challenge_cancel", "challenge":challenge})
        }
        Command::Chat { game, text } => {
            json!({"cmd":if text.is_some() {"chat"} else {"chat_history"}, "game":game, "text":text})
        }
        Command::Takeback { game, decline } => {
            json!({"cmd":"takeback", "game":game, "accept":!decline})
        }
        Command::Cancel => json!({"cmd":"cancel"}),
        Command::Ai { level } => json!({"cmd":"ai","level":level}),
        Command::Resign { game, yes } => {
            if !yes {
                bail!("Confirm with --yes");
            }
            json!({"cmd":"resign","game":game})
        }
        Command::Draw { game } => json!({"cmd":"draw","game":game}),
        Command::Export { game } => {
            let v = request(json!({"cmd":"export","game":game})).await?;
            print!("{}", v.as_str().unwrap_or(""));
            return Ok(());
        }
    };
    let data = request(cmd).await?;
    if args.json {
        println!("{data}");
    } else if let Some(items) = data.as_array() {
        for g in items {
            println!(
                "{}  {} × {}  [{}]",
                g["id"].as_str().unwrap_or(""),
                g["white"].as_str().unwrap_or(""),
                g["black"].as_str().unwrap_or(""),
                g["status"].as_str().unwrap_or("")
            );
        }
    } else {
        println!("{}", serde_json::to_string_pretty(&data)?);
    }
    Ok(())
}
