# CLAUDE.md

Windows command center for running llama.cpp on AMD Radeon GPUs and connecting it to VS Code Copilot Chat, llama-vscode and Continue. Two shipped files plus docs:

- `Start-LlamaCpp.cmd` — beginner batch menu (double-click entry point). Calls the PowerShell script for all real work.
- `Install-LlamaCpp-AMD.ps1` — everything else: hardware scan, backend install, model catalog/download, launcher generation, editor integrations. `-Action` selects the mode (see README "Command-line reference").
- `tests/Test-CommandCenter.ps1` — offline test harness (no downloads, no real install touched).
- `docs/index.html` — GitHub Pages site. Keep it in sync with `README.md`.

Live install lives in `%LOCALAPPDATA%\Programs\llama.cpp` (`current\`, `models\`, `active-model.json`, generated `Start-LlamaCpp.cmd`, `logs\`).

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
- `server-args.user.json` is user-owned: read and merge it last, never write it.
- `Get-ServerArguments` is the single source of truth for launcher and direct-start flags.
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
