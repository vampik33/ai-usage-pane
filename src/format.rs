use chrono::Duration;

/// Time until reset: `now`, `<1m`, `45m`, `1h07m`, `3d14h`.
pub fn countdown(d: Duration) -> String {
    let secs = d.num_seconds();
    if secs <= 0 {
        return "now".into();
    }
    let (days, hours, mins) = (secs / 86_400, secs % 86_400 / 3600, secs % 3600 / 60);
    match (days, hours, mins) {
        (0, 0, 0) => "<1m".into(),
        (0, 0, m) => format!("{m}m"),
        (0, h, m) => format!("{h}h{m:02}m"),
        (d, h, _) => format!("{d}d{h}h"),
    }
}

/// How long ago something happened: `just now`, `4m ago`, `2h ago`.
pub fn ago(d: Duration) -> String {
    match d.num_minutes() {
        m if m < 1 => "just now".into(),
        m if m < 60 => format!("{m}m ago"),
        m => format!("{}h ago", m / 60),
    }
}

/// Text progress bar of `width` cells.
pub fn bar(percent: f64, width: usize) -> String {
    let filled = ((percent.clamp(0.0, 100.0) / 100.0) * width as f64).round() as usize;
    format!("{}{}", "█".repeat(filled), "░".repeat(width - filled))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn countdown_cases() {
        let s = Duration::seconds;
        assert_eq!(countdown(s(-5)), "now");
        assert_eq!(countdown(s(0)), "now");
        assert_eq!(countdown(s(59)), "<1m");
        assert_eq!(countdown(s(60)), "1m");
        assert_eq!(countdown(s(59 * 60 + 59)), "59m");
        assert_eq!(countdown(s(3600 + 7 * 60)), "1h07m");
        assert_eq!(countdown(s(23 * 3600 + 59 * 60)), "23h59m");
        assert_eq!(countdown(s(86_400)), "1d0h");
        assert_eq!(countdown(s(3 * 86_400 + 14 * 3600 + 30 * 60)), "3d14h");
    }

    #[test]
    fn ago_cases() {
        let s = Duration::seconds;
        assert_eq!(ago(s(30)), "just now");
        assert_eq!(ago(s(4 * 60)), "4m ago");
        assert_eq!(ago(s(125 * 60)), "2h ago");
    }

    #[test]
    fn bar_cases() {
        assert_eq!(bar(0.0, 4), "░░░░");
        assert_eq!(bar(50.0, 4), "██░░");
        assert_eq!(bar(100.0, 4), "████");
        assert_eq!(bar(150.0, 4), "████");
        assert_eq!(bar(-3.0, 4), "░░░░");
    }
}
