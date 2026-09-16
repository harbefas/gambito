use anyhow::{Context, Result, bail};
use futures_util::StreamExt;
use serde_json::Value;
use std::time::Duration;

#[derive(Clone)]
pub struct Api {
    client: reqwest::Client,
    token: String,
    base: String,
}
impl Api {
    pub fn new(token: String) -> Result<Self> {
        // A loopback override supports integration tests without touching real accounts.
        let base =
            std::env::var("GAMBITO_API_URL").unwrap_or_else(|_| "https://lichess.org".into());
        let url: reqwest::Url = base.parse()?;
        if base != "https://lichess.org"
            && !matches!(url.host_str(), Some("127.0.0.1" | "localhost" | "[::1]"))
        {
            bail!("GAMBITO_API_URL aceita apenas loopback para testes");
        }
        let client = reqwest::Client::builder()
            .user_agent("gambito/0.1 (personal Board API client)")
            .redirect(reqwest::redirect::Policy::none())
            .connect_timeout(Duration::from_secs(15))
            .build()?;
        Ok(Self {
            client,
            token,
            base,
        })
    }
    async fn check(response: reqwest::Response) -> Result<reqwest::Response> {
        let status = response.status();
        if status.is_success() {
            return Ok(response);
        }
        if status.as_u16() == 429 {
            bail!("Lichess limitou as requisições (429); aguarde um minuto");
        }
        if status.as_u16() == 401 || status.as_u16() == 403 {
            bail!("Autenticação/permissão recusada ({status}); confira o token e board:play");
        }
        let body: Value = response.json().await.unwrap_or_default();
        bail!(
            "Lichess {status}: {}",
            body["error"].as_str().unwrap_or("requisição recusada")
        )
    }
    pub async fn get(&self, path: &str) -> Result<Value> {
        Ok(Self::check(
            self.client
                .get(format!("{}{path}", self.base))
                .bearer_auth(&self.token)
                .timeout(Duration::from_secs(25))
                .send()
                .await?,
        )
        .await?
        .json()
        .await?)
    }
    pub async fn post(&self, path: &str, form: &[(&str, String)]) -> Result<Value> {
        Ok(Self::check(
            self.client
                .post(format!("{}{path}", self.base))
                .bearer_auth(&self.token)
                .form(form)
                .timeout(Duration::from_secs(25))
                .send()
                .await?,
        )
        .await?
        .json()
        .await?)
    }
    pub async fn stream(&self, path: &str) -> Result<reqwest::Response> {
        Self::check(
            self.client
                .get(format!("{}{path}", self.base))
                .bearer_auth(&self.token)
                .send()
                .await?,
        )
        .await
    }
    pub async fn seek(&self, minutes: u64, increment: u64, rated: bool) -> Result<()> {
        let response = Self::check(
            self.client
                .post(format!("{}/api/board/seek", self.base))
                .bearer_auth(&self.token)
                .form(&[
                    ("time", minutes.to_string()),
                    ("increment", increment.to_string()),
                    ("rated", rated.to_string()),
                    ("variant", "standard".into()),
                ])
                .send()
                .await?,
        )
        .await?;
        let mut stream = response.bytes_stream();
        while let Some(chunk) = tokio::time::timeout(Duration::from_secs(60), stream.next()).await?
        {
            chunk?;
        }
        Ok(())
    }
}

/// Accepts fragmented UTF-8 / multiple records per chunk. Blank records are keepalives.
pub async fn records(
    response: reqwest::Response,
    tx: tokio::sync::mpsc::Sender<Value>,
) -> Result<()> {
    let mut stream = response.bytes_stream();
    let mut buffer = Vec::new();
    while let Some(chunk) = tokio::time::timeout(Duration::from_secs(45), stream.next())
        .await
        .context("Stream sem resposta")?
    {
        buffer.extend_from_slice(&chunk?);
        if buffer.len() > 2_000_000 {
            bail!("Registro remoto excede o limite");
        }
        while let Some(end) = buffer.iter().position(|&b| b == b'\n') {
            let line: Vec<u8> = buffer.drain(..=end).collect();
            if line.iter().all(u8::is_ascii_whitespace) {
                continue;
            }
            let value = serde_json::from_slice(&line).context("Evento JSON inválido")?;
            if tx.send(value).await.is_err() {
                return Ok(());
            }
        }
    }
    bail!("Stream encerrado; reconectando")
}
