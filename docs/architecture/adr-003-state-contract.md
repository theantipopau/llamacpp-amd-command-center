# ADR-003: Typed application-state contract — `-Action State`

- **Status:** Accepted, 2026-10-08 (Phase A, implemented in the same phase)
- **Checklist:** §3 (typed commands, progress events, errors), §9 (supervisor state),
  §16 (version application state), §19 Phase B

## Context

The application currently exposes two string contracts:

- `Get-CommandCenterStatus` → `alias|name|context|server|vscode|idle|shortcuts`
  (7 `|` fields, frozen because `read_status` in the batch menu reads `tokens=1-7`),
- `Get-InstalledModelList` → `number|id|name|state`.

The WPF window re-parses the status line; scripts split it positionally. Checklist §3
requires typed, version-aware commands instead of scraping, and §9 requires an explicit
lifecycle state. Any future shell (ADR-001) needs one structured source of truth.

## Decision

1. **Add `Get-ApplicationState`** — one pure function returning a `pscustomobject` with
   `schema_version` (integer, starts at `1`), `generated_at`, `command_center_version`,
   `install_root`, `runtime` (installed/tag/backend/exe present), `model` (active model
   or `$null`, with `model_present` and `runtime_blocker`), `server`
   (`state ∈ {stopped, loading, running}`, `port`, `base_url`, `process_ids`),
   `models[]` (id/name/state per downloaded model), `settings`
   (`idle_sleep_minutes`, `use_case`), `editors.vscode` (`yes|stale|no`),
   `desktop_shortcuts`, optional `hardware` summary, and `hardware_error`.
2. **Expose it as `-Action State`**, printing exactly one JSON document to stdout and
   exiting 0. Read-only: no downloads, no writes, no prompts; hardware detection failure
   degrades to `hardware: null` + `hardware_error`, never a crash.
3. **Single source of truth.** The status line and installed-model list are *derived
   from* the same helpers (`Get-ServerState`, `Get-VsCodeChatState`,
   `Get-DesktopShortcutState`, `Get-InstalledModelStates`) that build the typed state,
   so the frozen 7-field contract and the JSON can never drift apart.
4. **Versioning rule.** `schema_version` increments only on a breaking change
   (field renamed, meaning changed, field removed). Additive fields are allowed within
   a version; consumers must ignore unknown fields. Non-breaking additions and the
   version bump policy get a regression test when the first consumer appears.

## Non-goals (this slice)

- No mutation commands (`start`/`stop` via JSON) — supervisor actions stay on existing
  `-Action Launch`/menu paths until the Phase B/C supervisor exists.
- No progress-event stream yet; the contract notes where events will attach.
- The batch menu keeps reading the pipe line (contract frozen); migrating it to
  `-Action State` is possible later but changes `read_status` and the CI smoke greps
  together (CLAUDE.md rule).

## Consequences

- Scripts and future UI consume structured state instead of splitting strings.
- The GUI can switch from re-parsing the status line to `Get-ApplicationState` without
  behaviour change (follow-up slice).
- Tests assert schema shape, allowed `server.state` values, JSON round-trip, and that
  the subprocess `-Action State` emits parseable JSON with `schema_version: 1`.

## Amendment 1 (2026-10-08, same phase): core state, projections, snapshots

Implemented follow-ups, all additive to `schema_version` 1:

1. **`Get-CoreApplicationState` is the single source.** The state is built once in a
   hardware-free core object (adds `idle_minutes`, the validated computed value);
   `Get-ApplicationState` = core + `schema_version`/`generated_at` + the hardware scan,
   copying core fields straight across so the two documents cannot disagree;
   `Get-CommandCenterStatus` is now a pure projection of the core (cmd.exe still cannot
   parse JSON, so the 7-field line remains the batch serialization); `Get-GuiState`
   reads the core object directly — the window no longer splits the status line.
   Regression tests assert the state document is a superset of the core and that line
   and window values match the core verbatim.
2. **State snapshots for diagnostics/rollback/benchmarking.**
   `Save-StateSnapshot` writes the full state document plus `snapshot_reason` into
   `<install>/state-history/state-<UTC stamp>.json` (UTF-8, no BOM), keeps the newest
   `$script:StateSnapshotKeep` (40), and never throws. Captured automatically before
   `Activate`/`Install`/`Update`/`Uninstall`/`RemoveModel`/`Easy` (reason
   `before-<action>`) and on demand via `-Action Snapshot`, which prints the path.
   `-Action State` remains strictly read-only (subprocess test proves the install
   folder stays untouched).
3. **Hardware section expanded additively:** `cpu`, `memory`, `detection`
   (`gpu_source ∈ {dxgi, registry, wmi, mixed}`, `confidence ∈ {high, medium, low}`),
   `support` (`level ∈ {supported, warning, unsupported}`, `confidence`, `reasons[]`),
   `recommendation` (`backend ∈ {ROCm, Vulkan}`, `model_id`, `confidence`, `reason`),
   `HasDiscreteAmdGpu`, and per-GPU `Source`/`VramConfidence` (DXGI = high, registry =
   medium, WMI `AdapterRAM` = low). No field was renamed or removed, so the version
   stays 1; consumers keep ignoring unknown fields.
