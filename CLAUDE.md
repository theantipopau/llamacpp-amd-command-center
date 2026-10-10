# CLAUDE.md

Windows command center for running llama.cpp on AMD Radeon GPUs and connecting it to VS Code Copilot Chat, llama-vscode and Continue. Two shipped scripts, a versioned data folder, plus docs:

- `Start-LlamaCpp.cmd` — beginner batch menu (double-click entry point). Calls the PowerShell script for all real work.
- `Install-LlamaCpp-AMD.ps1` — everything else: hardware scan, backend install, model catalog/download, launcher generation, editor integrations. `-Action` selects the mode (see README "Command-line reference").
- `catalog/` — versioned JSON data loaded at runtime by `Get-CatalogJson`: `models.json` (the nine-model catalog), `runtimes.json` (AMD package facts), `hardware_profiles.json` (ROCm matrix pattern and reasons), `compatibility.json` (runtime-vs-model rules). Single source of truth (ADR-004): never duplicate catalogue values in code or tests, and never embed a fallback copy — a missing or broken file must fail loudly with its path.
- `tests/Test-CommandCenter.ps1` — offline test harness (no downloads, no real install touched).
- `docs/index.html` — GitHub Pages site. Keep it in sync with `README.md`.

Live install lives in `%LOCALAPPDATA%\Programs\llama.cpp` (`current\`, `models\`, `active-model.json`, generated `Start-LlamaCpp.cmd`, `logs\`, `state-history\`).

`state-history\` holds auto-taken state snapshots (`Save-StateSnapshot`): one before `Activate`/`Install`/`Update`/`Uninstall`/`RemoveModel`/`Easy`, one on demand via `-Action Snapshot`, newest `$script:StateSnapshotKeep` (40) kept. `Save-StateSnapshot` never throws — history must never block the change it records, and `-Action State` itself stays strictly read-only.

## Validate before every commit

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-CommandCenter.ps1
```

Also: AST-parse the script with Windows PowerShell 5.1, run `Invoke-ScriptAnalyzer -Severity Error` on the script and tests (must be 0), and confirm `.cmd`/`.ps1` files have no LF-only line endings. CI (`.github/workflows/ci.yml`) runs the same plus a batch smoke test; reproduce it with `LLAMACPP_NO_PAUSE=1` and a redirected choices file (`(echo x& echo 5& echo 8& echo 0) > choices.txt`), never a pipe.

## PowerShell 5.1 rules

- Target Windows PowerShell 5.1; `Set-StrictMode -Version Latest` is on. Reading a property a PSCustomObject lacks throws — check `PSObject.Properties.Name -contains` first.
- `return @()` returns `$null`. Use `return ,@()` / `return ,@($x)` when a caller needs an array.
- `if` expressions unroll arrays — wrap in `@(...)`.
- One-element arrays: `ConvertTo-Json -InputObject $list`, not the pipeline.
- Write JSON/YAML config with `[IO.File]::WriteAllText(..., UTF8Encoding($false))` (no BOM). `Install-LlamaCpp-AMD.ps1` itself is UTF-8 **with** BOM.
- Simple functions ignore unknown named parameters; the test harness checks every internal call uses real parameter names.
- The test harness only loads function definitions, not script-scope variables. New `$script:` settings must also be set at the top of the test file.

## Batch rules

- CRLF only (`.gitattributes` enforces it). Git Bash `sed -i` silently converts to LF — re-normalize afterwards.
- Delayed expansion is on: no `!` in echoed text.
- A caret continuation followed by a blank line splits the command.
- Give `powershell`, `mode` and `chcp` calls `<nul` unless they need keyboard input (the live monitor does).

## Product rules

- Never download or install without showing what and asking for `YES` (`-Force` skips prompts for scripted use).
- Server binds `127.0.0.1` only.
- Editor integrations back up first, touch only the entries this project owns, and fall back to printing instructions when a safe merge is impossible (commented `settings.json`, a Continue `config.yaml` that already has its own `models:` list). Never modify GitHub Copilot itself.
- `server-args.user.json` is user-owned: read and merge it last, never write it. `settings.json` is the opposite: managed by this project (`idle_sleep_minutes`, `easy_extras_done`), read through `Get-AppSettings`/`Set-AppSetting`.
- Easy start (`-Action Easy`) asks for one `YES` for the whole plan, then sets `$script:AssumeYes` so the per-download prompts are skipped. Never use `-Force` for that: it also bypasses the no-Radeon check. `$script:AssumeYes` is also set at the top of the test file.
- Generated `Chat.cmd`/`Gaming-Mode.cmd` and the desktop shortcuts live in the install folder and must never reference the extracted ZIP folder, which users move or delete. Desktop shortcuts and idle unload are opt-in; `Remove-DesktopShortcuts` only deletes shortcuts whose target is inside this install.
- `Start-LlamaCpp.cmd` opens the WPF window (`-Action Gui`) by default and falls back to the text menu if `LLAMACPP_TEXT_MENU` or `LLAMACPP_NO_PAUSE` is set (CI uses the latter) or the window throws. The window only calls existing functions; steps that need typing run in a console window via `cmd /c`. Slow work (GPU counters, 2.5 s) runs on a worker runspace, never the UI thread. WPF handlers see the enclosing function's variables only while `ShowDialog` is on the stack, so keep it inside `Show-CommandCenterWindow`. Display logic lives in the pure `Get-GuiState`/`Set-GuiState`, which the tests drive (they skip on a non-STA thread). Re-render `docs/window.png` after visual changes.
- The use-case picker (`Get-ModelForUseCase`) chooses by catalog flags (`Tools`, `Vision`, `ApproxGiB`) and the assessment order, and must skip anything `Get-ModelRuntimeBlocker` rejects for `Get-PlannedRuntime`. Add new catalog models with accurate `Tools`/`Vision` flags and it will consider them. `$UseCase` is also set at the top of the test file; the answer persists as `use_case` in `settings.json`.
- The `Status` line has seven `|`-separated fields; `read_status` in the batch menu reads `tokens=1-7`. Change both together. The line is now a projection of `Get-CoreApplicationState` (cmd.exe cannot parse JSON): the window and `-Action State` read that typed object directly, so state logic never goes back into string parsing.
- In batch, keep commands that expand `%PS_RUN%` or the install path outside parenthesised blocks (a folder name containing `)` ends the block early).
- `Get-ServerArguments` is the single source of truth for launcher and direct-start flags. It returns its list through the `,@()` idiom, so **iterate it with `foreach`, never with a pipeline** (`$args | ForEach-Object` sees the whole list as one object and silently collapses the launcher to a single argument line).
- Generated `.cmd` launchers are written as ASCII and must never embed the install root: absolute paths inside it collapse to `%~dp0` (`ConvertTo-LauncherArgument`), so an install folder with spaces or non-Latin characters still works. The JSON actions (`State`, `Recommend`, `Diagnose`, `Runtime`, `Settings`, the printed `Snapshot` path) write UTF-8 **without a BOM** straight to the console output stream (`Write-JsonStdout`/`Write-Utf8StdoutLine`): the console code page would otherwise destroy a Unicode path on the way out. During Settings runs `$script:JsonDocumentsOnly` silences the `║` banner writers so stdout stays exactly one document (the run log still records every event); the settings write goes only through `Set-IdleSleep`/`Set-AppSetting`, and its patch text parameter is `$SettingsPatchText` — PowerShell variables are case-insensitive, so a lowercase `$patch` local would be the SAME variable and wipe the parameter.
- Downloads are staged in `<install root>\downloads\staging` and only promoted by rename after the size and SHA-256 both pass; a failed checksum deletes the staged file and reports expected vs actual hash, and a server that cannot resume (curl 33) triggers exactly one full restart.
- The configured port is checked before every start (`Resolve-PortConflict`): our own `llama-server` means "already running", anything else is a hard error naming the port and PID — never kill it, never silently pick another port. `Get-DiagnosticReport` carries the same verdict in `runtime_health.port_owner`.
- `-Action Runtime -RuntimeAction health|start|stop` is the command-line face of the adapter layer (ADR-005) and the only surface the desktop app uses for process control; `stop` without `-Force` still never kills anything.
- The desktop app in `desktop/` (Tauri v2 + React/TypeScript + a Rust supervisor, ADR-006) owns no domain logic: it runs the PowerShell script as a subprocess and renders the documents it prints. Debug builds load the Vite dev server (`npm run dev`); only `npm run build` produces a standalone binary — building with plain `cargo build --release` leaves the window pointing at `devUrl` (127.0.0.1:5173), which shows "refused to connect" (found during D-2; diagnosed from the WebView2 request log). Every adapter document starts with `schema_version = 1`.
- Fit wording: `ModelBudgetGiB` includes system RAM (VRAM × 0.88 + RAM × 0.35). Any text that says a model "stays in VRAM" or quotes headroom must use the assessment's `VramHeadroomGiB`/`GpuResident`, never `HeadroomGiB` or `ModelBudgetGiB`.
- Desktop Open chat calls the install's `Chat.cmd` (`open_chat`), which starts the AI when it is off; the window never re-implements chat launch. Library downloads are confirmed in the UI before `-Action Models -Force`; that `-Force` only skips the console's own YES, and the UI confirm and backend validation run first.
- Router mode: the server runs `--models-preset server-preset.ini --models-max 1` with the router's own flags (`--host`, `--port`, `--metrics`) on the command line and every model flag in the preset. `Write-ServerPreset` builds both from `Get-ServerArguments`; never assign its result through `@(...)` (it is already wrapped by `,`), or the whole list arrives as one item.
- Verified on the installed build, keep these true: `POST /models/unload` exists only in router mode (404 in single mode) and frees the model's memory; `/models` still says `loaded` while the model sleeps (use `/props?model=` `is_sleeping`); `/metrics?model=` gives `llamacpp:requests_processing`; `load-on-startup = true` keeps the model in memory when the server starts; a router-level `--sleep-idle-seconds` does not unload, so idle sleep stays in the model section; a relative model path resolves from the working directory, which is why the server runs from the install folder.
- Game pause: `Get-GamePauseStep` is the pure decision (two high samples and no running request before an unload, a full minute of low use and a 3 GiB gap before a wake). The watcher runs from `tools\Install-LlamaCpp-AMD.ps1`, a copy made by `Copy-WatcherTools` with its catalogue, never from the ZIP folder. The footprint it subtracts is `Get-VramPreflight`'s estimate, which is not yet calibrated on the GPU.
- `Chat.cmd` is ready when `/models` reports `loaded`, not when `/health` answers: the router answers `/health` while its model is still loading.
- Hardware intelligence (ADR-005): `-Action Recommend` and `-Action Diagnose` are read-only early exits printing one typed JSON document each (they run before run logging, like `State`/`Snapshot`). The recommendation engine is entirely catalogue-driven — never hardcode a GPU name, model pick or status; statuses come from fit rules plus the catalogue `Experimental` flag and `Get-ModelRuntimeBlocker`.
- Runtime adapters: `Get-RuntimeAdapter`/`Test-RuntimeAdapter`/`Start-Runtime`/`Stop-Runtime`/`Get-RuntimeHealth` are the only supported runtime entry points; llama.cpp is the sole active adapter, Lemonade and Strata are structured stubs that return `not_implemented` with catalogue `unknowns` instead of guessing. `Stop-Runtime` without `-Force` never kills a process (confirmation contract); the `-Force` kill path is an untested gap until exercised safely.
- `Resolve-HardwareSupport` guards optional properties by name: partial hardware objects are legitimate callers, so never read a field without checking `PSObject.Properties.Name` first.
- No fabricated data: benchmark fields stay `null` until a real run fills them; capabilities stay `null`/`none` until an actual `--help` probe answers.
- The Ryzen iGPU is never used automatically; the launcher pins the dedicated Radeon by name (`--device`).
- Don't claim GPU acceleration from adapter presence or an HTTP response alone.
- Label publisher benchmark claims as unverified, and don't market a local 9B model as frontier-equivalent.

## Hardware findings (RX 9070 XT, Ryzen 7 9800X3D, 31 GB RAM)

- Stable setup: AMD ROCm 7.2.1 package (llama.cpp b8407) + Qwen3.5 9B, 64k context × 2 slots (`--parallel 2`, `--ctx-size 131072`), `--reasoning off` for tool-capable models.
- Copilot Agent needs ≥32k context per conversation; thinking must be off or tool calls land in `reasoning_content`; two slots prevent 500 "context size exceeded" when VS Code sends a concurrent summary request.
- The official Vulkan build lost the GPU (`device lost on Vulkan0`) in long Agent sessions and once caused bugcheck 0x116. Prefer ROCm on ROCm-capable cards.
- Ornith 1.5 9B's GGUF has an MTP block the b8407 ROCm package cannot load (`missing tensor 'blk.32.ssm_conv1d.weight'`). It is blocked on that runtime.

## Working with the user's machine

- Never stop or restart the user's running llama-server without asking — they may be mid-task in Copilot.
- Start the server via `Start-Process explorer.exe "<launcher>"` so it isn't tied to the agent's shell.
- Don't run write actions (`ContinueConfig`, `LlamaVscodeConfig`, `VSCodeChat`, `Uninstall`) against the real profile to test them. The test harness redirects `APPDATA`/`USERPROFILE` to temp folders at the very top and fails if the real `chatLanguageModels.json` changes. Keep new tests below that redirect: indirect side effects (such as auto-sync from `Switch-InstalledModel`) once overwrote the real file.
- `notes/` and `dist/` are gitignored local scratch.

## Releases

Bump `$script:CommandCenterVersion` (script and test file), push, wait for CI, then tag `vX.Y.Z`. `.github/workflows/release.yml` builds the ZIP + `.sha256`. Tagging is public — confirm with the user first.
