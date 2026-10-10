# AMD Local AI Command Centre: Master Agent Prompt and Implementation Checklist

## 0. Start here: your assignment

You are the engineering agent working in the existing `llamacpp-amd-command-center` repository. Evolve it into a polished, AMD-first local AI desktop application, preserving useful existing functionality and providing a safe migration path from its script-based interface.

This document is a proposed implementation specification, not a verified description of the current repository or upstream products. Inspect the actual checkout and verify current official documentation before making technical decisions. Do not treat earlier review statements, release numbers, model names, dates or performance claims as established facts.

### Product outcome

An ordinary AMD GPU owner should be able to:

1. Install and open the application.
2. See an accurate explanation of their hardware and supported options.
3. Choose a purpose such as coding, general chat or image/document assistance.
4. Receive a compatible model recommendation with honest memory and storage requirements.
5. Download, validate and start the model without manually editing scripts.
6. Connect supported coding tools through safe, reversible configuration changes.
7. Change models without repeatedly repairing editor settings.
8. Understand errors and recover without becoming an inference expert.
9. Use downloaded models offline without silent cloud fallback.
10. Obtain measurable performance improvements rather than speculative tuning promises.

### Scope

- AMD discrete GPUs are the primary target.
- Intel and AMD CPUs must both be supported where the chosen runtime supports them.
- AMD APUs, Intel integrated GPUs and supported NPUs are optional, capability-gated targets.
- Windows is the initial product target unless repository evidence justifies another priority.
- Preserve an architecture that can support Linux later without claiming untested parity.
- Local inference engines remain separate from the application orchestration layer.
- A visual application is the main interface; existing scripts may remain as documented recovery tools.

### Non-negotiable execution rules

- Inspect first, then implement. Do not replace the repository wholesale.
- Preserve working features unless a documented replacement passes regression tests.
- Implement actual functionality, not a mock dashboard or buttons with no connected behaviour.
- Distinguish planned, implemented, tested, blocked and experimentally supported features.
- Never claim a benchmark or hardware test was run when it was not.
- Never invent model availability, download URLs, GPU support, release versions or licence terms.
- Do not install drivers, change security settings, enable remote access or overwrite user configurations without explicit user approval in the application.
- Do not commit secrets, downloaded model weights, proprietary assets or large runtime binaries.
- Do not enable telemetry or cloud fallback by default.
- Do not assume that more devices, larger contexts or more CPU threads mean better performance.
- Do not treat OpenAI-compatible endpoints as proof of complete editor compatibility.
- Keep each implementation slice buildable and reviewable.
- When blocked, finish independent work, document the exact blocker and leave a safe disabled state.
- Do not stop at a plan if implementation tools and repository access are available.

## 1. Verification gate: correct the evidence before coding

The previous review suggested ROCm updates, particular model releases, runtime options and specific repository behaviours. Those suggestions are research leads only. Re-establish the facts from the checkout and official upstream sources.

### Required evidence record

Create `docs/research/upstream-evidence.md`. For every consequential dependency or claim, record:

- Product/project and official source link.
- Date checked, exact release/tag/commit and operating system.
- Relevant GPU architecture and tested device, if published.
- What the source explicitly establishes.
- What remains unknown or conflicting.
- Licence and redistribution considerations.
- Decision: recommended, experimental, deferred or rejected.
- Local validation performed and its reproducible command/log reference.

### Checklist

- [ ] Confirm the repository default branch, working tree status and current commit.
- [ ] Read all project instructions, manifests, documentation and relevant source files.
- [ ] Inventory scripts, configuration files, downloads, models, integrations and CI workflows.
- [ ] Verify whether the previously mentioned installer and launcher filenames actually exist.
- [ ] Verify any hardcoded model aliases, ports, runtime versions and download paths.
- [ ] Verify current checksum, GPU detection, logging and loopback-binding behaviour.
- [ ] Inspect actual test workflows; do not infer test coverage from workflow names alone.
- [ ] Verify current AMD driver, ROCm/HIP and runtime compatibility using official documentation.
- [ ] Verify llama.cpp backend capabilities against the exact selected build.
- [ ] Investigate Lemonade, Strata, llama-swap and KTransformers using their official repositories.
- [ ] Investigate GAIA only as an optional later agent layer, not a mandatory inference dependency.
- [ ] Resolve conflicting Strata support statements by exact release and platform; record unresolved conflicts.
- [ ] Verify the existence, availability, architecture and licence of every proposed model.
- [ ] Treat previously mentioned Qwen3.8, Flash-Next, Liquid d1 and Reflection Beam names as unverified research leads.
- [ ] Replace unavailable or unsuitable model candidates with currently verified alternatives.
- [ ] Distinguish announced, downloadable, engine-supported and locally validated models.
- [ ] Verify current Continue configuration formats and editor integration mechanisms.
- [ ] Verify official VS Code local-model integration support and its limits.
- [ ] Record evidence gaps instead of converting them into optimistic assumptions.

Acceptance: no download, recommendation or compatibility badge depends solely on an unverified earlier review claim.

## 2. Baseline audit and preservation plan

Create `docs/engineering/baseline-audit.md` and a feature-preservation matrix.

- [ ] Map first-run installation, hardware detection, model download, server start/stop and editor setup.
- [ ] Identify user-owned files versus application-owned files.
- [ ] Identify where model files and runtime binaries are currently stored.
- [ ] Record existing settings and migration requirements.
- [ ] Audit quoting, paths containing spaces, Unicode paths and environment-variable handling.
- [ ] Audit process ownership, termination and stale PID handling.
- [ ] Audit network binding, API authentication and logs.
- [ ] Audit checksum verification and partial-download recovery.
- [ ] Audit privilege requirements and unexpected elevation.
- [ ] Audit model aliases and selected-model propagation into editor settings.
- [ ] Audit configuration handling for JSON, JSONC and YAML.
- [ ] Identify dependencies with unknown maintenance or redistribution status.
- [ ] Capture baseline automated tests before changing core behaviour.
- [ ] Write regression tests for useful behaviours already present.
- [ ] Document every deliberate behavioural change and its replacement.

Feature-preservation matrix columns: existing behaviour, source location, risk, replacement component, migration test, status.

Acceptance: an existing user can retain their models and recover their previous configuration after migration.

## 3. Architecture decision and repository structure

Preferred proposal: Tauri desktop shell, React/TypeScript interface and Rust orchestration core. Validate suitability against the actual repository, dependency footprint, platform requirements and maintainability. An alternative is acceptable only with a written architecture decision explaining the trade-offs.

### Separation of concerns

```text
Desktop UI
  -> Typed application commands and events
  -> Application services
       Hardware inventory
       Compatibility catalogue
       Model/download manager
       Runtime/process supervisor
       Local routing and aliases
       Benchmark/profile manager
       Editor integration adapters
       Diagnostics/migration/update services
  -> Engine adapters
       llama.cpp
       Lemonade, if validated
       Strata, experimental until validated
       Other engines only when justified
```

Suggested structure, adapted rather than imposed blindly:

```text
apps/desktop/
crates/core/
crates/hardware/
crates/runtime/
crates/catalogue/
crates/integrations/
crates/diagnostics/
config/catalogue/
schemas/
tests/unit/
tests/integration/
tests/e2e/
docs/architecture/
docs/research/
docs/testing/
legacy/
```

- [ ] Write architecture decisions for desktop stack, routing and runtime management.
- [ ] Define typed commands, progress events, errors and cancellation contracts.
- [ ] Keep domain logic independent of the UI framework.
- [ ] Keep runtime-specific flags inside adapters.
- [ ] Avoid scraping coloured terminal output when structured interfaces are available.
- [ ] Use a narrow desktop IPC surface and explicit permissions.
- [ ] Validate all IPC inputs; never expose arbitrary shell execution to the renderer.
- [ ] Use argument arrays rather than shell-concatenated user input.
- [ ] Separate production code, fixtures, generated files and downloaded artefacts.
- [ ] Provide a documented development build and test entry point.
- [ ] Make missing hardware/runtime capabilities produce clear disabled states.

Acceptance: the UI can be replaced without rewriting model management or runtime supervision.

## 4. Hardware inventory and capability model

Detect hardware accurately and report uncertainty honestly. A CPU brand is not a performance profile. Shared memory is not extra physical RAM.

### Inventory fields

Record OS/build, CPU model and topology, usable RAM, available RAM, GPU adapter IDs, vendor/device identifiers, dedicated memory, shared-memory relationship, driver version, supported backend probes, free storage and relevant platform constraints. Distinguish physical adapters from remote/virtual adapters.

- [ ] Implement reliable Windows adapter enumeration using supported native interfaces.
- [ ] Avoid relying solely on WMI VRAM fields.
- [ ] Distinguish AMD dGPU, AMD APU, Intel iGPU and unsupported adapters.
- [ ] Distinguish installed, available and currently usable memory.
- [ ] Avoid double-counting system RAM and shared GPU memory.
- [ ] Detect hybrid systems and multiple adapters without assuming compatibility.
- [ ] Probe runtime support rather than trusting a GPU name string.
- [ ] Record CPU instruction support relevant to selected binaries.
- [ ] Detect unsupported driver/runtime combinations and explain them.
- [ ] Handle virtual machines, remote desktop and missing driver information gracefully.
- [ ] Cache inventory with invalidation after hardware/driver changes.
- [ ] Expose a redacted hardware summary suitable for support.
- [ ] Provide a manual override only in advanced settings, labelled unvalidated.

### Recommendation policy

- [ ] AMD dGPU plus Intel CPU: choose a validated Radeon path and benchmark CPU settings.
- [ ] AMD dGPU plus AMD CPU: apply the same evidence-based policy.
- [ ] Intel iGPU alongside Radeon: consider separate workloads only after backend validation.
- [ ] Ordinary Ryzen iGPU alongside Radeon: do not automatically pool execution.
- [ ] Supported high-memory APU: use a dedicated shared-memory profile.
- [ ] Multiple discrete GPUs: expose only validated splitting modes.
- [ ] Unsupported GPU: offer a clearly labelled CPU fallback when available.

Acceptance: unsupported hardware is never presented as fully supported merely because a related device was tested upstream.

## 5. Compatibility catalogue and trust model

Create a versioned, schema-validated catalogue separate from application code.

### Catalogue entities

Runtime build, driver requirement, GPU architecture, operating system, model artefact, capability profile, integration profile and validation record.

### Required model fields

- Stable catalogue ID and display name.
- Official publisher/repository and pinned revision.
- Exact files, sizes, checksums and dependencies.
- Licence, gated-access requirements and acceptance state.
- Architecture, quantisation and required engine support.
- Chat, streaming, tools, vision, FIM, embeddings and reranking capabilities.
- Projector/tokeniser/draft-model dependencies where applicable.
- Download size, installation peak storage and estimated working-memory range.
- Tested context sizes and backend profiles.
- Validation date, test provenance and support tier.

- [ ] Define and test catalogue schemas.
- [ ] Use pinned revisions for recommendations.
- [ ] Keep discovered, verified, experimental and recommended states separate.
- [ ] Validate metadata updates before activation.
- [ ] Preserve the last known-good catalogue for offline use and rollback.
- [ ] Do not silently replace installed models after metadata updates.
- [ ] Support revoking a recommendation without deleting user files.
- [ ] Require trustworthy provenance for runtime downloads.
- [ ] Distinguish publisher-provided checksums from application-computed hashes.
- [ ] If signed catalogues are used, define key rotation and recovery procedures.
- [ ] Never fetch an arbitrary executable solely because untrusted model metadata names it.
- [ ] Document licence obligations for bundled and downloaded components.

Acceptance: a recommendation can be traced to exact artefacts and an explicit compatibility record.

## 6. Memory, storage and model recommendations

Do not equate GGUF file size with runtime memory usage. Do not equate download size with GPU residency. Estimates must include uncertainty.

- [ ] Estimate weights, KV cache, runtime buffers, vision components and safety headroom.
- [ ] Account for architecture-specific memory behaviour and context settings.
- [ ] Distinguish download size, final disk size and peak installation disk usage.
- [ ] Account for existing display/application GPU usage.
- [ ] Distinguish comfortable fit, partial offload, experimental and cannot fit.
- [ ] Explain the recommendation in plain language.
- [ ] Offer lower-context or smaller-model alternatives when appropriate.
- [ ] Avoid automatically recommending maximum advertised context.
- [ ] Detect likely system-memory pressure and swapping risk.
- [ ] Calibrate estimates using actual measurements without hiding discrepancies.
- [ ] Keep published model context limits separate from tested local context profiles.
- [ ] Treat active parameter count and total storage as different quantities.
- [ ] For specialised large models, verify engine-specific loading requirements.
- [ ] Present a pre-install summary with required disk space and expected support status.

Acceptance: the UI never promises that a model fits comfortably based only on its download size or nominal GPU capacity.

## 7. Model library and downloads

- [ ] Implement searchable installed/recommended/experimental model views.
- [ ] Support local import without copying huge files unnecessarily.
- [ ] Validate imported artefacts and mark unknown provenance clearly.
- [ ] Support multi-file models and required auxiliary files.
- [ ] Implement resumable downloads with safe fallback when resume is unsupported.
- [ ] Implement pause/cancel/retry and structured progress.
- [ ] Detect changed remote artefacts before resuming.
- [ ] Verify hashes before activation.
- [ ] Download to staging and atomically promote validated artefacts.
- [ ] Check disk space before and during installation.
- [ ] Handle network loss, rate limits, authentication and expired credentials.
- [ ] Store credentials through supported secure storage, not plain logs/configuration.
- [ ] Prevent path traversal and unsafe archive extraction.
- [ ] Prevent symlink/archive escape from the installation root.
- [ ] Deduplicate artefacts by verified identity where practical.
- [ ] Track references before deleting shared dependencies.
- [ ] Separate removing a model entry from deleting model files.
- [ ] Show licence acceptance before gated downloads.
- [ ] Keep the application usable during downloads.

Acceptance: interrupted downloads do not produce apparently installed but corrupted models.

## 8. Runtime adapters and installation

Define a common adapter interface for capabilities, install, validate, start, stop, health, logs and benchmark support.

- [ ] Implement llama.cpp first using a pinned, verified distribution.
- [ ] Evaluate supported HIP/ROCm and Vulkan builds independently.
- [ ] Investigate Lemonade as an embeddable/runtime-management option before duplicating its functions.
- [ ] Compare a direct adapter with a delegated runtime-management approach in an architecture decision.
- [ ] Evaluate llama-swap versus an application-owned router; avoid redundant supervisors.
- [ ] Add Strata only behind a release-specific experimental gate until validated.
- [ ] Defer KTransformers unless its support and user benefit justify complexity.
- [ ] Keep GAIA optional and outside the initial inference dependency chain.
- [ ] Probe exact runtime capabilities rather than assuming flags exist.
- [ ] Record engine version, build options and runtime dependencies.
- [ ] Install runtimes into versioned directories.
- [ ] Keep a last known-good runtime and rollback path.
- [ ] Avoid system-wide PATH changes unless explicitly approved.
- [ ] Detect missing dependencies with actionable messages.
- [ ] Do not bundle a complete SDK when a supported smaller distribution suffices.
- [ ] Do not update drivers automatically.
- [ ] Verify redistribution rights before bundling binaries.
- [ ] Keep runtime updates separate from model updates.

Acceptance: a failed runtime upgrade can be rolled back without re-downloading model weights.

## 9. Process supervisor and local API routing

Use a defined lifecycle: stopped, preparing, starting, ready, stopping, failed and recovering. Readiness requires more than process existence.

- [ ] Track process identity and ownership safely.
- [ ] Use platform process-group/job mechanisms where appropriate.
- [ ] Stop only processes owned by this application.
- [ ] Detect occupied ports and offer safe alternatives.
- [ ] Bind locally by default; never silently enable LAN access.
- [ ] Validate endpoint configuration and prevent arbitrary command injection.
- [ ] Implement readiness timeouts, cancellation and useful failure states.
- [ ] Test a small generation before declaring the model ready.
- [ ] Preserve bounded logs and redact sensitive values.
- [ ] Handle sleep/resume, GPU resets and unexpected exits.
- [ ] Bound restart attempts; avoid crash loops.
- [ ] Define graceful shutdown and forced termination behaviour.
- [ ] Implement idle unloading only with visible policy and request-awareness.
- [ ] Coordinate model switches with in-flight requests.
- [ ] Reject or queue requests according to an explicit concurrency policy.
- [ ] Support streaming cancellation and client disconnects.
- [ ] Preserve correct error/status semantics through any proxy.
- [ ] Avoid duplicate copies of the same model when routing.

### Stable aliases

Proposed aliases: `local-chat`, `local-code`, `local-autocomplete`, `local-embed`.

- [ ] Implement aliases at a stable application endpoint or a validated router.
- [ ] Do not merely write alias names into editor settings without resolving them.
- [ ] Expose correct model discovery metadata.
- [ ] Update routing targets transactionally.
- [ ] Keep alias changes reversible.
- [ ] Separate role-specific models and capability checks.

Acceptance: changing the selected model does not require users to repair every connected editor, and unsupported requests fail clearly.

## 10. Desktop UX and visual quality

Build a real application, not a web page showing simulated hardware values.

### Screens

- Home: readiness, active model, start/stop, quick connections and clear next action.
- Models: installed, recommended and advanced models with honest resource requirements.
- Hardware: detected devices, support status, memory and explanations.
- Connections: editor/client status, configuration preview, tests and rollback.
- Performance: reproducible benchmarks and saved profiles.
- Diagnostics: understandable issues, repair actions and redacted support export.

### Checklist

- [ ] Design a consistent visual system with accessible typography, spacing and contrast.
- [ ] Support keyboard navigation, focus states and screen-reader labels.
- [ ] Avoid colour-only status indicators.
- [ ] Support resizing, high DPI and common display scaling settings.
- [ ] Keep technical flags in advanced panels.
- [ ] Use plain-language errors with an expandable technical detail view.
- [ ] Provide real progress, cancellation and retry actions.
- [ ] Distinguish loading, empty, offline, unsupported and error states.
- [ ] Do not hide experimental status behind a tooltip.
- [ ] Show the exact target of destructive actions.
- [ ] Confirm deletion and provide undo/rollback where feasible.
- [ ] Keep the interface responsive during inference and downloads.
- [ ] Provide a lightweight built-in chat/test panel for validating the selected model.
- [ ] Keep chat history optional, local and explicitly manageable.
- [ ] Add an advanced command preview without exposing secrets.
- [ ] Verify layouts with actual screenshots, not only component tests.

Acceptance: a first-time user can complete the primary journey without opening a terminal or editing a configuration file.

## 11. First-run and onboarding

- [ ] Detect existing installation and offer import/migration before downloading duplicates.
- [ ] Show hardware results and explain support confidence.
- [ ] Ask for purpose, not backend flags.
- [ ] Offer coding, general chat, vision/documents and low-memory presets where validated.
- [ ] Recommend one safe default and show alternatives.
- [ ] Explain download size, peak storage, licence and support status before installation.
- [ ] Provide progress with cancellation and recovery.
- [ ] Run a real generation test after installation.
- [ ] Offer editor connection only after model readiness is established.
- [ ] Let users skip editor integration.
- [ ] Preserve a completed setup across restarts.
- [ ] Provide a repair journey distinct from first-run setup.

Acceptance: a failed download or runtime start can be resumed or repaired without restarting the entire onboarding process.

## 12. Editor and client integrations

Create version-aware integration adapters. JSON is not the universal format. Verify current supported configuration mechanisms before writing anything.

### Candidate integrations

Continue, Cline, Roo Code and official VS Code local-model facilities, only where current documentation establishes support. Other clients may be added after explicit capability and configuration validation.

- [ ] Detect editor installations and user profiles without scanning unrelated private content.
- [ ] Detect extension IDs and versions.
- [ ] Handle stable/Insiders variants and portable installations where supported.
- [ ] Distinguish local Windows, WSL, remote SSH and container extension hosts.
- [ ] Do not assume localhost refers to the same machine across remote contexts.
- [ ] Determine configuration location from documented mechanisms.
- [ ] Support JSON, JSONC and YAML with appropriate parsers.
- [ ] Preserve comments, unrelated entries and user formatting where practical.
- [ ] Detect concurrent edits and refuse unsafe overwrite.
- [ ] Preview exact changes before applying them.
- [ ] Back up the original and record a transaction manifest.
- [ ] Modify only clearly application-owned entries.
- [ ] Validate syntax and schema before atomic replacement.
- [ ] Provide rollback and explain conflicts.
- [ ] Prefer official settings/API mechanisms over private extension storage.
- [ ] Never modify opaque extension databases as an undocumented shortcut.
- [ ] Use stable aliases and a stable endpoint where implemented.
- [ ] Keep chat, tools, autocomplete and embedding roles distinct.
- [ ] Use FIM-capable models for autocomplete when required by the integration.
- [ ] Do not claim chat configuration replaces every completion feature.
- [ ] Do not enable autonomous shell/tool execution in the editor by default.
- [ ] Explain unsupported versions and offer safe manual instructions.
- [ ] Keep connection status tied to actual tests, not file existence.

### Connection tests

- [ ] Model discovery.
- [ ] Non-streaming generation.
- [ ] Streaming generation and cancellation.
- [ ] Tool-call schema and response handling where supported.
- [ ] Image input where supported.
- [ ] FIM/autocomplete where supported.
- [ ] Embeddings where supported.
- [ ] Authentication and error behaviour.
- [ ] End-to-end editor smoke test where test automation permits.

Acceptance: integration updates are reversible and do not erase unrelated user settings.

## 13. Performance tuning and benchmarks

Optimise against measurements on the actual hardware. Use bounded, reproducible tests and retain provenance.

- [ ] Benchmark supported HIP/ROCm versus Vulkan where both are valid.
- [ ] Compare CPU thread settings, including hybrid CPU considerations.
- [ ] Compare GPU offload settings with desktop headroom.
- [ ] Compare tested context sizes and batch settings.
- [ ] Evaluate Flash Attention and cache precision only when supported by the build/model.
- [ ] Evaluate speculative decoding only for compatible target/draft combinations.
- [ ] Include draft-model memory and latency overhead.
- [ ] Test single-device execution before multi-device alternatives.
- [ ] Separate cold loading, warm loading, prompt processing and generation.
- [ ] Measure time to first token, tokens per second and peak memory.
- [ ] Record system load, power mode and relevant thermal conditions when available.
- [ ] Use repeated runs and report variability, not a single favourable result.
- [ ] Label missing telemetry rather than inventing measurements.
- [ ] Use synthetic test prompts without user/private data.
- [ ] Include a small coding edit-and-test task and tool-call correctness checks.
- [ ] Keep speed metrics separate from quality and correctness metrics.
- [ ] Support cancelling tuning without losing the previous working profile.
- [ ] Key profiles by hardware, driver, runtime, model revision and settings.
- [ ] Invalidate or flag stale profiles after meaningful changes.
- [ ] Show before/after results and permit rollback.

Acceptance: the application never labels a setting optimised without a recorded validation basis.

## 14. Integrated GPU, APU and NPU experiments

Treat this as a gated later phase, not a prerequisite for the first usable release.

### Prefer task distribution over assumed device pooling

Potential experiments: Radeon for main chat/coding, iGPU for small autocomplete, CPU/iGPU for embeddings, supported NPU for a validated separate workload. These are hypotheses to test, not guaranteed capabilities.

- [ ] Verify exact backend/device support before exposing an option.
- [ ] Investigate Intel iGPU paths independently from AMD GPU paths.
- [ ] Do not assume one backend combines every vendor/device.
- [ ] Test ordinary APUs separately from high-memory unified-memory systems.
- [ ] Measure memory contention and desktop responsiveness.
- [ ] Measure end-to-end latency, not only per-device throughput.
- [ ] Include data-transfer and model-loading costs.
- [ ] Test concurrent workload contention.
- [ ] Enable an experimental profile only when it beats a documented baseline for its purpose.
- [ ] Explain whether the benefit is latency, concurrency, capacity or power usage.
- [ ] Provide immediate return to the single-device baseline.
- [ ] Do not count shared RAM twice.
- [ ] Never present multiple devices as a single combined VRAM number unless the exact execution model justifies it.

Acceptance: unsupported or slower combinations remain disabled, with a clear explanation.

## 15. Security, privacy and local operation

- [ ] Write a threat model covering renderer IPC, local API, downloads, models, archives and integrations.
- [ ] Restrict network exposure to loopback by default.
- [ ] Add local API authentication where supported by the architecture.
- [ ] Restrict browser origins and protect management endpoints.
- [ ] Keep inference and privileged management operations separate.
- [ ] Protect credentials using supported OS secure storage.
- [ ] Redact secrets, prompts and sensitive paths from diagnostic exports.
- [ ] Exclude prompt contents from logs by default.
- [ ] Require explicit opt-in for telemetry, remote endpoints and cloud services.
- [ ] Provide offline mode with clear metadata freshness status.
- [ ] Do not silently fall back to a cloud model after local failure.
- [ ] Verify executable provenance and hashes.
- [ ] Treat model files and native runtimes as untrusted input requiring validation.
- [ ] Keep runtime privileges minimal.
- [ ] Prevent command, path and configuration injection.
- [ ] Review desktop CSP, navigation restrictions and external-link handling.
- [ ] Keep updater trust separate from model catalogue trust.
- [ ] Do not expose arbitrary local files through the built-in chat panel.
- [ ] Make optional tool/MCP integrations explicit and permission-scoped.
- [ ] Document what leaves the device during downloads and update checks.

Acceptance: default installation is local-first, does not grant unnecessary privileges and does not silently transmit user prompts.

## 16. Migration, updates, rollback and uninstall

- [ ] Detect existing runtime/model/configuration locations.
- [ ] Import settings without deleting the original installation.
- [ ] Reuse verified model files rather than downloading duplicates.
- [ ] Back up configuration before migration.
- [ ] Version application state and provide migration tests.
- [ ] Make migrations restart-safe and idempotent.
- [ ] Retain a documented recovery launcher where useful.
- [ ] Separate application, runtime, catalogue and model updates.
- [ ] Show update impact and required downloads.
- [ ] Keep last known-good versions where storage permits.
- [ ] Avoid updating an engine while it serves active requests.
- [ ] Provide rollback after failed health checks.
- [ ] Make uninstall preserve models by default unless explicitly selected otherwise.
- [ ] Explain retained data and provide a separate cleanup action.
- [ ] Never delete files outside recorded application-owned locations.

Acceptance: upgrade failure does not strand the user without their previous working setup.

## 17. Testing and CI

### Automated tests

- [ ] Unit tests for catalogue schemas, recommendations, memory estimates and state machines.
- [ ] Unit tests for argument construction and input validation.
- [ ] Fixtures for hardware detection, clearly labelled simulated.
- [ ] Integration tests for download interruption, checksum mismatch and archive safety.
- [ ] Integration tests for process ownership, ports and crash recovery.
- [ ] Configuration tests for JSON, JSONC, YAML and concurrent edits.
- [ ] Tests for comments and unrelated settings preservation.
- [ ] Migration and rollback tests.
- [ ] Router tests for aliases, streaming, cancellation and errors.
- [ ] UI tests for onboarding, empty/error states and destructive actions.
- [ ] Accessibility and visual regression checks.
- [ ] Security regression tests for injection and path traversal.
- [ ] Offline operation tests.

### Hardware validation matrix

Include Intel CPU plus AMD dGPU, AMD CPU plus AMD dGPU, supported APU, Intel iGPU alongside Radeon, unsupported GPU/CPU fallback and multi-GPU configurations where claimed. Record exact devices, drivers, engine builds and results. Hardware not physically tested must remain labelled untested.

### Failure matrix

- [ ] Low disk space and low available RAM/VRAM.
- [ ] Network loss and unavailable download hosts.
- [ ] Corrupted/changed model files.
- [ ] Unsupported runtime flags.
- [ ] Port occupied by an unrelated process.
- [ ] User cancels during installation or model start.
- [ ] Application closes during a configuration transaction.
- [ ] Driver reset, sleep/resume and runtime crash.
- [ ] Existing custom editor settings.
- [ ] Paths with spaces and Unicode.
- [ ] Remote editor extension hosts.
- [ ] Catalogue unavailable or invalid.

### CI

- [ ] Formatting, linting, type checking and unit tests.
- [ ] Build validation for supported targets.
- [ ] Dependency/licence and secret checks.
- [ ] Catalogue schema validation.
- [ ] Packaging smoke tests where feasible.
- [ ] Separate hardware tests from ordinary hosted CI.
- [ ] Document which checks are required for release.

Acceptance: passing simulated tests is never described as proof of real GPU compatibility.

## 18. Packaging and documentation

- [ ] Produce a repeatable installer/build process.
- [ ] Verify clean installation and upgrade paths on supported Windows versions.
- [ ] Document signing requirements; do not claim signing without a real certificate/process.
- [ ] Include licence notices and required attribution.
- [ ] Provide a beginner quick-start with actual screenshots.
- [ ] Provide hardware support and experimental-feature tables.
- [ ] Provide troubleshooting, offline-use and rollback guides.
- [ ] Document configuration ownership and editor backups.
- [ ] Document runtime/model storage and disk cleanup.
- [ ] Document development setup, tests and architecture decisions.
- [ ] Include release notes with known limitations.
- [ ] Keep recovery scripts documented and clearly secondary.

Acceptance: a release artefact can be reproduced and its support claims match the validation record.

## 19. Phased implementation plan and release gates

### Phase A: establish truth and preserve behaviour

Deliver baseline audit, evidence record, regression tests and architecture decisions. Fix confirmed hardcoded integration inconsistencies and unsafe behaviours before expanding scope.

Gate: baseline tests pass; claims are verified or explicitly unresolved; existing user data is protected.

### Phase B: usable desktop vertical slice

Implement real hardware inventory, one validated runtime, local model import/download, start/stop, a functional test panel and persistent state. Include failure and recovery states.

Gate: a user can install, run and stop one supported model through the GUI without a terminal.

### Phase C: safe editor connections

Implement one fully tested integration first, then additional adapters. Add previews, backups, managed entries, stable aliases and rollback.

Gate: connect, change model and rollback work without losing unrelated settings.

### Phase D: catalogue and recommendations

Implement verified model metadata, honest memory estimates, purpose-based recommendations and offline catalogue fallback.

Gate: recommendations are traceable and resource warnings match measured behaviour on tested hardware.

### Phase E: performance and additional engines

Implement reproducible benchmarks and profiles. Evaluate Lemonade and routing options. Add Strata only after release-specific validation.

Gate: tuning benefits are measured; experimental engines cannot replace the stable path silently.

### Phase F: heterogeneous experiments

Test iGPU/APU/NPU task distribution and advanced CPU/GPU execution where supported.

Gate: only validated beneficial configurations are offered, with explicit experimental status.

### Phase G: release hardening

Complete accessibility, packaging, clean-install tests, documentation, privacy/security review and rollback verification.

Gate: all release-critical checks pass or the release is explicitly limited to a documented preview scope.

## 20. Agent working protocol

### Before each implementation slice

- [ ] Read the relevant source and tests.
- [ ] State the concrete behaviour being implemented.
- [ ] Identify dependencies, risks and acceptance tests.
- [ ] Check that upstream facts needed for this slice are verified.
- [ ] Choose the smallest complete vertical slice.

### During implementation

- [ ] Implement production behaviour and tests together.
- [ ] Keep UI and core contracts typed and version-aware.
- [ ] Avoid unrelated refactors and gratuitous dependency additions.
- [ ] Keep logs useful and private.
- [ ] Update documentation when behaviour changes.
- [ ] Do not mark a checkbox complete for a stub or unconnected UI control.

### After each slice

- [ ] Run formatting, linting, relevant tests and builds.
- [ ] Inspect real UI screenshots where the interface changed.
- [ ] Record commands, results and remaining limitations.
- [ ] Update the preservation matrix and implementation status.
- [ ] Summarise changed files and the next independent slice.
- [ ] Leave the repository buildable or document an exact blocker.

### Required progress files

- `docs/engineering/implementation-status.md`
- `docs/engineering/baseline-audit.md`
- `docs/research/upstream-evidence.md`
- `docs/testing/validation-matrix.md`
- `docs/testing/benchmark-results.md`
- `docs/architecture/` decision records

Each status entry should include task ID, phase, state, changed files, tests, evidence and blockers. Use explicit states: not started, in progress, implemented, validated, blocked, deferred. Only mark a master checkbox complete when its stated acceptance condition is met.

## 21. Final definition of done

- [ ] Existing useful functionality is preserved or replaced with tested equivalents.
- [ ] The desktop application performs real installation, management and inference operations.
- [ ] AMD GPU owners with Intel or AMD CPUs receive accurate support information.
- [ ] Models and runtimes are selected from verified, versioned metadata.
- [ ] Memory and storage requirements are honest and distinguish estimates from measurements.
- [ ] Downloads are resumable, verified and recoverable.
- [ ] Runtime start/stop, readiness, failure and rollback are robust.
- [ ] Editor configuration is safe, reversible and capability-aware.
- [ ] Stable aliases actually resolve through a working endpoint/router.
- [ ] Performance profiles are backed by recorded tests.
- [ ] Integrated GPU/NPU options are evidence-gated, not marketing promises.
- [ ] Offline operation works after installation.
- [ ] No silent cloud fallback, unnecessary privilege or default prompt telemetry exists.
- [ ] Tests, packaging and documentation support the stated release scope.
- [ ] Unsupported features are visibly disabled or labelled experimental.
- [ ] Final report lists implemented features, test evidence, untested hardware and unresolved blockers.

## 22. Research starting points

These are starting points, not endorsements or assertions of current support. Verify exact versions and official documentation before use.

- [Target repository](https://github.com/theantipopau/llamacpp-amd-command-center)
- [Strata repository](https://github.com/Niko1221/Strata)
- [llama.cpp repository](https://github.com/ggml-org/llama.cpp)
- [AMD ROCm documentation](https://rocm.docs.amd.com/)
- [Lemonade repository](https://github.com/lemonade-sdk/lemonade)
- [llama-swap repository](https://github.com/mostlygeek/llama-swap)
- [KTransformers repository](https://github.com/kvcache-ai/ktransformers)
- [Continue documentation](https://docs.continue.dev/)
- [VS Code documentation](https://code.visualstudio.com/docs)
- [Tauri documentation](https://v2.tauri.app/)

## 23. Immediate instruction to the agent

Begin with Phase A in the actual checkout. Inspect the repository and verify the upstream evidence. Produce the audit, preservation matrix and architecture decisions, then implement the first safe, complete vertical slice. Continue through the checklist in dependency order, preserving a working build and reporting concrete test evidence. Do not deliver only another roadmap, do not invent hardware validation, and do not prioritise experimental acceleration over a reliable beginner experience.
