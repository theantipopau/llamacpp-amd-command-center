# llama.cpp Command Center — desktop app

A real desktop window over the existing PowerShell backend. It renders the typed JSON
documents the backend already prints (`-Action State`, `-Action Recommend`,
`-Action Diagnose`, `-Action Runtime`, `-Action Settings`), and it owns no domain logic: it
never reads files, never parses output text and never decides what the state is (ADR-006).

Shipped so far: launch, show state, Start, Stop, Diagnose, and the Settings screen (idle
unload minutes and the use-case picker, saved through the backend's own settings
helpers). Model downloads and editor integrations are later phases.

## Requirements

| Tool | Version used | Notes |
|---|---|---|
| Node | 24.21.0 | any current LTS works |
| Rust + Cargo | 1.96.0 (`x86_64-pc-windows-msvc`) | needs the MSVC linker |
| Visual Studio Build Tools | 2022, "Desktop development with C++" | provides `link.exe` and the Windows SDK |
| WebView2 runtime | present on current Windows 10/11 | the window uses it; no browser is bundled |

The PowerShell backend (`Install-LlamaCpp-AMD.ps1`) must exist — see "How the window finds
the backend" below. The llama.cpp install itself is optional: without it the window shows
the backend's own "not installed" verdict.

## Run it

```powershell
cd desktop
npm install     # once
npm run dev     # one command: Vite + the window against it
```

| Command | What it does |
|---|---|
| `npm run dev` | development: starts Vite (127.0.0.1:5173) and opens the window |
| `npm run build` | standalone release binary in `src-tauri/target/release/` (frontend embedded, no dev server, no network) |
| `npm run check` | `tsc --noEmit` + the pure display-rule tests (vitest) |
| `npm test` | the display-rule tests only |

**Always build the release binary with `npm run build`, never plain `cargo build
--release`.** Tauri's dev-context switch is set by its build pipeline: a binary compiled
with plain cargo still points the window at the `devUrl` (127.0.0.1:5173), which shows
"127.0.0.1 refused to connect" when no dev server is running — even though the exe sits in
`release/`. Found the hard way during the model-library slice; diagnosed by WebView2's
request log (`--log-file`).

**Debug builds load the Vite dev URL.** If you run the debug `.exe` from
`src-tauri/target/debug/` without `npm run dev`, the window shows
"127.0.0.1 refused to connect" — that is the dev server being absent, not a backend
problem. Use `npm run dev`, or `npm run build` for a binary that carries its own copy of
the interface.

npm 12 blocks `esbuild`'s postinstall script until it is approved; `package.json` records
the approval (`allowScripts`), so a fresh clone needs no manual step. When esbuild is
upgraded, approve the new pinned version once with `npm install-scripts approve esbuild`.

## How the window finds the backend

Checked in order, and all listed in the window when none resolves:

1. `LLAMACPP_SCRIPT` — full path to `Install-LlamaCpp-AMD.ps1`.
2. `<install root>\Install-LlamaCpp-AMD.ps1`.
3. Walking up to six folders from the executable (which is how it works from a build tree).

The install root is `LLAMACPP_INSTALL_ROOT`, or the same
`%LOCALAPPDATA%\Programs\llama.cpp` the script uses by default.

## What the buttons do

- **Start the AI** — asks the backend for health first (it answers "already running"
  instead of starting a second server), then opens the server in its own console window
  through `-Action Runtime -RuntimeAction start`, so the port-ownership guard and the
  loader diagnostics apply. The window then polls `-Action Runtime -RuntimeAction health`
  and shows the real state and elapsed time while the model loads.
- **Stop the AI** — calls the adapter stop *without* force first: the backend answers
  `requires_confirmation` and kills nothing. Only after you confirm does the window call it
  with `-Force`, then waits for the backend to report the server gone.
- **Update llama.cpp** — the same two-step contract for the runtime itself: the backend
  answers `requires_confirmation` (or `server_running` if the AI is on — close it first),
  and only after you confirm does the confirmed call delegate to the backend's
  single-source updater — staged download with SHA-256/size checks, automatic backup of
  the current build, and launcher rebuild. Blocked models (for example Gemma 4 12B on
  the ROCm 7.2.1 package) become loadable when a newer build lands. Auto keeps the
  installed backend choice; the update never silently swaps ROCm for Vulkan.
  Directly under the button, the window states exactly which blocked models a newer
  build would unblock — computed by the backend **from the compatibility catalogue**
  (`unlocked_models` in the Library document), never a hardcoded list, and the line
  simply does not render when nothing would unlock.
- **Run diagnostics** — renders the four health sections in plain language, with the raw
  document behind a disclosure.
- **Model library** — every catalogued model with its size, capability flags, fit
  wording and local state straight from the backend's `-Action Library` document.
  Download validates first (disk space, runtime blocker, not-already-downloaded) and
  then opens the real transfer in its own console window through the proven
  `-Action Models` path, size- and SHA-256-verified; Activate switches instantly through
  the existing offline switch (launchers and VS Code endpoint re-sync included);
  Remove asks first and refuses the active model. Blocked models show the backend's
  own reason with the operation disabled, never a hidden row.
- **Settings** — reads the backend's settings document; idle unload offers a minute box
  **only when the installed llama.cpp actually supports `--sleep-idle-seconds`** (probed,
  never assumed), and the use-case picker lists exactly what the backend catalogues.
  The card also states what the choice means for the Radeon in VRAM terms
  ("about 8.0 GiB … stays free for games"), from the document's `gpu_vram_gib` and
  `active_model_gib` with the same headroom arithmetic the recommendation engine uses;
  when either is unknown the line simply does not appear — no guessed numbers.
  Save sends one JSON patch; the backend validates field by field and the window shows
  both what was applied and what was rejected, with the backend's own reasons. A refused
  idle write leaves no stale value on disk.
- Anything that fails shows the backend's own sentence plus an expandable "Technical
  detail" block with the exact command, exit code, standard error and document.
- **The layout scales with the window** — fluid type and spacing, single-column fact
  tables below 640 px, a two-column model library on wide windows. Verified at narrow
  and wide sizes with `Capture-DesktopScreenshot.ps1` (`docs/desktop-window-narrow.png`
  and `docs/desktop-window-wide.png`).

## Window capture (the repeatable screenshot check)

`Capture-DesktopScreenshot.ps1` (repo root) replaces every ad-hoc
SendKeys/manual-copy screenshot step. One command finds the window by title,
renders it with `PrintWindow` (no focus steal, no clipboard, no keyboard automation —
a minimized window is restored first) and writes the PNG next to a typed result
document on stdout:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Capture-DesktopScreenshot.ps1 `
  -OutputPath .\docs\desktop-window.png
```

Exit codes: `0` captured and verified (PNG signature + non-empty, self-reported in the
document), `2` capture failed, `3` no matching visible window. The harness runs this
as a **gate**: with the window open it re-verifies the artifact every run; with no
window (CI, app closed) it reports a SKIP — a missing window is never claimed a pass.
No external dependencies beyond .NET (`System.Drawing`).

## Tests

- `npm run check` — display rules and types (30 vitest cases, including the settings
  wording, minutes/use-case validation, and the model-library badges/fit/state/operation
  rules).
- `cargo test` (in `src-tauri`) — the supervisor layer against a real backend call:
  document parsing, contract version, failure detail, backend discovery, and the
  settings read/refuse paths (6 cases).
- `cargo test -- --ignored --nocapture live_start_stop` — the real lifecycle on this
  machine: start, wait for the model, diagnose, soft stop must refuse to kill, forced stop
  must stop it.

## Known gaps in this slice

- **No automated UI driver.** Clicking the real buttons is not automated (WebDriver for a
  WebView2 window is a Phase D concern); the window is verified by launching it, exercising
  the same commands through `cargo test`, and the harness's capture gate against
  `Capture-DesktopScreenshot.ps1` (see above).
- **No pixel-diff regression.** Visual changes are checked by re-running the capture tool
  and comparing the artifact.
- The server console window closes when the server exits; the window's state then reads
  `stopped` and Diagnose explains why.
