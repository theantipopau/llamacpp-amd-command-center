// Typed view of the backend documents the window renders (State, Recommend, Diagnose and
// the runtime adapter result). These types describe a *subset* of the contract: the
// backend states that consumers must ignore fields they do not know, so every field here
// exists out of the document, not out of guesswork (ADR-003, ADR-005, ADR-006).

export interface BackendResult {
  ok: boolean;
  action: string;
  document: unknown;
  error: string | null;
  command: string;
  exit_code: number | null;
  stderr: string;
  install_root: string;
  script: string | null;
  candidates: string[];
}

export type ServerPhase = "running" | "loading" | "stopped";

/** The model inside a running server: loaded, asleep (memory released, wakes on the next request), unloaded, loading or unknown. */
export type RouterModelState = "loaded" | "asleep" | "unloaded" | "loading" | "unknown";

export interface ServerState {
  state: ServerPhase;
  port: number;
  base_url: string;
  process_ids: number[];
  model_state?: RouterModelState;
}

export interface ModelState {
  id: string;
  alias: string;
  name: string;
  context_size: number;
  port: number;
  model_present: boolean;
  runtime_blocker: string;
}

export interface RuntimeState {
  tag: string;
  backend: string;
  installed_at: string;
  exe_present: boolean;
}

export interface GpuInfo {
  Name: string;
  IsAmd: boolean;
  IsIntegrated: boolean;
  VramGiB: number;
}

export interface HardwareProfile {
  CpuName: string;
  CpuCores: number;
  CpuThreads: number;
  RamGiB: number;
  RocmGpu: string;
  MaxAmdVramGiB: number;
  Gpus: GpuInfo[];
  support: { level: string; confidence: string; reasons: string[] };
  recommendation: { backend: string; model_id: string; confidence: string; reason: string };
}

/** The backend's graphics-memory estimate for the active model (always an estimate). */
export interface VramEstimate {
  estimate: boolean;
  available?: boolean;
  weights_gib: number;
  kv_gib: number;
  compute_gib: number;
  headroom_gib: number;
  needed_gib: number;
  total_gib: number;
  used_gib?: number;
  free_gib?: number;
  context_tokens?: number;
  slots?: number;
  verdict: "fits" | "tight" | "will_not_fit" | string;
  confidence: string;
  warnings?: string[];
}

export interface StateDocument {
  schema_version: number;
  generated_at: string;
  command_center_version: string;
  install_root: string;
  runtime: RuntimeState | null;
  model: ModelState | null;
  server: ServerState;
  models: Array<{ id: string; name: string; state: string }>;
  settings: { idle_sleep_minutes: number | null; use_case: string | null };
  idle_minutes: number;
  editors: { vscode: string };
  desktop_shortcuts: string;
  hardware: HardwareProfile | null;
  hardware_error: string | null;
  /** Optional so an older backend document still parses; null with no active model or Radeon. */
  vram_estimate?: VramEstimate | null;
}

export interface Tier {
  tier: string;
  model_id: string;
  model_name: string;
  status: string;
  confidence: string;
  reason: string;
  gpu_resident: boolean;
  blockers: string[];
}

export interface RecommendationDocument {
  schema_version: number;
  generated_at: string;
  hardware_error: string | null;
  recommended: { fast: Tier; balanced: Tier; maximum: Tier };
}

export interface PortOwner {
  status: "free" | "owned" | "conflict";
  process_id: number;
  process_name: string;
  message: string;
}

export interface RuntimeHealthSection {
  adapter: string;
  state: ServerPhase;
  ok: boolean;
  validation_status: string;
  capabilities_available: boolean;
  confidence: string;
  port: number;
  port_owner: PortOwner;
  warnings: string[];
  blockers: string[];
}

export interface DiagnosticDocument {
  schema_version: number;
  generated_at: string;
  command_center_version: string;
  install_root: string;
  runtime_health: RuntimeHealthSection | null;
  hardware_health: {
    level: string | null;
    confidence: string;
    reasons: string[];
    backend: string;
    recommended_model: string;
    error: string | null;
  } | null;
  model_health: {
    id: string;
    present: boolean;
    fit: string;
    blocker: string;
    confidence: string;
    warnings: string[];
    blockers: string[];
  } | null;
  editor_health: {
    confidence: string;
    vscode: { state: string; connected: boolean };
    ll_continue: { configured: boolean };
    llama_vscode: { endpoint_set: boolean };
    warnings: string[];
  } | null;
  warnings: string[];
  blockers: string[];
  overall: { status: string; confidence: string };
}

export interface RuntimeHealthDocument {
  adapter: string;
  state: ServerPhase;
  ok: boolean;
  confidence: string;
  reason: string;
  process_ids: number[];
  port: number;
  base_url: string;
}

export interface RuntimeAdapterResult {
  adapter: string;
  status: string;
  detail: string;
  killed?: number;
}

/** Desktop-only preferences stored next to the app, not in the backend settings.json. */
export interface DesktopSettings {
  start_minimised_to_tray: boolean;
}

/** One backend family's newest-build check (`-RuntimeAction updates`). */
export interface RuntimeUpdateEntry {
  backend: string;
  installed_tag: string;
  latest_tag: string;
  channel: string;
  update_available: boolean;
  checked_at: string;
  cached: boolean;
  stale: boolean;
  error: string;
}

export interface RuntimeUpdatesDocument {
  schema_version: number;
  generated_at: string;
  updates: RuntimeUpdateEntry[];
}

/** The typed answer of `-RuntimeAction rollback`. */
export interface RuntimeRollbackDocument {
  schema_version: number;
  action: string;
  status: string;
  detail: string;
  backend: string;
  from_tag: string;
  to_tag: string;
  restarted: boolean;
}

/** The settings document the backend prints for `-Action Settings` (read). */
export interface SettingsDocument {
  schema_version: number;
  generated_at: string;
  install_root: string;
  /** The discrete Radeon's VRAM and the active model's size, null when unknown. */
  gpu_vram_gib: number | null;
  active_model_gib: number | null;
  /** Estimated graphics memory the loaded model holds (weights, KV cache, compute), null when unknown. */
  active_model_footprint_gib?: number | null;
  idle_unload: { minutes: number | null; capable: boolean; installed_models: number };
  use_case: { saved: string | null; allowed: string[] };
  /** Optional so an older backend document still parses. */
  game_pause?: { gib: number; capable: boolean; min: number; max: number };
}

/** One applied or rejected field in the settings save result. */
export interface SettingsPatchOutcome {
  field: string;
  note?: string;
  value?: number | string;
  reason?: string;
}

/** The save result the backend prints for `-Action Settings -SettingsPatch`. */
export interface SettingsSaveDocument {
  schema_version: number;
  generated_at: string;
  applied: SettingsPatchOutcome[];
  rejected: SettingsPatchOutcome[];
  settings: SettingsDocument | null;
}

/** One measured speed number from a Tune run on this PC. */
export interface ReceiptSpeed {
  tokens: number;
  tokens_per_second: number;
  noisy: boolean;
}

/** "Tested on this PC": one backend's saved benchmark for one model. */
export interface LibraryReceipt {
  backend: string;
  runtime_tag: string;
  job_id: string;
  measured_at: string;
  gpu_layers: number | null;
  prompt: ReceiptSpeed[];
  decode: ReceiptSpeed | null;
  unreliable: boolean;
}

/** One model entry in the backend's Library document. */
export interface LibraryModel {
  id: string;
  name: string;
  alias: string;
  approx_gib: number;
  tools: boolean;
  vision: boolean;
  experimental: boolean;
  downloaded: boolean;
  active: boolean;
  runtime_blocker: string;
  fit_status: string;
  gpu_resident: boolean;
  /** Optional so an older backend document still parses. */
  preferred_backend?: string;
  backend_source?: "user" | "default" | string;
  backend_reason?: string;
  /** "" when the user has not chosen; otherwise Vulkan or ROCm. */
  backend_override?: string;
  receipts?: LibraryReceipt[];
}

/** One model a newer runtime would unblock (catalogue-derived, id+name only). */
export interface UnlockableModel {
  id: string;
  name: string;
}

/** The read document the backend prints for `-Action Library`. */
export interface LibraryDocument {
  schema_version: number;
  generated_at: string;
  install_root: string;
  active_model_id: string;
  models: LibraryModel[];
  /** Models a newer llama.cpp build would unblock; empty when none or no runtime. */
  unlocked_models: UnlockableModel[] | null;
  active_backend?: string;
  /** Why measured backends are not a like-for-like comparison, from the saved Tune run. */
  receipts_caveat?: string;
  hardware_error: string | null;
}

/** The typed result of a library change; `library` re-syncs the screen. */
export interface LibraryResultDocument {
  schema_version: number;
  generated_at: string;
  action: string;
  model_id: string;
  status: string;
  detail: string;
  library: LibraryDocument | null;
}

/** Narrow an unknown backend document to one of the typed views without throwing. */
export function asDocument<T>(document: unknown): T | null {
  return document && typeof document === "object" ? (document as T) : null;
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function asFiniteNumber(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function asPositiveNumber(value: unknown): number | null {
  const number = asFiniteNumber(value);
  return number !== null && number > 0 ? number : null;
}

function asNonNegativeCount(value: unknown): number {
  const number = asFiniteNumber(value);
  return number !== null && number > 0 ? Math.trunc(number) : 0;
}

function asMinutes(value: unknown): number | null {
  const number = asFiniteNumber(value);
  return number !== null && Number.isInteger(number) && number >= 0 && number <= 1440 ? number : null;
}

/**
 * Normalize a settings document before it reaches React. The backend contract is
 * additive and older builds can omit fields that were added later; a missing optional
 * fact must render as "unknown/unavailable", never crash the whole window.
 */
export function asSettingsDocument(document: unknown): SettingsDocument | null {
  const source = asRecord(document);
  if (!source) {
    return null;
  }
  const idle = asRecord(source.idle_unload);
  const useCase = asRecord(source.use_case);
  const allowed = Array.isArray(useCase?.allowed)
    ? useCase.allowed.filter((value): value is string => typeof value === "string" && value.length > 0)
    : [];
  const settings: SettingsDocument = {
    schema_version: asFiniteNumber(source.schema_version) ?? 0,
    generated_at: typeof source.generated_at === "string" ? source.generated_at : "",
    install_root: typeof source.install_root === "string" ? source.install_root : "",
    gpu_vram_gib: asPositiveNumber(source.gpu_vram_gib),
    active_model_gib: asPositiveNumber(source.active_model_gib),
    active_model_footprint_gib: asPositiveNumber(source.active_model_footprint_gib),
    idle_unload: {
      minutes: asMinutes(idle?.minutes),
      capable: idle?.capable === true,
      installed_models: asNonNegativeCount(idle?.installed_models)
    },
    use_case: {
      saved: typeof useCase?.saved === "string" && useCase.saved.length > 0 ? useCase.saved : null,
      allowed
    }
  };
  const pause = asRecord(source.game_pause);
  if (pause) {
    settings.game_pause = {
      gib: asNonNegativeCount(pause.gib),
      capable: pause.capable === true,
      min: asNonNegativeCount(pause.min) || 4,
      max: asNonNegativeCount(pause.max) || 40
    };
  }
  return settings;
}

function asSettingsOutcome(value: unknown): SettingsPatchOutcome | null {
  const source = asRecord(value);
  if (!source || typeof source.field !== "string" || source.field.length === 0) {
    return null;
  }
  const outcome: SettingsPatchOutcome = { field: source.field };
  if (typeof source.note === "string") {
    outcome.note = source.note;
  }
  if (typeof source.reason === "string") {
    outcome.reason = source.reason;
  }
  if ((typeof source.value === "number" && Number.isFinite(source.value)) || typeof source.value === "string") {
    outcome.value = source.value;
  }
  return outcome;
}

function asSettingsOutcomes(value: unknown): SettingsPatchOutcome[] {
  if (!Array.isArray(value)) {
    return [];
  }
  const outcomes: SettingsPatchOutcome[] = [];
  for (const item of value) {
    const outcome = asSettingsOutcome(item);
    if (outcome) {
      outcomes.push(outcome);
    }
  }
  return outcomes;
}

/** Normalize a save result too; older or partial results must not make the window throw. */
export function asSettingsSaveDocument(document: unknown): SettingsSaveDocument | null {
  const source = asRecord(document);
  if (!source) {
    return null;
  }
  return {
    schema_version: asFiniteNumber(source.schema_version) ?? 0,
    generated_at: typeof source.generated_at === "string" ? source.generated_at : "",
    applied: asSettingsOutcomes(source.applied),
    rejected: asSettingsOutcomes(source.rejected),
    settings: asSettingsDocument(source.settings)
  };
}
