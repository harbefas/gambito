//! Download and install a published Gambito release.
use anyhow::{Context, Result, bail, ensure};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{fs, os::unix::fs::PermissionsExt, path::{Path, PathBuf}, process::Command};

const API: &str = "https://api.github.com/repos/harbefas/gambito/releases/latest";

fn asset_name() -> Result<&'static str> {
    match std::env::consts::ARCH {
        "x86_64" => Ok("gambito-linux-x86_64.tar.gz"),
        arch => bail!("No published Gambito release for architecture {arch}"),
    }
}

fn command_status(program: &str, args: &[&str]) -> Result<()> {
    let status = Command::new(program).args(args).status().with_context(|| format!("Could not run {program}"))?;
    ensure!(status.success(), "{program} failed");
    Ok(())
}

fn install_tree(root: &Path, executable: &Path) -> Result<()> {
    let binary = root.join("gambito");
    let ui = root.join("ui");
    ensure!(binary.is_file() && ui.is_dir(), "Release archive is missing the binary or UI");
    let install_dir = executable.parent().context("Installed binary has no parent directory")?;
    let target_ui = std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(std::env::var_os("HOME").unwrap()).join(".local/share"))
        .join("gambito/ui");
    fs::create_dir_all(&target_ui)?;
    for entry in fs::read_dir(&ui)? {
        let entry = entry?;
        fs::copy(entry.path(), target_ui.join(entry.file_name()))?;
    }
    let staged = install_dir.join(".gambito-update");
    fs::copy(binary, &staged)?;
    let mut permissions = fs::metadata(&staged)?.permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(&staged, permissions)?;
    fs::rename(staged, executable)?;
    Ok(())
}

pub async fn run() -> Result<()> {
    let client = reqwest::Client::builder().user_agent(concat!("gambito/", env!("CARGO_PKG_VERSION"))).build()?;
    let release: Value = client.get(API).send().await?.error_for_status()?.json().await?;
    let tag = release["tag_name"].as_str().context("Latest release has no tag")?;
    let asset = asset_name()?;
    let assets = release["assets"].as_array().context("Latest release has no assets")?;
    let package = assets.iter().find(|a| a["name"] == asset).context(format!("Latest release has no {asset}"))?;
    let checksum_name = format!("{asset}.sha256");
    let checksum_asset = assets.iter().find(|a| a["name"] == checksum_name).context("Latest release has no checksum")?;
    let archive = client.get(package["browser_download_url"].as_str().context("Release package has no URL")?).send().await?.error_for_status()?.bytes().await?;
    let expected = client.get(checksum_asset["browser_download_url"].as_str().context("Checksum has no URL")?).send().await?.error_for_status()?.text().await?;
    let expected = expected.split_whitespace().next().context("Checksum is empty")?.to_ascii_lowercase();
    let actual = Sha256::digest(&archive).iter().map(|byte| format!("{byte:02x}")).collect::<String>();
    ensure!(actual == expected, "Release checksum mismatch");
    let base = std::env::var_os("XDG_CACHE_HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from(std::env::var_os("HOME").unwrap()).join(".cache")).join("gambito/update");
    if base.exists() { fs::remove_dir_all(&base)?; }
    fs::create_dir_all(&base)?;
    let archive_path = base.join(asset);
    fs::write(&archive_path, &archive)?;
    command_status("tar", &["-xzf", archive_path.to_str().context("Invalid archive path")?, "-C", base.to_str().context("Invalid cache path")?])?;
    let current = std::env::current_exe()?;
    let service_was_active = Command::new("systemctl").args(["--user", "is-active", "--quiet", "gambito.service"]).status().is_ok_and(|s| s.success());
    if service_was_active { let _ = Command::new("systemctl").args(["--user", "stop", "gambito.service"]).status(); }
    let result = install_tree(&base, &current);
    if service_was_active { let _ = Command::new("systemctl").args(["--user", "start", "gambito.service"]).status(); }
    result?;
    println!("Updated Gambito to {tag}");
    Ok(())
}
