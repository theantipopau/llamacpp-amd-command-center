# ADR-006: Desktop stack — Tauri v2 + React/TypeScript over the PowerShell backend

- **Status:** Accepted, 2026-10-09 (Phase C, written and reviewed before any UI code)
- **Checklist:** §3 (desktop stack decision), §4 (typed command surface), §19 (Phase C)
- **Builds on:** ADR-002 (runtime management), ADR-003 (state contract),
  ADR-004 (versioned catalogue), ADR-005 (adapters/diagnostics)
- **Amends:** ADR-001 ("keep PowerShell + WPF near-term; Tauri deferred"). ADR-001's
  *revisit trigger* — "the Tauri port can be staged behind the typed command surface with
  the PowerShell harness still passing" — is now satisfied, and the Phase C brief asks for
  exactly that slice. ADR-001's core rule is kept unchanged: **no domain logic in the UI
  layer**, and the PowerShell scripts stay the single implementation of behaviour.

## Context

Phase C requires a real desktop window that renders the typed state contract, starts and
stops the server, and shows diagnostics — with all IPC consuming the typed JSON State
contract, no string parsing, no direct file reads and no duplicated detection logic in the
UI layer. Measured on the target machine before this decision: Node 24.21.0, npm 12.0.2,
rustc/cargo 1.96.0 (`x86_64-pc-windows-msvc`), Visual Studio 2022 Community with the MSVC
linker (14.44) and Windows SDK 10.0.26100, WebView2 runtime 154. A trivial `cargo build`
was run to confirm the toolchain links. Both the WPF window and the batch menu already
exist and stay in place; this ADR adds a third front end, it does not replace them.

## Decision 1 — Stack: Tauri v2 + React + TypeScript + a Rust supervisor

| Option | Verdict |
|---|---|
| **Tauri v2 + React/TypeScript (this decision)** | Small binaries, no bundled browser, and the WebView2 runtime is already present on supported Windows. Rust is a good supervisor process and needs no GC/event-loop ceremony for a handful of commands. |
| Electron | Works, but ships a whole Chromium and a Node runtime for a window that shows a dozen fields; heavier install and update story for no capability this slice needs. |
| WinUI/.NET | Would keep .NET, but the UI layer would be a second implementation language away from the contract and would tempt domain logic back into the shell. |
| In-process WPF (status quo) | Already exists, but has no IPC boundary at all: it calls functions in the same process, so it cannot demonstrate a contract another front end could follow. It stays as the beginner fallback. |

React is chosen for the same reason the checklist recommends it: small component state
plus a real build step for the multi-screen Phase D surface. TypeScript is not optional —
the whole point of this slice is that the window renders *typed* documents, so `StateDocument`,
`RecommendationDocument` and `DiagnosticDocument` exist as types in `desktop/src/types.ts`.

## Decision 2 — IPC: one-shot PowerShell subprocess per action, JSON on standard output

Three options were considered:

1. **Local HTTP management API.** Rejected: the backend is a CLI script, not a server, so
   this would mean building and supervising a listener, pinning a port (the project just
   spent a workstream making port ownership explicit — see Gap 3), and adding an
   unauthenticated local surface that the batch menu and WPF window would then have to
   bypass anyway.
2. **Rust supervisor over a long-lived PowerShell process.** Rejected *for this slice*: it
   needs a stateful protocol (framing, request ids, timeouts, crash handling) that the
   script does not implement. It remains the right answer if sub-second live metrics are
   ever needed; the one-shot contract below is exactly what such a daemon would wrap.
3. **One subprocess per action, one typed JSON document on standard output.** Chosen.

**The contract** (implemented in `desktop/src-tauri/src/main.rs`, tested by the PowerShell
harness and by the slice itself):

| Piece | Rule |
|---|---|
| Invocation | `powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File <script> -Action <State\|Recommend\|Diagnose\|Runtime> [-RuntimeAction health\|start\|stop] [-Force] -InstallRoot <root>` |
| Success | Exit code 0 and exactly one JSON document, `schema_version` first, on stdout |
| Encoding | **UTF-8, no BOM**, written to the standard output *stream* so a console code page can never corrupt a path (Gap 1 measured this: `ö` became one byte and `中` became `?` through the console encoder) |
| Failure | Non-zero exit code, human text on stderr, the typed failure document (when one exists) on stdout |
| UI access | Only these documents. No file reads, no output scraping, no re-derived state |
| Expandable errors | Rust returns the document *plus* the exact command, exit code and stderr, and the window shows the human sentence with a "Technical detail" disclosure |

Trade-offs accepted: each `-Action State` call re-runs the hardware scan (~1–3 s), so the
window refreshes *after* actions and polls the cheap `-Action Runtime -RuntimeAction health`
(no hardware scan) while a model loads. A subprocess per action means no long-lived state
to desynchronise, which is worth more than the latency for a slice this size.

The **stop confirmation contract** (ADR-005) is exercised across the IPC boundary as
designed: `stop_server(false)` returns `requires_confirmation` and kills nothing; only
after the user confirms does the window call `stop_server(true)`, which is the first
deliberate exercise of the `-Force` kill path (previously an untested gap).

## Decision 3 — Build and development workflow

One-time: `cd desktop && npm install` (npm 12 blocks `esbuild`'s postinstall until it is
approved; `package.json` carries the approval as `allowScripts: { "esbuild@0.21.5": true }`,
so a fresh clone needs no manual step).

| Command | What it does |
|---|---|
| `npm run dev` | **One command**: Tauri starts Vite, then opens the real window against it |
| `npm run check` | `tsc --noEmit` + the pure display-rule tests (vitest) |
| `npm run build` | Vite production build + Rust release binary (`bundle.active: false`, so no installer toolchain is needed) |

The window finds the backend without configuration: `LLAMACPP_SCRIPT` (explicit) →
`<install root>\Install-LlamaCpp-AMD.ps1` → walking up to six folders from the executable
(which covers `src-tauri/target/debug`). `LLAMACPP_INSTALL_ROOT` overrides the install root,
which otherwise defaults to the same `%LOCALAPPDATA%\Programs\llama.cpp` the script uses.
When none resolve, the window shows the exact list of paths checked — never a placeholder.

## Decision 4 — How UI changes are verified

1. **Pure display rules** live in `desktop/src/format.ts` and are unit tested
   (`npm test`), so wording ("Starting — the model is loading into the GPU"), progress
   text and the "backend not found" explanation are checked without a window.
2. **Typed contracts** are checked by `tsc --noEmit`; the backend side of every document is
   covered by the PowerShell harness (400 checks), which remains the authoritative contract
   test.
3. **Visual changes** are verified by a **repeatable capture gate**:
   `Capture-DesktopScreenshot.ps1` (repo root) finds the running window by title and
   renders it with `PrintWindow` — no SendKeys, no clipboard, no focus steal — writing
   the PNG plus a typed result document (window found, width/height, byte size, PNG
   signature). The PowerShell harness runs it as a gate on every pass: with the window
   open it re-verifies the artifact; with no window (CI, app closed) it reports a SKIP
   rather than failing — a missing window is never claimed a pass. Layout changes are
   captured at two window sizes (`docs/desktop-window-narrow.png` / `-wide.png`, the
   responsive scaling check). Automated pixel-diff regression is still **not**
   implemented: it needs a driver for a native WebView2 window (`tauri-driver` +
   WebDriver) and a stable fixture. Recorded as a gap, not claimed as a pass; the
   gated capture is the current substitute for the old manual step.

## Decision 5 — Upgrade path after the GUI exists

- The GUI is a **client**: it owns no install state and writes nothing except through the
  backend actions it calls. Deleting `desktop/` leaves the product fully functional.
- `Start-LlamaCpp.cmd`, `Chat.cmd`, `Gaming-Mode.cmd` and the WPF window keep working
  unchanged, and remain the documented recovery path if the desktop app will not start.
- `Start-LlamaCpp.cmd` still opens by default; the desktop app is opt-in for now, so an
  installation is never dependent on the new toolchain.
- Backend evolution stays additive: consumers must ignore unknown fields, so new document
  fields (for example the `port_owner` block added to diagnostics in this phase) do not
  break older windows, and the batch menu keeps reading the seven-field status line.

## Consequences

- A second front end now consumes the same contract as the batch menu and the WPF window,
  which is the evidence the architecture wanted: one implementation, three projections.
- The repository gains a Node/Rust build (documented in `desktop/README.md`). CI keeps
  running the PowerShell harness unchanged; a desktop job is a Phase D concern.
- The window cannot show anything the backend does not report, by construction: no status
  is computed in TypeScript.
