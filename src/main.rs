mod game;
mod lichess;
mod server;

use anyhow::{Context, Result, bail};
use clap::{Parser, Subcommand};
use serde_json::{Value, json};
use std::{io::Read, os::unix::fs::PermissionsExt, path::PathBuf};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    net::UnixStream,
};

#[derive(Parser)]
#[command(
    version,
    about = "Xadrez em janelas independentes, com um daemon compartilhado"
)]
struct Args {
    #[arg(long, global = true, help = "Saída JSON para scripts")]
    json: bool,
    #[command(subcommand)]
    command: Command,
}
#[derive(Subcommand)]
enum Command {
    Daemon,
    /// Lê token de stdin, valida no Lichess e salva com permissão 0600
    Auth,
    List,
    /// Cria uma partida local para duas pessoas no mesmo computador
    Local,
    /// Abre uma janela; sem ID abre a lista de partidas
    Open {
        game: Option<String>,
    },
    Move {
        game: String,
        notation: String,
    },
    /// Busca adversário (minutos, incremento); casual por padrão
    Seek {
        #[arg(default_value_t = 10)]
        minutes: u32,
        #[arg(default_value_t = 5)]
        increment: u32,
        #[arg(long)]
        rated: bool,
    },
    Cancel,
    /// Desafia a IA do Lichess (nível 1 a 8)
    Ai {
        #[arg(default_value_t = 1)]
        level: u8,
    },
    /// Desiste de uma partida
    Resign {
        game: String,
        #[arg(long)]
        yes: bool,
    },
    /// Oferece/aceita empate
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
            .context("XDG_RUNTIME_DIR ausente; defina GAMBITO_SOCKET")?,
    )
    .join("gambito/socket"))
}
pub fn private_dir(path: &std::path::Path) -> Result<()> {
    std::fs::create_dir_all(path)?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))?;
    Ok(())
}

pub async fn request(value: Value) -> Result<Value> {
    let mut stream = UnixStream::connect(socket_path()?)
        .await
        .context("Daemon indisponível. Execute: gambito daemon")?;
    stream.write_all(format!("{}\n", value).as_bytes()).await?;
    let mut lines = BufReader::new(stream).lines();
    loop {
        let line = tokio::time::timeout(std::time::Duration::from_secs(40), lines.next_line())
            .await??
            .context("Daemon desconectado")?;
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
        "Daemon não iniciou; consulte {}/daemon.log",
        data_dir().display()
    )
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();
    let cmd = match args.command {
        Command::Daemon => return server::run().await,
        Command::Auth => {
            eprintln!(
                "Token Lichess com board:play e challenge:write; cole e finalize com Ctrl-D:"
            );
            let mut token = String::new();
            std::io::stdin().read_to_string(&mut token)?;
            let token = token.trim();
            if token.is_empty() {
                bail!("Token vazio");
            }
            let api = lichess::Api::new(token.to_owned())?;
            let account = api.get("/api/account").await?;
            private_dir(&config_dir())?;
            use std::os::unix::fs::OpenOptionsExt;
            let mut file = std::fs::OpenOptions::new()
                .write(true)
                .create(true)
                .truncate(true)
                .mode(0o600)
                .open(config_dir().join("token"))?;
            std::io::Write::write_all(&mut file, token.as_bytes())?;
            std::fs::set_permissions(
                config_dir().join("token"),
                std::fs::Permissions::from_mode(0o600),
            )?;
            ensure_daemon().await?;
            request(json!({"cmd":"reload_auth"})).await?;
            println!(
                "Conectado como {}",
                account["username"].as_str().unwrap_or("usuário")
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
            let child = std::process::Command::new("quickshell")
                .arg("--daemonize")
                .arg("--path")
                .arg(ui)
                .env("GAMBITO_BIN", std::env::current_exe()?)
                .env("GAMBITO_SOCKET", socket_path()?)
                .env("GAMBITO_GAME", game.unwrap_or_default())
                .spawn()
                .context("Não foi possível abrir Quickshell")?;
            println!("Janela iniciada (PID {})", child.id());
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
        Command::Cancel => json!({"cmd":"cancel"}),
        Command::Ai { level } => json!({"cmd":"ai","level":level}),
        Command::Resign { game, yes } => {
            if !yes {
                bail!("Confirme com --yes");
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
