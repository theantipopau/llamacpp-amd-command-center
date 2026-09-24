@echo off
setlocal EnableExtensions EnableDelayedExpansion
chcp 65001 >nul 2>&1
mode con: cols=140 lines=45 >nul 2>&1
title llama.cpp for Windows - AMD CPU and GPU Command Center

rem ============================================================================
rem  LLAMA.CPP FOR WINDOWS - ALL-IN-ONE WALKTHROUGH AND CONTROL PANEL
rem  Created by Matt Hurley - matthurley.dev
rem
rem  This batch file is intentionally self-documenting. It does not silently
rem  install anything: every installation action is shown in the menu first.
rem  The PowerShell command center performs hardware detection, backend
rem  selection, llama.cpp installation, model download, hash verification, and
rem  server launch.
rem ============================================================================

set "SCRIPT_DIR=%~dp0"
set "PS_SCRIPT=%SCRIPT_DIR%Install-LlamaCpp-AMD.ps1"
set "INSTALL_ROOT=%LOCALAPPDATA%\Programs\llama.cpp"
set "SERVER_CMD=%INSTALL_ROOT%\Start-LlamaCpp.cmd"
set "API_URL=http://127.0.0.1:8080"
set "API_MODELS_URL=http://127.0.0.1:8080/v1/models"
set "CONTINUE_TEMPLATE=%SCRIPT_DIR%Continue-llamacpp-config.yaml"
set "EXTENSION_ID=ggml-org.llama-vscode"
set "ACTIVE_ALIAS="
set "ACTIVE_NAME="

if not exist "%PS_SCRIPT%" (
    color 0C
    echo.
    echo  ERROR: Install-LlamaCpp-AMD.ps1 was not found next to this file.
    echo  Expected: "%PS_SCRIPT%"
    echo.
    call :wait_for_key
    exit /b 1
)

:menu
call :read_active_model
cls
color 0F
echo.
echo  ========================================================================================================
echo   LLAMA.CPP / AMD WINDOWS COMMAND CENTER
echo   Local AI setup for AMD Ryzen and Radeon systems
echo  ========================================================================================================
echo   Created by Matt Hurley - matthurley.dev
echo.
if defined ACTIVE_ALIAS (echo  ACTIVE MODEL: %ACTIVE_NAME%  [%ACTIVE_ALIAS%]) else (echo  ACTIVE MODEL: none yet - choose [1])
echo.
echo  [ FIRST-TIME PATH ]  Choose [1] if you are new to local LLMs.
echo  [ ALREADY READY? ]   Choose [2] to start the active model, or [6] to test it.
echo  [ L ]  LOCAL ENGINE     llama.cpp server, Web UI, and localhost API
echo  [ M ]  MODEL LAYER      hardware-fit advice and verified GGUF downloads
echo  [ V ]  VS CODE LAYER    Copilot Chat, llama-vscode, Continue, and Cline guidance
echo  [ A ]  API LAYER        local OpenAI-compatible endpoint
echo.
echo  --------------------------------------------------------------------------------------------------------
echo   [1]  FIRST-TIME SETUP       Scan hardware, install backend, and activate the recommended model
echo   [2]  START LOCAL SERVER     Run the active model with its Web UI and local API
echo   [3]  INSTALL VS CODE        Install the official llama-vscode extension
echo   [4]  CONTINUE TEMPLATE      Create a safe local-provider YAML template
echo   [5]  CONFIGURE VS CODE      Point Copilot Chat at the active model (asks first) + Cline settings
echo   [6]  TEST LOCAL API         Check whether the server is ready
echo   [7]  COMPLETE WALKTHROUGH   Read the full beginner-friendly setup guide
echo   [8]  OFFICIAL LINKS         Open trusted upstream project information
echo   [9]  VIEW LATEST LOG        Read the most recent persistent run log
echo   [0]  EXIT                   Close the command center
echo  --------------------------------------------------------------------------------------------------------
echo.
echo  TIP: Windows Terminal with Cascadia Mono or Consolas gives the cleanest display.
echo.
set "choice="
set /p "choice=Choose an option (0 to exit): "
if defined choice set "choice=%choice:~0,1%"
if not defined choice set "choice=0"

if "%choice%"=="1" goto :dashboard
if "%choice%"=="2" goto :start_server
if "%choice%"=="3" goto :install_extension
if "%choice%"=="4" goto :continue_template
if "%choice%"=="5" goto :cline_settings
if "%choice%"=="6" goto :test_api
if "%choice%"=="7" goto :walkthrough
if "%choice%"=="8" goto :links
if "%choice%"=="9" goto :view_log
if "%choice%"=="0" goto :done

color 0E
echo.
echo  Please choose a number from the menu.
timeout /t 2 /nobreak >nul
goto :menu

:dashboard
cls
color 0B
echo.
echo  Opening the llama.cpp AMD Command Center...
echo  The next screen will detect your CPU, GPU, VRAM, RAM, and best model.
echo  Nothing is downloaded until you approve the installation.
echo.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" %*
set "EXIT_CODE=%ERRORLEVEL%"
echo.
if not "%EXIT_CODE%"=="0" (
    color 0C
    echo  The command center exited with code %EXIT_CODE%.
) else (
    color 0A
    echo  Command center closed normally.
)
call :wait_for_key
goto :menu

:start_server
cls
color 0A
echo.
echo  STARTING THE ACTIVE LOCAL MODEL
echo  --------------------------------------------------------------------------------------------------------
echo  The active model is launched by:
echo    "%SERVER_CMD%"
echo.
if exist "%SERVER_CMD%" (
    echo  Opening the generated server launcher...
    echo  Keep this window open while VS Code is using the model.
    echo.
    call "%SERVER_CMD%"
    echo.
    echo  Server launcher closed.
) else (
    color 0E
    echo    No generated server launcher was found yet.
    echo    Choose [1] and run the guided first-time setup first.
    echo    If you are unsure, choose [7] for the complete walkthrough.
    echo.
    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" -Action Launch
)
echo.
call :wait_for_key
goto :menu

:install_extension
cls
color 0B
echo.
echo  OFFICIAL VS CODE EXTENSION
echo  --------------------------------------------------------------------------------------------------------
echo  Extension: llama-vscode
echo  Publisher: ggml.org / ggml.ai
echo  ID: %EXTENSION_ID%
echo.
echo  This extension provides local completion, chat, and agent features.
echo  It can also manage llama.cpp environments and local models.
echo.
set "CODE_CMD="
for /f "delims=" %%I in ('where code 2^>nul') do if not defined CODE_CMD set "CODE_CMD=%%I"
if not defined CODE_CMD for /f "delims=" %%I in ('powershell.exe -NoLogo -NoProfile -Command "$c=Get-Command code -ErrorAction SilentlyContinue; if ($null -ne $c) { $c.Source }"') do if not defined CODE_CMD set "CODE_CMD=%%I"
if not defined CODE_CMD (
    color 0E
    echo  VS Code is installed or may be installed, but its command could not be found.
    echo  This is common on Windows and does not mean VS Code is missing.
    echo  VS Code may be open already; that is okay.
    echo  Open VS Code and select Extensions, search llama-vscode, and install it.
    echo  Official download: https://code.visualstudio.com/download
    echo.
    call :wait_for_key
    goto :menu
)
echo  Installing the official extension now...
echo  Using: "%CODE_CMD%"
call "%CODE_CMD%" --install-extension %EXTENSION_ID%
if errorlevel 1 (
    color 0C
    echo  VS Code extension installation failed.
) else (
    color 0A
    echo  llama-vscode installed successfully.
)
echo.
call :wait_for_key
goto :menu

:continue_template
cls
color 0A
echo.
echo  CONTINUE CONFIGURATION TEMPLATE
echo  --------------------------------------------------------------------------------------------------------
echo  This creates a separate template and does not overwrite your existing
echo  Continue configuration.
echo.
if exist "%CONTINUE_TEMPLATE%" (
    color 0E
    echo  Template already exists:
    echo    "%CONTINUE_TEMPLATE%"
    echo  It was left unchanged.
    goto :show_continue
)
if not defined ACTIVE_ALIAS (
    color 0E
    echo  No active model yet. Choose [1] first so the template uses the right model.
    echo.
    call :wait_for_key
    goto :menu
)
(
    echo name: Local llama.cpp
    echo version: 0.0.1
    echo schema: v1
    echo.
    echo models:
    echo   - name: %ACTIVE_NAME%
    echo     provider: llama.cpp
    echo     model: %ACTIVE_ALIAS%
    echo     apiBase: %API_URL%
) > "%CONTINUE_TEMPLATE%"
color 0A
echo  Created safely:
echo    "%CONTINUE_TEMPLATE%"
:show_continue
echo.
echo  Continue setup:
echo    1. Install the Continue extension in VS Code.
echo    2. Start the llama.cpp server with option [2].
echo    3. Add or merge the YAML settings into your Continue configuration.
echo    4. Select the model named in the template.
echo.
call :wait_for_key
goto :menu

:cline_settings
cls
color 0B
echo.
echo  CONFIGURING VS CODE COPILOT CHAT
echo  --------------------------------------------------------------------------------------------------------
echo  The command center will update the llama.cpp ROCm provider and back up
echo  the existing VS Code chatLanguageModels.json file.
echo.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" -Action VSCodeChat
if errorlevel 1 (
    echo.
    echo  VS Code Chat setup did not complete. Read the message above.
    echo  You can still use the manual values shown below.
)
echo.
echo  COPILOT CHAT / CLINE / OPENAI-COMPATIBLE SETTINGS
echo  --------------------------------------------------------------------------------------------------------
echo  Provider:       OpenAI Compatible
echo  Base URL:       %API_URL%/v1
echo  Chat endpoint:  %API_URL%/v1/chat/completions
if defined ACTIVE_ALIAS (echo  Model:          %ACTIVE_ALIAS%) else (echo  Model:          the id shown by option [6])
echo  API key:        any non-empty placeholder, for example: local
echo.
echo  NATIVE COPILOT CHAT
echo  1. Start the server with option [2] and wait for loading.
echo  2. VS Code: Chat: Manage Language Models
echo  3. Add Models -> Custom Endpoint -> Chat Completions
echo  4. Use the Chat endpoint and model above.
echo  5. Enable Tools and Vision, save chatLanguageModels.json, reload VS Code.
echo.
echo  The local server is bound to 127.0.0.1, so it is not exposed to your LAN.
echo  Start the server with option [2] before testing Copilot, Cline, or another client.
echo.
echo  If Agent mode hides the model, verify toolCalling is true in the VS Code model entry.
echo  If Agent mode fails with "No lowest priority node found", the context is too small:
echo  re-activate the model with -ContextSize 32768, restart the server, and run [5] again.
echo  For Cline, use the OpenAI-compatible provider and the Base URL above.
echo.
call :wait_for_key
goto :menu

:test_api
cls
color 0B
echo.
echo  TESTING THE LOCAL LLAMA.CPP API
echo  --------------------------------------------------------------------------------------------------------
echo  Endpoint: %API_MODELS_URL%
echo.
powershell.exe -NoLogo -NoProfile -Command "$ErrorActionPreference='Stop'; $r=Invoke-RestMethod -Uri '%API_MODELS_URL%'; Write-Output 'API reachable. Server response:'; Write-Output $r"
if errorlevel 1 (
    color 0C
    echo.
    echo  API test failed. Is the server running?
    echo  Start it with option [2] and wait for model loading to finish.
) else (
    color 0A
    echo.
    echo  API test passed.
    echo  VS Code clients can now use the model id shown above.
)
echo.
call :wait_for_key
goto :menu

:walkthrough
cls
color 0E
echo.
echo  ========================================================================================================
echo   COMPLETE WALKTHROUGH: LLAMA.CPP TO VISUAL STUDIO CODE
echo  ========================================================================================================
echo.
echo  STEP 1 - DETECT HARDWARE
echo  --------------------------------------------------------------------------------------------------------
echo  The PowerShell command center detects:
echo    - AMD Ryzen / EPYC CPU cores and threads
echo    - Radeon dGPU and Ryzen iGPU devices
echo    - True DXGI dedicated VRAM, avoiding the WMI 4 GiB reporting cap
echo    - System RAM, Vulkan loader, and AMD driver state
echo.
echo  STEP 2 - SELECT THE BACKEND
echo  --------------------------------------------------------------------------------------------------------
echo  Auto mode selects:
echo    - AMD ROCm 7.2.1 for supported Radeon dGPUs such as RX 9070 XT
echo    - Vulkan for Ryzen iGPUs, older Radeon cards, and unsupported GPUs
echo.
echo  ROCm is AMD's validated Windows path for supported Radeon hardware.
echo  Vulkan is the portable fallback and uses the AMD Vulkan driver.
echo.
echo  STEP 3 - INSTALL LLAMA.CPP
echo  --------------------------------------------------------------------------------------------------------
echo  The command center downloads the official backend package, verifies the
echo  available upstream SHA-256 digest, extracts llama-server.exe, validates
echo  the runtime, and preserves models during updates.
echo.
echo  STEP 4 - INSTALL A GGUF MODEL
echo  --------------------------------------------------------------------------------------------------------
echo  The command center recommends the strongest tool-capable model that fits
echo  entirely in your GPU memory. On a 16 GB Radeon RX 9070 XT that is:
echo.
echo  RECOMMENDED: Qwen3.5 9B Q4_K_M
echo    Weights:     Qwen3.5-9B-Q4_K_M.gguf
echo    Projector:   mmproj-F16.gguf
echo    API alias:   qwen3.5:9b
echo    Download:    approximately 6.20 GiB including projector
echo    Best for:    fast VS Code Agent turns and tool calling
echo    Context:     32768 tokens, enough for Copilot Agent mode
echo.
echo  QUALITY OPTION: Qwen3.8 27B Q4_K_M
echo  Stronger answers, but it does not fit in 16 GB of VRAM, so part of it runs
echo  from system RAM at roughly 4-7 tokens per second.
echo  llama.cpp alias:   qwen3.8:latest
echo  Model weights:     Qwen3.8-27B-Q4_K_M.gguf
echo  Vision projector:  mmproj-Qwen3.8-27B-Q8_0.gguf
echo  Download:          approximately 18.25 GiB including projector
echo.
echo  The script resolves Hugging Face metadata at download time and verifies
echo  each Git LFS SHA-256 digest.
echo.
echo  STEP 5 - START THE LOCAL SERVER
echo  --------------------------------------------------------------------------------------------------------
echo  Use the generated launcher:
echo    "%SERVER_CMD%"
echo.
echo  Web UI and API:
echo    %API_URL%/
echo    %API_URL%/v1
echo.
echo  The server binds to 127.0.0.1 only. It is private to this PC.
echo.
echo  STEP 6 - CONNECT VS CODE
echo  --------------------------------------------------------------------------------------------------------
echo  Official llama-vscode extension:
echo    code --install-extension %EXTENSION_ID%
echo.
echo  Native VS Code Copilot Chat custom endpoint:
echo    Option [5] can configure this automatically for the active model.
echo    It preserves Copilot settings and creates a JSON backup.
echo    After it finishes, run Developer: Reload Window in VS Code.
echo.
echo    Manual fallback:
echo    1. Start the server with option [2] and wait for loading.
echo    2. Run: Chat: Manage Language Models
echo    3. Add Models -> Custom Endpoint -> Chat Completions
echo    4. Endpoint: %API_URL%/v1/chat/completions
echo    5. Model: the id shown by option [6], for example qwen3.5:9b
echo    6. API key: any non-empty placeholder, such as local
echo    7. Enable Tools and Vision, save chatLanguageModels.json, reload VS Code
echo.
echo  Continue:
echo    provider: llama.cpp
echo    apiBase:  %API_URL%
echo    model:    the active model id, for example qwen3.5:9b
echo.
echo  Cline or another OpenAI-compatible extension:
echo    Base URL: %API_URL%/v1
echo    Model:    the active model id, for example qwen3.5:9b
echo    API key:  any non-empty placeholder
echo.
echo  STEP 7 - TEST THE CONNECTION
echo  --------------------------------------------------------------------------------------------------------
echo  From this menu choose [6], or run:
echo    Invoke-RestMethod %API_MODELS_URL%
echo.
echo  If the response lists your active model id, the server is ready for VS Code.
echo.
echo  IMPORTANT MODEL NOTE
echo  --------------------------------------------------------------------------------------------------------
echo  The Qwen models are general reasoning, chat, tool, and vision models.
echo  The official llama-vscode extension may perform best for inline completion
echo  with an FIM-capable coding model. The general model remains suitable for
echo  chat, editing, and agent workflows.
echo.
echo  COPILOT AND LOCAL LLM
echo  --------------------------------------------------------------------------------------------------------
echo  GitHub Copilot can stay installed and enabled. This project does not
echo  remove or reconfigure Copilot. Use the Custom Endpoint steps above
echo  when you want Copilot Chat to use the local model. Continue, Cline,
echo  and llama-vscode are separate local-client options.
echo.
echo  If Agent mode hides the model, verify toolCalling is true in
echo  chatLanguageModels.json. If Agent mode fails with "No lowest priority
echo  node found", the model's context is too small for Copilot's prompt:
echo  use at least 32768 tokens.
echo.
echo  STEP 8 - IF SOMETHING GOES WRONG
echo  --------------------------------------------------------------------------------------------------------
echo  API test fails: start the server with [2], wait for loading, test [6].
echo  code not found: VS Code may still be installed. Open VS Code and select
echo  Extensions, search llama-vscode, and install it there; or add VS Code to PATH.
echo  Model too slow: use the model browser or hardware/model advisor.
echo  Qwen3.5 9B is the recommended Agent model; Qwen3.8 27B is slower but stronger.
echo  GPU missing: update AMD Adrenalin, reboot, then run diagnostics.
echo.
echo  RELEASE DOWNLOAD
echo  --------------------------------------------------------------------------------------------------------
echo  GitHub Releases (latest) provides a ZIP with Start-LlamaCpp.cmd,
echo  Install-LlamaCpp-AMD.ps1, README.md, LICENSE, and logo.png.
echo  Download the ZIP, extract it, and keep both script files together.
echo.
call :wait_for_key
goto :menu

:links
cls
color 0F
echo.
echo  OFFICIAL INFORMATION AND LINKS
echo  ========================================================================================================
echo.
echo  Official llama.cpp VS Code extension:
echo    https://marketplace.visualstudio.com/items?itemName=ggml-org.llama-vscode
echo    https://github.com/ggml-org/llama.vscode
echo.
echo  Official llama.cpp:
echo    https://github.com/ggml-org/llama.cpp
echo    https://github.com/ggml-org/llama.cpp/releases
echo.
echo  AMD Windows ROCm llama.cpp package:
echo    https://rocm.docs.amd.com/projects/radeon-ryzen/en/latest/docs/advanced/advancedrad/windows/llm/llamacpp.html
echo.
echo  AMD Windows ROCm compatibility matrix:
echo    https://rocm.docs.amd.com/projects/radeon-ryzen/en/latest/docs/compatibility/compatibilityrad/windows/windows_compatibility.html
echo.
echo  AMD ROCm llama.cpp documentation:
echo    https://rocm.docs.amd.com/projects/llama-cpp/en/docs-26.02/install/llama-cpp-install.html
echo.
echo  Continue llama.cpp provider:
echo    https://docs.continue.dev/customize/model-providers/more/llamacpp
echo.
echo  Qwen / Ollama qwen3.8:
echo    https://ollama.com/library/qwen3.8
echo    https://huggingface.co/ggml-org/Qwen3.8-27B-GGUF
echo.
echo  Qwen3.5 fast local-agent model:
echo    https://huggingface.co/unsloth/Qwen3.5-9B-GGUF
echo.
echo  AMD Vulkan and UMA guidance:
echo    https://www.amd.com/en/resources/support-articles/faqs/PA-280.html
echo.
echo  --------------------------------------------------------------------------------------------------------------
echo  Created by Matt Hurley - matthurley.dev
echo  ----------------------------------------------------------------------------------------------------------------
echo.
call :wait_for_key
goto :menu

:view_log
cls
color 0F
echo.
echo  VIEWING THE LATEST RUN LOG
echo  The log is stored under the managed install directory.
echo.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" -Action ViewLog
echo.
call :wait_for_key
goto :menu

:read_active_model
set "ACTIVE_ALIAS="
set "ACTIVE_NAME="
if not exist "%INSTALL_ROOT%\active-model.json" exit /b 0
for /f "usebackq tokens=1* delims=|" %%A in (`powershell.exe -NoLogo -NoProfile -Command "try { $m = ConvertFrom-Json (Get-Content -Raw -LiteralPath (Join-Path $env:LOCALAPPDATA 'Programs\llama.cpp\active-model.json')); Write-Output ($m.alias + '|' + $m.name) } catch { }"`) do (
    set "ACTIVE_ALIAS=%%A"
    set "ACTIVE_NAME=%%B"
)
exit /b 0

:wait_for_key
if defined LLAMACPP_NO_PAUSE exit /b 0
pause
exit /b 0

:done
cls
color 0A
echo.
echo  ========================================================================================================
echo   Thank you for using the llama.cpp for Windows command center.
echo   Created by Matt Hurley - matthurley.dev
echo  ========================================================================================================
echo.
echo  Official project: https://github.com/ggml-org/llama.cpp
echo  VS Code extension: https://marketplace.visualstudio.com/items?itemName=ggml-org.llama-vscode
echo.
exit /b 0
