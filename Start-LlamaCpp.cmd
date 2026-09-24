@echo off
setlocal EnableExtensions EnableDelayedExpansion
chcp 65001 >nul 2>&1
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
cls
color 0B
echo.
echo  =============================================================================
echo   LLAMA.CPP FOR WINDOWS        AMD CPU + GPU CONTROL CENTER
echo  =============================================================================
echo   Created by Matt Hurley - matthurley.dev
echo.
echo   [L] Local LLM engine       llama.cpp server + Web UI
echo   [M] Model layer            verified GGUF models with hardware fit advice
echo   [V] VS Code layer          official llama-vscode, Continue, and Cline
echo   [A] API layer              local OpenAI-compatible endpoint
echo.
echo   MENU
echo   ---------------------------------------------------------------------
echo   [1] Open the interactive llama.cpp command center
echo   [2] Start the active local llama.cpp model server
echo   [3] Install the official llama-vscode VS Code extension
echo   [4] Create a safe Continue llama.cpp configuration template
echo   [5] Show Cline / OpenAI-compatible connection settings
echo   [6] Test the local llama.cpp OpenAI-compatible API
echo   [7] Show the complete walkthrough and technical notes
echo   [8] Show official links and author information
echo   [0] Exit
echo   ---------------------------------------------------------------------
echo.
set "choice="
set /p "choice=Select an option: "
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
echo  ---------------------------------------------------------------------
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
    echo  No generated server launcher was found yet.
    echo  Choose [1] and run the one-click installer first.
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
echo  ---------------------------------------------------------------------
echo  Extension: llama-vscode
echo  Publisher: ggml.org / ggml.ai
echo  ID: %EXTENSION_ID%
echo.
echo  This extension provides local completion, chat, and agent features.
echo  It can also manage llama.cpp environments and local models.
echo.
where code >nul 2>&1
if errorlevel 1 (
    color 0E
    echo  VS Code command was not found on PATH.
    echo  Install VS Code first, reopen this window, and choose [3] again.
    echo  Official download: https://code.visualstudio.com/download
    echo.
    call :wait_for_key
    goto :menu
)
echo  Installing the official extension now...
code --install-extension %EXTENSION_ID%
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
echo  ---------------------------------------------------------------------
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
(
    echo name: Local llama.cpp
    echo version: 0.0.1
    echo schema: v1
    echo.
    echo models:
    echo   - name: Qwen3.8 27B
    echo     provider: llama.cpp
    echo     model: qwen3.8:latest
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
echo    4. Select Qwen3.8 27B as the model.
echo.
call :wait_for_key
goto :menu

:cline_settings
cls
color 0B
echo.
echo  CLINE / OPENAI-COMPATIBLE SETTINGS
echo  ---------------------------------------------------------------------
echo  Provider:       OpenAI Compatible
echo  Base URL:       %API_URL%/v1
echo  Model:          qwen3.8:latest
echo  API key:        any non-empty placeholder, for example: local-llama
echo.
echo  The local server is bound to 127.0.0.1, so it is not exposed to your LAN.
echo  Start the server with option [2] before testing Cline.
echo.
echo  If the extension offers a native llama.cpp provider, the OpenAI-compatible
echo  provider is usually the most straightforward connection method.
echo.
call :wait_for_key
goto :menu

:test_api
cls
color 0B
echo.
echo  TESTING THE LOCAL LLAMA.CPP API
echo  ---------------------------------------------------------------------
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
echo  =============================================================================
echo   COMPLETE WALKTHROUGH: LLAMA.CPP TO VISUAL STUDIO CODE
echo  =============================================================================
echo.
echo  STEP 1 - DETECT HARDWARE
echo  ---------------------------------------------------------------------
echo  The PowerShell command center detects:
echo    - AMD Ryzen / EPYC CPU cores and threads
echo    - Radeon dGPU and Ryzen iGPU devices
echo    - True DXGI dedicated VRAM, avoiding the WMI 4 GiB reporting cap
echo    - System RAM, Vulkan loader, and AMD driver state
echo.
echo  STEP 2 - SELECT THE BACKEND
echo  ---------------------------------------------------------------------
echo  Auto mode selects:
echo    - AMD ROCm 7.2.1 for supported Radeon dGPUs such as RX 9070 XT
echo    - Vulkan for Ryzen iGPUs, older Radeon cards, and unsupported GPUs
echo.
echo  ROCm is AMD's validated Windows path for supported Radeon hardware.
echo  Vulkan is the portable fallback and uses the AMD Vulkan driver.
echo.
echo  STEP 3 - INSTALL LLAMA.CPP
echo  ---------------------------------------------------------------------
echo  The command center downloads the official backend package, verifies the
echo  available upstream SHA-256 digest, extracts llama-server.exe, validates
echo  the runtime, and preserves models during updates.
echo.
echo  STEP 4 - INSTALL A GGUF MODEL
echo  ---------------------------------------------------------------------
echo  The recommended model for a Radeon RX 9070 XT with 16 GB VRAM and 32 GB
echo  system RAM is Qwen3.8-27B Q4_K_M.
echo.
echo  Ollama name:       qwen3.8:latest
echo  llama.cpp alias:   qwen3.8:latest
echo  Model weights:     Qwen3.8-27B-Q4_K_M.gguf
echo  Vision projector:  mmproj-Qwen3.8-27B-Q8_0.gguf
echo  Download:          approximately 18.25 GiB including projector
echo.
echo  The script resolves Hugging Face metadata at download time and verifies
echo  each Git LFS SHA-256 digest.
echo.
echo  STEP 5 - START THE LOCAL SERVER
echo  ---------------------------------------------------------------------
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
echo  ---------------------------------------------------------------------
echo  Official llama-vscode extension:
echo    code --install-extension %EXTENSION_ID%
echo.
echo  Continue:
echo    provider: llama.cpp
echo    apiBase:  %API_URL%
echo    model:    qwen3.8:latest
echo.
echo  Cline or another OpenAI-compatible extension:
echo    Base URL: %API_URL%/v1
echo    Model:    qwen3.8:latest
echo    API key:  any non-empty placeholder
echo.
echo  STEP 7 - TEST THE CONNECTION
echo  ---------------------------------------------------------------------
echo  From this menu choose [6], or run:
echo    Invoke-RestMethod %API_MODELS_URL%
echo.
echo  If the response includes qwen3.8:latest, the server is ready for VS Code.
echo.
echo  IMPORTANT MODEL NOTE
echo  ---------------------------------------------------------------------
echo  Qwen3.8 is a strong general reasoning, chat, tool, and vision model.
echo  The official llama-vscode extension may perform best for inline completion
echo  with an FIM-capable coding model. The general model remains suitable for
echo  chat, editing, and agent workflows.
echo.
call :wait_for_key
goto :menu

:links
cls
color 0F
echo.
echo  OFFICIAL INFORMATION AND LINKS
echo  =============================================================================
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
echo  AMD Vulkan and UMA guidance:
echo    https://www.amd.com/en/resources/support-articles/faqs/PA-280.html
echo.
echo  -----------------------------------------------------------------------------
echo  Created by Matt Hurley - matthurley.dev
echo  -----------------------------------------------------------------------------
echo.
call :wait_for_key
goto :menu

:wait_for_key
if defined LLAMACPP_NO_PAUSE exit /b 0
pause
exit /b 0

:done
cls
color 0A
echo.
echo  =============================================================================
echo   Thank you for using the llama.cpp for Windows command center.
echo   Created by Matt Hurley - matthurley.dev
echo  =============================================================================
echo.
echo  Official project: https://github.com/ggml-org/llama.cpp
echo  VS Code extension: https://marketplace.visualstudio.com/items?itemName=ggml-org.llama-vscode
echo.
exit /b 0
