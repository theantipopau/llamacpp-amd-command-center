# Validation matrix

What has actually been verified, how, and on what hardware. Checklist §17: "passing
simulated tests is never described as proof of real GPU compatibility."

Last updated: 2026-10-08 (Phase B).

## Legend

- **Simulated** — offline test harness or CI; no real GPU/server involved.
- **Local** — command run on the machine below; output quoted in the linked evidence.
- **Untested** — never run here; must not be claimed anywhere in docs.

## Test machine (the only hardware exercised)

| Component | Value |
|---|---|
| CPU | AMD Ryzen 7 9800X3D (8C/16T) |
| GPU | AMD Radeon RX 9070 XT 16 GB (gfx1201), driver exposing DXGI + Vulkan |
| iGPU | AMD Radeon Graphics (Ryzen) — present, **never used automatically** |
| RAM | 31 GB |
| OS | Windows 11 build 26300 x64, Windows PowerShell 5.1.26100.9549 |
| Runtime | ROCm 7.2.1 package (llama.cpp b8407), `llama-server` version 2500 (312cf033) |

Any other CPU/GPU/driver combination is **untested** and must stay labelled as such.

## Coverage matrix

| Behaviour | Kind | Evidence | Status |
|---|---|---|---|
| Catalogue matches verified upstream files (9 models, repo/file/projector/size) | Simulated | `tests/fixtures/catalog-evidence.json` + harness section (now validates the shipped `catalog/*.json`) | PASS (2026-10-08, 298 checks total) |
| Catalogue files are the single source: schemas, pinned AMD package facts, identical blocker rules, missing file fails loudly | Simulated | harness "Catalogue files: the single versioned source" | PASS |
| Launcher argument construction for every catalog model (carets, jinja, parallel, reasoning, device) | Simulated | harness "Launcher generation" | PASS |
| Recommendation/context sizing on simulated 16 GB / 8 GB profiles | Simulated | harness "Hardware recommendation" | PASS |
| `server-args.user.json` merge-last, never overwritten | Simulated | harness | PASS |
| Status line contract (7 fields), installed-model states incl. `blocked` | Simulated | harness + batch smoke | PASS |
| One authoritative source: state document ⊇ core state; line and window equal the core verbatim | Simulated | harness "Core state" | PASS |
| State snapshots: retention prune, newest-first order, reasons; manual action; auto-capture before a mutating action | Local (subprocess, temp install root) | harness "State snapshots" + "-Action Snapshot" | PASS |
| Typed hardware profile: support/confidence/recommendation structure on real hardware; pure verdicts on fake profiles | Local (real WMI/DXGI) + Simulated | harness "Hardware profile" | PASS |
| GPU selection never picks the Ryzen iGPU automatically | Simulated (device lists) | harness "GPU selection" | PASS |
| VS Code/Continue/llama-vscode writers: backup, merge, refuse unsafe, real profile untouched | Simulated (temp APPDATA) | harness | PASS |
| WPF display logic (`Get-GuiState`/`Set-GuiState`, all modes) | Simulated (STA thread) | harness | PASS |
| Batch menu end-to-end (choices file, health check, clean exit) | Local (cmd, no server) | CI smoke test, reproduced 2026-10-08 | PASS |
| CI pipeline (CRLF, AST, PSSA errors, harness, smoke) | Local reproduction of CI | recorded in `docs/engineering/implementation-status.md` | PASS (2026-10-08) |
| `-Action State` JSON contract (schema, round-trip, subprocess) | Simulated + Local subprocess | harness section (this phase) | PASS (2026-10-08) |
| Recommendation engine: tier statuses/confidences, four status transitions, nothing-fits degradation, GPU-name independence | Simulated (fake hardware) | harness "Recommendation engine: catalogue-driven tiers (ADR-005)" | PASS (2026-10-08) |
| Live `-Action Recommend` document | Local (real install) | exit 0; fast/balanced/maximum typed, no blockers, parsed by an independent JSON reader | PASS (2026-10-08) |
| Runtime adapters: catalogue ids/statuses, unknown id throws, capability honesty (nothing claimed without a probe), stub `not_implemented` + unknowns | Simulated | harness "Runtime adapters: one interface, honest stubs (ADR-005)" | PASS (2026-10-08) |
| `Stop-Runtime` without `-Force` never kills a process (process count asserted unchanged) | Simulated (no live server touched) | harness | PASS (2026-10-08) |
| `Stop-Runtime -Force` (real kill path) | Simulated (stand-in process) + Local (opt-in) | harness "Runtime adapters": spawns a stand-in `llama-server.exe`, force-stops it, asserts it is gone, skips if a real server is running; desktop `cargo test -- --ignored live_start_stop` drives the same path on a server it started | PASS (2026-10-09) |
| Diagnostics document: four sections, allowed value sets, JSON round-trip, overall roll-up, live subprocess | Simulated + Local subprocess | harness "Diagnostics: one typed document (ADR-005)" | PASS (2026-10-08) |
| Live `-Action Diagnose` on the real install | Local | exit 0; overall ok/high, runtime stopped/validated, hardware supported/high, no warnings/blockers | PASS (2026-10-08) |
| Benchmark contract: schema required fields, template matches schema, template measurements all `null` | Simulated | harness "Benchmark contract: stable schema, no fabricated data" | PASS (2026-10-09) |
| Every recorded result validates against the schema with non-null measurements (checked non-vacuously: rejects a null metric, a missing field and a wrong `schema_version`) | Simulated | harness "Benchmark contract" recorded-result check | PASS (2026-10-09) |
| Installed runtime enumerates the RX 9070 XT via ROCm | Local | `llama-server.exe --version` → 1 ROCm device, gfx1201, 16304 MiB (quoted in upstream evidence) | PASS (2026-10-08) |
| Flag support in the exact installed build | Local | `llama-server.exe --help` for `--device/--fit/--parallel/--api-key/--jinja/--reasoning/--sleep-idle-seconds` | PASS (2026-10-08) |
| End-to-end server start + generation on this machine | Local (prior session) | `Test-LocalServer` passed in earlier sessions; **not re-run in Phase A** | Prior-session evidence only |
| Staged downloads: resume a partial file, promote atomically, clean staging after success/failure | Simulated (fake downloader, real files) | harness "Robustness gap 2" | PASS (2026-10-09) |
| Download checksum/size mismatch fails loudly with expected+actual hash, promotes nothing, deletes the staged file | Simulated (real corrupt bytes) | harness "Robustness gap 2" | PASS (2026-10-09) |
| A server that refuses resume triggers exactly one full restart; a legacy `<file>.part` is adopted | Simulated | harness "Robustness gap 2" | PASS (2026-10-09) |
| Port ownership: free / foreign-owner conflict with PID & refusal, `owned` for our own listener, start guard refuses, diagnostics carry the verdict | Simulated (real TcpListener squatter) | harness "Robustness gap 3" | PASS (2026-10-09) |
| Paths with spaces + Unicode install root: generated launchers stay pure ASCII, use `%~dp0`, args stay an array, launcher runs for real, `-Action State` round-trips | Simulated + Local subprocess | harness "Robustness gap 1" | PASS (2026-10-09) |
| UTF-8 stdout contract for JSON actions (`-Action State/Recommend/Diagnose/Runtime`) so non-ASCII survives the console code page | Local subprocess | harness "Robustness gap 1" | PASS (2026-10-09) |
| Desktop supervisor (Rust/Tauri): typed command handlers, no shell string building, health/state parity with the PowerShell layer | Simulated + Local | `desktop/src-tauri/src/main.rs` `#[cfg(test)]` unit tests | PASS (2026-10-09) |
| Desktop UI pure formatting layer (`format.ts`) | Simulated | `desktop/src/format.test.ts` (vitest) | PASS (2026-10-10) |
| Settings screen shows the idle choice's VRAM effect (0.9 × Radeon VRAM − active model) from the Settings document's `gpu_vram_gib`/`active_model_gib`; null stays silent | Simulated + Local (real install) | harness Settings VRAM-field checks; `describeIdleVramEffect` vitest; `docs/desktop-settings-vram.png` | PASS (2026-10-10) |
| Desktop release binary renders the real install standalone (no dev server) | Local (real install) | `Capture-DesktopScreenshot.ps1` gate inside the harness; verified artifacts `docs/desktop-window.png` (+ `desktop-window-narrow.png`/`-wide.png` for the responsive layout) | PASS (2026-10-10); gate re-verified per harness run, honest SKIP when no window is open |
| Layout scales with window size: fluid type/spacing, two-column model library on wide windows, stacked fact rows below 640 px | Local (release binary at 780 px and 1560 px) | `docs/desktop-window-narrow.png` + `docs/desktop-window-wide.png` captured by the same tool | PASS (2026-10-10) |
| First real benchmark numbers recorded on the test machine (qwen3.5-9b, ROCm, single slot) | Local (real install) | `benchmarks/results/` + `docs/testing/benchmark-results.md` | PASS (2026-10-09); see results for the measurement |
| Settings surface: read document (schema, capability probed, catalogue-allowed list), write through the existing helpers, per-field rejection, junk input refused, nothing written on read | Simulated + Local | harness "`-Action Settings`" (17 checks, 2026-10-10) + `cargo test settings_read_and_save_return_typed_documents` | PASS (2026-10-10); at-capability idle save verified live on the real install, runtime-less root proves the refusal rule |
| Settings desktop screen renders from the backend document; Save shows applied/rejected honestly | Local (release binary) | `docs/desktop-settings-scrolled.png`; vitest settings cases | PASS (2026-10-10) |
| Runtime update action (`-RuntimeAction update`): without confirmation it only asks and writes nothing; a stub adapter reports `not_implemented`; the confirmed path delegates to the single-source updater (staged, backup, launcher rebuild) | Simulated + Local + **Live** | harness "`-Action Runtime`" update checks (440 total); real run on the test machine 2026-10-10: AMD-package path re-verified in place, ROCmLatest path downloaded **b11429 (ROCm 10.0)**, SHA-256 passed, GPU-visibility guard then declined it (no separate AMD ROCm runtime libs installed) and restored b8407 intact (models, launchers, settings) | PASS (2026-10-10) — both update paths exercised end to end; the guard's decline is correct behaviour, not a failure |
| Runtime update actually unblocks Gemma 4 12B / Ornith 1.5 9B | — | b11429 cannot be kept on this machine until AMD's ROCm runtime libraries (hipBLAS/rocBLAS) are installed separately; Library still shows both blocked on b8407 after the live run | **Untested** — gated on installing AMD's ROCm runtime; never claim unblocked without it |
| Model library: read document shape + typed refusals (not-downloaded activate, unknown action, missing -ModelId) on an empty install | Simulated + Local | harness "`-Action Library`" (12 checks, 2026-10-10) | PASS (2026-10-10) |
| Update-unlock list: `unlocked_models` in the Library document is derived from the compatibility catalogue's stage rule (backend + tag_regex + model flags), lists only stage-blocked models, empty for a foreign runtime or no runtime | Simulated + Local (real install) | harness unlock checks (447 total, 2026-10-10); live line under the Update button on the release binary (`docs/desktop-window.png`) | PASS (2026-10-10) |
| Model library live values (downloaded/active/fit/blocker for all 9 models) and blocked-model download rejection | Local (real install) | transcript probes; `docs/desktop-library.png` | PASS (2026-10-10) |
| Model download itself run end to end from the screen | — | transfer path is validated (staged checksum, harness gap 2) but the screen-initiated multi-GB run was not executed this slice | **Untested** — never claim it ran |
| Intel CPU + AMD dGPU, supported APU alone, Intel iGPU alongside Radeon, multi-GPU, non-Windows-11 | — | — | **Untested** — hardware not available; never claim support |
| iGPU/NPU offload benefits (checklist §14) | — | — | **Untested** — evidence-gated, no claims |
| Sleep/resume, GPU reset, driver crash recovery | — | — | **Untested** (Phase C gap) |
| Editor rollback after a failed mid-write | — | backups asserted; simulated crash mid-write not tested | Partial |

## Failure-matrix coverage (checklist §17)

| Failure | Covered? |
|---|---|
| Low disk / low VRAM | Preflight logic simulated (`Get-VramPreflight` tests); real low-disk run untested |
| Network loss during download | Covered — staged resume + one full restart when resume is refused (harness "Robustness gap 2") |
| Corrupted/changed model files | Covered — size/hash mismatch fails loudly and deletes the staged file (harness "Robustness gap 2") |
| Unsupported runtime flags | Covered — `Test-LlamaServerSupports` probes `--help` (tested) |
| Port occupied | Covered — foreign owner detected by PID, start refuses, diagnostics carry the blocker (harness "Robustness gap 3") |
| User cancels during install | Covered — exit code 2 paths tested for `VSCodeChat`/`Easy`/`Models` |
| App closes mid-configuration-transaction | Untested |
| Driver reset / sleep-resume / crash | Untested |
| Existing custom editor settings | Covered — harness seeds unrelated providers/settings and asserts preservation |
| Paths with spaces / Unicode | Covered — ASCII launchers via `%~dp0`, array args, real launcher run, UTF-8 JSON stdout (harness "Robustness gap 1") |
| Remote editor extension host | Untested |
| Catalogue unavailable/invalid | Covered — offline catalogue is compiled-in; HF metadata failure path reviewed, network test untested |

## Required before each release gate

1. Re-run: `powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-CommandCenter.ps1`
   plus the full CI-equivalent set (see `CLAUDE.md` / implementation status).
2. Live `Test-LocalServer` run on the test machine (start → ready → generation → stop).
3. Any newly claimed hardware must be physically tested and added to the table above
   with exact device, driver, engine build and results — otherwise it stays **untested**.
