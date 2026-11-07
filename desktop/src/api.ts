import { invoke } from "@tauri-apps/api/core";
import type { BackendResult, DesktopSettings } from "./types";

// Every call is one backend action. The Rust supervisor runs the PowerShell script,
// captures its UTF-8 JSON document and returns it with the raw call detail. Nothing in
// this file reads a file, parses output text, or decides what the state is.

export function backendInfo(): Promise<BackendResult> {
  return invoke<BackendResult>("backend_info");
}

export function getState(): Promise<BackendResult> {
  return invoke<BackendResult>("get_state");
}

export function getRecommendations(): Promise<BackendResult> {
  return invoke<BackendResult>("get_recommendations");
}

export function getDiagnostics(): Promise<BackendResult> {
  return invoke<BackendResult>("get_diagnostics");
}

export function runtimeHealth(): Promise<BackendResult> {
  return invoke<BackendResult>("runtime_health");
}

export function startServer(): Promise<BackendResult> {
  return invoke<BackendResult>("start_server");
}

export function stopServer(force: boolean): Promise<BackendResult> {
  return invoke<BackendResult>("stop_server", { force });
}

export function updateRuntime(force: boolean): Promise<BackendResult> {
  return invoke<BackendResult>("update_runtime", { force });
}

export function copyToClipboard(text: string): Promise<void> {
  return invoke<void>("copy_to_clipboard", { text });
}

export function getRuntimeUpdates(): Promise<BackendResult> {
  return invoke<BackendResult>("get_runtime_updates");
}

export function rollbackRuntime(): Promise<BackendResult> {
  return invoke<BackendResult>("rollback_runtime");
}

export function getDesktopSettings(): Promise<DesktopSettings> {
  return invoke<DesktopSettings>("get_desktop_settings");
}

export function saveDesktopSettings(startMinimisedToTray: boolean): Promise<DesktopSettings> {
  return invoke<DesktopSettings>("save_desktop_settings", { startMinimisedToTray });
}

export function getSettings(): Promise<BackendResult> {
  return invoke<BackendResult>("get_settings");
}

export function saveSettings(patch: string): Promise<BackendResult> {
  return invoke<BackendResult>("save_settings", { patch });
}

export function getLibrary(): Promise<BackendResult> {
  return invoke<BackendResult>("get_library");
}

export function libraryChange(action: string, modelId: string): Promise<BackendResult> {
  return invoke<BackendResult>("library_change", { action, modelId });
}

/** Opens the install's own Chat.cmd (starts the AI first when it is off). */
export function openChat(): Promise<BackendResult> {
  return invoke<BackendResult>("open_chat");
}

export function downloadModel(modelId: string): Promise<BackendResult> {
  return invoke<BackendResult>("download_model", { modelId });
}
