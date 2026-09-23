use std::io::stdout;
use std::path::PathBuf;
use std::sync::mpsc::{self, Receiver, Sender};
use std::thread;
use std::time::{Duration, Instant};

use anyhow::Result;
use chrono::{DateTime, Utc};
use ratatui::crossterm::event::{
    self, DisableMouseCapture, EnableMouseCapture, Event, KeyCode, KeyEventKind, KeyModifiers,
    MouseButton, MouseEventKind,
};
use ratatui::crossterm::execute;
use ratatui::layout::{Position, Rect};
use ratatui::style::{Color, Style, Stylize};
use ratatui::text::{Line, Span};
use ratatui::widgets::Paragraph;
use ratatui::{DefaultTerminal, Frame};

use crate::cache::{self, Fetchers, Mode};
use crate::format::{ago, bar, countdown};
use crate::model::{ProviderState, Snapshot, Window};
use crate::{claude, codex};

/// How often to ask the cache; it only hits the network once per `AUTO_TTL`,
/// but frequent checks pick up snapshots fetched by other panes.
const CHECK_EVERY: Duration = Duration::from_secs(15);
const BAR_WIDTH: usize = 10;
const BUTTON: &str = "[⟳ refresh]";
const HEIGHT: u16 = 3;

pub fn run(home: PathBuf, cache_path: PathBuf) -> Result<()> {
    let mut terminal = ratatui::init();
    execute!(stdout(), EnableMouseCapture)?;
    let result = App::new(home, cache_path).run(&mut terminal);
    let _ = execute!(stdout(), DisableMouseCapture);
    ratatui::restore();
    result
}

struct App {
    home: PathBuf,
    cache_path: PathBuf,
    snapshot: Snapshot,
    refreshing: bool,
    last_check: Instant,
    /// Cache I/O failure (not a provider fetch error).
    cache_error: Option<String>,
    /// Where the refresh button was last drawn, for mouse hit-testing.
    button: Rect,
    tx: Sender<Result<Snapshot>>,
    rx: Receiver<Result<Snapshot>>,
}

impl App {
    fn new(home: PathBuf, cache_path: PathBuf) -> Self {
        let (tx, rx) = mpsc::channel();
        Self {
            home,
            cache_path,
            snapshot: Snapshot::default(),
            refreshing: false,
            last_check: Instant::now(),
            cache_error: None,
            button: Rect::default(),
            tx,
            rx,
        }
    }

    fn run(mut self, terminal: &mut DefaultTerminal) -> Result<()> {
        self.spawn_refresh(Mode::Auto);
        loop {
            terminal.draw(|f| self.draw(f))?;
            if event::poll(Duration::from_secs(1))? {
                match event::read()? {
                    Event::Key(k) if k.kind == KeyEventKind::Press => match k.code {
                        KeyCode::Char('q') | KeyCode::Esc => return Ok(()),
                        KeyCode::Char('c') if k.modifiers.contains(KeyModifiers::CONTROL) => {
                            return Ok(());
                        }
                        KeyCode::Char('r') => self.spawn_refresh(Mode::Manual),
                        _ => {}
                    },
                    Event::Mouse(m)
                        if m.kind == MouseEventKind::Down(MouseButton::Left)
                            && self.button.contains(Position::new(m.column, m.row)) =>
                    {
                        self.spawn_refresh(Mode::Manual)
                    }
                    _ => {}
                }
            }
            while let Ok(result) = self.rx.try_recv() {
                self.refreshing = false;
                match result {
                    Ok(snapshot) => {
                        self.snapshot = snapshot;
                        self.cache_error = None;
                    }
                    Err(e) => self.cache_error = Some(format!("{e:#}")),
                }
            }
            if self.last_check.elapsed() >= CHECK_EVERY {
                self.spawn_refresh(Mode::Auto);
            }
        }
    }

    /// Fetching blocks on the network and the cache lock, so it runs off the
    /// UI thread; the countdowns keep ticking meanwhile.
    fn spawn_refresh(&mut self, mode: Mode) {
        if self.refreshing {
            return;
        }
        self.refreshing = true;
        self.last_check = Instant::now();
        let (tx, home, path) = (self.tx.clone(), self.home.clone(), self.cache_path.clone());
        thread::spawn(move || {
            let now = Utc::now();
            let result = cache::refresh(
                &path,
                now,
                mode,
                Fetchers {
                    claude: || claude::fetch(&home, now),
                    codex: || codex::fetch(&home),
                },
            );
            let _ = tx.send(result);
        });
    }

    fn draw(&mut self, f: &mut Frame) {
        let now = Utc::now();
        let area = f.area();
        // Stick to the bottom edge of the pane, whatever its height.
        let height = HEIGHT.min(area.height);
        let rect = Rect {
            y: area.y + area.height - height,
            height,
            ..area
        };
        let lines = vec![
            provider_line("Claude", &self.snapshot.claude, now),
            provider_line("Codex", &self.snapshot.codex, now),
            self.status_line(now),
        ];
        f.render_widget(Paragraph::new(lines), rect);
        self.button = if height == HEIGHT {
            Rect::new(rect.x, rect.y + 2, Span::raw(BUTTON).width() as u16, 1)
        } else {
            Rect::default()
        };
    }

    fn status_line(&self, now: DateTime<Utc>) -> Line<'static> {
        let status = if self.refreshing {
            Span::raw("refreshing…").dim()
        } else if let Some(e) = &self.cache_error {
            Span::styled(format!("cache error: {e}"), Style::new().fg(Color::Red))
        } else if let Some(t) = self.snapshot.attempted_at {
            Span::raw(format!("updated {}", ago(now - t))).dim()
        } else {
            Span::raw("")
        };
        Line::from(vec![
            Span::raw(BUTTON).bold().reversed(),
            Span::raw("  r refresh · q quit  ").dim(),
            status,
        ])
    }
}

fn provider_line(name: &str, state: &ProviderState, now: DateTime<Utc>) -> Line<'static> {
    let mut spans = vec![Span::raw(format!("{name:<7}")).bold()];
    match &state.usage {
        Some(u) => {
            spans.extend(window_spans("5h", u.five_hour.as_ref(), now));
            spans.push(Span::raw(" │ ").dim());
            spans.extend(window_spans("wk", u.weekly.as_ref(), now));
        }
        None if state.error.is_none() => spans.push(Span::raw("loading…").dim()),
        None => {}
    }
    if let Some(e) = &state.error {
        let prefix = if state.usage.is_some() {
            "  stale: "
        } else {
            ""
        };
        spans.push(Span::styled(
            format!("{prefix}⚠ {e}"),
            Style::new().fg(Color::Red),
        ));
    }
    Line::from(spans)
}

fn window_spans(label: &str, window: Option<&Window>, now: DateTime<Utc>) -> Vec<Span<'static>> {
    let mut spans = vec![Span::raw(format!("{label} ")).dim()];
    let Some(w) = window else {
        spans.push(Span::raw("—").dim());
        return spans;
    };
    // Past the reset time the percentage is outdated until the next fetch.
    let expired = w.resets_at.is_some_and(|t| t <= now);
    let style = if expired {
        Style::new().dim()
    } else {
        Style::new().fg(level_color(w.used_percent))
    };
    let percent = if expired {
        "   —".to_string()
    } else {
        format!("{:>3.0}%", w.used_percent)
    };
    let reset = match w.resets_at {
        None => "—".to_string(),
        Some(_) if expired => "reset".to_string(),
        Some(t) => countdown(t - now),
    };
    spans.push(Span::styled(bar(w.used_percent, BAR_WIDTH), style));
    spans.push(Span::styled(format!(" {percent}"), style));
    spans.push(Span::raw(format!(" ↻{reset:<6}")));
    spans
}

fn level_color(percent: f64) -> Color {
    match percent {
        p if p >= 90.0 => Color::Red,
        p if p >= 75.0 => Color::Yellow,
        _ => Color::Green,
    }
}
