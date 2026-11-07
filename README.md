# llama.cpp AMD Command Center

<p align="center">
  <img src="logo.png" alt="llama.cpp AMD Command Center logo" width="160">
</p>

<p align="center">
  <strong>Run AI models privately on your AMD Radeon PC and use them in VS Code: set up from one friendly Windows menu.</strong><br>
  <a href="https://github.com/theantipopau/llamacpp-amd-command-center/releases/latest">Download</a> ·
  <a href="https://theantipopau.github.io/llamacpp-amd-command-center/">Website</a> ·
  <a href="#troubleshooting">Troubleshooting</a>
</p>

<p align="center">
  <a href="https://github.com/theantipopau/llamacpp-amd-command-center/actions/workflows/ci.yml"><img alt="Windows checks" src="https://github.com/theantipopau/llamacpp-amd-command-center/actions/workflows/ci.yml/badge.svg"></a>
  <a href="https://github.com/theantipopau/llamacpp-amd-command-center/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/theantipopau/llamacpp-amd-command-center"></a>
  <a href="LICENSE"><img alt="MIT license" src="https://img.shields.io/badge/license-MIT-blue"></a>
</p>

**Created by Matt Hurley - [matthurley.dev](https://matthurley.dev)**

> **Community project.** This is an independent helper around [llama.cpp](https://github.com/ggml-org/llama.cpp). It is not affiliated with, endorsed by, or published by ggml-org, AMD, Microsoft, GitHub, Continue, Cline, or Anthropic.

![The command center window: Your AI is on, an Open chat button, graphics memory use, and gaming switches](docs/window.png)

<sub>The window you get when you double-click `Start-LlamaCpp.cmd`. The text menu below is still there under **More options**, and runs by itself if the window cannot open.</sub>

## New in v0.2.0

- **A desktop app with a Windows installer.** A window with tabs for Home, Models, Settings and Health, one status badge, and Start, Stop, Open chat and Update buttons that stay in view while you scroll. It installs per user, needs no administrator rights, and bundles the backend it runs.
- **Game pause.** Set a graphics-memory limit in the desktop app's Settings (0 is off, 4 to 40 GiB). When a game takes that much graphics memory, the model unloads, and it loads again on your next message. It never cuts off a chat in progress.
- **Router mode.** The server now runs llama.cpp's router with a generated `server-preset.ini`, which is what makes unloading possible. Idle unload keeps working as before.
- **Asleep, not stopped.** When the model is out of graphics memory but the server is up, the badge says **Asleep** instead of showing a misleading status.

![The desktop app's Home tab: status badge, server actions, your model, and the recommended models](docs/desktop-window.png)

<sub>The desktop app (optional). Models, Settings and Health are one click away in the tab bar; the Settings tab includes the game-pause limit.</sub>

<p align="center">
  <img src="docs/desktop-settings.png" alt="Desktop app Settings tab: idle unload, graphics memory, the game-pause limit, use case and Save settings" width="48%">
  <img src="docs/desktop-models.png" alt="Desktop app Models tab: the model library with fit, download, switch and remove actions" width="48%">
</p>

<p align="center">
  <img src="docs/desktop-health.png" alt="Desktop app Health tab after Run diagnostics: runtime, hardware, model and editor checks" width="60%">
</p>

![The text menu showing the model, a running AI server, and VS Code connected](docs/menu.png)

## What you get

- **A local AI model on your own graphics card.** No subscription, no cloud account, and your code stays on your PC.
- **A guided setup.** It scans your CPU, Radeon GPU, and memory, then picks the model and settings that fit. Nothing downloads until you type `YES`, and every model file is checked against its published SHA-256 fingerprint.
- **GitHub Copilot Chat integration.** One menu option adds the model to Copilot Chat, including **Agent mode**, which reads and edits files. Your Copilot account and cloud models stay exactly as they were.
- **A health check** that tests chat, tool calling, and memory in about 10 seconds and explains any failure in plain English.

## Before you start

You need:

- **Windows 10 or 11** (64-bit).
- **An AMD Radeon graphics card.** A card with 12–16 GB of memory, such as an RX 7700 XT, 7900, 9060 XT or 9070 XT, gives the best experience. Older and smaller Radeon cards and Ryzen processors with built-in Radeon graphics also work, just more slowly.
- **Any modern processor.** AMD Ryzen and Intel CPUs are both fine. Intel CPUs are supported as the main processor; Intel graphics are not used to run models.
- **About 20 GB of free disk space** for llama.cpp and one model.
- **An internet connection** for the one-time downloads. After that, everything runs offline.
- **Optional: VS Code with the GitHub Copilot Chat extension**, if you want the model inside your code editor. You can also skip VS Code and chat in your web browser.

No programming or AI knowledge is needed. The menu explains each step and always asks before downloading anything.

## Words you will see

| Word | What it means |
|---|---|
| **Model** | The AI itself: one large file (about 6 GB) that does the thinking. You can download several and switch between them. |
| **AI server** | A program that loads the model onto your graphics card so apps can talk to it. The classic launchers show it in its own window; close that window and the AI stops. The desktop app runs it hidden and controls it with Start and Stop. |
| **VRAM** | Your graphics card's own memory. A model that fits entirely in VRAM replies quickly. |
| **Context** | How much of the conversation (and your code) the model can keep in mind at once, measured in **tokens**. A token is roughly three-quarters of a word. |
| **Agent mode** | A Copilot mode where the AI can read and edit files in your project, not just answer questions. |
| **Backend (ROCm / Vulkan)** | The engine that runs the model on your graphics card. The setup picks the right one for you. |

## Quick start

Allow about 15 minutes, most of it the one-time 6 GB model download.

**Prefer a normal Windows app?** Download `llamacpp-command-center-setup-vX.Y.Z.exe` from the [latest release](https://github.com/theantipopau/llamacpp-amd-command-center/releases/latest) and run it. It installs per user into `%LOCALAPPDATA%\llama.cpp Command Center`, and needs no administrator rights. Open **llama.cpp Command Center** from the Start menu (the installer adds a shortcut for your user) and follow the same steps the window shows. The installer is not code-signed yet, so Windows SmartScreen may warn; choose **More info → Run anyway** only if you downloaded it from the release page above.

**Fastest path:** update your AMD driver, extract the ZIP, double-click `Start-LlamaCpp.cmd`, then press the big orange **Set up and start** button (in the text menu that is **E**, Easy start). It shows what it will download, asks for one `YES`, installs, starts the AI and opens a chat window. The numbered steps below do the same thing one stage at a time.

1. **Update your AMD graphics driver** (AMD Software: Adrenalin Edition).
2. **Download** `llamacpp-amd-command-center-vX.Y.Z.zip` from the [latest release](https://github.com/theantipopau/llamacpp-amd-command-center/releases/latest). Right-click it, choose **Extract All**, and open the extracted folder. Do not run it from inside the ZIP.
3. **Double-click `Start-LlamaCpp.cmd`.** Windows may show a SmartScreen warning because the file came from the internet. If you downloaded it from the release page above, choose **More info → Run anyway**.
4. Choose **[1] Setup and models**, then **[1] First-time setup** on the next screen, and type `YES` when asked.
5. Back in the main menu, choose **[2] Start AI server**. A second window opens; leave it open. The menu shows **READY** when the model has loaded.
6. Choose **[5] Health check**. Every line should say **PASS**.
7. Choose **[6] Connect VS Code** and type `YES`. Then follow the four steps it prints (reload VS Code and pick the model).

The **NEXT STEP** line at the top of the menu always tells you what to do next.

### Every day after that

1. Double-click `Start-LlamaCpp.cmd` and press **Start AI and open chat**, or double-click the **AI Chat** desktop shortcut if you added it. The AI starts and the chat opens. (**[2] Start AI server** still works; with more than one model it asks which to run, or press Enter to keep the last one.)
2. Use the chat window, or the model in VS Code.
3. When you're done, or before gaming, double-click **AI Off** or choose **[G] Gaming mode** to free your graphics card.

### Gaming mode

A game and the AI model both want your graphics memory (VRAM). Easy start and **[G]** handle that for you:

- **AI Off / Turn the AI off now** stops the server and frees VRAM at once. **AI Chat** (or **E**) brings it back.
- **Game pause** (off by default) unloads the model while other programs hold a set amount of graphics memory, from 4 to 40 GiB (8 is a good start). Set it in the **desktop app's Settings** (or with `-Action Settings`). The model loads again on your next message, or a minute after the other program leaves. A chat in progress is never cut off, and nothing is stopped. It needs a llama.cpp new enough for router mode; the app says so when it is not. The classic window and text menu show idle unload only.
- **Auto-unload when idle** (off by default; Easy start offers it, and you can switch it in **[G]**) adds `--sleep-idle-seconds 900` to the server. After 15 minutes without a message the model leaves VRAM, and it reloads on your next message (a few seconds). It needs a llama.cpp build that has that option; the AMD ROCm 7.2.1 package does.
- **Free-memory check:** before starting, the menu asks Windows how much graphics memory other apps are using. If a game or browser leaves too little room for the model, it names the biggest users and lets you cancel or start anyway (the model then partly runs from system RAM, more slowly). If Windows' counters are unavailable (for example a non-English Windows), the check is skipped.
- **Desktop shortcuts** (optional, only added when you say yes) point at `Chat.cmd` and `Gaming-Mode.cmd` in the install folder, so they keep working if you move or delete the extracted ZIP folder.

![Health check: all five checks pass](docs/healthcheck.png)

## The menu

| Option | What it does |
|---|---|
| **[W] Open the window** | The point-and-click version of this menu. To start in the text menu instead of the window, set the environment variable `LLAMACPP_TEXT_MENU=1` before running `Start-LlamaCpp.cmd`. |
| **[E] Easy start** | The one-step path. Sets up whatever is missing after a single `YES`, starts the AI and opens a chat window. Offers desktop shortcuts and idle unload the first time. |
| **[G] Gaming mode** | Turn the AI off to free VRAM, switch auto-unload when idle, add or remove the desktop shortcuts. |
| **[1] Setup and models** | Scans your PC and opens the setup screen: first-time install, model browser, llama.cpp updates, diagnostics, removing a model you no longer need ([11], frees disk space), and uninstall. |
| **[2] Start AI server** | Starts the model in its own window and waits until it is ready. Keep that window open while you work. If you have more than one model downloaded, it first asks which one to run (Enter keeps the current one). Switching is instant and offline, and VS Code follows automatically. |
| **[3] Stop AI server** | Stops the server and frees GPU memory, for example before gaming. Asks first. |
| **[4] Open the chat window** | Opens the built-in llama.cpp chat at `http://127.0.0.1:8080/` in an app-style Edge or Chrome window, or your default browser if neither is installed. |
| **[5] Health check** | Tests that the server is up, the model answers, tool calling works, and there is enough memory for Agent mode. |
| **[6] Connect VS Code** | Adds the model to GitHub Copilot Chat. Makes a backup first and only touches its own entry. |
| **[7] Other editors** | The official llama-vscode extension, a Continue settings file, and settings for Cline or any OpenAI-compatible tool. |
| **[8] Beginner guide** | Plain-English explanations of every term, plus official links. |
| **[9] Logs and fixes** | The latest run log and answers to common problems. |
| **[B] Benchmark** | Measures prompt and generation speed with a fixed prompt (the server must be running). Each result is saved to `logs\benchmark-history.jsonl`, and the menu lists earlier runs so models, quants and settings can be compared. |
| **[M] Live monitor** | Watches server status, active model, and prompt/generation speed, refreshing every 2 seconds. Press `Q` then Enter to leave it. |

The status panel shows the active model, whether the AI server is running, and whether VS Code is connected. It also prints a one-line notice if a newer command-center release exists on GitHub — nothing downloads automatically.

## Using the model in VS Code

After **[6] Connect VS Code**:

1. In VS Code press `Ctrl+Shift+P`, type **Reload Window**, and press Enter.
2. Open Copilot Chat with `Ctrl+Alt+I`.
3. Click the model name under the chat box and choose **Qwen3.5 9B - llama.cpp local** (or whichever model you activated).
4. Choose **Agent** to let it read and edit files, or **Ask** for questions.

Switch back to a cloud model at any time from the same list. The AI server must be running (**[2]**) while you use the local model.

**You only connect once.** After that, every time you switch or install a model in the model browser, the VS Code entry updates to that model on its own (with a backup). Reload the VS Code window, restart the AI server, and the picker shows the new model. The server runs one model at a time, so VS Code lists only the active one.

<details>
<summary>Manual setup, if you prefer not to use option [6]</summary>

1. In VS Code run **Chat: Manage Language Models**.
2. Choose **Add Models → Custom Endpoint → Chat Completions**.
3. Endpoint `http://127.0.0.1:8080/v1/chat/completions`, model id `qwen3.5:9b`, API key `local` (any text works).
4. Turn on **Tools** and **Vision**, set the input limit to about 57000 and output to 8192 tokens, save, and reload VS Code.

Option [6] writes exactly this into `%APPDATA%\Code\User\chatLanguageModels.json` as a provider named `llama.cpp local`, keeps every other entry, and saves a backup as `chatLanguageModels.json.command-center.bak`. It refuses to edit the file if it is not valid JSON.
</details>

## Which model? Start with what you want to do

Setup asks **"What do you want to use it for?"** and suggests the model that suits it best on *your* PC. In the window it is a panel; in the text menu it is a numbered question. You can change your mind later with **Choose a different model**.

| You pick | You get | Why |
|---|---|---|
| Everyday chat and writing | The best model that fits in graphics memory | Fast, well-rounded, good for questions and scripts |
| Coding help in VS Code | The best fitting model that can call tools | Tool calling is what lets Copilot Agent read and edit your files |
| Understanding pictures and screenshots | The best fitting model with vision | It can look at images as well as read text |
| Quick answers, easy on my PC | The smallest tool-capable model | Leaves most graphics memory free for games |
| Best possible answers (slower) | The biggest model your PC can hold | May spill into system RAM, so replies take longer |

On a 16 GB Radeon the first three usually land on the same model (Qwen3.5 9B), and it says so. The suggestion never includes a model the installed (or about-to-be-installed) llama.cpp cannot load. Your answer is saved in `settings.json` as `use_case`; `-UseCase chat|coding|images|fast|quality` sets it from the command line.

The full list and details:

The setup recommends the **strongest tool-capable model that fits entirely in your graphics card's memory (VRAM)**. Models that spill into system RAM still work, but reply several times more slowly.

| Model | Download | Tool calling (Agent mode) | Vision | Notes |
|---|---:|:---:|:---:|---|
| **Qwen3.5 9B** | 6.2 GB | ✓ | ✓ | **Recommended for 12–16 GB Radeon cards.** On an RX 9070 XT: fully on the GPU (33/33 layers), 64k context. First *measured* run on this card: median **13.3 tokens/s** and 235 ms to first token on a busy desktop — see [benchmarks/results](benchmarks/results). Older "45–90 t/s" figures in this project were never reproduced and stay labelled unverified. |
| Qwen3.8 27B | 18.3 GB | ✓ | ✓ | Strongest answers, but on a 16 GB card about 5 GB runs from system RAM: roughly 4–7 tokens/s. |
| Qwen3 8B | 8.1 GB | ✓ | | High-quality 8-bit weights. |
| Llama 3.1 8B | 5.6 GB | ✓ | | Proven general-purpose model. |
| Gemma 4 12B *(new)* | 6.9 GB | ✓ | ✓ | Google's April 2026 model (Q4_0 quant). Tool calling is supported by current llama.cpp but hasn't been tested with Copilot Agent mode here. Needs the Vulkan or *llama.cpp ROCm (latest)* backend: AMD's ROCm 7.2.1 package is older than Gemma 4 and can't load it. |
| Gemma 3 12B | 7.6 GB | | ✓ | Chat and image understanding; not for Agent mode. |
| Gemma 3 4B | 3.1 GB | | ✓ | For 8 GB systems and Ryzen integrated graphics. |
| Qwen3 4B | 2.3 GB | ✓ | | Smallest and fastest; good for CPU-only machines. |
| Ornith 1.5 9B *(experimental)* | 6.2 GB | ✓ | ✓ | A community-tuned version of Qwen3.5 9B aimed at coding. Its makers report better results; that hasn't been checked here. AMD's ROCm 7.2.1 package can't load it (the menu stops you before downloading). It needs the Vulkan backend, which crashed during long sessions on an RX 9070 XT, or the advanced *llama.cpp ROCm (latest)* backend, which should load it but hasn't been tested with it here. |

The model browser in **[1]** shows each model's fit for *your* PC: `VRAM` means it fits in graphics memory, `VRAM+RAM` means it spills into system RAM and runs more slowly. Downloads come from Hugging Face; the current revision and SHA-256 are resolved at download time, and files are verified before they are activated.

![Hardware advisor: detected hardware, model fit, and the recommendation](docs/advisor.png)

## How it is tuned for Copilot, and why (optional reading)

These settings came from diagnosing real Copilot failures on an RX 9070 XT. They are applied automatically when you activate a model.

| Setting | Value (Qwen3.5 9B, 16 GB card) | Why |
|---|---|---|
| Context per conversation | 65,536 tokens | Copilot's Agent prompt alone is 26k–40k tokens. Below about 32k, VS Code fails with *No lowest priority node found*. |
| Conversations at once | 2 (`--parallel 2`, 131,072-token pool) | VS Code sometimes sends a second large request (such as a summary) while an Agent turn is running. With room for only one, both fail with *Server error: 500*. |
| Thinking | Off (`--reasoning off`) for tool-capable models | With thinking on, Qwen often hides its tool call inside the thinking text, and VS Code shows *Sorry, no response was returned*. |
| VS Code token budget | 57,344 input / 8,192 output | Matches one conversation's context. |
| Speculative drafting | n-gram (`--spec-type ngram-mod`) | Guesses repeated text from the conversation and verifies it, so replies are unchanged. Newer llama.cpp builds gain speed on code and lists. AMD's ROCm 7.2.1 package logs that it is not supported for Qwen3.5 and ignores it. Opt out with `["--spec-type", "none"]` in `server-args.user.json`. |
| Network | `127.0.0.1` only | Other devices on your network cannot reach the server. |

Context is sized from the VRAM left after the model loads, and from each model's measured memory cost per token. Dense 8B models get 32k; hybrid models such as Qwen3.5 need much less memory and get 64k. You can override it:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-LlamaCpp-AMD.ps1 -Action Models -ModelId qwen3.5-9b -ContextSize 49152
```

## Troubleshooting

Start with **[5] Health check**. It names the failing step and what to do.

| What you see | What to do |
|---|---|
| Health check: *Server is running* **FAIL** | Choose **[2]** and wait for **READY**. Loading takes 5–60 seconds. |
| VS Code: *No lowest priority node found* | The model's context is too small for Copilot. In **[1]** open the model browser, activate your model again (it now gets 64k), then stop and start the server. |
| VS Code: *Sorry, no response was returned* | Your launcher predates the thinking fix. Re-activate the model in **[1]**, then restart the server. |
| VS Code: *Server error: 500* and the server log says *Context size has been exceeded* | Your launcher predates the two-conversation setting. Re-activate the model in **[1]**, then restart the server. |
| VS Code: *ERR_CONNECTION_RESET* | The server stopped or restarted mid-reply. Start it with **[2]** and click **Try again** in Copilot. |
| The model is not in Copilot's model list | Run **[6]** again, then **Reload Window** in VS Code. |
| Replies are very slow | The model does not fit in VRAM. Pick one marked `VRAM` (not `VRAM+RAM`) in the model browser. If it used to be fast, a game or browser may be holding graphics memory: use **[G] Gaming mode** or close it, then restart the AI. |
| A button in the window says *Something went wrong with that button* | The window keeps running. Send `%LOCALAPPDATA%\Programs\llama.cpp\logs\gui-error.log` (and the latest run log) when asking for help; if the window cannot open at all, the text menu opens instead and the reason is in the same file. |
| *Only X GiB of your graphics memory is free* when starting | Another app is using VRAM. Close it and press Enter to start, or start anyway and accept slower replies. |
| Graphics card not detected | Update the AMD driver, restart Windows, then run **Diagnostics** from **[1]**. |
| *Install-LlamaCpp-AMD.ps1 is missing* | Extract the whole ZIP and keep both scripts and the `catalog` folder in the same folder. |
| The desktop app says *The PowerShell backend was not found* | Use the installer, which bundles the backend in its `backend` folder. If you run the app from a build, set `LLAMACPP_SCRIPT` to the full path of `Install-LlamaCpp-AMD.ps1`. |
| Game pause does nothing | Check `%LOCALAPPDATA%\Programs\llama.cpp\logs\game-watch.log`. It needs a discrete Radeon with at least 4 GiB of graphics memory, a llama.cpp new enough for router mode, and a server started after you saved the setting (saving rebuilds the launchers). |
| The model shows *Asleep* in the app | Normal: the server is up, but the model has left graphics memory (idle unload or game pause). Send a message, or press **Open chat**, and it loads again. |
| The model list says a model *cannot run on the installed llama.cpp build* | That model needs a newer llama.cpp than AMD's ROCm 7.2.1 package. Pick another model, or switch backend (the Which model? and AMD backends tables explain the options). |
| The server window closed by itself | Choose **[9] Logs and fixes**, then start it again with **[2]**. If it keeps happening on the Vulkan backend, see the next row. |
| PC froze, blue-screened (`VIDEO_TDR_FAILURE`, 0x116), or the server log says `device lost on Vulkan0` | On a Radeon that supports ROCm (such as the RX 9070 XT), use the **ROCm backend**. In testing on an RX 9070 XT, the Vulkan build lost the GPU during long Agent sessions (about 58k tokens of context), once taking Windows down with it; ROCm ran for days without a fault. From v0.1.5 the launcher also pins the dedicated Radeon, so Ryzen integrated graphics is never used automatically. |
| The server log says `speculative decoding not supported by this context` | Harmless. AMD's ROCm 7.2.1 build cannot combine n-gram drafting with the Qwen3.5 hybrid model, so the server ignores it and replies are unchanged. To silence the message, add `["--spec-type", "none"]` to `server-args.user.json`. |
| VS Code says `code` is not recognized ([7] → llama-vscode) | Install the extension from inside VS Code: Extensions, search **llama-vscode**, Install. |

**[9] Logs and fixes** shows the latest run log. Logs live in `%LOCALAPPDATA%\Programs\llama.cpp\logs`; common API keys and tokens are removed automatically, but look them over before sharing.

## Other editors and tools

- **llama-vscode**: the official llama.cpp VS Code extension (`ggml-org.llama-vscode`) for completion, chat, and agents. Option **[7] → [1]** installs it, then points its `llama-vscode.endpoint*` settings at your server. Every other line in `settings.json` is preserved and a backup is made first. If `settings.json` contains `//` comments, nothing is auto-written — you get the exact lines to paste instead, so comments are never silently lost.
- **Continue**: option **[7] → [2]** writes (or updates) a clearly marked block in Continue's own `%USERPROFILE%\.continue\config.yaml`, backed up first. If that file already has its own `models:` list, nothing is changed automatically — you get the exact YAML to add under your existing list, so your other models are never hidden by a second `models:` key.
- **Cline and other OpenAI-compatible tools**: base URL `http://127.0.0.1:8080/v1`, model `qwen3.5:9b`, API key `local`.
- **Claude Code** uses an Anthropic-compatible gateway (`ANTHROPIC_BASE_URL`), not an OpenAI-compatible endpoint. This project does not install or claim support for a gateway.

## AMD backends

| Backend | Used for | Notes |
|---|---|---|
| **ROCm** | Radeon cards in AMD's Windows ROCm list, such as the RX 9070 XT | AMD's validated Windows package (ROCm 7.2.1). Fastest on supported cards. |
| **Vulkan** | Ryzen integrated graphics, older Radeon cards, everything else | Official llama.cpp Vulkan build using the standard AMD driver. On cards that support ROCm, stay on ROCm: on an RX 9070 XT, Vulkan crashed during long sessions. |
| **llama.cpp ROCm (latest)** *(advanced, opt-in)* | Anyone who wants the newest llama.cpp on ROCm, for example to run Gemma 4 or Ornith | llama.cpp's own Windows ROCm build, updated with every llama.cpp release. It needs AMD's ROCm runtime libraries installed separately, so it is never chosen automatically. After installing, setup checks that the build can see your Radeon; if not, it removes the new build and keeps your previous llama.cpp. Not yet tested by this project on every card. |

The setup chooses ROCm or Vulkan automatically on a fresh install; you can override it with the backend selector in **[1]** (option [8], then [5] to install). After that, updates keep the backend you have installed, so choosing Vulkan (for example, to run Ornith) is never undone by an update. The dashboard's BACKEND line shows the build actually installed. VRAM is read through DXGI, which avoids the Windows WMI bug that reports modern cards as 4 GB.

## Command-line reference (advanced)

You never need this; the menu does everything. For scripting, every menu action is also available directly:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-LlamaCpp-AMD.ps1 -Action <Action> [options]
```

| Action | What it does |
|---|---|
| `Dashboard` (default) | The setup screen from menu option [1]. |
| `Install` | Install llama.cpp and the recommended model (`-SkipModel` for llama.cpp only). |
| `Models` | Model browser, or `-ModelId qwen3.5-9b` to install and activate one directly. |
| `Advisor` | Show detected hardware and model fit without changing anything (same as `-DryRun`). |
| `Launch` | Start the server in the current window. |
| `SelfTest` | The health check from menu option [5]. |
| `VSCodeChat` | Connect VS Code Copilot Chat (menu option [6]). Exit code 2 means you cancelled. |
| `Status` | One line for scripts: alias, name, context, server state, VS Code state, idle-unload minutes (`0` = off) and desktop shortcuts (`yes`/`no`), separated by `\|`. |
| `State` | One JSON document for scripts and the window: schema version, command-center version, installed runtime, active model (with `model_present` and `runtime_blocker`), server state and port, downloaded models, settings, VS Code state, desktop shortcuts, idle-unload minutes, and detected hardware (`null` plus `hardware_error` if the scan fails). Strictly read-only; on a breaking change only `schema_version` moves, so consumers must ignore unknown fields. |
| `Snapshot` | Save the current state as a JSON file under `<install>\state-history\` and print its path. The same snapshot is taken automatically before `Activate`, `Install`, `Update`, `Uninstall`, `RemoveModel` and `Easy`, so diagnostics and rollback always have history; the newest 40 are kept. |
| `Recommend` | One JSON document: catalogue-driven model advice for `fast`, `balanced` and `maximum` workloads, each with `model_id`, a status (`supported`/`recommended`/`experimental`/`unsupported`), `confidence`, a plain-English `reason` and any `blockers`, plus the aggregate blocker list. Derived only from the detected hardware and `catalog/`; no GPU names are hardcoded. Strictly read-only. |
| `Diagnose` | One JSON document: typed runtime, hardware, model and editor health sections, each with validation status, confidence, warnings and blockers, plus an `overall` verdict (`ok`/`degraded`/`broken`). The runtime section also reports the configured port and who holds it (`free`/`owned`/`conflict`). Machine-readable, string-parsing-free, no GUI. Strictly read-only. |
| `Runtime` | One JSON document from the runtime adapter entry points (ADR-005): `-RuntimeAction health` (read-only liveness), `start` (the proven start path, with the port-ownership guard), or `stop` (without `-Force` it only reports `requires_confirmation` and kills nothing). This is the surface the desktop window uses, so the window never re-implements process control. |
| `Gui` | Open the window (what double-clicking `Start-LlamaCpp.cmd` runs). If it cannot open, the text menu starts instead. |
| `Easy` | Menu option [E]: set up whatever is missing after one `YES` (`-Force` skips it), then offer the optional extras once. Exit code 2 means you cancelled. |
| `Preflight` | Check free graphics memory before starting the server. Exit code 3 means other apps leave too little room for the active model. |
| `IdleSleep` | `-IdleMinutes 15` unloads the model after 15 idle minutes; `-IdleMinutes 0` turns it off. Applies at the next server start. |
| `GameWatch` | The background helper the launcher starts when game pause is on. It exits by itself when the server stops, so there is nothing to run by hand. |
| `Shortcuts` / `RemoveShortcuts` | Add or remove the **AI Chat** and **AI Off** desktop shortcuts. Removal only deletes shortcuts that still point into this install. |
| `Update` | Update llama.cpp and keep every model. |
| `Diagnostics` | llama.cpp version, detected devices, and active model check. |
| `ViewLog` | Show the latest run log. |
| `Uninstall` | Remove llama.cpp, all downloaded models, and the launchers (asks first). |
| `ListInstalled` | One line per downloaded model: number, id, name, and `active`, `ready` or `blocked`. |
| `Activate` | Switch to an already-downloaded model instantly (`-ModelId qwen3.5-9b`). Never downloads. |
| `RemoveModel` | Delete one downloaded model to free disk space (asks first; refuses the active model). Without `-ModelId` it shows a list. |
| `Benchmark` | Menu option [B] (and dashboard [12]): one measured request after a warm-up, printed and appended to the benchmark history. Needs the server running. |
| `Monitor` | The live monitor from menu option [M]: server status, active model, and prompt/generation speed, refreshing every 2 seconds. |
| `CheckUpdate` | Check GitHub for a newer command-center release. Prints a message; never downloads or installs anything. |
| `ContinueConfig` | Write or update the managed block in Continue's `config.yaml` (menu [7] → [2]). |
| `LlamaVscodeConfig` | Point the llama-vscode extension's settings at your server (menu [7] → [1]). |

| Option | Meaning |
|---|---|
| `-ModelId` | `qwen3.5-9b`, `qwen3.8-27b`, `qwen3-8b`, `llama3.1-8b`, `gemma4-12b`, `gemma3-12b`, `gemma3-4b`, `qwen3-4b`, `ornith-1.5-9b` |
| `-ContextSize` | Tokens per conversation. `0` (default) sizes it from your hardware. |
| `-Thinking` | `Auto` (default: off for tool-capable models), `On`, or `Off`. |
| `-Backend` | `Auto` (default), `ROCm` (AMD's validated package), `ROCmLatest` (llama.cpp's own ROCm build; advanced), or `Vulkan`. |
| `-Port` | Server port, default `8080`. |
| `-UseCase` | `chat`, `coding`, `images`, `fast` or `quality`: what you want to use the AI for. Easy start picks the model from it (and asks when it is not set). |
| `-IdleMinutes` | With `-Action IdleSleep`: minutes of idleness before the model leaves graphics memory (`0` = off). |
| `-Force` | Skip confirmation prompts. |

## Where files live

| Path | Contents |
|---|---|
| `%LOCALAPPDATA%\Programs\llama.cpp\current` | llama.cpp itself (`llama-server.exe` and its libraries). |
| `%LOCALAPPDATA%\Programs\llama.cpp\models` | Downloaded models. |
| `%LOCALAPPDATA%\Programs\llama.cpp\Start-LlamaCpp.cmd` | The generated server launcher that menu option [2] runs. |
| `%LOCALAPPDATA%\Programs\llama.cpp\active-model.json` | The active model and its settings. |
| `%LOCALAPPDATA%\Programs\llama.cpp\settings.json` | Settings this project manages, such as `idle_sleep_minutes` and `game_pause_gib`. Safe to delete. |
| `%LOCALAPPDATA%\Programs\llama.cpp\server-preset.ini` | The model's settings for llama.cpp's router, rebuilt by the launchers and every server start. Model files inside the install folder are written relative to it. Safe to delete (the next start rewrites it). |
| `%LOCALAPPDATA%\Programs\llama.cpp\tools\`, `logs\game-watch.log` | With game pause on: this project's own copy of the script and catalogue, which the watcher runs, and the watcher's log. |
| `%LOCALAPPDATA%\Programs\llama.cpp\Chat.cmd`, `Gaming-Mode.cmd` | Generated helpers the desktop shortcuts run: start the AI and open the chat, or stop it and free VRAM. |
| `%LOCALAPPDATA%\Programs\llama.cpp\logs` | Run logs (`run-*.log`, `run-*.jsonl`, `run-*-summary.json`, `latest.log`). |
| `%LOCALAPPDATA%\Programs\llama.cpp\server-args.user.json` | Optional. Your own `llama-server` flags as a JSON array of strings, e.g. `["--threads", "12", "--no-mmap"]`. Merged in **last**, after every program and hardware default, so your choices always win. This file is never created or overwritten by setup or updates — it is entirely yours. |

To remove everything, choose **Uninstall** in **[1]**. It asks for confirmation, then removes only the settings this project manages — the `llama.cpp local` entry in VS Code Chat, the llama-vscode endpoint settings, and the managed block in Continue's config.yaml (each backed up first) — and leaves Copilot, your account, and every unrelated setting exactly as they were.

## Safety and privacy

- Nothing is installed or downloaded until you choose it and confirm.
- Downloads use official HTTPS sources. Model files are checked against their published Git LFS SHA-256 values before activation.
- AMD does not publish a SHA-256 file for its ROCm package, so its downloaded hash is recorded locally instead of claimed as verified.
- The server listens on `127.0.0.1` only and needs no API key.
- Editor settings (VS Code Chat, llama-vscode, Continue) are changed only when you choose to connect that editor. Each file is backed up first, and only this project's own entries are edited. GitHub Copilot itself is never changed.
- Desktop shortcuts and idle unload are created only when you say yes (Easy start asks once; **[G]** changes them later). Uninstall removes the shortcuts, but only ones that still point into this install.
- The setup only uses your dedicated Radeon card. Ryzen built-in graphics is never used automatically.

## Development

```text
Start-LlamaCpp.cmd              Windows menu (what users double-click)
Install-LlamaCpp-AMD.ps1        Hardware detection, install, models, launcher, VS Code setup, health check
catalog/                        Versioned JSON data loaded at runtime: models, runtimes, hardware profiles, compatibility rules (ADR-004)
desktop/                        Desktop app (Tauri + React/TypeScript + Rust supervisor) — a client of the same JSON documents, ADR-006
benchmarks/                     Benchmark contract, the local runner and the first measured results
tests/Test-CommandCenter.ps1    Offline checks: launchers, recommendations, GPU selection, model switching, editor settings writers, state contract
CLAUDE.md                       Conventions and hardware findings for AI coding assistants working on this repo
docs/                           GitHub Pages site
.github/workflows/ci.yml        Windows checks on every push: CRLF, PowerShell 5.1 parse, analyzer, tests, menu smoke test
.github/workflows/release.yml   Builds the release ZIP and SHA-256 for v* tags
.github/workflows/pages.yml     Deploys docs/ to GitHub Pages
```

Run the offline checks before opening a pull request:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-CommandCenter.ps1
```

The scripts target Windows PowerShell 5.1. `.gitattributes` keeps `.cmd` and `.ps1` files in CRLF, which `cmd.exe` needs. See [CONTRIBUTING.md](CONTRIBUTING.md) for the full checklist.

### Desktop app (optional)

The scripts stay the product: they work standalone, and the desktop app is a client that
calls them. It renders the same typed documents (`-Action State`, `Recommend`, `Diagnose`,
`Runtime`) and never reads files or parses output itself.

```powershell
cd desktop
npm install
npm run dev        # one command: front end + window
npm run build      # release app AND the Windows installer (NSIS, per user)
```

`npm run build` writes the installer to `desktop\src-tauri\target\release\bundle\nsis\`. The installer bundles `Install-LlamaCpp-AMD.ps1` and `catalog\` in a `backend` folder beside the app, which is where the app looks first after its own folder. See [desktop/README.md](desktop/README.md) for requirements, the backend-discovery order,
and the debug-vs-release difference (a debug build loads the Vite dev server, so run it
with `npm run dev` or build the standalone release binary with `npm run build`).

## License

MIT License. See [LICENSE](LICENSE).

## Author

**Created by Matt Hurley - [matthurley.dev](https://matthurley.dev)**

If you fork or extend this project, please keep the credit or clearly attribute the original work.
