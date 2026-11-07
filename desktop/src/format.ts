// Pure display rules. Everything the window shows is derived here from a typed backend
// document, so the rules are unit testable without a window or a backend (ADR-006 §4).

import type {
  BackendResult,
  DiagnosticDocument,
  HardwareProfile,
  LibraryModel,
  UnlockableModel,
  ModelState,
  PortOwner,
  RouterModelState,
  RuntimeState,
  ServerPhase,
  Tier
} from "./types";

export function describeServer(phase: ServerPhase | string | undefined): string {
  switch (phase) {
    case "running":
      return "Running and answering health checks";
    case "loading":
      return "Starting — the model is loading into the GPU";
    case "stopped":
      return "Stopped";
    default:
      return "Unknown — the backend did not report a server state";
  }
}

export function isRunning(phase: ServerPhase | string | undefined): boolean {
  return phase === "running";
}

export function describeRuntime(runtime: RuntimeState | null): string {
  if (!runtime || !runtime.tag) {
    return "No runtime installed yet — run the installer from the command line";
  }
  const installed = runtime.installed_at ? `, installed ${runtime.installed_at.slice(0, 10)}` : "";
  const build = runtime.exe_present ? "" : " (llama-server.exe is missing)";
  return `${runtime.backend} ${runtime.tag}${installed}${build}`;
}

export function describeModel(model: ModelState | null): string {
  if (!model) {
    return "No model selected yet";
  }
  const context = model.context_size > 0 ? `${Math.round(model.context_size / 1024)}k context` : "context not recorded";
  const missing = model.model_present ? "" : " — the file is missing from disk";
  return `${model.name} (${model.alias}), ${context}${missing}`;
}

export function describeSupport(level: string | undefined, confidence: string | undefined): string {
  switch (level) {
    case "supported":
      return `Supported (${confidence ?? "unknown"} confidence)`;
    case "warning":
      return `Supported with warnings (${confidence ?? "unknown"} confidence)`;
    case "unsupported":
      return `Not supported (${confidence ?? "unknown"} confidence)`;
    default:
      return "Hardware support unknown";
  }
}

export function describeGpu(hardware: HardwareProfile | null): string {
  if (!hardware) {
    return "Hardware scan unavailable";
  }
  const dedicated = hardware.Gpus.filter((gpu) => !gpu.IsIntegrated);
  const named = hardware.RocmGpu || (dedicated[0] && dedicated[0].Name) || hardware.CpuName;
  const vram = hardware.MaxAmdVramGiB > 0 ? `, ${hardware.MaxAmdVramGiB} GiB VRAM` : "";
  const ram = hardware.RamGiB > 0 ? `, ${hardware.RamGiB} GiB system RAM` : "";
  const igpu = hardware.Gpus.some((gpu) => gpu.IsIntegrated) ? " (an integrated Radeon is present and never used automatically)" : "";
  return `${named}${vram}${ram}${igpu}`;
}

export function describeTierStatus(status: string | undefined): string {
  switch (status) {
    case "recommended":
      return "Recommended";
    case "supported":
      return "Supported";
    case "experimental":
      return "Experimental";
    case "unsupported":
      return "Not supported on this runtime";
    default:
      return "Unknown";
  }
}

/** The backend's reason already states residency (VRAM or system RAM), so it is not repeated here. */
export function describeTier(tier: Tier | undefined): string {
  if (!tier) {
    return "No recommendation for this tier";
  }
  const blockers = tier.blockers.length > 0 ? ` Blockers: ${tier.blockers.join(" ")}` : "";
  return `${tier.model_name} — ${describeTierStatus(tier.status)} (${tier.confidence} confidence). ${tier.reason}${blockers}`;
}

/**
 * The tab the arrow, Home and End keys move to (ARIA tabs pattern, wrapping at the ends),
 * or null when the key is not one of those. Keeps the keyboard rule testable.
 */
export function nextTabIndex(key: string, current: number, count: number): number | null {
  switch (key) {
    case "ArrowRight":
      return (current + 1) % count;
    case "ArrowLeft":
      return (current - 1 + count) % count;
    case "Home":
      return 0;
    case "End":
      return count - 1;
    default:
      return null;
  }
}

/** What the model inside a running server is doing; empty when the backend did not say. */
export function describeModelState(modelState: RouterModelState | string | undefined): string {
  switch (modelState) {
    case "loaded":
      return "model loaded";
    case "asleep":
      return "model asleep: it frees graphics memory and loads again on your next message";
    case "unloaded":
      return "model unloaded: it loads again on your next message";
    case "loading":
      return "model loading";
    default:
      return "";
  }
}

/** The game-pause line under the setting: what the number means, or why it is unavailable. */
export function describeGamePause(gib: number | null | undefined, capable: boolean | undefined): string {
  if (capable !== true) {
    return "Needs a newer llama.cpp (router mode). Update llama.cpp first.";
  }
  if (!gib) {
    return "Off. The model stays in graphics memory until you stop the server.";
  }
  return `When other programs hold ${gib} GiB or more of graphics memory, the model unloads. It loads again on your next message, or once they have left for a minute.`;
}

/** Validation for the game-pause box: 0 is off, otherwise a whole number from 4 to 40. */
export function isGamePauseValid(text: string): boolean {
  const trimmed = text.trim();
  if (!/^\d+$/.test(trimmed)) {
    return false;
  }
  const value = Number(trimmed);
  return value === 0 || (value >= 4 && value <= 40);
}

export type BadgeTone = "ok" | "busy" | "off" | "unknown";

/** The header badge: one word and one colour for the server phase, and "Asleep" when the model is out of memory. */
export function describeStatusBadge(
  phase: ServerPhase | string | undefined,
  modelState?: RouterModelState | string
): { label: string; tone: BadgeTone } {
  switch (phase) {
    case "running":
      if (modelState === "asleep" || modelState === "unloaded") {
        return { label: "Asleep", tone: "off" };
      }
      return { label: "Running", tone: "ok" };
    case "loading":
      return { label: "Starting…", tone: "busy" };
    case "stopped":
      return { label: "Stopped", tone: "off" };
    default:
      return { label: "Unknown", tone: "unknown" };
  }
}

export function describePortOwner(owner: PortOwner | null | undefined): string {
  if (!owner || owner.status === "free") {
    return "The port is free";
  }
  if (owner.status === "owned") {
    return `${owner.process_name} (PID ${owner.process_id}) already runs this server, so it is validated instead of restarted`;
  }
  return owner.message || `Another program holds the port (PID ${owner.process_id})`;
}

export function describeOverall(status: string | undefined, confidence: string | undefined): string {
  switch (status) {
    case "ok":
      return `Everything checks out (${confidence ?? "unknown"} confidence)`;
    case "degraded":
      return `Working, with warnings (${confidence ?? "unknown"} confidence)`;
    case "broken":
      return `Something is broken (${confidence ?? "unknown"} confidence)`;
    default:
      return "No verdict from the backend";
  }
}

export function formatElapsed(milliseconds: number): string {
  const seconds = Math.max(0, Math.floor(milliseconds / 1000));
  if (seconds < 60) {
    return `${seconds}s`;
  }
  const minutes = Math.floor(seconds / 60);
  return `${minutes}m ${seconds % 60}s`;
}

export function formatStartProgress(phase: ServerPhase | string | undefined, elapsedMs: number): string {
  const elapsed = formatElapsed(elapsedMs);
  if (phase === "loading") {
    return `Loading the model into the GPU — ${elapsed} so far. The server window shows the live log.`;
  }
  if (phase === "running") {
    return `Running — ready after ${elapsed}.`;
  }
  return `Waiting for the server to answer — ${elapsed} so far. The server window shows the live log.`;
}

/** Why the window cannot show anything yet: the exact places that were searched. */
export function describeMissingBackend(result: BackendResult): string {
  const searched = result.candidates.length > 0 ? ` Checked: ${result.candidates.join(", ")}.` : "";
  return `${result.error ?? "The backend is unavailable."} Install root: ${result.install_root}.${searched}`;
}

// --- Settings display and validation rules -------------------------------

/** The use-case choices, labelled the way the console picker labels them. */
const USE_CASE_LABELS: Record<string, string> = {
  chat: "Everyday chat",
  coding: "Coding help",
  images: "Pictures and screenshots",
  fast: "Quick answers",
  quality: "Best answers"
};

export function describeUseCase(id: string): string {
  return USE_CASE_LABELS[id] ?? id;
}

/** Idle-unload wording that asserts the capability instead of offering a dead control. */
export function describeIdleCapability(capable: boolean | undefined, installedModels: number | undefined): string {
  const installed = typeof installedModels === "number" && Number.isFinite(installedModels) && installedModels > 0;
  if (capable !== true) {
    return installed
      ? "The installed llama.cpp is too old to unload the model when idle. Update the runtime first."
      : "Idle unload needs llama.cpp installed. Set up the AI first.";
  }
  return "After this many minutes of chat silence the model leaves graphics memory and returns on your next message.";
}

/**
 * What the idle choice means for the Radeon, in GiB: the same arithmetic the
 * recommendation engine uses (Get-VramHeadroom keeps 10% of VRAM aside, then the
 * weights come out of it when the model unloads). Null everywhere the hardware scan
 * or the active model is unknown — the window then stays silent instead of guessing.
 */
export function describeIdleVramEffect(vramGiB: number | null | undefined, footprintGiB: number | null | undefined): string | null {
  const vram = typeof vramGiB === "number" && Number.isFinite(vramGiB) && vramGiB > 0 ? vramGiB : null;
  const held = typeof footprintGiB === "number" && Number.isFinite(footprintGiB) && footprintGiB > 0 ? footprintGiB : null;
  if (vram === null || held === null) {
    return null;
  }
  return `Unloading the model frees an estimated ${Math.min(held, vram).toFixed(1)} GiB of the Radeon's ${vram.toFixed(1)} GiB (weights, context cache and compute buffers).`;
}

/** The minutes a save attempt asks for, validated the same way the backend validates. */
export function isMinutesValid(minutes: number | null | undefined): boolean {
  return typeof minutes === "number" && Number.isInteger(minutes) && minutes >= 0 && minutes <= 1440;
}

/** True when the string is one of the use cases the backend's document lists. */
export function isUseCaseValid(id: string, allowed: string[]): boolean {
  return allowed.includes(id);
}

/** One-line summary of a save result, naming every rejected field and its reason. */
export function describeSettingsSave(
  applied: number | null | undefined,
  rejected: { field: string; reason?: string }[] | null | undefined
): string {
  const rejectedFields = Array.isArray(rejected) ? rejected : [];
  const appliedCount = typeof applied === "number" && Number.isFinite(applied) ? applied : 0;
  if (rejectedFields.length === 0) {
    return appliedCount > 0 ? `Saved (${appliedCount} setting${appliedCount === 1 ? "" : "s"}).` : "Nothing to change.";
  }
  const parts = rejectedFields.map((r) => `${r.field}: ${r.reason ?? "rejected"}`);
  return `Not saved — ${parts.join("; ")}`;
}

// --- Model library display rules -----------------------------------------

/** Size and capability badges, e.g. "7 GB · tools · vision". Never invents a flag. */
export function describeLibraryBadges(model: LibraryModel): string {
  const parts = [`${model.approx_gib} GB`];
  if (model.tools) {
    parts.push("tools");
  }
  if (model.vision) {
    parts.push("vision");
  }
  if (model.experimental) {
    parts.push("experimental");
  }
  return parts.join(" · ");
}

/** One line of fit wording; empty when the backend could not assess (no hardware scan). */
export function describeLibraryFit(model: LibraryModel): string {
  switch (model.fit_status) {
    case "EXCELLENT":
      return model.gpu_resident ? "Fits fully in VRAM with headroom" : "Fits in the memory budget";
    case "GOOD":
      return "Fits, with little headroom";
    case "TIGHT":
      return "Marginal fit — expect some slowdown";
    case "SLOWER":
      return "Partly loads from system RAM, so replies are slower";
    case "NOT RECOMMENDED":
      return "Does not fit this machine's memory budget";
    default:
      return "";
  }
}

/** What each model's local state means, asserted from the backend's fields. */
export function describeLibraryState(model: LibraryModel): string {
  if (model.active) {
    return "Active now";
  }
  if (model.runtime_blocker) {
    return `Blocked: the installed runtime cannot run it`;
  }
  if (model.downloaded) {
    return "Downloaded — activate to switch to it";
  }
  return "Not downloaded";
}

/** Which operation is possible right now. The screen renders exactly one per model. */
export type LibraryOperation = "download" | "activate" | "remove" | "blocked" | "active" | "none";

export function libraryOperation(model: LibraryModel): LibraryOperation {
  if (model.active) {
    return "active";
  }
  if (model.runtime_blocker) {
    return "blocked";
  }
  if (model.downloaded) {
    return "remove";
  }
  if (model.experimental) {
    // Experimental models download only when no blocker exists; the backend already
    // refuses them with the same reason, so the UI mirrors it instead of hiding them.
    return "blocked";
  }
  return "download";
}

/** What the update button says a newer runtime would unlock — only names the
 * catalogue itself listed; never invents model names or counts. */
export function describeUnlockableModels(models: UnlockableModel[] | null | undefined): string | null {
  if (!models || models.length === 0) {
    return null;
  }
  const names = models.map((m) => m.name).join(", ");
  return models.length === 1
    ? `Updating unlocks: ${names}.`
    : `Updating unlocks ${models.length} models: ${names}.`;
}

/** Confirmation wording; nothing the screen shows is stronger than the backend's own rule. */
export function libraryConfirmText(model: LibraryModel, operation: LibraryOperation): string | null {
  if (operation === "remove") {
    return `Delete ${model.name} (${model.approx_gib} GB) from disk? You can download it again later.`;
  }
  if (operation === "download") {
    return `Download ${model.name}, about ${model.approx_gib} GB? The size and SHA-256 are checked against the published values.`;
  }
  return null;
}

/** A change result line: status plus the backend's own sentence. */
export function describeLibraryResult(status: string, detail: string): { message: string; ok: boolean } {
  const ok = status === "activated" || status === "removed" || status === "validated";
  return { message: detail || status, ok };
}

export function describeDiagnostics(diagnostics: DiagnosticDocument | null): string {
  if (!diagnostics) {
    return "No diagnostics have been collected yet";
  }
  return describeOverall(diagnostics.overall?.status, diagnostics.overall?.confidence);
}
