# llama.cpp AMD Windows Command Center

<p align="center">
  <img src="logo.png" alt="llama.cpp AMD Windows Command Center logo" width="180">
</p>

**A colorful, hardware-aware Windows front end for installing, configuring, running, and connecting [llama.cpp](https://github.com/ggml-org/llama.cpp) to VS Code.**

**Created by Matt Hurley - [matthurley.dev](https://matthurley.dev)**

> **Community project:** This repository is an independent convenience and orchestration layer. It is not affiliated with, endorsed by, or published by ggml-org, AMD, Microsoft, VS Code, Continue, Cline, or Anthropic.

## What this is

`Start-LlamaCpp.cmd` is the user-facing command center. It provides a clear, colorful Windows menu around the PowerShell implementation in `Install-LlamaCpp-AMD.ps1`.

The project is designed for a user who wants one guided path from:

**AMD hardware detection → backend selection → verified GGUF download → local llama-server → VS Code/Continue/Cline connection**

### The four layers

- **[L] Local LLM engine** — installs and launches `llama-server.exe` and its local Web UI.
- **[M] Model layer** — finds hardware-appropriate GGUF models, resolves current metadata, and verifies published SHA-256 digests.
- **[V] VS Code layer** — documents the official `llama-vscode` extension, Continue, and Cline/OpenAI-compatible settings.
- **[A] API layer** — exposes a localhost-only OpenAI-compatible endpoint for local tools.

## If you are new to local LLMs

You do not need to understand ROCm, Vulkan, GGUF files, context sizes, or API servers before starting. The command center explains the choices and asks before it downloads a backend or model.

**The simplest path is:**

1. Double-click `Start-LlamaCpp.cmd`.
2. Choose **[1] Start first-time setup / hardware scan**. The first model download can take a while, so keep the window open until it finishes.
3. Accept the recommended model and backend when prompted.
4. Return to the menu and choose **[2]** to start the local server.
5. Choose **[6]** to confirm the local API is working.
6. Choose **[3]** for the official VS Code extension, or **[4]** for a Continue template.

If you are unsure which option to choose, start with **[1]**. If you only want to read first, choose **[7] Show the complete walkthrough**. Choose **[9]** any time to view the latest run log.

## Quick start

1. Install a current AMD Adrenalin driver.
2. Download or clone this repository.
3. Double-click **`Start-LlamaCpp.cmd`**.
4. Choose **[1] Start first-time setup / hardware scan**.
5. Let the hardware scan finish, then choose the recommended backend and model.
6. Choose **[2]** in the batch menu to start the generated local server launcher.
7. Choose **[6]** to test `http://127.0.0.1:8080/v1/models`.
8. Choose **[3]** for the official VS Code extension, or **[4]** to create a safe Continue template.

The installer stores its managed files under:

```text
%LOCALAPPDATA%\Programs\llama.cpp
```

Models and runtime files are kept separate from this source repository. The batch front end does not silently install or download anything until the corresponding action is selected.

## Console appearance

The batch front end sets a wide 140-column console and uses high-contrast CMD colors. CMD cannot reliably change the active font from inside a `.cmd` file; for the intended appearance, use **Windows Terminal** with **Cascadia Mono** or **Consolas**. The menu uses safe text labels and geometric separators so it remains readable even when emoji glyphs are unavailable in the current console font.

## Supported Windows path

| Component | Behavior |
|---|---|
| Operating system | Windows 10/11 x64 |
| PowerShell | Windows PowerShell 5.1 or newer |
| AMD dGPU | Validated AMD ROCm package when supported; otherwise Vulkan |
| Ryzen iGPU / older Radeon | Vulkan fallback using the installed AMD Vulkan driver |
| CPU | llama.cpp CPU fallback when appropriate |
| Server binding | `127.0.0.1` only; not exposed to the LAN |

The command center uses DXGI inventory for GPU VRAM detection. This avoids the common Windows WMI `AdapterRAM` reporting cap that can incorrectly show a modern Radeon card as having only 4 GiB.

## Backend selection

### ROCm

The AMD Windows package is used for supported Radeon dGPUs, including the RX 9070 XT when it appears in AMD's current compatibility matrix. This is the validated AMD-specific path for supported hardware.

The AMD package currently distributed by the project is downloaded over official AMD HTTPS. AMD does not publish a SHA-256 sidecar for that ZIP, so the installer records and reports the local SHA-256 after download rather than claiming a publisher checksum that is not available.

### Vulkan

Vulkan is the portable fallback for Ryzen integrated graphics, older Radeon cards, and GPUs not covered by the AMD ROCm Windows package. It uses the normal AMD Vulkan driver path.

Users can explicitly select the backend from the PowerShell command center. Automatic mode is recommended for most users.

## Model recommendations

Model availability and filenames can change, so the installer resolves the current Hugging Face revision and Git LFS SHA-256 values at download time.

For the tested Ryzen 7 9800X3D + Radeon RX 9070 XT system, the default recommendation is:

| Item | Value |
|---|---|
| Model family | Qwen3.8 27B |
| Quantization | Q4_K_M |
| Weights | `Qwen3.8-27B-Q4_K_M.gguf` |
| Vision projector | `mmproj-Qwen3.8-27B-Q8_0.gguf` |
| API model ID | `qwen3.8:latest` |
| Approximate download | 18.25 GiB including projector |

A 16 GiB Radeon card can run this model with a sensible memory budget, but context size, projector use, and runtime offload settings affect actual VRAM use. Always review the command center's fit estimate before downloading.

## If you already use GitHub Copilot

You can keep using GitHub Copilot and run a local llama.cpp model at the same time. This project does not remove, replace, reconfigure, or sign you out of Copilot.

Use the local integrations when you want the request to stay on your computer:

- **llama-vscode** for the official local llama.cpp experience.
- **Continue** for a configurable local provider.
- **Cline** or another client that supports an OpenAI-compatible base URL.

Copilot Chat and a local model are separate clients. If you want to keep using Copilot Chat, leave it configured as-is and use the local extension or client when you want the local model.

## VS Code and local API

The server exposes:

```text
Web UI:  http://127.0.0.1:8080/
API:     http://127.0.0.1:8080/v1
Models:  http://127.0.0.1:8080/v1/models
```

### Official llama-vscode

The official extension is:

```text
ggml-org.llama-vscode
```

It provides local completion, chat, agent features, environment/model management, and direct Hugging Face model browsing. The official extension is particularly suited to FIM-capable coding models for inline completion. The general Qwen3.8 model remains useful for chat, editing, tools, and agent workflows.

### Continue

The generated template uses the officially documented shape:

```yaml
name: Local llama.cpp
version: 0.0.1
schema: v1
models:
  - name: Qwen3.8 27B
    provider: llama.cpp
    model: qwen3.8:latest
    apiBase: http://127.0.0.1:8080
```

### Cline and other OpenAI-compatible clients

Use:

```text
Base URL: http://127.0.0.1:8080/v1
Model:    qwen3.8:latest
API key:  any non-empty placeholder
```

The API key is only a placeholder for clients that require one. The server is local and does not need a cloud API key.

## Claude Code and other CLI agents

Claude Code is not the same type of client as the VS Code integrations above. Its documented gateway model uses `ANTHROPIC_BASE_URL` and an Anthropic-compatible gateway. The llama.cpp OpenAI-compatible endpoint should not be assumed to be a direct drop-in Claude Code backend.

A separate gateway or protocol translator may be required, and compatibility must be tested against the specific Claude Code release. This project does not silently install a gateway or claim unsupported direct compatibility.

## If something goes wrong

### The API test says the server is not reachable

Start the server first with batch option **[2]**, wait for the model to finish loading, then choose **[6]**. The server may take time to load a large model into VRAM/RAM.

### VS Code says `code` is not recognized

This can happen even when VS Code is already installed. The easiest route is to open VS Code, select **Extensions**, search for `llama-vscode`, and install the official extension there. Alternatively, add VS Code's `bin` folder to PATH, close and reopen the terminal, and run the batch file again.

### The local model is slow or does not fit

Return to the command center and choose the model browser or hardware/model advisor. A smaller model, fewer context tokens, or a different quantization can reduce memory use and improve speed.

### The GPU is not detected

Update the AMD Adrenalin driver, reboot Windows, and run the command center again. The diagnostics option can show detected adapters and the selected execution mode.

### You want to undo the setup

The uninstall option removes the managed llama.cpp installation and downloaded models. It does not remove VS Code, Copilot, or the source repository. It asks for confirmation before deleting anything.

## Run logs and diagnostics

Every command-center run creates a persistent log bundle under:

```text
%LOCALAPPDATA%\Programs\llama.cpp\logs
```

The bundle contains:

- `run-*.log` — human-readable console transcript;
- `run-*.jsonl` — structured JSON events;
- `run-*-summary.json` — final status, action, backend, model, and timing;
- `latest.log` and `latest-summary.json` — easy-to-find copies of the latest completed run.

Choose **[9] View the latest run log** from the batch menu, or run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-LlamaCpp-AMD.ps1 -Action ViewLog
```

Logs redact common API-key, token, authorization, and bearer patterns. They do not intentionally record secrets. When reporting a problem, attach the human-readable log and the JSON summary after reviewing them for anything personal.

## Safety and privacy

- Downloads use official HTTPS sources where available.
- Published Git LFS SHA-256 values are verified for model files.
- The AMD ROCm ZIP has no publisher-side SHA-256 sidecar; its downloaded hash is recorded locally.
- The server binds to localhost only.
- No cloud API key is required for the local server.
- The batch menu labels installation, extension installation, and server launch before performing them.
- The project does not overwrite an existing Continue template.

## Files

```text
Start-LlamaCpp.cmd             Colorful Windows menu and walkthrough
Install-LlamaCpp-AMD.ps1       Hardware detection, installer, advisor, launcher, diagnostics
logo.png                       Project logo used by the README and documentation site
docs/                          GitHub Pages documentation
.github/workflows/pages.yml   GitHub Pages deployment workflow
```

## Development and validation

The PowerShell implementation is written for Windows PowerShell 5.1 compatibility and is UTF-8 BOM encoded so its Unicode dashboard renders correctly in older Windows PowerShell hosts.

Before publishing a change, validate at minimum:

```powershell
powershell.exe -NoLogo -NoProfile -Command "[System.Management.Automation.Language.Parser]::ParseFile('.\Install-LlamaCpp-AMD.ps1',[ref]$null,[ref]$null) | Out-Null; Write-Output 'AST parse OK'"
```

The batch front end can be smoke-tested with redirected menu input. Normal interactive use should be tested by double-clicking `Start-LlamaCpp.cmd`.

## Roadmap

- Add a signed release package and checksum manifest.
- Add optional Claude Code gateway guidance with an explicitly tested adapter.
- Add hardware/model benchmark presets.
- Add automated Windows CI for parser, menu, and template tests.
- Add screenshots and short demo recordings to the documentation site.

## License

MIT License. See [LICENSE](LICENSE).

## Author

**Created by Matt Hurley - [matthurley.dev](https://matthurley.dev)**

If you fork or extend this project, preserve the credit or clearly attribute the original work.
