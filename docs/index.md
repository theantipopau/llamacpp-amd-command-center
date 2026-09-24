# llama.cpp AMD Windows Command Center

<p align="center">
  <img src="logo.png" alt="llama.cpp AMD Windows Command Center logo" width="180">
</p>

**A hardware-aware Windows command center for llama.cpp, local models, and VS Code.**

Created by **Matt Hurley - [matthurley.dev](https://matthurley.dev)**

> Independent community project. Not affiliated with ggml-org, AMD, Microsoft, Anthropic, or the maintainers of the integrated editor extensions.

## Start here

**New to local LLMs?** You do not need to know ROCm, Vulkan, GGUF files, or API servers first. The command center explains the choices and asks before downloading.


1. Install or update the AMD Adrenalin driver.
2. Download and extract the [release ZIP](https://github.com/theantipopau/llamacpp-amd-command-center/releases/latest), or clone this repository.
3. Double-click `Start-LlamaCpp.cmd`.
4. Select **Start first-time setup / hardware scan**.
5. Review the detected CPU, Radeon GPU, VRAM, RAM, backend, and model recommendation.
6. Install the selected backend and model.
7. Return to the batch menu and start the generated server launcher.
8. Test the local API, then connect VS Code.

The managed installation lives under `%LOCALAPPDATA%\Programs\llama.cpp`; model files are kept outside the source checkout.

## See the actual setup

These screenshots show the intended first-time experience: the hardware-aware dashboard, the verified model download, and the local server launch screen.

| First-time dashboard | Verified installation | Local server launch |
|---|---|---|
| ![First-time user dashboard](firsttimeuser.png) | ![Installation screen](installing.png) | ![Local server launch screen](launchscreen.png) |

## One menu, four layers

| Layer | Purpose |
|---|---|
| **L — Local engine** | `llama-server.exe`, Web UI, localhost API |
| **M — Model** | GGUF discovery, hardware fit advice, revision resolution, SHA-256 verification |
| **V — VS Code** | Copilot Chat custom endpoints, official llama-vscode, Continue, and Cline instructions |
| **A — API** | OpenAI-compatible local endpoint for compatible tools |

## Console appearance

The batch front end sets a 140-column console and uses high-contrast CMD colors. For the intended premium appearance, use Windows Terminal with Cascadia Mono or Consolas. CMD cannot reliably change the active font from inside a batch file, so the interface uses safe labels and separators instead of depending on emoji glyphs.

## Hardware-aware backend choice

### AMD ROCm

Automatic mode selects the validated AMD ROCm Windows package for supported Radeon dGPUs, including the RX 9070 XT when supported by the current AMD matrix.

### Vulkan

Vulkan is the fallback for Ryzen iGPUs, older Radeon GPUs, and hardware outside the ROCm package matrix. It uses the installed AMD Vulkan driver.

The batch front door makes the choice visible. The PowerShell command center performs the detailed hardware scan and lets the user override the backend when needed.

## Tested local target

The command center has been validated for a system with:

- AMD Ryzen 7 9800X3D, 8 cores / 16 threads
- AMD Radeon RX 9070 XT with approximately 15.8 GiB dedicated VRAM
- 31.2 GiB system RAM
- Radeon integrated GPU / UMA reporting
- Windows DXGI adapter inventory

The command center recommends the strongest tool-capable model that fits entirely in VRAM. For that target it is Qwen3.5 9B Q4_K_M with its vision projector, exposed as `qwen3.5:9b`, at 32768 tokens of context. It runs fully on the GPU at roughly 70 tokens per second and handles 20k-token Agent prompts with tool calls.

Qwen3.8 27B Q4_K_M (`qwen3.8:latest`) is offered as a quality option. It does not fit in 16 GiB of VRAM, so part of it runs from system RAM at roughly 4–7 tokens per second. The model source is [Unsloth Qwen3.5-9B-GGUF](https://huggingface.co/unsloth/Qwen3.5-9B-GGUF), and the installer verifies the current Hugging Face Git LFS SHA-256 digest.

## Local endpoints

```text
Web UI: http://127.0.0.1:8080/
API:    http://127.0.0.1:8080/v1
Models: http://127.0.0.1:8080/v1/models
```

The server binds to `127.0.0.1` only.

## Using Copilot and a local model together

GitHub Copilot and llama.cpp can be used side by side. This project does not remove or reconfigure Copilot. Keep using Copilot Chat as usual, and use llama-vscode, Continue, or Cline when you want a request handled by your local model.

### Local model in Copilot Chat

Current VS Code supports local models through **Chat: Manage Language Models → Add Models → Custom Endpoint**:

1. Start the server with option **[2]** and wait for loading to finish.
2. Choose **Custom Endpoint** and API type **Chat Completions**.
3. Use `http://127.0.0.1:8080/v1/chat/completions` as the endpoint.
4. Use the model ID from `/v1/models`, such as `qwen3.5:9b`.
5. Use any non-empty placeholder API key, enable **Tools** and **Vision** for the Qwen models, save the generated `chatLanguageModels.json`, and reload VS Code.

The API key is only a client placeholder; the llama.cpp server is local and requires no cloud key. Conversation compaction and other VS Code utility requests can be slower or less compatible than normal Chat requests. If the model is hidden in Agent mode, verify `toolCalling: true` and keep the server running. If Agent mode fails with **No lowest priority node found**, the context is too small for Copilot's prompt: re-activate the model with `-ContextSize 32768` (or larger), restart the server, and run option **[5]** again.

## One-click VS Code setup

The main `Start-LlamaCpp.cmd` menu option **[5] Configure VS Code** calls the PowerShell `VSCodeChat` action. It reads the active model, updates or creates only the `llama.cpp local` provider (replacing the older `llama.cpp ROCm` entry) in `%APPDATA%\Code\User\chatLanguageModels.json`, preserves existing Copilot and unrelated providers, and creates a `chatLanguageModels.json.command-center.bak` backup when possible.

The action configures the current model alias, localhost Chat Completions endpoint, context budget, tool-calling capability, and vision capability. It does not delete models or modify the llama.cpp server. If the existing VS Code JSON is malformed, the command refuses to overwrite it so unknown settings are not lost. Run **Developer: Reload Window** after it finishes.

For a manual setup or a different VS Code installation, use the Custom Endpoint values documented above.

## Editor integrations

### Official llama-vscode

Install from VS Code using extension ID `ggml-org.llama-vscode`. It supports local completion, chat, agents, model/environment management, and Hugging Face model browsing.

### Continue

```yaml
name: Local llama.cpp
version: 0.0.1
schema: v1
models:
  - name: Qwen3.5 9B
    provider: llama.cpp
    model: qwen3.5:9b
    apiBase: http://127.0.0.1:8080
```

The batch menu can create `Continue-llamacpp-config.yaml` without overwriting an existing file. Choose **[9]** to view the latest run log at any time.

### Cline / OpenAI-compatible clients

```text
Base URL: http://127.0.0.1:8080/v1
Model:    qwen3.5:9b
API key:  any non-empty placeholder
```

## Claude Code note

Claude Code is a separate CLI client. Its documented gateway setup uses `ANTHROPIC_BASE_URL` and an Anthropic-compatible gateway. The local llama.cpp OpenAI-compatible endpoint is not promised to be a direct Claude Code backend. A gateway or protocol adapter may be needed and must be tested against the Claude Code version in use.

## Beginner troubleshooting

- **API test fails:** start the server with option `[2]`, wait for model loading, then test with `[6]`.
- **`code` is not recognized:** VS Code may still be installed. Open VS Code > Extensions, search `llama-vscode`, and install it there; or add VS Code to PATH and reopen the terminal.
- **The model is slow:** choose the model browser or hardware/model advisor and try a smaller model or lower context setting.
- **The GPU is missing:** update AMD Adrenalin, reboot, and rerun diagnostics.
- **Starting over:** use the uninstall option in the command center; it asks for confirmation and does not remove VS Code or Copilot.

## Release download

Download the runnable ZIP from the [latest GitHub release](https://github.com/theantipopau/llamacpp-amd-command-center/releases/latest), extract it, and double-click `Start-LlamaCpp.cmd`. Keep `Install-LlamaCpp-AMD.ps1` next to the BAT file. The release ZIP contains the two runnable scripts, README, license, and logo; models and the ROCm runtime remain separate downloads.

## Run logs and diagnostics

Each command-center run writes a human-readable transcript, JSONL events, and a JSON summary under:

```text
%LOCALAPPDATA%\Programs\llama.cpp\logs
```

Choose **[9]** to view the latest run log. The log bundle is useful for diagnosing driver, download, model-fit, and server-startup issues. Common API-key, token, authorization, and bearer patterns are redacted; review logs before sharing them.

## Safety model

- Nothing is downloaded until the user chooses an installation or model action.
- Official HTTPS sources are used where available.
- Model downloads verify published Git LFS SHA-256 values.
- The AMD ROCm package has no publisher-side SHA-256 sidecar; the local downloaded hash is recorded instead.
- The local server is not exposed to the network.
- The Continue template is created separately and is not overwritten.
- The menu documents each action before running it.

## Project layout

```text
Start-LlamaCpp.cmd             Interactive colorful front end
Install-LlamaCpp-AMD.ps1       PowerShell command center
logo.png                       Project logo
docs/                          Documentation site
.github/workflows/pages.yml    GitHub Pages deployment
```

## Author

**Created by Matt Hurley - [matthurley.dev](https://matthurley.dev)**

MIT licensed. See the repository `LICENSE` file.
