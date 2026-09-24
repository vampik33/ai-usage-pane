//! Shared on-disk snapshot so that many panes fetch at most once per TTL.

use std::fs::{self, File};
use std::path::Path;
use std::thread;

use anyhow::{Context, Result};
use chrono::{DateTime, Duration, Utc};

use crate::model::{Snapshot, Usage};

/// Auto refresh re-fetches when the snapshot is older than this.
pub const AUTO_TTL: Duration = Duration::minutes(5);
/// Manual refresh still won't re-fetch more often than this
/// (the Anthropic usage endpoint rate-limits aggressive polling).
pub const MANUAL_FLOOR: Duration = Duration::seconds(30);

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Mode {
    Auto,
    Manual,
}

pub struct Refreshed {
    pub snapshot: Snapshot,
    /// The cache could not be locked or written; `snapshot` is still current,
    /// just not shared with other panes.
    pub cache_error: Option<anyhow::Error>,
}

/// Returns the cached snapshot, fetching first if it is older than the
/// mode's threshold. An exclusive lock serialises concurrent panes, so the
/// ones that wait pick up the snapshot the first one just wrote.
///
/// `last` is the caller's in-memory snapshot. It is used when newer than the
/// cache, so a pane that cannot use the cache still throttles its fetches.
///
/// `clock` is read once the lock is held, so the calls it serialises see
/// increasing times.
pub fn refresh<N, C, X>(
    path: &Path,
    clock: N,
    mode: Mode,
    last: Snapshot,
    fetch_claude: C,
    fetch_codex: X,
) -> Refreshed
where
    N: FnOnce() -> DateTime<Utc>,
    C: FnOnce() -> Result<Usage> + Send,
    X: FnOnce() -> Result<Usage>,
{
    // Held until the new snapshot is saved.
    let lock = lock(path);
    let now = clock();

    // A missing or corrupt cache just means "fetch now".
    let cached: Snapshot = fs::read_to_string(path)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default();
    // A time in the future (the clock stepped back) would block fetching until
    // the clock caught up, so it counts as never attempted.
    let attempted = |s: &Snapshot| s.attempted_at.filter(|&t| t <= now);
    let mut snap = if attempted(&last) > attempted(&cached) {
        last
    } else {
        cached
    };

    let min_age = match mode {
        Mode::Auto => AUTO_TTL,
        Mode::Manual => MANUAL_FLOOR,
    };
    if attempted(&snap).is_some_and(|t| now - t < min_age) {
        return Refreshed {
            snapshot: snap,
            cache_error: lock.err(),
        };
    }

    // Independent endpoints: fetch both at once to halve the time the lock is held.
    let (claude, codex) = thread::scope(|s| {
        let claude = s.spawn(fetch_claude);
        let codex = fetch_codex();
        (claude.join().expect("claude fetch panicked"), codex)
    });
    snap.claude.apply(claude);
    snap.codex.apply(codex);
    snap.attempted_at = Some(now);

    Refreshed {
        cache_error: lock.and_then(|_lock| save(path, &snap)).err(),
        snapshot: snap,
    }
}

fn lock(path: &Path) -> Result<File> {
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir).with_context(|| format!("create {}", dir.display()))?;
    }
    let lock = File::create(path.with_extension("lock")).context("create lock file")?;
    lock.lock().context("lock cache")?;
    Ok(lock)
}

fn save(path: &Path, snap: &Snapshot) -> Result<()> {
    let tmp = path.with_extension("tmp");
    fs::write(&tmp, serde_json::to_string_pretty(snap)?).context("write cache")?;
    fs::rename(&tmp, path).context("replace cache")?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::Window;
    use anyhow::anyhow;
    use chrono::TimeZone;
    use std::sync::atomic::{AtomicU32, Ordering};

    fn usage(pct: f64) -> Usage {
        Usage {
            five_hour: Some(Window {
                used_percent: pct,
                resets_at: None,
            }),
            weekly: None,
        }
    }

    fn t0() -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 9, 23, 12, 0, 0).unwrap()
    }

    /// Runs refresh with fetchers returning the given results; returns the
    /// snapshot and how many fetchers were called.
    fn run(
        path: &Path,
        now: DateTime<Utc>,
        mode: Mode,
        claude: Result<Usage>,
        codex: Result<Usage>,
    ) -> (Snapshot, u32) {
        let (refreshed, calls) = run_with(path, now, mode, Snapshot::default(), claude, codex);
        assert!(refreshed.cache_error.is_none());
        (refreshed.snapshot, calls)
    }

    fn run_with(
        path: &Path,
        now: DateTime<Utc>,
        mode: Mode,
        last: Snapshot,
        claude: Result<Usage>,
        codex: Result<Usage>,
    ) -> (Refreshed, u32) {
        let calls = AtomicU32::new(0);
        let count = || calls.fetch_add(1, Ordering::Relaxed);
        let refreshed = refresh(
            path,
            || now,
            mode,
            last,
            || {
                count();
                claude
            },
            || {
                count();
                codex
            },
        );
        (refreshed, calls.into_inner())
    }

    #[test]
    fn first_run_fetches_and_persists() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("nested/cache.json");
        let (snap, calls) = run(&path, t0(), Mode::Auto, Ok(usage(10.0)), Ok(usage(20.0)));
        assert_eq!(calls, 2);
        assert_eq!(snap.claude.usage, Some(usage(10.0)));
        assert_eq!(snap.codex.usage, Some(usage(20.0)));
        assert_eq!(snap.attempted_at, Some(t0()));
        let on_disk: Snapshot = serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(on_disk, snap);
    }

    #[test]
    fn auto_respects_ttl() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("c.json");
        run(&path, t0(), Mode::Auto, Ok(usage(1.0)), Ok(usage(1.0)));

        let just_before = t0() + AUTO_TTL - Duration::seconds(1);
        let (snap, calls) = run(
            &path,
            just_before,
            Mode::Auto,
            Ok(usage(2.0)),
            Ok(usage(2.0)),
        );
        assert_eq!(calls, 0);
        assert_eq!(snap.claude.usage, Some(usage(1.0)));

        let (snap, calls) = run(
            &path,
            t0() + AUTO_TTL,
            Mode::Auto,
            Ok(usage(2.0)),
            Ok(usage(2.0)),
        );
        assert_eq!(calls, 2);
        assert_eq!(snap.claude.usage, Some(usage(2.0)));
    }

    #[test]
    fn manual_bypasses_ttl_but_not_floor() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("c.json");
        run(&path, t0(), Mode::Auto, Ok(usage(1.0)), Ok(usage(1.0)));

        let (_, calls) = run(
            &path,
            t0() + MANUAL_FLOOR - Duration::seconds(1),
            Mode::Manual,
            Ok(usage(2.0)),
            Ok(usage(2.0)),
        );
        assert_eq!(calls, 0);

        let (snap, calls) = run(
            &path,
            t0() + MANUAL_FLOOR,
            Mode::Manual,
            Ok(usage(2.0)),
            Ok(usage(2.0)),
        );
        assert_eq!(calls, 2);
        assert_eq!(snap.codex.usage, Some(usage(2.0)));
    }

    #[test]
    fn failure_keeps_last_good_usage_and_success_clears_error() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("c.json");
        run(&path, t0(), Mode::Auto, Ok(usage(1.0)), Ok(usage(1.0)));

        let t1 = t0() + AUTO_TTL;
        let (snap, _) = run(&path, t1, Mode::Auto, Err(anyhow!("boom")), Ok(usage(3.0)));
        assert_eq!(snap.claude.usage, Some(usage(1.0)));
        assert_eq!(snap.claude.error.as_deref(), Some("boom"));
        assert_eq!(snap.codex.error, None);
        assert_eq!(snap.attempted_at, Some(t1));

        let t2 = t1 + AUTO_TTL;
        let (snap, _) = run(&path, t2, Mode::Auto, Ok(usage(4.0)), Ok(usage(4.0)));
        assert_eq!(snap.claude.usage, Some(usage(4.0)));
        assert_eq!(snap.claude.error, None);
    }

    #[test]
    fn corrupt_cache_is_refetched() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("c.json");
        fs::write(&path, "{not json").unwrap();
        let (snap, calls) = run(&path, t0(), Mode::Auto, Ok(usage(5.0)), Ok(usage(5.0)));
        assert_eq!(calls, 2);
        assert_eq!(snap.claude.usage, Some(usage(5.0)));
    }

    #[test]
    fn save_failure_keeps_fetched_usage_and_throttles_in_memory() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("c.json");
        // A directory in the temp file's place makes the write fail.
        fs::create_dir(path.with_extension("tmp")).unwrap();

        let (refreshed, calls) = run_with(
            &path,
            t0(),
            Mode::Auto,
            Snapshot::default(),
            Ok(usage(1.0)),
            Ok(usage(2.0)),
        );
        assert_eq!(calls, 2);
        assert!(refreshed.cache_error.is_some());
        let snap = refreshed.snapshot;
        assert_eq!(snap.claude.usage, Some(usage(1.0)));
        assert_eq!(snap.codex.usage, Some(usage(2.0)));
        assert_eq!(snap.attempted_at, Some(t0()));

        let (refreshed, calls) = run_with(
            &path,
            t0() + MANUAL_FLOOR - Duration::seconds(1),
            Mode::Manual,
            snap,
            Ok(usage(3.0)),
            Ok(usage(3.0)),
        );
        assert_eq!(calls, 0);
        assert_eq!(refreshed.snapshot.claude.usage, Some(usage(1.0)));
    }

    #[test]
    fn future_attempt_does_not_block_fetching() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("c.json");
        // Written before the clock stepped back a day.
        let future = t0() + Duration::days(1);
        run(&path, future, Mode::Auto, Ok(usage(1.0)), Ok(usage(1.0)));

        let (snap, calls) = run(&path, t0(), Mode::Auto, Ok(usage(2.0)), Ok(usage(2.0)));
        assert_eq!(calls, 2);
        assert_eq!(snap.claude.usage, Some(usage(2.0)));
        assert_eq!(snap.attempted_at, Some(t0()));
    }

    #[test]
    fn future_cache_with_failed_save_throttles_in_memory() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("c.json");
        run(
            &path,
            t0() + Duration::days(1),
            Mode::Auto,
            Ok(usage(1.0)),
            Ok(usage(1.0)),
        );
        // The future snapshot stays in the cache: saves fail from now on.
        fs::create_dir(path.with_extension("tmp")).unwrap();

        let (refreshed, calls) = run_with(
            &path,
            t0(),
            Mode::Auto,
            Snapshot::default(),
            Ok(usage(2.0)),
            Ok(usage(2.0)),
        );
        assert_eq!(calls, 2);
        assert!(refreshed.cache_error.is_some());

        let (refreshed, calls) = run_with(
            &path,
            t0() + Duration::seconds(1),
            Mode::Manual,
            refreshed.snapshot,
            Ok(usage(3.0)),
            Ok(usage(3.0)),
        );
        assert_eq!(calls, 0);
        assert_eq!(refreshed.snapshot.claude.usage, Some(usage(2.0)));
    }

    #[test]
    fn newer_cache_wins_over_older_in_memory_snapshot() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("c.json");
        let (old, _) = run(&path, t0(), Mode::Auto, Ok(usage(1.0)), Ok(usage(1.0)));
        // Another pane fetched later.
        let t1 = t0() + AUTO_TTL;
        run(&path, t1, Mode::Auto, Ok(usage(2.0)), Ok(usage(2.0)));

        let (refreshed, calls) = run_with(
            &path,
            t1 + Duration::seconds(1),
            Mode::Auto,
            old,
            Ok(usage(3.0)),
            Ok(usage(3.0)),
        );
        assert_eq!(calls, 0);
        assert_eq!(refreshed.snapshot.claude.usage, Some(usage(2.0)));
    }

    #[test]
    fn lock_failure_still_fetches() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("c.json");
        // A directory in the lock file's place makes locking fail.
        fs::create_dir(path.with_extension("lock")).unwrap();

        let (refreshed, calls) = run_with(
            &path,
            t0(),
            Mode::Auto,
            Snapshot::default(),
            Ok(usage(1.0)),
            Ok(usage(2.0)),
        );
        assert_eq!(calls, 2);
        assert!(refreshed.cache_error.is_some());
        assert_eq!(refreshed.snapshot.claude.usage, Some(usage(1.0)));
        assert!(!path.exists());
    }
}
