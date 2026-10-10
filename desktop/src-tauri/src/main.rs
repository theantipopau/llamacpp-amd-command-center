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

use serde::Serialize;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::process::Command;

const SCRIPT_NAME: &str = "Install-LlamaCpp-AMD.ps1";
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
    command
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
#[tauri::command]
fn get_state() -> BackendResult {
    run_backend("State", "state", &[])
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

/// Start the server through the supported adapter entry point, detached, in its own
/// console window so the user watches the real server log. The port-ownership guard and
/// the loader diagnostics live in the backend, not here.
#[tauri::command]
fn start_server() -> BackendResult {
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
        "cmd.exe /C start \"llama.cpp AI server\" /D \"{}\" powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"{}\" -Action Runtime -RuntimeAction start -InstallRoot \"{}\"",
        root.display(),
        script.display(),
        root.display()
    );
    let spawned = Command::new("cmd.exe")
        .args(["/C", "start", "llama.cpp AI server", "/D"])
        .arg(&root)
        .arg("powershell.exe")
        .args(["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File"])
        .arg(&script)
        .args(["-Action", "Runtime", "-RuntimeAction", "start"])
        .arg("-InstallRoot")
        .arg(&root)
        .status();

    let candidates = script_candidates()
        .iter()
        .map(|path| path.display().to_string())
        .collect();
    match spawned {
        Ok(status) if status.success() => BackendResult {
            ok: true,
            action: "runtime:start".to_string(),
            document: Some(json!({
                "spawned": true,
                "launcher_console": console_command,
                "health_before_start": health.document,
            })),
            error: None,
            command: console_command,
            exit_code: status.code(),
            stderr: String::new(),
            install_root: root_text,
            script: Some(script.display().to_string()),
            candidates,
        },
        Ok(status) => BackendResult {
            ok: false,
            action: "runtime:start".to_string(),
            document: None,
            error: Some(format!(
                "The server window did not open (cmd.exe exit code {}).",
                status.code().unwrap_or(-1)
            )),
            command: console_command,
            exit_code: status.code(),
            stderr: String::new(),
            install_root: root_text,
            script: Some(script.display().to_string()),
            candidates,
        },
        Err(spawn_error) => BackendResult {
            ok: false,
            action: "runtime:start".to_string(),
            document: None,
            error: Some(format!("Could not open the server window: {spawn_error}")),
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
    run_backend("Runtime", if force { "runtime:stop:force" } else { "runtime:stop" }, &extra)
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

/// A download runs for minutes. Validate first (the backend answers with a typed result
/// that carries the refreshed library), and open the real transfer in its own console
/// window through the proven `-Action Models -ModelId <id>` path, detached from this
/// process so the window is never tied to the download.
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
        let spawned = Command::new("cmd.exe")
            .args([
                "/C",
                "start",
                "llama.cpp model download",
                "/D",
            ])
            .arg(&root)
            .arg("powershell.exe")
            .args(["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File"])
            .arg(&script)
            .args(["-Action", "Models", "-ModelId", &model_id, "-Force"])
            .arg("-InstallRoot")
            .arg(&root)
            .status();
        let candidates = script_candidates()
            .iter()
            .map(|path| path.display().to_string())
            .collect();
        match spawned {
            Ok(status_ok) if status_ok.success() => BackendResult {
                ok: true,
                action: "library:download".to_string(),
                document: validated.document,
                error: None,
                command: format!("-Action Models -ModelId {model_id} -Force"),
                exit_code: status_ok.code(),
                stderr: String::new(),
                install_root: root_text,
                script: Some(script.display().to_string()),
                candidates,
            },
            Ok(status_failed) => BackendResult {
                ok: false,
                action: "library:download".to_string(),
                document: None,
                error: Some(format!(
                    "The download window did not open (cmd.exe exit code {}).",
                    status_failed.code().unwrap_or(-1)
                )),
                command: format!("-Action Models -ModelId {model_id} -Force"),
                exit_code: status_failed.code(),
                stderr: String::new(),
                install_root: root_text,
                script: Some(script.display().to_string()),
                candidates,
            },
            Err(spawn_error) => BackendResult {
                ok: false,
                action: "library:download".to_string(),
                document: None,
                error: Some(format!("Could not open the download window: {spawn_error}")),
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
        let result = get_state();
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
    fn an_odd_install_root_degrades_instead_of_failing() {
        let root = temp_root("odd-root");
        // State never throws (ADR-003): a root that is a file still returns a document
        // that states the root it was asked about.
        let odd_root = temp_root("odd-root-file").join("not-a-folder");
        std::fs::write(&odd_root, b"x").expect("write the decoy file");
        point_at_test_backend(&odd_root);
        let result = get_state();
        assert!(result.ok, "state must degrade, not fail: {:?}", result.error);
        let document = result.document.expect("a state document");
        assert_eq!(document["install_root"], odd_root.to_string_lossy().as_ref());
        assert!(document["model"].is_null(), "no model can be active in an empty install");
        point_at_test_backend(&root);
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
}

fn main() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![
            backend_info,
            get_state,
            get_recommendations,
            get_diagnostics,
            runtime_health,
            start_server,
            stop_server,
            update_runtime,
            get_settings,
            save_settings,
            get_library,
            library_change,
            download_model
        ])
        .run(tauri::generate_context!())
        .expect("the command center window failed to start");
}
