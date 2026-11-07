# llama.cpp Command Center — desktop app

A real desktop window over the existing PowerShell backend. It renders the typed JSON
documents the backend already prints (`-Action State`, `-Action Recommend`,
`-Action Diagnose`, `-Action Runtime`, `-Action Settings`), and it owns no domain logic: it
never reads files, never parses output text and never decides what the state is (ADR-006).

Shipped so far: launch, show state, Start, Stop, Open chat, Diagnose, the Settings screen (idle
unload minutes and the use-case picker, saved through the backend's own settings helpers), the
model library, and the system tray. Per tab:

- **Home** - the AI's state and a graphics-memory bar drawn from the backend's own
  `vram_estimate` (weights, context cache, compute buffers, reserve), every segment named and
  numbered in text. With no estimate it says so; it never falls back to weights alone.
- **Models** - download, switch and remove models. Each downloaded model has a backend choice
  (Auto, Vulkan or ROCm, saved through the settings patch `model_backends`; it applies the next
  time that model starts) and a "Tested on this PC" list of the speeds Tune measured here
  (read-only, from the saved results; models never measured say so).
- **Settings** - idle unload, game pause, use case, start minimised to the tray.
- **Health** - diagnostics, **Copy diagnostics** (the Windows user folder is replaced with
  `%USERPROFILE%` / `%LOCALAPPDATA%` first), a user-started check for newer llama.cpp builds,
  and **Roll back to the previous build** (confirmed first, and refused while the AI is running
  so the window never has to open a console to restart it).

Editor integrations and Tune are not in the window.

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
| `npm run build` | standalone release binary in `src-tauri/target/release/` (frontend embedded, no dev server, no network) and the NSIS installer in `src-tauri/target/release/bundle/nsis/`, which bundles the backend in a `backend` folder |
| `npm run check` | `tsc --noEmit` + the pure display-rule tests (vitest) |
| `npm test` | the display-rule tests only |
| `npm run test:lifecycle` | the release-window lifecycle test (needs a completed `npm run build`) |

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
3. `backend\Install-LlamaCpp-AMD.ps1` beside the app: where the installer puts the backend and its `catalog` folder.
4. Walking up to six folders from the executable (which is how it works from a build tree).

The install root is `LLAMACPP_INSTALL_ROOT`, or the same
`%LOCALAPPDATA%\Programs\llama.cpp` the script uses by default.

## What the buttons do

- **Start the AI** — asks the backend for health first (it answers "already running"
  instead of starting a second server), then starts the server hidden through
  `-Action Runtime -RuntimeAction start`, so the port-ownership guard and the loader
  diagnostics apply and no terminal is opened. Server output is appended to
  `<install root>\logs\desktop-server.log`. The window then polls
  `-Action Runtime -RuntimeAction health` and shows the real state and elapsed time while
  the model loads.
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
- **Open chat** — starts the AI through the app's tracked launcher when it is off, then runs the install's own `Chat.cmd` hidden. That helper waits for the model and opens the chat browser, so the desktop never repeats its logic and does not leave a second terminal behind. A missing `Chat.cmd` gets a plain message that says how to recreate it.
- **Run diagnostics** (Health tab) — renders the four health sections in plain language, with the raw
  document behind a disclosure.
- **Model library** — every catalogued model with its size, capability flags, fit
  wording and local state straight from the backend's `-Action Library` document.
  Download validates first (disk space, runtime blocker, not-already-downloaded) and
  then runs the real transfer hidden through the proven `-Action Models` path,
  size- and SHA-256-verified. While that download runs, the list re-reads the library every 15 seconds (for up to an hour) and marks the model downloaded when the file lands; Refresh always works too. Activate switches instantly through
  the existing offline switch (launchers and VS Code endpoint re-sync included);
  Remove asks first and refuses the active model. Blocked models show the backend's
  own reason with the operation disabled, never a hidden row.
- **Asleep** — the header badge reads Asleep when the server is up but its model has left graphics memory (idle sleep or game pause). The next message loads it again; Home says so under the server line.
- **Game pause** (Settings) — a GiB box: 0 is off, 4 to 40 unloads the model while other programs hold that much graphics memory. The control is hidden as unavailable when the installed llama.cpp is too old for router mode, and the save sends the value only then.
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
- **Header and tabs** — the logo, the title and one status badge (Running, Starting…, Stopped) sit at the top. Start, Stop, Open chat, Update and Refresh stay in a bar that remains visible while scrolling. Home, Models, Settings and Health are tabs; the Start-to-Running wait shows one progress line that stays accurate.
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

- `npm run check` — display rules and types (43 vitest cases, including the settings
  wording, minutes/use-case validation, and the model-library badges/fit/state/operation
  rules).
- `cargo test` (in `src-tauri`) — the supervisor layer against a real backend call:
  document parsing, contract version, failure detail, backend discovery, and the
  settings read/refuse paths (14 passed and 1 ignored by default).
- `cargo test -- --ignored --nocapture live_start_stop` — the real lifecycle on this
  machine: start, wait for the model, diagnose, soft stop must refuse to kill, forced stop
  must stop it.
- `npm run test:lifecycle` — the release-window regression test. It launches the built
  executable against a stub backend and fails if duplicate Start creates a second
  launcher, Stop or Quit leaves a server launcher, Quit leaves the live hidden Chat.cmd
  helper behind, or any step opens a new terminal window. It uses the built executable;
  run `npm run build` first. It refuses to run over an existing app or `llama-server`
  process.

## Known gaps in this slice

- **No automated full UI driver.** The lifecycle test drives the real tray menu and
  Open chat (via UI Automation and WebView2's CDP endpoint), but it does not click every
  button or compare pixels. The window is also verified by launching it, exercising the
  same commands through `cargo test`, and the harness's capture gate against
  `Capture-DesktopScreenshot.ps1` (see above).
- **No pixel-diff regression.** Visual changes are checked by re-running the capture tool
  and comparing the artifact.
- The app opens no terminal windows: the server, chat and model downloads run hidden.
  Server output is in `<install root>\logs\desktop-server.log`. Stop and Quit stop the
  server this app started; a server that was already running before the app started is
  left untouched.
