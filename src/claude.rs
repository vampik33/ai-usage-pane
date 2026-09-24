use std::path::Path;

use anyhow::{Context, Result, bail};
use chrono::{DateTime, Utc};
use serde::Deserialize;

use crate::model::{Usage, Window};

const USAGE_URL: &str = "https://api.anthropic.com/api/oauth/usage";
const EXPIRED: &str = "token expired, open claude";

#[derive(Deserialize)]
struct Credentials {
    #[serde(rename = "claudeAiOauth")]
    oauth: OAuth,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct OAuth {
    access_token: String,
    #[serde(with = "chrono::serde::ts_milliseconds")]
    expires_at: DateTime<Utc>,
}

#[derive(Deserialize)]
struct Response {
    five_hour: Option<RawWindow>,
    seven_day: Option<RawWindow>,
}

#[derive(Deserialize)]
struct RawWindow {
    utilization: f64,
    resets_at: Option<DateTime<Utc>>,
}

impl From<RawWindow> for Window {
    fn from(w: RawWindow) -> Self {
        Window {
            used_percent: w.utilization,
            resets_at: w.resets_at,
        }
    }
}

/// Extracts the access token. Never refreshes it: refreshing rotates the
/// refresh token and would log Claude Code out.
pub fn access_token(credentials_json: &str, now: DateTime<Utc>) -> Result<String> {
    let creds: Credentials =
        serde_json::from_str(credentials_json).context("bad credentials file")?;
    if now >= creds.oauth.expires_at {
        bail!(EXPIRED);
    }
    Ok(creds.oauth.access_token)
}

pub fn parse(body: &str) -> Result<Usage> {
    let r: Response = serde_json::from_str(body).context("unexpected response")?;
    Ok(Usage {
        five_hour: r.five_hour.map(Window::from),
        weekly: r.seven_day.map(Window::from),
    })
}

pub fn fetch(home: &Path, now: DateTime<Utc>) -> Result<Usage> {
    let creds = std::fs::read_to_string(home.join(".claude/.credentials.json"))
        .context("not logged in to claude")?;
    let token = access_token(&creds, now)?;
    let body = crate::http::get(
        USAGE_URL,
        &[
            ("Authorization", &format!("Bearer {token}")),
            ("anthropic-beta", "oauth-2025-04-20"),
        ],
        EXPIRED,
    )?;
    parse(&body)
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    #[test]
    fn parses_real_shape() {
        let body = r#"{"five_hour":{"utilization":12.0,"resets_at":"2026-09-23T19:59:59.776412+00:00","limit_dollars":null},
            "seven_day":{"utilization":33.0,"resets_at":"2026-09-29T04:59:59.776434+00:00"},
            "seven_day_opus":null,"limits":[]}"#;
        let u = parse(body).unwrap();
        let five = u.five_hour.unwrap();
        assert_eq!(five.used_percent, 12.0);
        assert_eq!(
            five.resets_at.unwrap().timestamp(),
            Utc.with_ymd_and_hms(2026, 9, 23, 19, 59, 59)
                .unwrap()
                .timestamp()
        );
        assert_eq!(u.weekly.unwrap().used_percent, 33.0);
    }

    #[test]
    fn parses_null_windows_and_resets() {
        let body = r#"{"five_hour":{"utilization":0.0,"resets_at":null},"seven_day":null}"#;
        let u = parse(body).unwrap();
        assert_eq!(u.five_hour.unwrap().resets_at, None);
        assert_eq!(u.weekly, None);
    }

    #[test]
    fn rejects_garbage() {
        assert!(parse("<html>").is_err());
    }

    #[test]
    fn token_valid_and_expired() {
        let creds =
            r#"{"claudeAiOauth":{"accessToken":"tok","expiresAt":2000,"refreshToken":"r"}}"#;
        let before = Utc.timestamp_millis_opt(1999).unwrap();
        let at = Utc.timestamp_millis_opt(2000).unwrap();
        assert_eq!(access_token(creds, before).unwrap(), "tok");
        assert_eq!(access_token(creds, at).unwrap_err().to_string(), EXPIRED);
    }
}
