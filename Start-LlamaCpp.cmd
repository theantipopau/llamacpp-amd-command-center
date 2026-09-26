@echo off
setlocal EnableExtensions EnableDelayedExpansion
chcp 65001 <nul >nul 2>&1
mode con: cols=120 lines=50 <nul >nul 2>&1
title llama.cpp Command Center - AMD Radeon and Ryzen

rem ============================================================================
rem  LLAMA.CPP COMMAND CENTER FOR AMD WINDOWS PCs
rem  Created by Matt Hurley - matthurley.dev
rem
rem  Double-click this file. It never installs or downloads anything without
rem  asking first. Install-LlamaCpp-AMD.ps1 (kept next to this file) does the
rem  hardware scan, installation, verified model downloads, and VS Code setup.
rem
rem  Note: delayed expansion is on, so screen text must not contain the
rem  exclamation mark character.
rem ============================================================================

set "SCRIPT_DIR=%~dp0"
set "PS_SCRIPT=%SCRIPT_DIR%Install-LlamaCpp-AMD.ps1"
set "PS_RUN=powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%""
set "INSTALL_ROOT=%LOCALAPPDATA%\Programs\llama.cpp"
set "SERVER_CMD=%INSTALL_ROOT%\Start-LlamaCpp.cmd"
set "API_URL=http://127.0.0.1:8080"
set "EXTENSION_ID=ggml-org.llama-vscode"

rem ANSI colours (Windows 10 and 11 consoles and Windows Terminal).
for /f %%e in ('echo prompt $E^| cmd') do set "ESC=%%e"
set "R=%ESC%[0m"
set "B=%ESC%[1m"
set "DIM=%ESC%[90m"
set "CYAN=%ESC%[96m"
set "GREEN=%ESC%[92m"
set "YELLOW=%ESC%[93m"
set "RED=%ESC%[91m"
set "WHITE=%ESC%[97m"
set "MAG=%ESC%[95m"
set "OK_BADGE=%ESC%[30;102m"
set "WARN_BADGE=%ESC%[30;103m"
set "OFF_BADGE=%ESC%[97;100m"
set "BAD_BADGE=%ESC%[97;101m"
set "LINE=%DIM%  ----------------------------------------------------------------------------------------------------%R%"

if not exist "%PS_SCRIPT%" (
    echo.
    echo  %RED%%B%Install-LlamaCpp-AMD.ps1 is missing.%R%
    echo  Keep it in the same folder as this file. Expected:
    echo    "%PS_SCRIPT%"
    echo.
    echo  If you downloaded a ZIP, extract the whole ZIP first instead of running
    echo  this file from inside it.
    echo.
    call :wait_for_key
    exit /b 1
)

rem ============================================================================
rem  MAIN MENU
rem ============================================================================
:menu
call :read_status
cls
echo.
echo  %CYAN%%B%  LLAMA.CPP COMMAND CENTER%R%  %DIM%for AMD Radeon and Ryzen PCs%R%
echo  %DIM%  Run AI models privately on your own PC and use them in VS Code. No cloud account needed.%R%
echo %LINE%
echo.
echo  %WHITE%%B%  STATUS%R%
if defined ACTIVE_ALIAS (
    echo     Model       %WHITE%%ACTIVE_NAME%%R%  %DIM%id %ACTIVE_ALIAS%, memory %ACTIVE_CTX% tokens%R%
) else (
    echo     Model       %OFF_BADGE% NONE YET %R%  %DIM%choose [1] to set one up%R%
)
if "%SERVER_STATE%"=="running" echo     AI server   %OK_BADGE% RUNNING %R%  %DIM%%API_URL%%R%
if "%SERVER_STATE%"=="loading" echo     AI server   %WARN_BADGE% STARTING %R%  %DIM%loading the model into GPU memory...%R%
if "%SERVER_STATE%"=="stopped" echo     AI server   %OFF_BADGE% STOPPED %R%
if "%VSCODE_STATE%"=="yes" echo     VS Code     %OK_BADGE% CONNECTED %R%  %DIM%Copilot Chat can use this model%R%
if "%VSCODE_STATE%"=="stale" echo     VS Code     %WARN_BADGE% NEEDS UPDATE %R%  %DIM%set up for a different model - choose [6]%R%
if "%VSCODE_STATE%"=="no" echo     VS Code     %OFF_BADGE% NOT SET UP %R%
echo.
call :next_step
echo  %YELLOW%%B%  NEXT STEP%R%  %YELLOW%%NEXT_STEP%%R%
echo %LINE%
echo.
echo  %MAG%  GET STARTED%R%
echo     %CYAN%[1]%R%  %WHITE%Setup and models%R%        %DIM%Scan your PC, install llama.cpp, download or switch models%R%
echo.
echo  %MAG%  RUN%R%
echo     %CYAN%[2]%R%  %WHITE%Start AI server%R%         %DIM%Opens in its own window - leave it open while you work%R%
echo     %CYAN%[3]%R%  %WHITE%Stop AI server%R%          %DIM%Frees your GPU memory for games and other apps%R%
echo     %CYAN%[4]%R%  %WHITE%Chat in your browser%R%    %DIM%Talk to the model in the built-in Web UI%R%
echo     %CYAN%[5]%R%  %WHITE%Health check%R%            %DIM%Tests chat, tool calling, and memory in about 10 seconds%R%
echo     %CYAN%[M]%R%  %WHITE%Live monitor%R%            %DIM%Watch server status and speed refresh every 2 seconds%R%
echo.
echo  %MAG%  CONNECT%R%
echo     %CYAN%[6]%R%  %WHITE%Connect VS Code%R%         %DIM%Adds the model to GitHub Copilot Chat - asks before changing anything%R%
echo     %CYAN%[7]%R%  %WHITE%Other editors%R%           %DIM%llama-vscode extension, Continue, Cline and other tools%R%
echo.
echo  %MAG%  HELP%R%
echo     %CYAN%[8]%R%  %WHITE%Beginner guide%R%          %DIM%What everything means, step by step, plus official links%R%
echo     %CYAN%[9]%R%  %WHITE%Logs and fixes%R%          %DIM%Latest run log and answers to common problems%R%
echo     %CYAN%[0]%R%  %WHITE%Exit%R%
echo %LINE%
echo  %DIM%  Created by Matt Hurley - matthurley.dev%R%
echo.
set "choice="
set /p "choice=  Choose an option: "
if defined choice set "choice=%choice:~0,1%"
if not defined choice set "choice=0"

if "%choice%"=="1" goto :setup
if "%choice%"=="2" goto :start_server
if "%choice%"=="3" goto :stop_server
if "%choice%"=="4" goto :open_webui
if "%choice%"=="5" goto :health_check
if /I "%choice%"=="M" goto :live_monitor
if "%choice%"=="6" goto :vscode
if "%choice%"=="7" goto :editors
if "%choice%"=="8" goto :guide
if "%choice%"=="9" goto :logs
if "%choice%"=="0" goto :done

echo.
echo  %YELLOW%Please choose a number from the menu.%R%
timeout /t 2 /nobreak >nul 2>&1
goto :menu

rem ============================================================================
rem  [1] SETUP AND MODELS
rem ============================================================================
:setup
cls
call :header "SETUP AND MODELS"
echo   The next screen scans your CPU, graphics card, and memory, then recommends
echo   the best model for your PC. From there you can:
echo.
echo     %CYAN%[1]%R%  First-time setup     install llama.cpp and the recommended model
echo     %CYAN%[2]%R%  Model browser        compare, download, or switch models
echo     %CYAN%[5]%R%  Update llama.cpp     keeps all downloaded models
echo     %CYAN%[6]%R%  Diagnostics          if something is not working
echo.
echo   %GREEN%Nothing is downloaded until you type YES.%R% The first setup downloads
echo   about 6 GB for the recommended model and usually takes 10 to 20 minutes.
echo.
call :wait_for_key
%PS_RUN% %*
set "EXIT_CODE=%ERRORLEVEL%"
echo.
if not "%EXIT_CODE%"=="0" (
    echo  %RED%The setup screen closed with an error, code %EXIT_CODE%.%R% Choose [9] to read the log.
) else (
    echo  %GREEN%Back from setup.%R% If you changed the model, stop and start the AI server to use it.
)
call :wait_for_key
goto :menu

rem ============================================================================
rem  [2] START AI SERVER
rem ============================================================================
:start_server
cls
call :header "START AI SERVER"
call :read_status
if "%SERVER_STATE%"=="running" (
    echo   %GREEN%The AI server is already running.%R%
    echo   Web UI and API: %WHITE%%API_URL%%R%
    echo.
    call :wait_for_key
    goto :menu
)
if not exist "%SERVER_CMD%" (
    echo   %YELLOW%No model is set up yet.%R%
    echo   Choose %CYAN%[1] Setup and models%R% first. It installs llama.cpp and a model that fits your PC.
    echo.
    call :wait_for_key
    goto :menu
)
if "%SERVER_STATE%"=="stopped" (
    echo   Opening the server in its own window: %WHITE%"llama.cpp AI server"%R%
    echo   %DIM%Keep that window open while you use the model. Closing it stops the server.%R%
    echo.
    start "llama.cpp AI server" "%SERVER_CMD%"
)
<nul set /p "=  Loading %ACTIVE_NAME% into GPU memory "
set /a WAITED=0
:start_wait
call :server_ready
if "%READY%"=="1" goto :start_ready
set /a WAITED+=2
if %WAITED% geq 180 goto :start_slow
<nul set /p "=."
ping -n 3 127.0.0.1 >nul
goto :start_wait

:start_ready
echo.
echo.
echo   %OK_BADGE% READY %R%  %GREEN%The AI server is running.%R%  %DIM%took about %WAITED% seconds%R%
echo.
echo     Web UI   %WHITE%%API_URL%/%R%           %DIM%menu option [4] opens it%R%
echo     API      %WHITE%%API_URL%/v1%R%         %DIM%for VS Code, Continue, Cline and other tools%R%
echo.
if not "%VSCODE_STATE%"=="yes" (
    echo   Next: choose %CYAN%[6] Connect VS Code%R% to use this model in GitHub Copilot Chat.
) else (
    echo   VS Code is already connected. Pick %WHITE%%ACTIVE_NAME% - llama.cpp local%R% in the Copilot Chat model list.
)
echo.
call :wait_for_key
goto :menu

:start_slow
echo.
echo.
echo   %YELLOW%The server has not reported ready after 3 minutes.%R%
echo   Look at the %WHITE%llama.cpp AI server%R% window for an error message, or choose [9] for common fixes.
echo   Large models can take longer to load the first time. You can check again with [5].
echo.
call :wait_for_key
goto :menu

rem ============================================================================
rem  [3] STOP AI SERVER
rem ============================================================================
:stop_server
cls
call :header "STOP AI SERVER"
tasklist /fi "imagename eq llama-server.exe" 2>nul | find /i "llama-server.exe" >nul
if errorlevel 1 (
    echo   The AI server is not running. Nothing to stop.
    echo.
    call :wait_for_key
    goto :menu
)
echo   This stops the local AI server and frees its GPU memory.
echo   Anything using the model, such as a VS Code chat in progress, will stop getting replies.
echo.
set "confirm="
set /p "confirm=  Type Y to stop the server: "
if /i not "%confirm%"=="Y" (
    echo.
    echo   Cancelled. The server is still running.
    echo.
    call :wait_for_key
    goto :menu
)
taskkill /im llama-server.exe /f >nul 2>&1
echo.
echo   %GREEN%The AI server has stopped.%R% You can close its window. Start it again any time with [2].
echo.
call :wait_for_key
goto :menu

rem ============================================================================
rem  [4] CHAT IN YOUR BROWSER
rem ============================================================================
:open_webui
cls
call :header "CHAT IN YOUR BROWSER"
call :server_ready
if not "%READY%"=="1" (
    echo   %YELLOW%The AI server is not running yet.%R% Choose [2] to start it, then try again.
    echo.
    call :wait_for_key
    goto :menu
)
echo   Opening %WHITE%%API_URL%/%R% in your default browser.
echo   %DIM%The Web UI talks only to the server on this PC. Nothing is sent to the internet.%R%
start "" "%API_URL%/"
echo.
call :wait_for_key
goto :menu

rem ============================================================================
rem  [5] HEALTH CHECK
rem ============================================================================
:health_check
cls
call :header "HEALTH CHECK"
%PS_RUN% -Action SelfTest <nul
echo.
call :wait_for_key
goto :menu

rem ============================================================================
rem  [M] LIVE MONITOR
rem ============================================================================
:live_monitor
cls
call :header "LIVE MONITOR"
%PS_RUN% -Action Monitor
goto :menu

rem ============================================================================
rem  [6] CONNECT VS CODE
rem ============================================================================
:vscode
cls
call :header "CONNECT VS CODE (GITHUB COPILOT CHAT)"
if not defined ACTIVE_ALIAS (
    echo   %YELLOW%No model is set up yet.%R% Choose [1] first, then come back here.
    echo.
    call :wait_for_key
    goto :menu
)
echo   This adds %WHITE%%ACTIVE_NAME%%R% to the model list in GitHub Copilot Chat.
echo.
echo     %GREEN%+%R%  Your Copilot sign-in, settings, and cloud models are kept as they are.
echo     %GREEN%+%R%  A backup of the VS Code model settings file is made first.
echo     %GREEN%+%R%  Only the entry named "llama.cpp local" is added or updated.
echo.
%PS_RUN% -Action VSCodeChat
set "VSCODE_EXIT=%ERRORLEVEL%"
call :read_status
if not "%VSCODE_EXIT%"=="0" set "VSCODE_STATE=unchanged"
if not "%VSCODE_STATE%"=="yes" (
    echo.
    echo   %YELLOW%VS Code was not changed.%R% Read the message above, or use the manual steps in [7].
    echo.
    call :wait_for_key
    goto :menu
)
echo.
echo  %WHITE%%B%  NOW IN VS CODE%R%
echo     1. Press %WHITE%Ctrl+Shift+P%R%, type %WHITE%Reload Window%R%, and press Enter.
echo     2. Open Copilot Chat with %WHITE%Ctrl+Alt+I%R%.
echo     3. Click the model name under the chat box and choose %WHITE%%ACTIVE_NAME% - llama.cpp local%R%.
echo     4. Pick %WHITE%Agent%R% to let it read and edit files, or %WHITE%Ask%R% for questions.
echo.
echo   %DIM%Keep the AI server running [2] while you use it. Switch back to a cloud model any time%R%
echo   %DIM%from the same model list.%R%
echo.
call :wait_for_key
goto :menu

rem ============================================================================
rem  [7] OTHER EDITORS
rem ============================================================================
:editors
cls
call :header "OTHER EDITORS AND TOOLS"
echo     %CYAN%[1]%R%  %WHITE%llama-vscode%R%       %DIM%Official llama.cpp extension for VS Code: completion, chat, agents%R%
echo     %CYAN%[2]%R%  %WHITE%Continue%R%           %DIM%Point Continue's config.yaml at your local server%R%
echo     %CYAN%[3]%R%  %WHITE%Cline and others%R%   %DIM%Settings for any tool that accepts an OpenAI-compatible server%R%
echo     %CYAN%[0]%R%  %WHITE%Back%R%
echo.
set "sub="
set /p "sub=  Choose an option: "
if "%sub%"=="1" goto :install_extension
if "%sub%"=="2" goto :continue_template
if "%sub%"=="3" goto :openai_settings
goto :menu

:install_extension
cls
call :header "INSTALL THE llama-vscode EXTENSION"
echo   Extension ID: %WHITE%%EXTENSION_ID%%R%   %DIM%published by ggml.org, the llama.cpp team%R%
echo.
set "CODE_CMD="
for /f "delims=" %%I in ('where code 2^>nul') do if not defined CODE_CMD set "CODE_CMD=%%I"
if not defined CODE_CMD for /f "delims=" %%I in ('powershell.exe -NoLogo -NoProfile -Command "$c=Get-Command code -ErrorAction SilentlyContinue; if ($null -ne $c) { $c.Source }"') do if not defined CODE_CMD set "CODE_CMD=%%I"
if not defined CODE_CMD (
    echo   %YELLOW%The VS Code "code" command was not found.%R% That is common and does not mean
    echo   VS Code is missing. Install the extension from inside VS Code instead:
    echo.
    echo     1. Open VS Code and click %WHITE%Extensions%R% on the left, or press Ctrl+Shift+X.
    echo     2. Search for %WHITE%llama-vscode%R% and click Install.
    echo.
    echo   %DIM%Get VS Code: https://code.visualstudio.com/download%R%
    echo.
    call :wait_for_key
    goto :menu
)
echo   Installing with: %DIM%"%CODE_CMD%"%R%
call "%CODE_CMD%" --install-extension %EXTENSION_ID%
if errorlevel 1 (
    echo.
    echo   %RED%The extension could not be installed.%R% Try installing it from inside VS Code as above.
    echo.
    call :wait_for_key
    goto :menu
)
echo.
echo   %GREEN%llama-vscode is installed.%R%
if not defined ACTIVE_ALIAS (
    echo   %DIM%Set up a model with [1] on the main menu, then come back here to point it at your server.%R%
    echo.
    call :wait_for_key
    goto :menu
)
echo.
echo   This sets llama-vscode's endpoint settings to your local server. Everything else in
echo   VS Code's settings.json is left untouched, and a backup is made first.
%PS_RUN% -Action LlamaVscodeConfig
echo.
echo   %DIM%Reload VS Code (Ctrl+Shift+P, "Developer: Reload Window") to pick up the change.%R%
echo.
call :wait_for_key
goto :menu

:continue_template
cls
call :header "CONTINUE SETTINGS"
if not defined ACTIVE_ALIAS (
    echo   %YELLOW%No model is set up yet.%R% Choose [1] first so the settings use the right model.
    echo.
    call :wait_for_key
    goto :menu
)
echo   This writes (or updates) a managed block in Continue's own config file:
echo     %WHITE%%USERPROFILE%%R%\.continue\config.yaml
echo   A backup is made first, and if you already have your own models: list there,
echo   nothing is changed automatically - you get the exact lines to paste instead.
echo.
%PS_RUN% -Action ContinueConfig
echo.
echo     1. Install the %WHITE%Continue%R% extension in VS Code if you have not already.
echo     2. Start the AI server with [2].
echo     3. Choose %WHITE%%ACTIVE_NAME%%R% - llama.cpp local in Continue's model picker.
echo.
call :wait_for_key
goto :menu

:openai_settings
cls
call :header "CLINE AND OTHER OPENAI-COMPATIBLE TOOLS"
echo   Choose the %WHITE%OpenAI Compatible%R% provider in your tool and enter:
echo.
echo     Base URL   %WHITE%%API_URL%/v1%R%
if defined ACTIVE_ALIAS (echo     Model      %WHITE%%ACTIVE_ALIAS%%R%) else (echo     Model      %DIM%set up a model with [1] first%R%)
echo     API key    %WHITE%local%R%   %DIM%any text works - the server is on your PC and needs no key%R%
echo.
echo   %DIM%The server listens on 127.0.0.1 only, so other computers on your network cannot reach it.%R%
echo.
echo  %WHITE%%B%  MANUAL COPILOT CHAT SETUP%R%  %DIM%if you prefer not to use option [6]%R%
echo     1. In VS Code run %WHITE%Chat: Manage Language Models%R%.
echo     2. Choose %WHITE%Add Models%R%, then %WHITE%Custom Endpoint%R%, then %WHITE%Chat Completions%R%.
echo     3. Endpoint %WHITE%%API_URL%/v1/chat/completions%R%, the model above, and API key %WHITE%local%R%.
echo     4. Turn on Tools and Vision, set the input limit to about 57000 tokens, and reload VS Code.
echo.
call :wait_for_key
goto :menu

rem ============================================================================
rem  [8] BEGINNER GUIDE
rem ============================================================================
:guide
cls
call :header "BEGINNER GUIDE"
echo  %WHITE%%B%  WHAT THIS DOES%R%
echo    It runs an AI language model on your own graphics card with llama.cpp, then lets VS Code
echo    and your browser talk to it. Your code and questions stay on your PC. No subscription.
echo.
echo  %WHITE%%B%  THE FIVE STEPS%R%
echo    %CYAN%1%R%  %WHITE%[1] Setup and models%R%  Scans your PC and recommends a model. On a 16 GB Radeon
echo       RX 9070 XT that is Qwen3.5 9B: about 6 GB to download, fits fully in GPU memory,
echo       and answers at around 60 to 90 words per second.
echo    %CYAN%2%R%  %WHITE%[2] Start AI server%R%   Loads the model. Keep its window open while you work.
echo    %CYAN%3%R%  %WHITE%[5] Health check%R%      Confirms chat, tool calling, and memory all work.
echo    %CYAN%4%R%  %WHITE%[6] Connect VS Code%R%   Adds the model to GitHub Copilot Chat.
echo    %CYAN%5%R%  %WHITE%Use it%R%                In Copilot Chat pick the model, then Agent or Ask.
echo.
echo  %WHITE%%B%  WORDS YOU WILL SEE%R%
echo    %WHITE%Model%R%          The AI itself: a large file ending in .gguf.
echo    %WHITE%ROCm / Vulkan%R%  Two ways to run on an AMD GPU. ROCm is faster on supported Radeon cards;
echo                   Vulkan works almost everywhere. The setup picks for you.
echo    %WHITE%VRAM%R%           Memory on your graphics card. Models that fit in it are much faster.
echo    %WHITE%Context%R%        How much text the model can keep in mind at once, in tokens. Copilot Agent
echo                   mode needs at least 32768; the recommended setup uses 65536.
echo    %WHITE%Tool calling%R%   Lets the model ask VS Code to read files or run commands - needed for Agent mode.
echo    %WHITE%Thinking%R%       Turned off for tool-capable models, because it made Copilot show
echo                   "Sorry, no response was returned".
echo.
echo  %WHITE%%B%  GOOD TO KNOW%R%
echo    - Copilot stays installed. Switch between cloud and local models in the chat model list.
echo    - The server only listens on this PC, 127.0.0.1, not your network.
echo    - Stop the server with [3] before gaming to free GPU memory.
echo    - Files live in %DIM%%INSTALL_ROOT%%R%
echo.
echo  %WHITE%%B%  OFFICIAL LINKS%R%
echo    Project and docs   %DIM%https://github.com/theantipopau/llamacpp-amd-command-center%R%
echo    llama.cpp          %DIM%https://github.com/ggml-org/llama.cpp%R%
echo    llama-vscode       %DIM%https://marketplace.visualstudio.com/items?itemName=ggml-org.llama-vscode%R%
echo    AMD ROCm llama.cpp %DIM%https://rocm.docs.amd.com/projects/radeon-ryzen/en/latest/docs/advanced/advancedrad/windows/llm/llamacpp.html%R%
echo    Qwen3.5 9B model   %DIM%https://huggingface.co/unsloth/Qwen3.5-9B-GGUF%R%
echo    Continue           %DIM%https://docs.continue.dev/customize/model-providers/more/llamacpp%R%
echo.
call :wait_for_key
goto :menu

rem ============================================================================
rem  [9] LOGS AND FIXES
rem ============================================================================
:logs
cls
%PS_RUN% -Action ViewLog <nul
echo.
echo %LINE%
echo  %WHITE%%B%  COMMON PROBLEMS%R%
echo    %YELLOW%Health check says the server is not reachable%R%
echo      Start it with [2] and wait for READY. Loading takes 10 to 60 seconds.
echo    %YELLOW%VS Code: "No lowest priority node found"%R%
echo      The model's memory is too small for Copilot. In [1] open the model browser and
echo      activate the model again - it now uses 65536 tokens - then restart the server.
echo    %YELLOW%VS Code: "Sorry, no response was returned"%R%
echo      Re-activate the model in [1] so thinking is turned off, then restart the server.
echo    %YELLOW%VS Code: "Server error: 500"%R%
echo      Two large requests arrived at once. Re-activate the model in [1] to get the
echo      two-conversation server settings, then restart the server.
echo    %YELLOW%The model is not in the Copilot model list%R%
echo      Run [6] again, then Reload Window in VS Code.
echo    %YELLOW%Replies are very slow%R%
echo      The model may be too big for your GPU. Pick one marked VRAM in the model browser.
echo    %YELLOW%Graphics card not detected%R%
echo      Update the AMD Adrenalin driver, restart Windows, then run Diagnostics from [1].
echo.
echo   %DIM%When asking for help, share the log above and the matching -summary.json file from%R%
echo   %DIM%%INSTALL_ROOT%\logs. Common keys and tokens are removed automatically.%R%
echo.
call :wait_for_key
goto :menu

rem ============================================================================
rem  HELPERS
rem ============================================================================
:header
echo.
echo  %CYAN%%B%  %~1%R%
echo %LINE%
echo.
exit /b 0

:read_status
set "ACTIVE_ALIAS="
set "ACTIVE_NAME="
set "ACTIVE_CTX="
set "SERVER_STATE=stopped"
set "VSCODE_STATE=no"
for /f "usebackq tokens=1-5 delims=|" %%A in (`powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" -Action Status ^<nul 2^>nul`) do (
    if not "%%A"=="-" set "ACTIVE_ALIAS=%%A"
    if not "%%B"=="-" set "ACTIVE_NAME=%%B"
    if not "%%C"=="-" set "ACTIVE_CTX=%%C"
    set "SERVER_STATE=%%D"
    set "VSCODE_STATE=%%E"
)
exit /b 0

:next_step
if not defined ACTIVE_ALIAS (
    set "NEXT_STEP=Choose [1] to scan your PC and set up your first model."
    exit /b 0
)
if "%SERVER_STATE%"=="stopped" (
    set "NEXT_STEP=Choose [2] to start the AI server."
    exit /b 0
)
if "%SERVER_STATE%"=="loading" (
    set "NEXT_STEP=The model is loading. Wait a moment, then choose [5] to check it."
    exit /b 0
)
if not "%VSCODE_STATE%"=="yes" (
    set "NEXT_STEP=Choose [6] to use this model in VS Code Copilot Chat."
    exit /b 0
)
set "NEXT_STEP=All set. In Copilot Chat, pick %ACTIVE_NAME% - llama.cpp local."
exit /b 0

:server_ready
set "READY=0"
curl.exe -s -m 2 "%API_URL%/health" 2>nul | findstr /r /c:"status.:.ok" >nul && set "READY=1"
exit /b 0

:wait_for_key
if defined LLAMACPP_NO_PAUSE exit /b 0
echo  %DIM%  Press any key to continue...%R%
pause >nul
exit /b 0

:done
cls
echo.
echo  %CYAN%%B%  Thanks for using the llama.cpp Command Center.%R%
echo.
call :read_status
if "%SERVER_STATE%"=="running" (
    echo   %DIM%The AI server is still running in its own window, so VS Code can keep using it.%R%
    echo   %DIM%Close that window, or run this again and choose [3], to stop it.%R%
    echo.
)
echo   %DIM%Created by Matt Hurley - matthurley.dev%R%
echo   %DIM%https://github.com/theantipopau/llamacpp-amd-command-center%R%
echo.
exit /b 0
