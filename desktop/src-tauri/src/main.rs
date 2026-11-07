// Prevents an extra console window on Windows in release builds.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

//! Desktop vertical slice for the llama.cpp Command Center (ADR-006).
//!
//! This crate owns no domain logic and no state. It is a supervisor: it runs the
//! PowerShell backend (`Install-LlamaCpp-AMD.ps1`) as a subprocess and hands the typed
//! JSON documents it prints to the webview unchanged, together with the raw call detail
//! (exact command, exit code, standard error) so any failure can be expanded in the UI.
//!
//! Contract with the backend: exit code 0 and exactly one UTF-8 JSON document (no BOM)
//! on standard output, starting with `schema_version`. Standard error carries human
//! diagnostics. The webview never reads files or parses strings: everything it shows
//! came out of one of these documents.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::fs;
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
#[cfg(windows)]
use std::os::windows::process::CommandExt;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Manager, RunEvent, WebviewUrl, WebviewWindowBuilder, WindowEvent};

const SCRIPT_NAME: &str = "Install-LlamaCpp-AMD.ps1";
/// Suppress the console window that Windows would otherwise allocate for every child of
/// this GUI process. The app opens no terminal windows at all; the server's output goes
/// to its log file instead.
#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;
const TRAY_ID: &str = "main-tray";
/// Loopback channel used to hand a second launch to the process that already owns the
/// tray. It is not a public API: it listens only on 127.0.0.1 and accepts a single word.
const SINGLE_INSTANCE_PORT: u16 = 47821;
/// A fixed, app-specific token makes the loopback handshake distinguishable from any
/// unrelated process that happens to own the port. It is not a secret.
const INSTANCE_TOKEN: &str = "llamacpp-command-center-single-instance-v1";
const INSTANCE_TIMEOUT: Duration = Duration::from_millis(500);
const INSTANCE_CONNECT_TIMEOUT: Duration = Duration::from_millis(250);
const INSTANCE_MESSAGE_LIMIT: usize = 128;
const DESKTOP_SETTINGS_FILE: &str = "desktop-settings.json";
/// How many parent folders to search for the backend script when running from a build tree.
const SEARCH_DEPTH: usize = 6;

#[derive(Serialize)]
struct BackendResult {
    /// True when the backend answered with a typed document.
    ok: bool,
    /// Backend action that was requested (`state`, `diagnose`, `runtime:health`, ...).
    action: String,
    /// The typed JSON document, exactly as the backend printed it.
    document: Option<Value>,
    /// Human-readable failure text when `ok` is false.
    error: Option<String>,
    /// Raw detail for the expandable section: the exact command line that ran.
    command: String,
    exit_code: Option<i32>,
    stderr: String,
    install_root: String,
    /// The resolved backend script, when one was found.
    script: Option<String>,
    /// Every location that was checked for the backend script.
    candidates: Vec<String>,
}

fn install_root() -> PathBuf {
    if let Ok(root) = std::env::var("LLAMACPP_INSTALL_ROOT") {
        if !root.trim().is_empty() {
            return PathBuf::from(root);
        }
    }
    let local = std::env::var("LOCALAPPDATA").unwrap_or_default();
    PathBuf::from(local).join("Programs").join("llama.cpp")
}

/// Where the PowerShell backend can live, most specific first. The list is reported to
/// the UI so an unavailable backend can explain exactly what was checked.
fn script_candidates() -> Vec<PathBuf> {
    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Ok(explicit) = std::env::var("LLAMACPP_SCRIPT") {
        if !explicit.trim().is_empty() {
            candidates.push(PathBuf::from(explicit));
        }
    }
    candidates.push(install_root().join(SCRIPT_NAME));
    if let Ok(exe) = std::env::current_exe() {
        let mut directory = exe.parent().map(Path::to_path_buf);
        for _ in 0..SEARCH_DEPTH {
            let Some(current) = directory else { break };
            candidates.push(current.join(SCRIPT_NAME));
            // The installer bundles the backend (and its catalogue) in a backend folder next to the app.
            candidates.push(current.join("backend").join(SCRIPT_NAME));
            directory = current.parent().map(Path::to_path_buf);
        }
    }
    candidates.dedup();
    candidates
}

fn resolve_script() -> Result<PathBuf, (String, Vec<String>)> {
    let candidates = script_candidates();
    let listed: Vec<String> = candidates
        .iter()
        .map(|path| path.display().to_string())
        .collect();
    match candidates.iter().find(|path| path.is_file()) {
        Some(found) => Ok(found.clone()),
        None => Err((
            format!(
                "The PowerShell backend ({SCRIPT_NAME}) was not found. Set LLAMACPP_SCRIPT to its full path, or keep it next to the app."
            ),
            listed,
        )),
    }
}

fn powershell_command(script: &Path, action: &str, extra: &[String], install_root: &Path) -> Command {
    let mut command = Command::new("powershell.exe");
    command
        .args(["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File"])
        .arg(script)
        .args(["-Action", action])
        .args(extra)
        .arg("-InstallRoot")
        .arg(install_root);
    #[cfg(windows)]
    command.creation_flags(CREATE_NO_WINDOW);
    command
}

/// Only tray Quit sets this flag; every other exit request (including the one produced by
/// destroying the last webview) must keep the process and tray alive.
fn should_prevent_exit(quitting: bool) -> bool {
    !quitting
}

fn describe(script: &Path, action: &str, extra: &[String], install_root: &Path) -> String {
    let mut parts = vec![
        "powershell.exe".to_string(),
        "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File".to_string(),
        format!("\"{}\"", script.display()),
        "-Action".to_string(),
        action.to_string(),
    ];
    parts.extend(extra.iter().cloned());
    parts.push(format!("-InstallRoot \"{}\"", install_root.display()));
    parts.join(" ")
}

/// Run one backend action and return its typed document, or the raw failure detail.
fn run_backend(action: &str, label: &str, extra: &[String]) -> BackendResult {
    let root = install_root();
    let root_text = root.display().to_string();
    let script = match resolve_script() {
        Ok(script) => script,
        Err((error, candidates)) => {
            return BackendResult {
                ok: false,
                action: label.to_string(),
                document: None,
                error: Some(error),
                command: String::new(),
                exit_code: None,
                stderr: String::new(),
                install_root: root_text,
                script: None,
                candidates,
            }
        }
    };
    let command_text = describe(&script, action, extra, &root);
    let output = powershell_command(&script, action, extra, &root).output();
    let candidates = script_candidates()
        .iter()
        .map(|path| path.display().to_string())
        .collect();
    match output {
        Ok(output) => {
            let stdout = String::from_utf8_lossy(&output.stdout)
                .trim_start_matches('\u{feff}')
                .to_string();
            let stderr = String::from_utf8_lossy(&output.stderr).to_string();
            let exit_code = output.status.code();
            match serde_json::from_str::<Value>(stdout.trim()) {
                Ok(document) if output.status.success() => BackendResult {
                    ok: true,
                    action: label.to_string(),
                    document: Some(document),
                    error: None,
                    command: command_text,
                    exit_code,
                    stderr,
                    install_root: root_text,
                    script: Some(script.display().to_string()),
                    candidates,
                },
                Ok(document) => BackendResult {
                    ok: false,
                    action: label.to_string(),
                    document: Some(document),
                    error: Some(format!(
                        "The backend reported a problem (exit code {}).",
                        exit_code.unwrap_or(-1)
                    )),
                    command: command_text,
                    exit_code,
                    stderr,
                    install_root: root_text,
                    script: Some(script.display().to_string()),
                    candidates,
                },
                Err(parse_error) => {
                    let detail = if stdout.trim().is_empty() {
                        stderr.clone()
                    } else {
                        stdout.chars().take(600).collect::<String>()
                    };
                    BackendResult {
                        ok: false,
                        action: label.to_string(),
                        document: None,
                        error: Some(format!(
                            "The backend did not return one JSON document ({parse_error}). Exit code {}.",
                            exit_code.unwrap_or(-1)
                        )),
                        command: command_text,
                        exit_code,
                        stderr: format!("{stderr}\n{detail}").trim().to_string(),
                        install_root: root_text,
                        script: Some(script.display().to_string()),
                        candidates,
                    }
                }
            }
        }
        Err(spawn_error) => BackendResult {
            ok: false,
            action: label.to_string(),
            document: None,
            error: Some(format!("Could not start PowerShell: {spawn_error}")),
            command: command_text,
            exit_code: None,
            stderr: String::new(),
            install_root: root_text,
            script: Some(script.display().to_string()),
            candidates,
        },
    }
}

/// Read-only backend state (`-Action State`): the single source for every displayed value.
fn get_state_inner() -> BackendResult {
    run_backend("State", "state", &[])
}

/// Desktop-only preferences. The backend remains the single source for server and model
/// settings; this file only controls how the frame itself behaves at launch.
#[derive(Clone, Debug, Default, Deserialize, Serialize)]
struct DesktopSettings {
    #[serde(default)]
    start_minimised_to_tray: bool,
}

/// The PowerShell process that owns the server. Keeping the child handle lets Stop/Quit
/// stop the server the app started; a server that existed before the app has no handle.
static LAUNCHER: Mutex<Option<Child>> = Mutex::new(None);

/// Serializes Start requests. The tray and the window can ask at the same time; without
/// this lock both health probes can see "stopped" and each spawn a server launcher.
static START_LOCK: Mutex<()> = Mutex::new(());

/// Detached, hidden helpers (the Chat.cmd launcher) that must not outlive the app.
static HELPERS: Mutex<Vec<Child>> = Mutex::new(Vec::new());

const LAUNCHER_EXIT_TIMEOUT: Duration = Duration::from_secs(5);

/// Wait for the server launcher to return after the backend stops the server; only
/// force-kill it if it is still alive after the grace period.
fn close_launcher_console() {
    let child = LAUNCHER.lock().ok().and_then(|mut slot| slot.take());
    let Some(mut child) = child else { return };
    let deadline = Instant::now() + LAUNCHER_EXIT_TIMEOUT;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => return,
            Ok(None) if Instant::now() < deadline => {
                std::thread::sleep(Duration::from_millis(50));
            }
            _ => break,
        }
    }
    let _ = child.kill();
    let _ = child.wait();
}

fn launcher_is_running() -> bool {
    let Ok(mut slot) = LAUNCHER.lock() else { return false };
    let Some(child) = slot.as_mut() else { return false };
    match child.try_wait() {
        Ok(None) => true,
        _ => {
            let _ = slot.take();
            false
        }
    }
}

fn reap_helpers() {
    if let Ok(mut helpers) = HELPERS.lock() {
        helpers.retain_mut(|child| matches!(child.try_wait(), Ok(None)));
    }
}

fn remember_helper(child: Child) {
    reap_helpers();
    if let Ok(mut helpers) = HELPERS.lock() {
        helpers.push(child);
    }
}

fn close_helpers() {
    let helpers = HELPERS
        .lock()
        .map(|mut helpers| std::mem::take(&mut *helpers))
        .unwrap_or_default();
    for mut child in helpers {
        let _ = child.kill();
        let _ = child.wait();
    }
}

#[derive(Default)]
struct TrayMemory {
    last_state: Mutex<Option<Value>>,
}

/// The health worker only runs while the window is visible and the server is running or
/// loading. This is deliberately separate from `TrayMemory`: hiding the window must stop
/// the probe immediately, even if the server keeps running.
#[derive(Default)]
struct HealthPoll {
    window_visible: AtomicBool,
    window_destroyed: AtomicBool,
    server_active: AtomicBool,
}

#[derive(Default)]
struct QuitRequested(AtomicBool);

const HEALTH_INTERVAL: Duration = Duration::from_secs(5);
const HEALTH_IDLE: Duration = Duration::from_millis(250);
const HEALTH_TIMEOUT: Duration = Duration::from_millis(250);

fn desktop_settings_path(app: &AppHandle) -> Option<PathBuf> {
    app.path()
        .app_config_dir()
        .ok()
        .map(|directory| directory.join(DESKTOP_SETTINGS_FILE))
}

fn parse_desktop_settings(text: &str) -> DesktopSettings {
    // A settings file edited in Notepad can start with a UTF-8 BOM; serde rejects it.
    serde_json::from_str(text.trim_start_matches('\u{feff}')).unwrap_or_default()
}

fn read_desktop_settings(app: &AppHandle) -> DesktopSettings {
    let Some(path) = desktop_settings_path(app) else {
        return DesktopSettings::default();
    };
    let Ok(text) = fs::read_to_string(path) else {
        return DesktopSettings::default();
    };
    parse_desktop_settings(&text)
}

fn write_desktop_settings(app: &AppHandle, settings: &DesktopSettings) -> Result<(), String> {
    let path = desktop_settings_path(app).ok_or_else(|| "The app config folder is unavailable.".to_string())?;
    if let Some(directory) = path.parent() {
        fs::create_dir_all(directory).map_err(|error| format!("Could not create the app config folder: {error}"))?;
    }
    let text = serde_json::to_string_pretty(settings).map_err(|error| error.to_string())?;
    fs::write(&path, text).map_err(|error| format!("Could not save desktop settings: {error}"))
}

fn tooltip_for_state(document: Option<&Value>) -> String {
    let state = document
        .and_then(|document| document.get("server"))
        .and_then(|server| server.get("state"))
        .and_then(Value::as_str)
        .filter(|state| !state.is_empty())
        .unwrap_or("unknown");
    let model = document
        .and_then(|document| document.get("model"))
        .and_then(|model| model.get("name"))
        .and_then(Value::as_str)
        .filter(|name| !name.is_empty())
        .unwrap_or("no active model");
    format!("llama.cpp Command Center\nServer: {state}\nModel: {model}")
}

fn remember_state(app: &AppHandle, document: &Value) {
    if let Some(memory) = app.try_state::<TrayMemory>() {
        if let Ok(mut last) = memory.last_state.lock() {
            *last = Some(document.clone());
        }
    }
    if let Some(poll) = app.try_state::<HealthPoll>() {
        let active = document
            .get("server")
            .and_then(|server| server.get("state"))
            .and_then(Value::as_str)
            .is_some_and(|state| state == "running" || state == "loading");
        poll.server_active.store(active, Ordering::SeqCst);
    }
    if let Some(tray) = app.tray_by_id(TRAY_ID) {
        let _ = tray.set_tooltip(Some(tooltip_for_state(Some(document))));
    }
}

fn health_window_changed(app: &AppHandle, visible: bool, destroyed: bool) {
    if let Some(poll) = app.try_state::<HealthPoll>() {
        poll.window_visible.store(visible, Ordering::SeqCst);
        poll.window_destroyed.store(destroyed, Ordering::SeqCst);
    }
}

/// Pure predicate for the health worker. A hidden, minimised or destroyed window never
/// probes; neither does a stopped server. While the server is starting, probing is
/// allowed so the tray can show when it becomes ready.
fn should_poll_health(visible: bool, minimised: bool, destroyed: bool, server_state: &str) -> bool {
    visible && !minimised && !destroyed && (server_state == "running" || server_state == "loading")
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum HealthOutcome {
    Ok,
    Non200(u16),
    Timeout,
    Unreachable,
    Malformed,
}

/// Parse a complete HTTP response. The split is intentionally strict: a timeout after a
/// partial header is `Malformed`, not a successful probe.
fn parse_health_response(bytes: &[u8]) -> HealthOutcome {
    let text = String::from_utf8_lossy(bytes);
    let Some((head, body)) = text.split_once("\r\n\r\n").or_else(|| text.split_once("\n\n")) else {
        return HealthOutcome::Malformed;
    };
    let status_line = head.lines().next().unwrap_or("").trim();
    let mut parts = status_line.split_whitespace();
    if !parts.next().is_some_and(|version| version.starts_with("HTTP/")) {
        return HealthOutcome::Malformed;
    }
    let Some(code) = parts.next().and_then(|value| value.parse::<u16>().ok()) else {
        return HealthOutcome::Malformed;
    };
    if code != 200 {
        return HealthOutcome::Non200(code);
    }
    if body.trim().is_empty() {
        return HealthOutcome::Malformed;
    }
    match serde_json::from_str::<Value>(body.trim()) {
        Ok(_) => HealthOutcome::Ok,
        Err(_) => HealthOutcome::Malformed,
    }
}

fn probe_health(port: u16) -> HealthOutcome {
    let address = SocketAddr::from(([127, 0, 0, 1], port));
    let Ok(mut stream) = TcpStream::connect_timeout(&address, HEALTH_TIMEOUT) else {
        return HealthOutcome::Unreachable;
    };
    let _ = stream.set_read_timeout(Some(HEALTH_TIMEOUT));
    let _ = stream.set_write_timeout(Some(HEALTH_TIMEOUT));
    let request = format!(
        "GET /health HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nConnection: close\r\n\r\n"
    );
    if stream.write_all(request.as_bytes()).is_err() {
        return HealthOutcome::Unreachable;
    }
    let mut bytes = Vec::new();
    match stream.read_to_end(&mut bytes) {
        Ok(_) => parse_health_response(&bytes),
        Err(error) if error.kind() == std::io::ErrorKind::WouldBlock || error.kind() == std::io::ErrorKind::TimedOut => {
            if bytes.is_empty() { HealthOutcome::Timeout } else { parse_health_response(&bytes) }
        }
        Err(_) => HealthOutcome::Unreachable,
    }
}

fn health_tooltip(state: Option<&Value>, outcome: &HealthOutcome) -> String {
    let status = match outcome {
        HealthOutcome::Ok => "OK",
        HealthOutcome::Non200(code) => return format!("{}\nHealth: HTTP {code}", tooltip_for_state(state)),
        HealthOutcome::Timeout => "timeout",
        HealthOutcome::Unreachable => "not answering",
        HealthOutcome::Malformed => "bad response",
    };
    format!("{}\nHealth: {status}", tooltip_for_state(state))
}

fn start_health_monitor(app: AppHandle) {
    std::thread::spawn(move || {
        let mut last: Option<HealthOutcome> = None;
        loop {
            let Some(poll) = app.try_state::<HealthPoll>() else {
                std::thread::sleep(HEALTH_IDLE);
                continue;
            };
            let visible = poll.window_visible.load(Ordering::SeqCst);
            let destroyed = poll.window_destroyed.load(Ordering::SeqCst);
            // The window's minimised state is folded into `visible` by the window event.
            let state = app
                .try_state::<TrayMemory>()
                .and_then(|memory| memory.last_state.lock().ok().and_then(|last| last.clone()));
            let server_state = state
                .as_ref()
                .and_then(|document| document.get("server"))
                .and_then(|server| server.get("state"))
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            let port = state
                .as_ref()
                .and_then(|document| document.get("server"))
                .and_then(|server| server.get("port"))
                .and_then(Value::as_u64)
                .unwrap_or(8080) as u16;
            if should_poll_health(visible, false, destroyed, &server_state) {
                let outcome = probe_health(port);
                let changed = last.as_ref() != Some(&outcome);
                if changed {
                    last = Some(outcome);
                    let last_outcome = last.clone().unwrap_or(HealthOutcome::Unreachable);
                    let tooltip = health_tooltip(state.as_ref(), &last_outcome);
                    if let Some(tray) = app.tray_by_id(TRAY_ID) {
                        let _ = tray.set_tooltip(Some(tooltip));
                    }
                }
                let started = Instant::now();
                while started.elapsed() < HEALTH_INTERVAL {
                    std::thread::sleep(HEALTH_IDLE);
                    if !poll.window_visible.load(Ordering::SeqCst)
                        || poll.window_destroyed.load(Ordering::SeqCst)
                    {
                        break;
                    }
                }
            } else {
                last = None;
                std::thread::sleep(HEALTH_IDLE);
            }
        }
    });
}

#[tauri::command]
fn get_state(app: AppHandle) -> BackendResult {
    let result = get_state_inner();
    if let Some(document) = result.document.as_ref() {
        remember_state(&app, document);
    }
    result
}

#[tauri::command]
fn get_desktop_settings(app: AppHandle) -> DesktopSettings {
    read_desktop_settings(&app)
}

#[tauri::command]
fn save_desktop_settings(app: AppHandle, start_minimised_to_tray: bool) -> Result<DesktopSettings, String> {
    let settings = DesktopSettings { start_minimised_to_tray };
    write_desktop_settings(&app, &settings)?;
    Ok(settings)
}

fn show_main_window(app: &AppHandle) {
    health_window_changed(app, true, false);
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.unminimize();
        let _ = window.show();
        let _ = window.set_focus();
        return;
    }
    let _ = WebviewWindowBuilder::new(app, "main", WebviewUrl::App("index.html".into()))
        .title("llama.cpp Command Center")
        .inner_size(1000.0, 780.0)
        .min_inner_size(720.0, 560.0)
        .center()
        .build();
}

fn refresh_tray_state(app: &AppHandle) {
    let result = get_state_inner();
    if let Some(document) = result.document.as_ref() {
        remember_state(app, document);
    }
}

fn build_tray(app: &AppHandle) -> tauri::Result<()> {
    let open = MenuItem::with_id(app, "open", "Open", true, None::<&str>)?;
    let start = MenuItem::with_id(app, "start", "Start server", true, None::<&str>)?;
    let stop = MenuItem::with_id(app, "stop", "Stop server", true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;
    let separator = PredefinedMenuItem::separator(app)?;
    let menu = Menu::with_items(app, &[&open, &start, &stop, &separator, &quit])?;

    let mut builder = TrayIconBuilder::with_id(TRAY_ID)
        .menu(&menu)
        .show_menu_on_left_click(false)
        .tooltip(tooltip_for_state(None))
        .on_menu_event(|app, event| match event.id.as_ref() {
            "open" => show_main_window(app),
            "start" => {
                let app = app.clone();
                std::thread::spawn(move || {
                    let _ = start_server();
                    refresh_tray_state(&app);
                });
            }
            "stop" => {
                let app = app.clone();
                std::thread::spawn(move || {
                    let _ = stop_server(true);
                    refresh_tray_state(&app);
                });
            }
            "quit" => {
                if let Some(flag) = app.try_state::<QuitRequested>() {
                    flag.0.store(true, Ordering::SeqCst);
                }
                app.exit(0);
            }
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = event
            {
                show_main_window(tray.app_handle());
            }
        });

    if let Some(icon) = app.default_window_icon() {
        builder = builder.icon(icon.clone());
    }
    builder.build(app)?;
    Ok(())
}

#[tauri::command]
fn get_recommendations() -> BackendResult {
    run_backend("Recommend", "recommend", &[])
}

#[tauri::command]
fn get_diagnostics() -> BackendResult {
    run_backend("Diagnose", "diagnose", &[])
}

/// Cheap liveness probe: no hardware scan, safe to poll while a model loads.
#[tauri::command]
fn runtime_health() -> BackendResult {
    run_backend(
        "Runtime",
        "runtime:health",
        &["-RuntimeAction".to_string(), "health".to_string()],
    )
}

/// Start the server through the supported adapter entry point, hidden. Its output goes
/// to `<install root>\\logs\\desktop-server.log`, so no terminal window is opened. The
/// port-ownership guard and the loader diagnostics live in the backend, not here.
#[tauri::command]
fn start_server() -> BackendResult {
    // One Start at a time: the tray and the window can race, and two health checks that
    // both see "stopped" would otherwise try to start two servers.
    let _start_guard = START_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let root = install_root();
    let root_text = root.display().to_string();
    let script = match resolve_script() {
        Ok(script) => script,
        Err((error, candidates)) => {
            return BackendResult {
                ok: false,
                action: "runtime:start".to_string(),
                document: None,
                error: Some(error),
                command: String::new(),
                exit_code: None,
                stderr: String::new(),
                install_root: root_text,
                script: None,
                candidates,
            }
        }
    };

    // Ask the backend for the current state first: it answers "already running" with the
    // same typed document the UI renders, and it names a foreign port owner.
    let health = run_backend(
        "Runtime",
        "runtime:health",
        &["-RuntimeAction".to_string(), "health".to_string()],
    );
    if health.ok {
        let state = health
            .document
            .as_ref()
            .and_then(|document| document.get("state"))
            .and_then(Value::as_str)
            .unwrap_or("");
        if state == "running" || state == "loading" {
            return health;
        }
    }

    let console_command = format!(
        "powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"{}\" -Action Runtime -RuntimeAction start -InstallRoot \"{}\"",
        script.display(),
        root.display()
    );
    let candidates = script_candidates()
        .iter()
        .map(|path| path.display().to_string())
        .collect();
    // A live launcher already owns the server. It can be alive while the server is still
    // initialising, so refuse a second start instead of starting a duplicate.
    if launcher_is_running() {
        return BackendResult {
            ok: false,
            action: "runtime:start".to_string(),
            document: None,
            error: Some(
                "The server is already starting. Wait for it to finish, or stop it first."
                    .to_string(),
            ),
            command: console_command,
            exit_code: None,
            stderr: String::new(),
            install_root: root_text,
            script: Some(script.display().to_string()),
            candidates,
        };
    }

    // Run the server hidden and keep its output in the install's logs folder. Creating a
    // console here left a Windows Terminal tab behind even after the process exited,
    // because Terminal's tab lifetime is a user setting the app cannot control.
    let log_path = root.join("logs").join("desktop-server.log");
    if let Some(parent) = log_path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let log = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&log_path)
        .ok();
    let mut command = Command::new("powershell.exe");
    command
        .args(["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File"])
        .arg(&script)
        .args(["-Action", "Runtime", "-RuntimeAction", "start"])
        .arg("-InstallRoot")
        .arg(&root)
        .stdin(Stdio::null());
    if let Some(file) = log {
        command.stdout(Stdio::from(file));
        if let Ok(errors) = fs::OpenOptions::new().create(true).append(true).open(&log_path) {
            command.stderr(Stdio::from(errors));
        }
    }
    #[cfg(windows)]
    command.creation_flags(CREATE_NO_WINDOW);
    let spawned = command.spawn();

    match spawned {
        Ok(child) => {
            let launcher_pid = child.id();
            if let Ok(mut slot) = LAUNCHER.lock() {
                *slot = Some(child);
            }
            BackendResult {
                ok: true,
                action: "runtime:start".to_string(),
                document: Some(json!({
                    "spawned": true,
                    "launcher_pid": launcher_pid,
                    "launcher_console": console_command,
                    "server_log": log_path.display().to_string(),
                    "health_before_start": health.document,
                })),
                error: None,
                command: console_command,
                exit_code: None,
                stderr: String::new(),
                install_root: root_text,
                script: Some(script.display().to_string()),
                candidates,
            }
        }
        Err(spawn_error) => BackendResult {
            ok: false,
            action: "runtime:start".to_string(),
            document: None,
            error: Some(format!("Could not start the server: {spawn_error}")),
            command: console_command,
            exit_code: None,
            stderr: String::new(),
            install_root: root_text,
            script: Some(script.display().to_string()),
            candidates,
        },
    }
}

/// Stop the server through the adapter. Without `force` the backend only reports that a
/// confirmation is required; nothing is killed until the user confirms.
#[tauri::command]
fn stop_server(force: bool) -> BackendResult {
    let mut extra = vec!["-RuntimeAction".to_string(), "stop".to_string()];
    if force {
        extra.push("-Force".to_string());
    }
    let result = run_backend("Runtime", if force { "runtime:stop:force" } else { "runtime:stop" }, &extra);
    if force && result.ok {
        close_launcher_console();
    }
    result
}

/// Tray Quit is the one exit path that owns the app's children. Stop the server through
/// the adapter, let its launcher exit, then close hidden helpers. A server that was
/// already running before this app started has no LAUNCHER and is left untouched.
fn shutdown_owned_processes() {
    if launcher_is_running() {
        let _ = stop_server(true);
    }
    close_launcher_console();
    close_helpers();
}

/// The runtime update entry (`-RuntimeAction update`): two-step like stop. The first
/// call asks the backend (it answers `requires_confirmation` and downloads nothing);
/// after the user confirms the window sends `force`, which delegates to the
/// backend's single-source updater (staged download, backup, launcher rebuild).
#[tauri::command]
fn update_runtime(force: bool) -> BackendResult {
    let mut extra = vec!["-RuntimeAction".to_string(), "update".to_string()];
    if force {
        extra.push("-Force".to_string());
    }
    run_backend("Runtime", if force { "runtime:update:force" } else { "runtime:update" }, &extra)
}

/// Put text on the Windows clipboard through clip.exe. The webview's own clipboard needs
/// the window focused and permitted; this works whenever the button was clicked and adds no
/// dependency. clip.exe reads UTF-16 as Unicode text; a byte-order mark would be pasted as a stray character.
#[tauri::command]
fn copy_to_clipboard(text: String) -> Result<(), String> {
    let mut command = Command::new("clip.exe");
    command.stdin(Stdio::piped()).stdout(Stdio::null()).stderr(Stdio::null());
    #[cfg(windows)]
    command.creation_flags(CREATE_NO_WINDOW);
    let mut child = command.spawn().map_err(|error| format!("clip.exe did not start: {error}"))?;
    let mut bytes: Vec<u8> = Vec::new();
    for unit in text.encode_utf16() {
        bytes.extend_from_slice(&unit.to_le_bytes());
    }
    if let Some(mut stdin) = child.stdin.take() {
        stdin.write_all(&bytes).map_err(|error| format!("clip.exe did not take the text: {error}"))?;
    }
    let status = child.wait().map_err(|error| format!("clip.exe did not finish: {error}"))?;
    if status.success() { Ok(()) } else { Err("clip.exe reported a failure.".to_string()) }
}

/// Newest-available check for each installed backend (`-RuntimeAction updates`). Read-only:
/// it asks GitHub for the latest tag (cached six hours by the backend) and downloads nothing.
#[tauri::command]
fn get_runtime_updates() -> BackendResult {
    run_backend(
        "Runtime",
        "runtime:updates",
        &["-RuntimeAction".to_string(), "updates".to_string()],
    )
}

/// Point llama.cpp back at the previous build of the active backend (`-RuntimeAction
/// rollback`). The backend would restart a running server in a visible console, which this
/// window never opens, so a running server is refused here and the user stops it first.
#[tauri::command]
fn rollback_runtime() -> BackendResult {
    let health = runtime_health();
    let state = health
        .document
        .as_ref()
        .and_then(|document| document.get("state"))
        .and_then(Value::as_str)
        .unwrap_or("");
    if state == "running" || state == "loading" {
        return BackendResult {
            ok: false,
            action: "runtime:rollback".to_string(),
            document: None,
            error: Some("Stop the AI before rolling llama.cpp back. Nothing was changed.".to_string()),
            command: String::new(),
            exit_code: None,
            stderr: String::new(),
            install_root: install_root().display().to_string(),
            script: None,
            candidates: Vec::new(),
        };
    }
    run_backend(
        "Runtime",
        "runtime:rollback",
        &["-RuntimeAction".to_string(), "rollback".to_string()],
    )
}

/// Read-only settings document (`-Action Settings`): what the user can change and what the
/// installed runtime actually supports.
#[tauri::command]
fn get_settings() -> BackendResult {
    run_backend("Settings", "settings:read", &[])
}

/// Save one settings patch through the backend's own single-source helpers. The patch is a
/// JSON string the backend validates field by field; its result document lists what was
/// applied and what was rejected, so the UI can show both honestly.
#[tauri::command]
fn save_settings(patch: String) -> BackendResult {
    run_backend(
        "Settings",
        "settings:save",
        &["-SettingsPatch".to_string(), patch],
    )
}

/// Read-only model library document (`-Action Library`): every catalog model with its
/// downloaded/active state, fit and runtime blockers.
#[tauri::command]
fn get_library() -> BackendResult {
    run_backend("Library", "library:read", &[])
}

/// Activation and removal are quick: answer synchronously through the adapter's own
/// helpers (`-LibraryAction activate|remove -ModelId <id>`). The window already asked the
/// user for confirmation before calling this.
#[tauri::command]
fn library_change(action: String, model_id: String) -> BackendResult {
    run_backend(
        "Library",
        &format!("library:{action}"),
        &["-LibraryAction".to_string(), action, "-ModelId".to_string(), model_id],
    )
}

/// Start the AI through this app's tracked launcher when it is off, then run the install's
/// own `Chat.cmd` hidden. Chat.cmd still waits for the model and opens the chat browser,
/// but it cannot open a second server console: the app already owns the hidden server.
#[tauri::command]
fn open_chat() -> BackendResult {
    let root = install_root();
    let root_text = root.display().to_string();
    let chat = root.join("Chat.cmd");
    let failure = |error: String| BackendResult {
        ok: false,
        action: "chat:open".to_string(),
        document: None,
        error: Some(error),
        command: String::new(),
        exit_code: None,
        stderr: String::new(),
        install_root: root_text.clone(),
        script: None,
        candidates: Vec::new(),
    };
    if !chat.is_file() {
        return failure(format!(
            "Chat.cmd is missing from {root_text}. Run Start-LlamaCpp.cmd and choose [E] Easy start once to recreate it."
        ));
    }

    // Chat.cmd starts a minimized Start-LlamaCpp.cmd console when the server is off. Start
    // through the app's own launcher first and wait until llama-server exists, so Chat.cmd
    // only waits and the app can close the one hidden launcher it owns.
    let mut state = runtime_health()
        .document
        .as_ref()
        .and_then(|document| document.get("state"))
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    if state != "running" && state != "loading" {
        let started = start_server();
        if !started.ok {
            return failure(started.error.unwrap_or_else(|| "The AI could not be started.".to_string()));
        }
        let deadline = Instant::now() + Duration::from_secs(20);
        while Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(250));
            let probe = runtime_health();
            state = probe
                .document
                .as_ref()
                .and_then(|document| document.get("state"))
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            if state == "running" || state == "loading" {
                break;
            }
        }
        if state != "running" && state != "loading" {
            return failure(format!(
                "The AI did not start, so the chat window was not opened. Check logs\\desktop-server.log or the Health tab."
            ));
        }
    }

    let mut command = Command::new("cmd.exe");
    command
        .args(["/C"])
        .arg(&chat)
        .current_dir(&root)
        .env("LLAMACPP_NO_PAUSE", "1")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    #[cfg(windows)]
    command.creation_flags(CREATE_NO_WINDOW);
    match command.spawn() {
        Ok(child) => {
            remember_helper(child);
            BackendResult {
                ok: true,
                action: "chat:open".to_string(),
                document: None,
                error: None,
                command: format!("{} /C Chat.cmd", chat.display()),
                exit_code: None,
                stderr: String::new(),
                install_root: root_text,
                script: Some(chat.display().to_string()),
                candidates: Vec::new(),
            }
        }
        Err(spawn_error) => failure(format!("Could not open the chat window: {spawn_error}")),
    }
}

/// A download runs for minutes. Validate first (the backend answers with a typed result
/// that carries the refreshed library), then run the real transfer hidden through the
/// proven `-Action Models -ModelId <id>` path. The window keeps polling the library; no
/// second console window is opened or left behind.
#[tauri::command]
fn download_model(model_id: String) -> BackendResult {
    let root = install_root();
    let root_text = root.display().to_string();
    let script = match resolve_script() {
        Ok(script) => script,
        Err((error, candidates)) => {
            return BackendResult {
                ok: false,
                action: "library:download".to_string(),
                document: None,
                error: Some(error),
                command: String::new(),
                exit_code: None,
                stderr: String::new(),
                install_root: root_text,
                script: None,
                candidates,
            }
        }
    };
    let validated = run_backend(
        "Library",
        "library:download",
        &["-LibraryAction".to_string(), "download".to_string(), "-ModelId".to_string(), model_id.clone()],
    );
    let status = validated
        .document
        .as_ref()
        .and_then(|document| document.get("status"))
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    if validated.ok && status == "validated" {
        let mut command = Command::new("powershell.exe");
        command
            .args(["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File"])
            .arg(&script)
            .args(["-Action", "Models", "-ModelId", &model_id, "-Force"])
            .arg("-InstallRoot")
            .arg(&root)
            .current_dir(&root)
            .env("LLAMACPP_NO_PAUSE", "1")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        #[cfg(windows)]
        command.creation_flags(CREATE_NO_WINDOW);
        let spawned = command.spawn();
        let candidates = script_candidates()
            .iter()
            .map(|path| path.display().to_string())
            .collect();
        match spawned {
            Ok(_child) => BackendResult {
                ok: true,
                action: "library:download".to_string(),
                document: validated.document,
                error: None,
                command: format!("-Action Models -ModelId {model_id} -Force"),
                exit_code: None,
                stderr: String::new(),
                install_root: root_text,
                script: Some(script.display().to_string()),
                candidates,
            },
            Err(spawn_error) => BackendResult {
                ok: false,
                action: "library:download".to_string(),
                document: None,
                error: Some(format!("Could not start the download: {spawn_error}")),
                command: format!("-Action Models -ModelId {model_id} -Force"),
                exit_code: None,
                stderr: String::new(),
                install_root: root_text,
                script: Some(script.display().to_string()),
                candidates,
            },
        }
    } else {
        validated
    }
}

/// Where the backend lives, and every location that was checked. The UI shows this when
/// the backend is unavailable instead of inventing a status.
#[tauri::command]
fn backend_info() -> BackendResult {
    let root = install_root();
    let candidates = script_candidates();
    let resolved = candidates.iter().find(|path| path.is_file());
    BackendResult {
        ok: resolved.is_some(),
        action: "info".to_string(),
        document: None,
        error: resolved.is_none().then(|| {
            format!("The PowerShell backend ({SCRIPT_NAME}) was not found.")
        }),
        command: String::new(),
        exit_code: None,
        stderr: String::new(),
        install_root: root.display().to_string(),
        script: resolved.map(|path| path.display().to_string()),
        candidates: candidates
            .iter()
            .map(|path| path.display().to_string())
            .collect(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The backend script as it lives in this repository, next to the desktop folder.
    fn repo_script() -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("..")
            .join("..")
            .join(SCRIPT_NAME)
    }

    fn temp_root(tag: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!("cc-desktop-{tag}-{}", std::process::id()));
        std::fs::create_dir_all(&root).expect("create a temp install root");
        root
    }

    fn point_at_test_backend(root: &Path) {
        std::env::set_var("LLAMACPP_SCRIPT", repo_script());
        std::env::set_var("LLAMACPP_INSTALL_ROOT", root);
    }

    #[test]
    fn the_explicit_script_path_wins_and_is_listed_first() {
        let root = temp_root("explicit");
        point_at_test_backend(&root);
        assert_eq!(script_candidates().first(), Some(&repo_script()));
        let info = backend_info();
        assert!(info.ok, "backend_info should resolve the repository script: {:?}", info.error);
        assert_eq!(info.script.as_deref(), Some(repo_script().to_string_lossy().as_ref()));
        assert!(!info.candidates.is_empty(), "the UI needs the list of checked paths");
    }

    #[test]
    fn state_returns_the_typed_document_for_the_requested_install_root() {
        let root = temp_root("state");
        point_at_test_backend(&root);
        let result = get_state_inner();
        assert!(result.ok, "state failed: {:?} ({})", result.error, result.stderr);
        let document = result.document.expect("a state document");
        assert_eq!(document["schema_version"], 1);
        assert_eq!(document["install_root"], root.to_string_lossy().as_ref());
        assert!(result.command.contains("-Action State"), "the raw detail names the exact command");
        assert_eq!(result.exit_code, Some(0));
        assert!(document["server"]["state"].is_string());
    }

    #[test]
    fn recommendations_diagnostics_and_health_all_parse() {
        let root = temp_root("documents");
        point_at_test_backend(&root);
        for (label, result) in [
            ("recommend", get_recommendations()),
            ("diagnose", get_diagnostics()),
            ("runtime:health", runtime_health()),
        ] {
            assert!(result.ok, "{label} failed: {:?} ({})", result.error, result.stderr);
            let document = result.document.expect("a document");
            assert_eq!(document["schema_version"], 1, "{label} must keep the contract version");
        }
    }

    #[test]
    fn settings_read_and_save_return_typed_documents() {
        let root = temp_root("settings");
        point_at_test_backend(&root);
        let read = get_settings();
        assert!(read.ok, "settings read failed: {:?} ({})", read.error, read.stderr);
        let read_doc = read.document.expect("a settings document");
        assert_eq!(read_doc["schema_version"], 1);
        assert!(read_doc["idle_unload"]["capable"].is_boolean(), "the idle capability is probed, not assumed");
        assert!(read_doc["use_case"]["allowed"].is_array());
        // A bad patch must be refused in a typed document, not by a crash.
        let refused = save_settings("not-json-at-all".to_string());
        assert!(refused.ok, "a refused patch still answers with a document: {:?}", refused.error);
        let refused_doc = refused.document.expect("a save result");
        let rejected = refused_doc["rejected"].as_array().expect("a rejected array");
        assert!(rejected.iter().any(|entry| entry["field"] == "patch"), "junk input is reported under the patch field");
    }

    #[test]
    fn rollback_with_no_runtime_is_typed_and_changes_nothing() {
        let root = temp_root("rollback");
        point_at_test_backend(&root);
        let result = rollback_runtime();
        assert!(result.ok, "rollback answered with an error: {:?} ({})", result.error, result.stderr);
        let document = result.document.expect("a rollback document");
        assert_eq!(document["action"], "rollback");
        assert_eq!(document["status"], "no_runtime");
        assert_eq!(document["restarted"], false);
    }

    #[test]
    fn an_odd_install_root_degrades_instead_of_failing() {
        let root = temp_root("odd-root");
        // State never throws (ADR-003): a root that is a file still returns a document
        // that states the root it was asked about.
        let odd_root = temp_root("odd-root-file").join("not-a-folder");
        std::fs::write(&odd_root, b"x").expect("write the decoy file");
        point_at_test_backend(&odd_root);
        let result = get_state_inner();
        assert!(result.ok, "state must degrade, not fail: {:?}", result.error);
        let document = result.document.expect("a state document");
        assert_eq!(document["install_root"], odd_root.to_string_lossy().as_ref());
        assert!(document["model"].is_null(), "no model can be active in an empty install");
        point_at_test_backend(&root);
    }

    #[test]
    fn desktop_settings_tolerate_a_utf8_bom() {
        let settings = parse_desktop_settings("\u{feff}{\"start_minimised_to_tray\":true}");
        assert!(settings.start_minimised_to_tray);
        assert!(parse_desktop_settings("not-json").start_minimised_to_tray == false);
    }

    #[test]
    fn tray_tooltip_is_built_from_the_last_state_document() {
        let document = json!({
            "server": { "state": "running" },
            "model": { "name": "Qwen3-4B" }
        });
        let tooltip = tooltip_for_state(Some(&document));
        assert!(tooltip.contains("Server: running"));
        assert!(tooltip.contains("Model: Qwen3-4B"));
        assert_eq!(tooltip_for_state(None), "llama.cpp Command Center\nServer: unknown\nModel: no active model");
    }

    #[test]
    fn health_poll_requires_a_visible_live_window_and_an_active_server() {
        assert!(should_poll_health(true, false, false, "running"));
        assert!(should_poll_health(true, false, false, "loading"));
        assert!(!should_poll_health(false, false, false, "running"));
        assert!(!should_poll_health(true, true, false, "running"));
        assert!(!should_poll_health(true, false, true, "running"));
        assert!(!should_poll_health(true, false, false, "stopped"));
        assert!(!should_poll_health(true, false, false, "unknown"));
    }

    #[test]
    fn health_parser_handles_success_non_200_timeout_and_partial_responses() {
        assert_eq!(parse_health_response(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"status\":\"ok\"}"), HealthOutcome::Ok);
        assert_eq!(parse_health_response(b"HTTP/1.1 503 Busy\r\n\r\n{}"), HealthOutcome::Non200(503));
        assert_eq!(parse_health_response(b"HTTP/1.1 200 OK\r\nContent-Length: 20\r\n\r\n{"), HealthOutcome::Malformed);
        assert_eq!(parse_health_response(b"HTTP/1.1 200 OK"), HealthOutcome::Malformed);
        assert_eq!(parse_health_response(b""), HealthOutcome::Malformed);
        assert_eq!(parse_health_response(b"not-http\r\n\r\n{}"), HealthOutcome::Malformed);
    }

    #[test]
    fn only_tray_quit_lets_the_process_exit() {
        assert!(should_prevent_exit(false), "a close-to-tray exit request must be refused");
        assert!(!should_prevent_exit(true), "tray Quit must be allowed to exit");
    }

    #[test]
    fn background_and_hidden_helper_commands_have_no_console_window() {
        // Background backend calls, the server launcher, hidden Chat.cmd, and hidden
        // model downloads all use the no-window flag.
        // Including the pieces through concat! keeps this assertion from matching itself.
        let flag_call = concat!(".creation_flags(", "CREATE_NO_WINDOW)");
        assert_eq!(include_str!("main.rs").matches(flag_call).count(), 5);
    }

    #[cfg(windows)]
    #[test]
    fn background_powershell_has_no_console_window() {
        let root = temp_root("no-window");
        let marker = root.join("console-window.txt");
        let script = root.join("console-probe.ps1");
        let script_text = format!(
            r#"param([string]$Action,[string]$InstallRoot)
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ConsoleProbe {{ [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); }}
'@
[IO.File]::WriteAllText('{}', [ConsoleProbe]::GetConsoleWindow().ToString())
"#,
            marker.display()
        );
        std::fs::write(&script, script_text).expect("write the console probe script");
        let output = powershell_command(&script, "Probe", &[], &root)
            .output()
            .expect("run the console probe");
        assert!(
            output.status.success(),
            "console probe failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        let handle = std::fs::read_to_string(&marker).expect("read the console handle");
        assert_eq!(handle.trim(), "0", "background PowerShell must not own a console window");
    }

    #[test]
    fn a_failing_action_keeps_the_command_and_the_real_error() {
        let root = temp_root("failure");
        point_at_test_backend(&root);
        // An action the backend does not accept must fail loudly, and the raw detail has
        // to keep the exact command and the backend's own error text.
        let broken = run_backend("NotAnAction", "bogus", &[]);
        assert!(!broken.ok, "an unknown action must not look like success");
        assert!(broken.error.is_some());
        assert!(broken.command.contains("-Action NotAnAction"));
        assert!(
            broken.stderr.contains("NotAnAction") || broken.stderr.contains("ValidateSet"),
            "the backend's own error text must survive: {}",
            broken.stderr
        );
        assert_ne!(broken.exit_code, Some(0));
    }

    /// The real lifecycle, through the same commands the window calls. Run explicitly:
    ///   cargo test -- --ignored --nocapture live_start_stop
    /// It starts the real server, waits for a real model to load, then stops it: the
    /// soft stop must only ask for confirmation and the forced stop must kill it.
    #[test]
    #[ignore = "starts the real server against the real install and stops it"]
    fn live_start_stop_lifecycle_through_the_app_commands() {
        std::env::set_var("LLAMACPP_SCRIPT", repo_script());
        let info = backend_info();
        assert!(info.ok, "the backend script must be found: {:?}", info.error);

        let before = runtime_health();
        assert!(before.ok, "health failed: {:?}", before.error);
        let before_state = before.document.as_ref().and_then(|d| d["state"].as_str()).unwrap_or("");
        println!("state before start: {before_state} (port {:?})", before.document.as_ref().map(|d| d["port"].clone()));

        if before_state != "running" {
            let started = start_server();
            assert!(started.ok, "start failed: {:?} ({})", started.error, started.stderr);
        }

        let mut phase = String::from("stopped");
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(240);
        while std::time::Instant::now() < deadline {
            std::thread::sleep(std::time::Duration::from_secs(3));
            let probe = runtime_health();
            phase = probe
                .document
                .as_ref()
                .and_then(|d| d["state"].as_str())
                .unwrap_or("")
                .to_string();
            println!("runtime state: {phase}");
            if phase == "running" {
                break;
            }
        }
        assert_eq!(phase, "running", "the server never became ready");

        let diagnostics = get_diagnostics();
        assert!(diagnostics.ok, "diagnose failed: {:?}", diagnostics.error);
        let document = diagnostics.document.expect("a diagnostics document");
        println!("diagnostics overall: {}", document["overall"]);
        assert!(document["runtime_health"]["port_owner"].is_object(), "diagnostics report port ownership");

        let soft = stop_server(false);
        assert!(soft.ok, "the soft stop failed: {:?}", soft.error);
        assert_eq!(
            soft.document.as_ref().and_then(|d| d["status"].as_str()),
            Some("requires_confirmation"),
            "stop without force must never kill the server"
        );
        assert_eq!(
            runtime_health().document.as_ref().and_then(|d| d["state"].as_str()),
            Some("running"),
            "the server must still be running after the soft stop"
        );

        let hard = stop_server(true);
        assert!(hard.ok, "the forced stop failed: {:?}", hard.error);
        println!("forced stop: {}", hard.document.as_ref().expect("a stop document"));
        // Killing a process is asynchronous: the process handle lingers for a moment, so
        // poll instead of assuming the next probe already sees it gone.
        let stop_deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
        let mut after_state = String::from("loading");
        while std::time::Instant::now() < stop_deadline {
            after_state = runtime_health()
                .document
                .as_ref()
                .and_then(|d| d["state"].as_str())
                .unwrap_or("")
                .to_string();
            if after_state == "stopped" {
                break;
            }
            std::thread::sleep(std::time::Duration::from_secs(2));
        }
        assert_eq!(after_state, "stopped", "the forced stop must leave no server running");
        println!("state after the forced stop: {after_state}");
    }

    #[test]
    fn single_instance_protocol_requires_the_exact_token_and_shape() {
        assert!(is_instance_request(&instance_request()));
        assert!(is_instance_ack(&instance_ack()));
        assert!(!is_instance_request(b"show\n"));
        assert!(!is_instance_request(b"show wrong-token\n"));
        assert!(!is_instance_request(b"show llamacpp-command-center-single-instance-v1\nextra"));
        assert!(!is_instance_request(b"show llamacpp-command-center-single-instance-v1"));
        assert!(!is_instance_ack(b"ok\n"));
        assert!(!is_instance_ack(b"ok wrong-token\n"));
        assert!(!is_instance_ack(instance_request().as_slice()));
    }
}

fn instance_request() -> Vec<u8> {
    format!("show {INSTANCE_TOKEN}\n").into_bytes()
}

fn instance_ack() -> Vec<u8> {
    format!("ok {INSTANCE_TOKEN}\n").into_bytes()
}

fn is_instance_request(bytes: &[u8]) -> bool {
    bytes == instance_request()
}

fn is_instance_ack(bytes: &[u8]) -> bool {
    bytes == instance_ack()
}

/// Read one bounded request/response. The deadline is for the whole message, not for each
/// individual read, so a peer that trickles bytes cannot keep the caller waiting.
fn read_instance_message(stream: &mut TcpStream) -> Option<Vec<u8>> {
    let deadline = Instant::now() + INSTANCE_TIMEOUT;
    let mut bytes = Vec::new();
    let mut buffer = [0u8; 64];
    loop {
        let remaining = deadline.checked_duration_since(Instant::now())?;
        let _ = stream.set_read_timeout(Some(remaining.max(Duration::from_millis(1))));
        match stream.read(&mut buffer) {
            Ok(0) => break,
            Ok(read) => {
                let room = INSTANCE_MESSAGE_LIMIT.saturating_sub(bytes.len());
                if room == 0 {
                    break;
                }
                bytes.extend_from_slice(&buffer[..read.min(room)]);
                if bytes.contains(&b'\n') || bytes.len() >= INSTANCE_MESSAGE_LIMIT {
                    break;
                }
            }
            Err(error)
                if error.kind() == std::io::ErrorKind::WouldBlock
                    || error.kind() == std::io::ErrorKind::TimedOut => break,
            Err(_) => return None,
        }
    }
    Some(bytes)
}

/// Send the exact request and require the exact acknowledgement. A connection without a
/// valid reply is a foreign listener, not an instance to hand this launch to.
fn forward_to_running_instance() -> bool {
    let address = SocketAddr::from(([127, 0, 0, 1], SINGLE_INSTANCE_PORT));
    let Ok(mut stream) = TcpStream::connect_timeout(&address, INSTANCE_CONNECT_TIMEOUT) else {
        return false;
    };
    let _ = stream.set_write_timeout(Some(INSTANCE_TIMEOUT));
    if stream.write_all(&instance_request()).is_err() {
        return false;
    }
    read_instance_message(&mut stream).is_some_and(|reply| is_instance_ack(&reply))
}

/// Listen for the handoff on the Tauri main thread's message loop. Recreating a destroyed
/// webview from the accept thread is unsafe and was the reopen failure: the window object
/// was created, but its native window could not be brought up reliably.
fn start_instance_listener(app: AppHandle) {
    match TcpListener::bind(("127.0.0.1", SINGLE_INSTANCE_PORT)) {
        Ok(listener) => {
            std::thread::spawn(move || {
                for stream in listener.incoming() {
                    let Ok(mut stream) = stream else { continue };
                    let Some(request) = read_instance_message(&mut stream) else { continue };
                    if !is_instance_request(&request) {
                        let _ = stream.write_all(b"no\n");
                        continue;
                    }
                    let _ = stream.set_write_timeout(Some(INSTANCE_TIMEOUT));
                    let _ = stream.write_all(&instance_ack());
                    // Let the second process close first. If the listener closes first, the
                    // server side of the accepted socket sits in TIME_WAIT on port 47821
                    // and a later launch can fail to bind after Quit.
                    let _ = stream.set_read_timeout(Some(Duration::from_millis(250)));
                    let mut drain = [0u8; 1];
                    let _ = stream.read(&mut drain);
                    let dispatcher = app.clone();
                    let for_window = app.clone();
                    let _ = dispatcher.run_on_main_thread(move || show_main_window(&for_window));
                }
            });
        }
        Err(error) => {
            // The port may belong to a foreign process, or a simultaneous cold start may
            // have won the bind. The second case has a valid handshake and exits; the first
            // must continue as a normal first instance rather than trusting the port.
            if forward_to_running_instance() {
                std::process::exit(0);
            }
            eprintln!(
                "Single-instance port {SINGLE_INSTANCE_PORT} is owned by another process; continuing without handoff: {error}"
            );
        }
    }
}

fn main() {
    // Before Tauri (and WebView2) starts, hand a second launch to the live app. The
    // listener is created in setup, so two simultaneous cold starts still race safely:
    // the later bind fails and exits.
    if forward_to_running_instance() {
        return;
    }
    let app = tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![
            backend_info,
            get_state,
            get_desktop_settings,
            save_desktop_settings,
            get_recommendations,
            get_diagnostics,
            runtime_health,
            start_server,
            stop_server,
            update_runtime,
            get_runtime_updates,
            copy_to_clipboard,
            rollback_runtime,
            get_settings,
            save_settings,
            get_library,
            library_change,
            download_model,
            open_chat
        ])
        .setup(|app| {
            start_instance_listener(app.handle().clone());
            app.manage(TrayMemory::default());
            app.manage(HealthPoll::default());
            app.manage(QuitRequested::default());
            build_tray(app.handle())?;
            let settings = read_desktop_settings(app.handle());
            let visible = !settings.start_minimised_to_tray;
            if let Some(window) = app.get_webview_window("main") {
                if settings.start_minimised_to_tray {
                    let _ = window.hide();
                } else {
                    let _ = window.show();
                    let _ = window.set_focus();
                }
            }
            health_window_changed(app.handle(), visible, false);
            start_health_monitor(app.handle().clone());
            Ok(())
        })
        .on_window_event(|window, event| {
            if window.label() == "main" {
                if let WindowEvent::CloseRequested { api, .. } = event {
                    // Keep the process and tray alive; the webview is destroyed so its
                    // WebView2 children are released. Open recreates it. Hide before the
                    // destroy: destroy waits for WebView2 teardown, and leaving the window
                    // visible during that wait made close-to-tray look stalled for 15 s.
                    // Destroy from a short-lived worker rather than re-entering the event
                    // loop from the close callback: destroying the last window immediately
                    // emits ExitRequested, and doing that inside this callback raced the
                    // close prevention on a rapid close/open/close cycle.
                    health_window_changed(window.app_handle(), false, false);
                    api.prevent_close();
                    let window = window.clone();
                    std::thread::spawn(move || {
                        // Hide from the worker as well: the close callback itself can be
                        // busy with WebView2 teardown, so asking the event loop to hide
                        // before returning delayed the visible change by about 9 s.
                        let _ = window.hide();
                        std::thread::sleep(Duration::from_millis(50));
                        let _ = window.destroy();
                    });
                }
                if let WindowEvent::Destroyed = event {
                    health_window_changed(window.app_handle(), false, true);
                }
                if let WindowEvent::Resized(_) = event {
                    let visible = window.is_visible().unwrap_or(false)
                        && !window.is_minimized().unwrap_or(false);
                    health_window_changed(window.app_handle(), visible, false);
                }
                if let WindowEvent::Focused(true) = event {
                    health_window_changed(window.app_handle(), true, false);
                }
            }
        })
        .build(tauri::generate_context!())
        .expect("the command center window failed to start");

    app.run(|app, event| {
        match event {
            RunEvent::ExitRequested { api, .. } => {
                let quitting = app
                    .try_state::<QuitRequested>()
                    .map(|flag| flag.0.load(Ordering::SeqCst))
                    .unwrap_or(false);
                if should_prevent_exit(quitting) {
                    api.prevent_exit();
                }
            }
            // Quit is allowed to leave the event loop only after the server it started and
            // the hidden helpers are stopped. A pre-existing server has no LAUNCHER and is
            // deliberately not touched.
            RunEvent::Exit => shutdown_owned_processes(),
            _ => {}
        }
    });
}
