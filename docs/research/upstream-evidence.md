# Upstream evidence record

Every consequential dependency or claim in this project, checked against the primary
source. Earlier review statements were treated as research leads only; nothing below
rests on them.

- **Method:** live HTTPS queries from this checkout (Windows 10/11 x64, PowerShell 5.1,
  Git Bash tooling) on the dates shown. Commands are reproducible with `curl`/`Invoke-RestMethod`
  against the exact URLs listed.
- **Local validation** means a command was run on this machine (AMD Ryzen 7 9800X3D,
  RX 9070 XT 16 GB, 31 GB RAM, Windows 11 build 26300) and produced the quoted output.
- **Decision values:** recommended / experimental / deferred / rejected.

---

## 1. This repository

| Item | Finding | Checked |
|---|---|---|
| Git metadata | **Not a git checkout on this host** — no `.git` directory exists, so default branch, `git status`, and current commit cannot be confirmed. Recorded as an evidence gap (§22 checklist item cannot be satisfied here). | 2026-10-08 |
| Installer/launcher files | `Install-LlamaCpp-AMD.ps1` (3,850 lines, 118 functions), `Start-LlamaCpp.cmd` (807 lines), `tests/Test-CommandCenter.ps1` (470 → 509 lines after this phase) all exist at repo root. README's Development section matches reality. | 2026-10-08 |
| Version | `$script:CommandCenterVersion = '0.1.6'`; `dist/` contains a v0.1.0 ZIP + SHA-256 (stale local artifact, gitignored). | 2026-10-08 |
| CI | `.github/workflows/ci.yml` runs CRLF check, PS 5.1 AST parse, PSSA (errors only), the offline test harness, and a batch menu smoke test with `(echo x& echo 5& echo 8& echo 0)`. All five reproduced locally: **pass**. | 2026-10-08 |
| Tests | Baseline run before changes: **177 PASS, 0 FAIL, exit 0**. After Phase A changes: **225 PASS, 0 FAIL, exit 0**. | 2026-10-08 |

## 2. AMD ROCm Windows llama.cpp package (default ROCm backend)

| Field | Value |
|---|---|
| Product | AMD-validated llama.cpp prebuilt binaries for Windows Radeon |
| Source | <https://rocm.docs.amd.com/projects/radeon-ryzen/en/latest/docs/advanced/advancedrad/windows/llm/llamacpp.html> and the directory index <https://repo.radeon.com/rocm/llama.cpp/windows/> |
| Date checked | 2026-10-08 |
| Exact artifact | `llama-b8407-windows-rocm-7.2.1-gfx110X-gfx115X-gfx120X-x64.zip`, **565,651,083 bytes**, dated 30-Mar-2026 |
| What the source establishes | AMD's docs page still documents exactly this URL and command. The repo index lists only `rocm-rel-7.1.1/`, `rocm-rel-7.2/`, `rocm-rel-7.2.1/` — **7.2.1 is still the newest Windows llama.cpp package**. Targets gfx110X/gfx115X/gfx120X (RDNA3/3.5/4). Docs note coverage "through 7.2.1" and unified docs from ROCm Core SDK 7.13.0 onward. |
| Unknown/conflicting | AMD publishes **no SHA-256 sidecar** for this ZIP (the script records the downloaded hash locally and says so — verified in `Get-VerifiedDownload`). Whether a newer ROCm-for-Radeon release supersedes 7.2.1 under the unified-docs scheme is not visible from this index. |
| Licence | AMD's package; redistribution not verified → **never bundled**, downloaded on user consent only. Decision: **recommended** (default backend for ROCm-capable cards). |
| Local validation | `%LOCALAPPDATA%\Programs\llama.cpp\current\installation.json` records `tag: rocm-7.2.1-b8407`, `backend: ROCm`. `llama-server.exe --version` → `version: 2500 (312cf033)`, built with Clang 22.0.0, and reports `found 1 ROCm devices … AMD Radeon RX 9070 XT, gfx1201 (0x1201) … 16304 MiB`. Commit `312cf033` resolves upstream to 2026-03-18. |

`$script:AmdRocmPackageCheckedOn` was **updated to 2026-10-08** because the package URL, name,
and byte size were re-confirmed against the directory index today.

## 3. llama.cpp upstream releases (ggml-org)

| Field | Value |
|---|---|
| Source | <https://api.github.com/repos/ggml-org/llama.cpp/releases> (same endpoint the script uses) |
| Date checked | 2026-10-08 |
| Findings | Stable "latest" release is **v0.6.0** (published 2026-10-05) and its only asset is `nightly-tag.txt` — exactly the fallback path `Get-LatestLlamaCppAsset` implements (read tag file → fetch that nightly tag's assets). Nightly **b11481** (2026-10-08) publishes `llama-b11481-bin-win-vulkan-x64.zip` (33,400,181 B) and `llama-b11481-bin-win-rocm-10.0-x64.zip`. |
| What this establishes | The script's asset-name patterns (`^llama-.*-bin-win-vulkan-x64\.zip$`, `^llama-.*-bin-win-rocm-[0-9.]+-x64\.zip$`) match real asset names **as of this date**; the stable→nightly resolution logic is correct for the current release layout. Upstream Windows ROCm builds now target **ROCm 10.0**, not 7.x. |
| Licence | MIT. Decision: **recommended** (Vulkan and "ROCm (latest)" backends). |
| Unknown | Future asset renaming would break both regexes; no schema contract exists upstream. Covered by the freshness check, not by a test. |

### Flag support in the installed build (b8407)

`llama-server.exe --help` on the installed package confirms every flag the launcher emits:
`--device`, `--list-devices`, `--fit`, `--parallel`, `--api-key`, `--jinja`, `--reasoning [on|off|auto]`,
`--sleep-idle-seconds`. Checked locally 2026-10-08. This is the exact selected build, not a
generic llama.cpp claim.

## 4. Model catalogue (every file the catalog can download)

Captured from the Hugging Face API (`/api/models/{repo}` + `/tree/{revision}?recursive=true&expand=true`)
on 2026-10-08 and pinned into **`tests/fixtures/catalog-evidence.json`**: repo revision (40-char sha),
exact file names, byte sizes, and Git LFS SHA-256 oids. The test harness now fails if the
catalog drifts from this record (`tests/Test-CommandCenter.ps1`, "Catalog matches the recorded
upstream evidence").

| Model id | Repo | File (verified) | Total (GiB) | Licence | Gated | Decision |
|---|---|---|---:|---|---|---|
| qwen3.8-27b | ggml-org/Qwen3.8-27B-GGUF @ `71bc7b62…` | Qwen3.8-27B-Q4_K_M.gguf | 18.26 | apache-2.0 | no | recommended (quality option; spills to RAM on ≤16 GB) |
| qwen3.5-9b | unsloth/Qwen3.5-9B-GGUF @ `3885219b…` | Qwen3.5-9B-Q4_K_M.gguf | 6.15 | apache-2.0 | no | recommended (default) |
| ornith-1.5-9b | ornith-ai/Ornith-1.5-9B-GGUF @ `abdd624b…` | Ornith-1.5-9B-Q4_K_M.gguf | 6.24 | mit | no | experimental (MTP block fails on b8407; publisher-reported gains unverified) |
| gemma4-12b | ggml-org/gemma-4-12B-it-GGUF @ `e3e68173…` | **gemma-4-12B-it-Q4_0.gguf** | 6.87 | apache-2.0 | no | experimental (needs newer llama.cpp than b8407) |
| gemma3-12b | ggml-org/gemma-3-12b-it-GGUF @ `ec0cbabd…` | gemma-3-12b-it-Q4_K_M.gguf | 7.59 | gemma | no | recommended (vision, no tools) |
| qwen3-8b | ggml-org/Qwen3-8B-GGUF | Qwen3-8B-Q8_0.gguf | 8.11 | apache-2.0 | no | recommended |
| llama3.1-8b | ggml-org/Meta-Llama-3.1-8B-Instruct-Q4_0-GGUF @ `0aba27dd…` | meta-llama-3.1-8b-instruct-q4_0.gguf | 5.62 | llama3.1 | no | recommended |
| gemma3-4b | ggml-org/gemma-3-4b-it-GGUF @ `d0976223…` | gemma-3-4b-it-Q4_K_M.gguf | 3.11 | gemma | no | recommended (low-memory/vision) |
| qwen3-4b | ggml-org/Qwen3-4B-GGUF | Qwen3-4B-Q4_K_M.gguf | 2.33 | apache-2.0 | no | recommended (fast/CPU fallback) |

### Confirmed inconsistency found and fixed in Phase A

**`gemma-4-12B-it-Q4_K_M.gguf` does not exist.** The ggml-org Gemma 4 repo publishes only
`gemma-4-12B-it-BF16/Q4_0/Q8_0.gguf` (+ projectors, + `mtp-*`); a direct API query for the
Q4_K_M path returns **404**. The catalog referenced it, so a Gemma 4 download would have failed
at `Get-HfFileDescriptor` with "File not found" after the user confirmed a 7 GB download.

- **Fix:** catalog now uses `gemma-4-12B-it-Q4_0.gguf` (7,219,673,216 B) with
  `ApproxGiB 7.02 → 6.87`; README and `docs/index.html` download figure corrected 7.5 GB → 6.9 GB.
- **Regression coverage:** the new evidence-fixture test asserts the catalog's file names match
  the verified upstream record, including an explicit assertion on the Gemma 4 file name.

### Model-architecture check (GGUF headers)

A 4 KiB HTTP range read of each primary file's GGUF header confirms `general.architecture`:
qwen35 (qwen3.8-27b, qwen3.5-9b, ornith), gemma4, gemma3 (both), qwen3 (both qwen3), llama.
Checked 2026-10-08. This distinguishes "published file exists" from "file is what its name claims".

### Leads from the earlier review, re-checked

| Lead | Verdict |
|---|---|
| Qwen3.8 | **Real** — `ggml-org/Qwen3.8-27B-GGUF` exists and is used by the catalogue (arch `qwen35`). |
| Qwen3.8-Flash-Next | **Real but unsuitable**: 177B-total/6B-active MoE (`Qwen/Qwen3.8-Flash-Next`, Aug 2026). Not offered; the Unloth GGUF was still being updated as of 2026-10-07 (upstream Reddit thread). Rejected for this catalogue: no verified fit for 8–16 GB cards. |
| Liquid d1 | **Not a local model** — Liquid AI's hosted *decision model* API (`liquid/d1`, closed, Sept 2026). No open GGUF. Rejected. |
| Reflection Beam | **Not found** — no matching Hugging Face model on search (2026-10-08). Recorded as unverified; never referenced in code or docs. |

## 5. Alternative engines and routers (checklist §8)

| Project | Source | Date | Status | Decision |
|---|---|---|---|---|
| Strata | <https://github.com/Niko1221/Strata>, MIT, latest release **v0.1.40.3** (2026-10-07) | 2026-10-08 | Active. Runs Qwen3.8-Flash-Next on consumer hardware (README claims AMD RX 9070 XT numbers — **publisher-reported, unverified here**). | **deferred** — experimental engine, release-specific validation required before any gate opens (§8). Not referenced by code. |
| Lemonade | <https://github.com/lemonade-sdk/lemonade>, Apache-2.0, pushed 2026-10-07 | 2026-10-08 | Active; AMD-sponsored local LLM server (Radeon/NPU). | **deferred** — investigate as delegated runtime management vs direct adapter before duplicating its functions (§8). |
| llama-swap | <https://github.com/mostlygeek/llama-swap>, MIT, pushed 2026-10-07 | 2026-10-08 | Active; model swapping for OpenAI-compatible servers. | **deferred** — this project already owns a single-model supervisor; evaluate only if multi-model routing is built (§9). |
| KTransformers | <https://github.com/kvcache-ai/ktransformers>, Apache-2.0, pushed 2026-10-01 | 2026-10-08 | Active; heterogeneous CPU/GPU inference framework. | **rejected for now** — complexity unjustified for the beginner-first scope (§8). |
| GAIA | — | 2026-10-08 | Not investigated beyond confirming it is out of scope. | **deferred** — optional later agent layer only, never an inference dependency (§8). |

## 6. Editor integrations (checklist §12)

| Integration | Official source | Date | What the source establishes | Decision |
|---|---|---|---|---|
| VS Code custom endpoint models | <https://code.visualstudio.com/docs/agent-customization/language-models> (also MS Learn + VS Code BYOK blog, June 2026) | 2026-10-08 | VS Code officially opens/edits `chatLanguageModels.json` for custom endpoint models — the mechanism option [6] writes is documented, not private. Schema details beyond documented keys remain version-sensitive; the project writes only the keys it needs and refuses malformed JSON. | **recommended** |
| Continue | <https://docs.continue.dev/reference> (config.yaml reference) | 2026-10-08 | `name`/`version`/`schema` are required top-level keys; `models:` is a list of `{name, provider, model, apiBase, roles, capabilities…}`. `provider: llama.cpp` with `apiBase` is a documented provider page (<https://docs.continue.dev/customize/model-providers/more/llamacpp>). | **recommended** — matches what `Install-ContinueConfig` writes; the "own `models:` key → instructions only" guard remains correct. |
| llama-vscode | `ggml-org.llama-vscode` extension; endpoint settings in VS Code `settings.json` | 2026-10-08 | Settings-key mechanism (JSONC-aware, comment guard) verified by tests against fixture files, not against the extension's source. | **recommended**, with existing comment-refusal guard |
| Cline / Roo Code | Not verified this phase. | — | — | **deferred** — no adapter until current docs establish the config mechanism (§12). |

## 7. Desktop stack candidates (checklist §3)

| Candidate | Source | Date | Finding | Decision |
|---|---|---|---|---|
| PowerShell + WPF window (current) | this repo | 2026-10-08 | Already shipped: `Show-CommandCenterWindow` builds real XAML, drives real functions; tests exercise `Get-GuiState`/`Set-GuiState` (225 checks). | **recommended** as the near-term shell — see ADR-001. |
| Tauri v2 | <https://github.com/tauri-apps/tauri>, Apache-2.0, active | 2026-10-08 | Requires a Rust/Node build toolchain and a rewrite of every UI handler; no user-visible capability gain over the current window for Phase B. | **deferred** — revisit only if the WPF shell hits a hard limit (documented in ADR-001). |

## 8. Hardware claims (checklist §4)

| Claim | Status |
|---|---|
| RX 9070 XT detected via DXGI with true dedicated memory (avoids the WMI 4 GiB cap) | **Verified locally** — `Get-DxgiGpuInventory` runs; `llama-server --list-devices` independently reports 16304 MiB on gfx1201. |
| ROCm b8407 package works on RX 9070 XT (gfx1201) | **Verified locally** — `--version` enumerates the device; prior long-run stability is documented as this project's own experience, not a benchmark. |
| Ryzen iGPU never used automatically | **Verified by tests** — `Select-PrimaryLlamaDevice` pins the dGPU by name, iGPU-only systems get no pin (4 assertions). |
| Vulkan instability on RX 9070 XT (`device lost on Vulkan0`, TDR/bugcheck 0x116) | **Single-machine observation** recorded in CLAUDE.md/README; not reproduced this phase, not generalised to other cards. Labelled as such in docs. |
| Token/s figures (45–90 tok/s Qwen3.5, 4–7 tok/s 27B, etc.) | **Publisher/prior-session measurements, unverified this phase.** No new benchmark was run; see `docs/testing/benchmark-results.md`. Never presented as fresh results. |
| iGPU/APU pooling improves performance | **Never claimed anywhere** and not tested. Remains gated (§14). |

## Evidence gaps (recorded, not optimised away)

1. **No git metadata on this host** — branch/commit/status unconfirmable; treat file mtimes and this record as the baseline.
2. **AMD ROCm package has no publisher checksum** — local-hash recording is the only option; documented in README and code.
3. **Strata/Lemonade claims** are from their own READMEs; no local runs performed.
4. **Gemma 4 tool-calling with Copilot Agent mode** untested here (README already says so).
5. **`chatLanguageModels.json` key set** beyond the written keys is not covered by a public schema; regression surface is fixture-based tests.
6. **Gemma 4 Q4_0 vs Q4_K_M quality** — Q4_K_M does not exist upstream, so no A/B claim is made; only the file that exists is offered.
