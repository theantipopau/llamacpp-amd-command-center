param(
    [string] $ExePath = '',
    [int] $DebugPort = 0
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$desktop = Split-Path -Parent $PSScriptRoot
$exe = if ($ExePath) { [IO.Path]::GetFullPath($ExePath) } else { Join-Path $desktop 'src-tauri\target\release\llamacpp-command-center-desktop.exe' }
$trayHelper = Join-Path $PSScriptRoot 'tray-menu.ps1'
$cdpHelper = Join-Path $PSScriptRoot 'cdp-open-chat.js'
$stub = Join-Path $PSScriptRoot 'fixtures\backend.ps1'
$install = Join-Path ([IO.Path]::GetTempPath()) ('cc-desktop-lifecycle-' + [guid]::NewGuid().ToString('N'))
$chat = Join-Path $install 'Chat.cmd'
$configDir = Join-Path $env:APPDATA 'org.local.llamacpp.commandcenter'
$config = Join-Path $configDir 'desktop-settings.json'
$originalConfig = if (Test-Path -LiteralPath $config) { [IO.File]::ReadAllText($config) } else { $null }
$oldScript = $env:LLAMACPP_SCRIPT
$oldRoot = $env:LLAMACPP_INSTALL_ROOT
$oldDebug = $env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS
$script:App = $null
$script:Failures = 0
$script:Steps = @()
$script:ErrorText = $null
$script:BaselineHandles = @()

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class DesktopLifecycleWindows {
    public delegate bool EnumProc(IntPtr hwnd, IntPtr lparam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lparam);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr hwnd, StringBuilder text, int count);
    public static long[] ConsoleHandles() {
        var found = new List<long>();
        EnumWindows(delegate(IntPtr hwnd, IntPtr unused) {
            if (!IsWindowVisible(hwnd)) return true;
            var name = new StringBuilder(128);
            GetClassName(hwnd, name, name.Capacity);
            var value = name.ToString();
            if (value == "ConsoleWindowClass" || value == "CASCADIA_HOSTING_WINDOW_CLASS") found.Add(hwnd.ToInt64());
            return true;
        }, IntPtr.Zero);
        return found.ToArray();
    }
}
'@

function Assert-True([bool] $Condition, [string] $Message) {
    if ($Condition) {
        Write-Host "  PASS  $Message" -ForegroundColor Green
    } else {
        Write-Host "  FAIL  $Message" -ForegroundColor Red
        $script:Failures++
    }
}

function Get-NewConsoleWindows {
    $current = @([DesktopLifecycleWindows]::ConsoleHandles())
    return @($current | Where-Object { $script:BaselineHandles -notcontains $_ }).Count
}

function Get-StubLaunchers {
    return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -eq 'powershell.exe' -and
        $_.CommandLine -and
        $_.CommandLine.IndexOf($stub, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and
        $_.CommandLine -like '*-RuntimeAction start*'
    })
}

function Get-ChatHelpers {
    return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -eq 'cmd.exe' -and
        $_.CommandLine -and
        $_.CommandLine.IndexOf($chat, [StringComparison]::OrdinalIgnoreCase) -ge 0
    })
}

function Wait-Until([scriptblock] $Condition, [int] $Seconds, [string] $What) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        if (& $Condition) { return }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    throw "timed out waiting for $What"
}

function Invoke-Tray([string] $Action) {
    $text = & $trayHelper -ProcessId $script:App.Id -Action $Action 2>&1 | Out-String
    if (-not $text.Trim()) { throw "tray $Action returned no result" }
    return ($text | ConvertFrom-Json)
}

function Wait-Main {
    $deadline = (Get-Date).AddSeconds(30)
    do {
        Start-Sleep -Milliseconds 250
        try { $script:App.Refresh() } catch { throw 'app exited before its window appeared' }
        if ($script:App.HasExited) { throw 'app exited before its window appeared' }
    } while ((Get-Date) -lt $deadline -and $script:App.MainWindowHandle -eq 0)
    if ($script:App.MainWindowHandle -eq 0) { throw 'app window did not appear' }
}

function Start-App {
    if (-not (Test-Path -LiteralPath $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }
    [IO.File]::WriteAllText($config, '{"start_minimised_to_tray":false}', (New-Object System.Text.UTF8Encoding($false)))
    $env:LLAMACPP_SCRIPT = $stub
    $env:LLAMACPP_INSTALL_ROOT = $install
    $env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--remote-debugging-port=$DebugPort"
    try {
        $script:App = Start-Process -FilePath $exe -PassThru
    } finally {
        $env:LLAMACPP_SCRIPT = $oldScript
        $env:LLAMACPP_INSTALL_ROOT = $oldRoot
        $env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = $oldDebug
    }
    Wait-Main
    Start-Sleep -Seconds 4
}

function Stop-App {
    if ($null -ne $script:App -and $null -ne (Get-Process -Id $script:App.Id -ErrorAction SilentlyContinue)) {
        Stop-Process -Id $script:App.Id -Force -ErrorAction SilentlyContinue
    }
    Get-StubLaunchers | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Get-ChatHelpers | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath (Join-Path $install 'stub-running.flag') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $install 'stub-starting.flag') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $install 'stub-launcher.pid') -Force -ErrorAction SilentlyContinue
    $script:App = $null
}

function Add-Step([string] $Name) {
    $script:Steps += [pscustomobject]@{
        step = $Name
        windows = (Get-NewConsoleWindows)
        launchers = @(Get-StubLaunchers).Count
        chat_helpers = @(Get-ChatHelpers).Count
        app_alive = if ($null -ne $script:App) { $null -ne (Get-Process -Id $script:App.Id -ErrorAction SilentlyContinue) } else { $false }
    }
}

try {
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        throw "release executable not found: $exe. Run 'npm run build' first."
    }
    if (@(Get-Process -Name 'llamacpp-command-center-desktop' -ErrorAction SilentlyContinue).Count -gt 0) {
        throw 'the desktop app is already running; refusing to test over it'
    }
    if (@(Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue).Count -gt 0) {
        throw 'a llama-server is already running; refusing to test on top of it'
    }

    if ($DebugPort -le 0) {
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $DebugPort = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
        $listener.Stop()
    }

    New-Item -ItemType Directory -Path $install -Force | Out-Null
    [IO.File]::WriteAllText($chat, "@echo off`r`n>`"%~dp0chat-ran.flag`" echo yes`r`n:wait`r`ngoto wait`r`n", (New-Object System.Text.ASCIIEncoding))
    Remove-Item -LiteralPath (Join-Path $install 'stub-running.flag'),(Join-Path $install 'stub-starting.flag'),(Join-Path $install 'stub-launcher.pid'),(Join-Path $install 'chat-ran.flag') -Force -ErrorAction SilentlyContinue

    $script:BaselineHandles = @([DesktopLifecycleWindows]::ConsoleHandles())
    Start-App
    Assert-True ((Get-NewConsoleWindows) -eq 0) 'launch opens no terminal window'
    Assert-True (@(Get-StubLaunchers).Count -eq 0) 'launch starts no server launcher'
    Add-Step 'launch'

    $null = Invoke-Tray 'Start'
    Wait-Until { Test-Path -LiteralPath (Join-Path $install 'stub-running.flag') } 20 'stub server'
    Wait-Until { @(Get-StubLaunchers).Count -eq 1 } 10 'one server launcher'
    Assert-True ((Get-NewConsoleWindows) -eq 0) 'Start opens no terminal window'
    Assert-True (@(Get-StubLaunchers).Count -eq 1) 'Start owns exactly one launcher'
    Add-Step 'start'

    $null = Invoke-Tray 'Start'
    Start-Sleep -Seconds 2
    Assert-True ((Get-NewConsoleWindows) -eq 0) 'duplicate Start opens no terminal window'
    Assert-True (@(Get-StubLaunchers).Count -eq 1) 'duplicate Start does not create a second launcher'
    Add-Step 'start_again'

    $null = Invoke-Tray 'Stop'
    Wait-Until { -not (Test-Path -LiteralPath (Join-Path $install 'stub-running.flag')) } 20 'stub stop'
    Wait-Until { @(Get-StubLaunchers).Count -eq 0 } 15 'launcher exit after stop'
    Wait-Until { (Get-NewConsoleWindows) -eq 0 } 15 'no console window after stop'
    Assert-True ((Get-NewConsoleWindows) -eq 0) 'Stop leaves no terminal window'
    Assert-True (@(Get-StubLaunchers).Count -eq 0) 'Stop leaves no server launcher'
    Add-Step 'stop'

    $null = Invoke-Tray 'Start'
    Wait-Until { @(Get-StubLaunchers).Count -eq 1 } 20 'server launcher before quit'
    $null = Invoke-Tray 'Quit'
    Wait-Until { @(Get-Process -Id $script:App.Id -ErrorAction SilentlyContinue).Count -eq 0 } 25 'app exit after quit'
    Wait-Until { @(Get-StubLaunchers).Count -eq 0 } 15 'launcher exit after quit'
    Wait-Until { (Get-NewConsoleWindows) -eq 0 } 15 'no console window after quit'
    Assert-True (@(Get-StubLaunchers).Count -eq 0) 'Quit stops the server launcher'
    Assert-True ((Get-NewConsoleWindows) -eq 0) 'Quit leaves no terminal window'
    Add-Step 'quit'
    $script:App = $null

    Remove-Item -LiteralPath (Join-Path $install 'chat-ran.flag') -Force -ErrorAction SilentlyContinue
    Start-App
    $chatOutput = & node.exe $cdpHelper ([string]$DebugPort) 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "Open chat could not be clicked: $chatOutput" }
    Wait-Until { Test-Path -LiteralPath (Join-Path $install 'chat-ran.flag') } 30 'hidden Chat.cmd marker'
    Wait-Until { @(Get-ChatHelpers).Count -eq 1 } 10 'one live hidden chat helper'
    Wait-Until { @(Get-StubLaunchers).Count -eq 1 } 10 'server launcher behind chat'
    Assert-True (@(Get-ChatHelpers).Count -eq 1) 'Open chat leaves exactly one live hidden helper'
    Assert-True (@(Get-StubLaunchers).Count -eq 1) 'Open chat leaves exactly one server launcher'
    Assert-True ((Get-NewConsoleWindows) -eq 0) 'Open chat opens no terminal window'
    Add-Step 'open_chat'

    $null = Invoke-Tray 'Quit'
    Wait-Until { @(Get-Process -Id $script:App.Id -ErrorAction SilentlyContinue).Count -eq 0 } 25 'app exit after chat quit'
    Wait-Until { @(Get-StubLaunchers).Count -eq 0 } 15 'launcher exit after chat quit'
    Wait-Until { @(Get-ChatHelpers).Count -eq 0 } 15 'hidden chat helper exit after quit'
    Wait-Until { (Get-NewConsoleWindows) -eq 0 } 15 'no console window after chat quit'
    Assert-True (@(Get-ChatHelpers).Count -eq 0) 'Quit shuts down the hidden chat helper'
    Assert-True (@(Get-StubLaunchers).Count -eq 0) 'Quit shuts down the server launcher after chat'
    Assert-True ((Get-NewConsoleWindows) -eq 0) 'Quit leaves no terminal window after chat'
    Add-Step 'chat_quit'
    $script:App = $null
} catch {
    $script:ErrorText = [string]$_.Exception.Message
    Write-Host "  FAIL  $script:ErrorText" -ForegroundColor Red
} finally {
    Stop-App
    if ($null -ne $originalConfig) {
        [IO.File]::WriteAllText($config, $originalConfig, (New-Object System.Text.UTF8Encoding($false)))
    } else {
        Remove-Item -LiteralPath $config -Force -ErrorAction SilentlyContinue
    }
    $env:LLAMACPP_SCRIPT = $oldScript
    $env:LLAMACPP_INSTALL_ROOT = $oldRoot
    $env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = $oldDebug
    $result = [ordered]@{
        exe = $exe
        exe_sha256 = if (Test-Path -LiteralPath $exe) { (Get-FileHash -Algorithm SHA256 -LiteralPath $exe).Hash } else { '' }
        steps = $script:Steps
        failures = $script:Failures
        error = $script:ErrorText
    }
    $result | ConvertTo-Json -Depth 6
    Remove-Item -LiteralPath $install -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Failures -gt 0 -or $null -ne $script:ErrorText) {
    exit 1
}
exit 0
