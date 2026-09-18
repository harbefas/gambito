use anyhow::{Context, Result, bail};
use futures_util::StreamExt;
use serde_json::Value;
use std::time::Duration;

#[derive(Clone)]
pub struct Api {
    client: reqwest::Client,
    token: String,
    base: String,
    explorer: String,
}

/// Production host, or a loopback override for integration tests.
fn endpoint(variable: &str, production: &str) -> Result<String> {
    let base = std::env::var(variable).unwrap_or_else(|_| production.into());
    let url: reqwest::Url = base.parse()?;
    if base != production && !matches!(url.host_str(), Some("127.0.0.1" | "localhost" | "[::1]")) {
        bail!("{variable} only accepts loopback, for tests");
    }
    Ok(base)
}
impl Api {
    pub fn new(token: String) -> Result<Self> {
        // Loopback overrides support integration tests without touching real accounts.
        let base = endpoint("GAMBITO_API_URL", "https://lichess.org")?;
        let explorer = endpoint("GAMBITO_EXPLORER_URL", "https://explorer.lichess.ovh")?;
        let client = reqwest::Client::builder()
            .user_agent("gambito/0.1 (personal Board API client)")
            .redirect(reqwest::redirect::Policy::none())
            .connect_timeout(Duration::from_secs(15))
            .build()?;
        Ok(Self {
            client,
            token,
            base,
            explorer,
        })
    }
    pub async fn explorer_text(&self, path: &str) -> Result<String> {
        Ok(Self::check(
            self.client
                .get(format!("{}{path}", self.explorer))
                .bearer_auth(&self.token)
                .timeout(Duration::from_secs(25))
                .send()
                .await?,
        )
        .await?
        .text()
        .await?)
    }
    /// Opening explorer (`/masters` or `/lichess`); Lichess requires a signed-in token for it.
    pub async fn explorer(&self, path: &str) -> Result<Value> {
        Ok(Self::check(
            self.client
                .get(format!("{}{path}", self.explorer))
                .bearer_auth(&self.token)
                .timeout(Duration::from_secs(25))
                .send()
                .await?,
        )
        .await?
        .json()
        .await?)
    }
    /// Cached cloud evaluation; None when Lichess has none for this position.
    pub async fn cloud_eval(&self, fen: &str) -> Result<Option<Value>> {
        let mut request = self
            .client
            .get(reqwest::Url::parse_with_params(
                &format!("{}/api/cloud-eval", self.base),
                [("fen", fen)],
            )?)
            .timeout(Duration::from_secs(10));
        if !self.token.is_empty() {
            request = request.bearer_auth(&self.token);
        }
        let response = request.send().await?;
        if response.status().as_u16() == 404 {
            return Ok(None);
        }
        Ok(Some(Self::check(response).await?.json().await?))
    }
    pub fn base(&self) -> &str {
        &self.base
    }
    /// OAuth PKCE: trades the authorization code for an access token.
    pub async fn exchange_code(
        &self,
        code: &str,
        verifier: &str,
        redirect: &str,
    ) -> Result<String> {
        let form = [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("code_verifier", verifier),
            ("redirect_uri", redirect),
            ("client_id", crate::OAUTH_CLIENT_ID),
        ];
        let body: Value = Self::check(
            self.client
                .post(format!("{}/api/token", self.base))
                .form(&form)
                .timeout(Duration::from_secs(25))
                .send()
                .await?,
        )
        .await?
        .json()
        .await?;
        Ok(body["access_token"]
            .as_str()
            .context("Lichess returned no access token")?
            .to_owned())
    }
    async fn check(response: reqwest::Response) -> Result<reqwest::Response> {
        let status = response.status();
        if status.is_success() {
            return Ok(response);
        }
        if status.as_u16() == 429 {
            bail!("Lichess rate limited requests (429); wait a minute");
        }
        let body: Value = response.json().await.unwrap_or_default();
        if status.as_u16() == 401 || status.as_u16() == 403 {
            // Tokens from before a scope was added keep their old permissions until the next login.
            if let Some(scope) = body["error"]
                .as_str()
                .and_then(|e| e.strip_prefix("Missing scope: "))
            {
                bail!("Lichess permission missing ({scope}): sign out and connect Lichess again");
            }
            bail!(
                "Auth/permission denied ({status}); connect Lichess again and grant the requested permissions"
            );
        }
        bail!(
            "Lichess {status}: {}",
            body["error"].as_str().unwrap_or("request refused")
        )
    }
    pub async fn get(&self, path: &str) -> Result<Value> {
        Ok(Self::check(
            self.client
                .get(format!("{}{path}", self.base))
                .bearer_auth(&self.token)
                .header("Accept", "application/json")
                .timeout(Duration::from_secs(25))
                .send()
                .await?,
        )
        .await?
        .json()
        .await?)
    }
    /// Non-JSON resources such as Atom feeds.
    pub async fn get_text(&self, path: &str) -> Result<String> {
        Ok(Self::check(
            self.client
                .get(format!("{}{path}", self.base))
                .timeout(Duration::from_secs(25))
                .send()
                .await?,
        )
        .await?
        .text()
        .await?)
    }
    /// Authenticated PGN export for broadcast chapters.
    pub async fn broadcast_pgn(&self, round: &str, chapter: &str) -> Result<String> {
        Ok(Self::check(
            self.client
                .get(format!("{}/api/study/{round}/{chapter}.pgn", self.base))
                .bearer_auth(&self.token)
                .timeout(Duration::from_secs(25))
                .send()
                .await?,
        )
        .await?
        .text()
        .await?)
    }
    pub async fn post_json(&self, path: &str, body: &Value) -> Result<Value> {
        Ok(Self::check(
            self.client
                .post(format!("{}{path}", self.base))
                .bearer_auth(&self.token)
                .json(body)
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
                .header("Accept", "application/x-ndjson")
                .send()
                .await?,
        )
        .await
    }
    /// Real-time seeks stream until paired; correspondence seeks return at once.
    pub async fn seek(&self, form: &[(&str, String)]) -> Result<()> {
        let response = Self::check(
            self.client
                .post(format!("{}/api/board/seek", self.base))
                .bearer_auth(&self.token)
                .form(form)
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
        .context("Stream not responding")?
    {
        buffer.extend_from_slice(&chunk?);
        if buffer.len() > 2_000_000 {
            bail!("Remote record exceeds size limit");
        }
        while let Some(end) = buffer.iter().position(|&b| b == b'\n') {
            let line: Vec<u8> = buffer.drain(..=end).collect();
            if line.iter().all(u8::is_ascii_whitespace) {
                continue;
            }
            let value = serde_json::from_slice(&line).context("Invalid JSON event")?;
            if tx.send(value).await.is_err() {
                return Ok(());
            }
        }
    }
    bail!("Stream closed; reconnecting")
}
