use std::path::Path;

use anyhow::{Context, Result};
use chrono::{DateTime, Utc};
use serde::Deserialize;

use crate::model::{Usage, Window};

const USAGE_URL: &str = "https://chatgpt.com/backend-api/wham/usage";
const EXPIRED: &str = "token expired, open codex";
const FIVE_HOURS_SECS: u64 = 5 * 3600;
const WEEK_SECS: u64 = 7 * 24 * 3600;

#[derive(Deserialize)]
struct Auth {
    tokens: Tokens,
}

#[derive(Deserialize)]
struct Tokens {
    access_token: String,
    account_id: String,
}

#[derive(Deserialize)]
struct Response {
    rate_limit: RateLimit,
}

#[derive(Deserialize)]
struct RateLimit {
    primary_window: Option<RawWindow>,
    secondary_window: Option<RawWindow>,
}

#[derive(Deserialize)]
struct RawWindow {
    used_percent: f64,
    limit_window_seconds: u64,
    #[serde(with = "chrono::serde::ts_seconds")]
    reset_at: DateTime<Utc>,
}

pub fn parse(body: &str) -> Result<Usage> {
    let r: Response = serde_json::from_str(body).context("unexpected response")?;
    let mut usage = Usage::default();
    // Classify by window length rather than trusting primary/secondary order.
    for w in [r.rate_limit.primary_window, r.rate_limit.secondary_window]
        .into_iter()
        .flatten()
    {
        let window = Window {
            used_percent: w.used_percent,
            resets_at: Some(w.reset_at),
        };
        match w.limit_window_seconds {
            FIVE_HOURS_SECS => usage.five_hour = Some(window),
            WEEK_SECS => usage.weekly = Some(window),
            _ => {}
        }
    }
    Ok(usage)
}

pub fn fetch(home: &Path) -> Result<Usage> {
    let auth =
        std::fs::read_to_string(home.join(".codex/auth.json")).context("not logged in to codex")?;
    let auth: Auth = serde_json::from_str(&auth).context("bad codex auth file")?;
    let body = crate::http::get(
        USAGE_URL,
        &[
            (
                "Authorization",
                &format!("Bearer {}", auth.tokens.access_token),
            ),
            ("ChatGPT-Account-Id", &auth.tokens.account_id),
            ("User-Agent", "codex-cli"),
        ],
        EXPIRED,
    )?;
    parse(&body)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_real_shape() {
        let body = r#"{"plan_type":"plus","rate_limit":{"allowed":true,
            "primary_window":{"used_percent":28,"limit_window_seconds":18000,"reset_after_seconds":3514,"reset_at":1790182412},
            "secondary_window":{"used_percent":79,"limit_window_seconds":604800,"reset_after_seconds":315376,"reset_at":1790494274}},
            "additional_rate_limits":[]}"#;
        let u = parse(body).unwrap();
        let five = u.five_hour.unwrap();
        assert_eq!(five.used_percent, 28.0);
        assert_eq!(five.resets_at.unwrap().timestamp(), 1790182412);
        let week = u.weekly.unwrap();
        assert_eq!(week.used_percent, 79.0);
        assert_eq!(week.resets_at.unwrap().timestamp(), 1790494274);
    }

    #[test]
    fn classifies_by_window_length_not_order() {
        let body = r#"{"rate_limit":{
            "primary_window":{"used_percent":79,"limit_window_seconds":604800,"reset_at":2},
            "secondary_window":{"used_percent":28,"limit_window_seconds":18000,"reset_at":1}}}"#;
        let u = parse(body).unwrap();
        assert_eq!(u.five_hour.unwrap().used_percent, 28.0);
        assert_eq!(u.weekly.unwrap().used_percent, 79.0);
    }

    #[test]
    fn missing_and_unknown_windows() {
        let body = r#"{"rate_limit":{"primary_window":{"used_percent":5,"limit_window_seconds":60,"reset_at":1},"secondary_window":null}}"#;
        assert_eq!(parse(body).unwrap(), Usage::default());
    }
}
