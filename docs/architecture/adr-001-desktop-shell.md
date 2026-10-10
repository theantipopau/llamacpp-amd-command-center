# ADR-001: Desktop shell — keep PowerShell 5.1 + WPF near-term; Tauri deferred

- **Status:** Accepted, 2026-10-08 (Phase A)
- **Checklist:** §3 (desktop stack decision), §19 Phase B

## Context

The checklist's preferred proposal is a Tauri desktop shell with a React/TypeScript UI
and a Rust orchestration core, and allows an alternative only with a written decision.
The repository today is a Windows PowerShell 5.1 script (3,850 lines, 118 functions) plus
a batch menu and an existing WPF window (`Get-GuiXaml`/`Show-CommandCenterWindow`) that
already provides the beginner front door: hero start/stop, memory bar, use-case picker,
gaming switches, diagnostics.

## Decision

Keep **PowerShell 5.1 + WPF as the near-term desktop shell**. Do not port to Tauri in
Phases A–C. Instead, evolve the script so a future shell is a thin skin:

1. **Typed command surface.** Every capability exposed to the UI goes through a single
   pure function returning a versioned object (`Get-ApplicationState` with
   `schema_version`, first shipped as `-Action State`). The window, the batch menu and
   any future shell consume that contract instead of parsing each other's output.
2. **Display logic stays pure.** `Get-GuiState`/`Set-GuiState` remain UI-agnostic
   (already tested), so WPF handlers only marshal and call services.
3. **No domain logic in XAML handlers.** Existing rule, now a stated contract: handlers
   call functions; slow work runs on a worker runspace.

## Why not Tauri now

| Factor | Assessment |
|---|---|
| Working product | The WPF window already passes the Phase B experience goal for the current feature set; a rewrite blocks installation/hardware/model/editor work behind a toolchain migration. |
| Dependency footprint | Tauri needs Rust, Node and a frontend build on every contributor/CI machine; today CI is 5 small PowerShell/cmd steps. |
| Distribution | A Tauri build changes packaging, code signing and the release workflow (checklist §18) — a Phase G concern, not Phase A. |
| Risk to user data | Rewriting integration code (VS Code/Continue/llama-vscode writers) in TypeScript risks the backup/merge/refuse contracts that are now regression-tested in PowerShell. |
| Test base | 225 offline checks exercise the PowerShell functions directly; a port would invalidate them before new coverage exists. |

## Consequences

- Phase B delivers the GUI gate ("install, run, stop one model without a terminal")
  inside the existing window, on the typed state contract.
- A later Tauri shell (revisit at Phase E/G, or when a feature genuinely needs a web
  UI) can speak to the same command/state functions via a narrow local IPC surface,
  because domain logic is forbidden from depending on WPF.
- Trade-off accepted: the near-term UI cannot use web-tech polish; mitigated by keeping
  display state pure and testable.
- The checklist §3 alternative-structure layout (`apps/desktop`, `crates/*`) is **not
  imposed**; repository layout stays PowerShell-first until the stack decision changes.

## Revisit triggers

- A Phase B/C feature cannot be built safely inside WPF (e.g. rich streaming preview).
- The Tauri port can be staged behind the typed command surface with the PowerShell
  harness still passing (domain functions unchanged, only the shell replaced).
