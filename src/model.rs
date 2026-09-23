use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

/// One rate-limit window (5-hour or weekly).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Window {
    /// 0..=100
    pub used_percent: f64,
    /// `None` when the window has not started yet (no usage in it).
    pub resets_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
pub struct Usage {
    pub five_hour: Option<Window>,
    pub weekly: Option<Window>,
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
pub struct ProviderState {
    /// Last successfully fetched usage; kept when a later fetch fails.
    pub usage: Option<Usage>,
    pub updated_at: Option<DateTime<Utc>>,
    /// Error from the most recent fetch, if it failed.
    pub error: Option<String>,
}

impl ProviderState {
    pub fn apply(&mut self, result: anyhow::Result<Usage>, now: DateTime<Utc>) {
        match result {
            Ok(usage) => {
                self.usage = Some(usage);
                self.updated_at = Some(now);
                self.error = None;
            }
            Err(e) => self.error = Some(e.to_string()),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
pub struct Snapshot {
    pub claude: ProviderState,
    pub codex: ProviderState,
    /// When a fetch was last attempted (successful or not).
    pub attempted_at: Option<DateTime<Utc>>,
}
