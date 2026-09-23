use std::time::Duration;

use anyhow::{Result, bail};

/// GET `url` and return the body, mapping 401/403 to `expired_hint`.
pub fn get(url: &str, headers: &[(&str, &str)], expired_hint: &str) -> Result<String> {
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .timeout_global(Some(Duration::from_secs(15)))
        .build()
        .into();
    let mut req = agent.get(url);
    for (k, v) in headers {
        req = req.header(*k, *v);
    }
    match req.call() {
        Ok(mut resp) => Ok(resp.body_mut().read_to_string()?),
        Err(ureq::Error::StatusCode(401 | 403)) => bail!("{expired_hint}"),
        Err(ureq::Error::StatusCode(429)) => bail!("rate limited, retry later"),
        Err(ureq::Error::StatusCode(code)) => bail!("HTTP {code}"),
        Err(e) => bail!("network: {e}"),
    }
}
