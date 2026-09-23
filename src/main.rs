mod cache;
mod claude;
mod codex;
mod format;
mod http;
mod model;
mod ui;

use std::path::PathBuf;

use anyhow::Context;

fn main() -> anyhow::Result<()> {
    let home = PathBuf::from(std::env::var_os("HOME").context("HOME is not set")?);
    let cache_dir = std::env::var_os("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| home.join(".cache"));
    ui::run(home, cache_dir.join("ai-usage-pane.json"))
}
