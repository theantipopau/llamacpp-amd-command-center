<#
.SYNOPSIS
    Visual all-in-one llama.cpp command center for Windows AMD CPU/GPU systems.

.DESCRIPTION
    Launches an interactive terminal dashboard that can:

      * Detect the CPU, physical/logical cores, system RAM, and DXGI GPU memory.
      * Recommend a quality model that fits the detected hardware.
      * Install the latest official llama.cpp Windows x64 Vulkan build or AMD's
        validated Windows ROCm package, depending on detected hardware.
      * Download verified GGUF models from ggml-org Hugging Face repositories.
      * Activate a model, generate launch scripts, and start the local Web UI/API.
      * Configure the active model as a native VS Code Copilot Chat custom endpoint
        while preserving unrelated VS Code settings and creating a backup.
      * Run device diagnostics, update llama.cpp without deleting models, and uninstall.

    Backend selection:
      * Auto uses AMD's validated ROCm 7.2.1 Windows package for supported Radeon
        dGPUs such as the Radeon RX 9070 XT, and uses Vulkan everywhere else.
      * ROCm is the preferred path for supported discrete Radeon hardware because
        it exposes HIP kernels directly. The package targets gfx110X/gfx115X/gfx120X.
      * Vulkan is the portable fallback for Ryzen iGPUs, older Radeon cards, and
        systems not present in AMD's Windows support matrix.
      * ROCmLatest (opt-in only) installs llama.cpp's own Windows ROCm build. It needs
        AMD's ROCm runtime libraries installed separately, so setup keeps it only if
        llama-server --list-devices shows a dedicated ROCm GPU, and rolls back otherwise.
      * AMD's linked llama.cpp 26.02 installation page is a Linux ROCm guide. The
        Windows-specific validated package is documented on AMD's Radeon Windows
        llama.cpp page, which this script uses.
      * Visual Studio, CMake, Ninja, Clang, Git, and the Vulkan SDK are source-build
        tools, not runtime prerequisites for these prebuilt packages.

    Model catalog:
      * All primary model files are published by ggml-org.
      * Model metadata, revisions, sizes, and Git LFS SHA-256 values are resolved from
        Hugging Face over HTTPS immediately before download.
      * Ollama's qwen3.8:latest currently means Qwen3.8-27B, not an 8B model.
      * The recommendation prefers the strongest tool-capable model that fits entirely
        in dedicated VRAM (Qwen3.5-9B on a 16 GB Radeon). Larger models that spill
        into system RAM are offered as a slower quality option.
      * Context size is sized from spare VRAM. Tool-capable models get at least 32k
        tokens where possible because VS Code Copilot Agent mode needs that much.

    Hardware guidance:
      * A current AMD Adrenalin driver must expose a Vulkan device.
      * APUs share system RAM with the GPU. Keep UMA Frame Buffer Size / UMA Cache
        Size on Auto unless your firmware setting is demonstrably limiting the iGPU.
      * A 32 GB system is recommended for Qwen3.8-27B Q4_K_M; 64 GB+ is preferable
        when the Radeon GPU does not have enough dedicated VRAM for the model.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install-LlamaCpp-AMD.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install-LlamaCpp-AMD.ps1 -DryRun

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install-LlamaCpp-AMD.ps1 -Action Install -ModelId qwen3.8-27b

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install-LlamaCpp-AMD.ps1 -Action Models -ModelId qwen3.5-9b -ContextSize 32768

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install-LlamaCpp-AMD.ps1 -Action Launch

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install-LlamaCpp-AMD.ps1 -Action Uninstall

.NOTES
    Research sources checked 2026-09-28:
      https://github.com/ggml-org/llama.cpp/blob/master/docs/build.md
      https://github.com/ggml-org/llama.cpp/releases/latest
      https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md
      https://ollama.com/library/qwen3.8/tags
      https://huggingface.co/ggml-org
      https://rocm.blogs.amd.com/artificial-intelligence/language-models-locally/README.html
      https://rocm.docs.amd.com/projects/llama-cpp/en/docs-26.02/install/llama-cpp-install.html
      https://rocm.docs.amd.com/projects/radeon-ryzen/en/latest/docs/advanced/advancedrad/windows/llm/llamacpp.html
      https://rocm.docs.amd.com/projects/radeon-ryzen/en/latest/docs/compatibility/compatibilityrad/windows/windows_compatibility.html
      https://www.amd.com/en/resources/support-articles/faqs/PA-280.html
      https://repo.radeon.com/rocm/llama.cpp/windows/ (rocm-rel-7.2.1 is still the newest)
      https://github.com/ggml-org/llama.cpp/blob/master/.github/workflows/release.yml (windows-rocm job)

    Research sources re-verified 2026-10-08 (see docs/research/upstream-evidence.md):
      https://repo.radeon.com/rocm/llama.cpp/windows/ index still ends at rocm-rel-7.2.1,
        file llama-b8407-windows-rocm-7.2.1-gfx110X-gfx115X-gfx120X-x64.zip = 565651083 bytes.
      https://api.github.com/repos/ggml-org/llama.cpp/releases/latest = v0.6.0 (nightly-tag.txt only);
        nightly b11481 publishes llama-b11481-bin-win-vulkan-x64.zip and -bin-win-rocm-10.0-x64.zip.
      Every catalog GGUF file exists at its Hugging Face repo with a Git LFS SHA-256;
        pinned revisions and sizes are recorded in tests/fixtures/catalog-evidence.json.
      ggml-org/gemma-4-12B-it-GGUF publishes no Q4_K_M file; the catalog now uses its Q4_0.
#>

[CmdletBinding()]
param(
    [ValidateSet('Dashboard', 'Install', 'Advisor', 'Models', 'Launch', 'Update', 'Diagnostics', 'VSCodeChat', 'Uninstall', 'ViewLog', 'Status', 'State', 'Snapshot', 'Recommend', 'Diagnose', 'Runtime', 'Tune', 'SelfTest', 'Monitor', 'CheckUpdate', 'ContinueConfig', 'LlamaVscodeConfig', 'ListInstalled', 'Activate', 'RemoveModel', 'Easy', 'Preflight', 'IdleSleep', 'Shortcuts', 'RemoveShortcuts', 'Settings', 'Library', 'Gui', 'GameWatch', 'Benchmark')]
    [string] $Action = 'Dashboard',
    [string] $InstallRoot = (Join-Path $env:LOCALAPPDATA 'Programs\llama.cpp'),
    [string] $SettingsPatch = '',
    [string] $LibraryAction = '',
    [string] $ModelId = 'auto',
    [ValidateSet('Auto', 'Vulkan', 'ROCm', 'ROCmLatest')]
    [string] $Backend = 'Auto',
    [ValidateRange(0, 262144)]
    [int] $ContextSize = 0,
    [ValidateRange(1, 65535)]
    [int] $Port = 8080,
    [ValidateSet('Auto', 'On', 'Off')]
    [string] $Thinking = 'Auto',
    [ValidateSet('health', 'start', 'stop', 'update', 'rollback', 'updates')]
    [string] $RuntimeAction = 'health',
    [string] $RuntimeAdapter = 'llamacpp',
    [ValidateSet('Plan', 'Start', 'Status', 'Cancel', 'Results', 'Resume', 'Worker')]
    [string] $TuneAction = 'Plan',
    [switch] $TuneSmoke,
    [string] $TuneJobId = '',
    [ValidateRange(0, 1440)]
    [int] $IdleMinutes = 0,
    [ValidateSet('', 'chat', 'coding', 'images', 'fast', 'quality')]
    [string] $UseCase = '',
    [switch] $SkipModel,
    [switch] $NoPath,
    [switch] $Force,
    [switch] $DryRun,
    [switch] $Uninstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

# ---------------------------------------------------------------------
# Catalogue loading (ADR-004)
# catalog/*.json next to this script is the single source of truth for models,
# runtimes, compatibility and hardware profiles. There is deliberately no
# embedded copy to drift against: a missing or broken file fails loudly.
# ---------------------------------------------------------------------

$script:CatalogDirectory = Join-Path $PSScriptRoot 'catalog'
$script:CatalogCache = @{}
# How many state snapshots to keep; taken automatically before state-changing actions.
$script:StateSnapshotKeep = 40

function Get-CatalogDirectory {
    # The catalog folder sits next to this script (repository checkout or release ZIP).
    $override = Get-Variable -Name 'CatalogDirectory' -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if (-not [string]::IsNullOrWhiteSpace([string]$override)) { return [string]$override }
    return (Join-Path $PSScriptRoot 'catalog')
}

function Get-CatalogJson {
    # One versioned JSON document per catalogue file, cached for the session.
    # Missing or malformed files throw with the exact path: better a clear error
    # than silently running on stale built-in data.
    param([string] $Name)
    $cache = Get-Variable -Name 'CatalogCache' -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($null -eq $cache) { $cache = @{}; $script:CatalogCache = $cache }
    if ($cache.ContainsKey($Name)) { return $cache[$Name] }
    $path = Join-Path (Get-CatalogDirectory) $Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Catalogue file not found: $path. The catalog folder must sit next to Install-LlamaCpp-AMD.ps1 - re-extract the release ZIP or re-clone the repository."
    }
    try {
        $document = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    } catch {
        throw "Catalogue file is not valid JSON: $path ($($_.Exception.Message))"
    }
    $cache[$Name] = $document
    return $document
}

$script:CommandCenterVersion = '0.3.0'
$script:CommandCenterRepo = 'theantipopau/llamacpp-amd-command-center'
$script:GitHubApi = 'https://api.github.com/repos/ggml-org/llama.cpp/releases'
$script:GitHubHeaders = @{
    Accept = 'application/vnd.github+json'
    'User-Agent' = 'llamacpp-amd-command-center'
    'X-GitHub-Api-Version' = '2022-11-28'
}
$script:HfApi = 'https://huggingface.co/api/models'
# Two server slots share one KV pool sized for two full conversations. VS Code sends
# a compaction/summary request while an Agent turn is still running; with a pool
# only one conversation deep, both fail with "Context size has been exceeded" (500).
$script:ServerSlots = 2
# Set only by Easy start after the user typed YES once for the whole plan, so the
# individual download prompts are not asked again. Unlike -Force it keeps every safety check.
$script:AssumeYes = $false
# The script's own file: the install folder's copy for the game watcher is made from it.
$script:ScriptSource = $PSCommandPath
# Set by the Settings write: the banner writers keep logging but print nothing, so
# stdout stays exactly one JSON document for the desktop window.
$script:JsonDocumentsOnly = $false
$script:HfRepositoryCache = @{}
# Runtime package facts come from catalog/runtimes.json (verified 2026-10-08; see the
# research date in this script's .NOTES). checked_on is the day the package was last
# hand-checked against AMD's page. Freshness is time-based only: no scraping of AMD's
# page, so it never depends on a page layout that can change.
$amdPackage = (Get-CatalogJson -Name 'runtimes.json').amd_rocm_package
$script:AmdRocmPackageUrl = [string]$amdPackage.url
$script:AmdRocmPackageName = [string]$amdPackage.name
$script:AmdRocmPackageSize = [long]$amdPackage.size
$script:AmdRocmPage = [string]$amdPackage.page
$script:AmdRocmPackageCheckedOn = [DateTime]::Parse([string]$amdPackage.checked_on, [System.Globalization.CultureInfo]::InvariantCulture)
$script:AmdRocmPackageFreshnessDays = [int]$amdPackage.freshness_days
# Fail fast when any catalogue file is missing or broken, instead of half-way through
# an install on a user's machine.
foreach ($catalogFile in 'models.json', 'hardware_profiles.json', 'compatibility.json') { $null = Get-CatalogJson -Name $catalogFile }

# ---------------------------------------------------------------------
# Visual terminal helpers
# ---------------------------------------------------------------------

function Clear-Screen {
    try { Clear-Host } catch { }
}

$script:RunLogDirectory = $null
$script:RunLogPath = $null
$script:RunJsonlPath = $null
$script:RunSummaryPath = $null
$script:RunStarted = $null
$script:RunTranscriptStarted = $false

function Get-RunLogDirectory {
    if ([string]::IsNullOrWhiteSpace($script:RunLogDirectory)) {
        $script:RunLogDirectory = Join-Path $InstallRoot 'logs'
    }
    return $script:RunLogDirectory
}

function Protect-LogText {
    param([AllowNull()][string] $Text)
    if ($null -eq $Text) { return '' }
    $safe = [string]$Text
    $safe = [regex]::Replace($safe, '(?i)(api[_ -]?key|token|authorization|bearer)\s*[:=]\s*\S+', '$1=[REDACTED]')
    $safe = [regex]::Replace($safe, '(?i)sk-[A-Za-z0-9_-]{10,}', '[REDACTED]')
    return $safe
}

function Write-RunLogEvent {
    param(
        [string] $Event = 'info',
        [AllowNull()][string] $Message = '',
        [hashtable] $Data = @{}
    )
    if ([string]::IsNullOrWhiteSpace($script:RunJsonlPath)) { return }
    $record = [ordered]@{
        timestamp = (Get-Date).ToUniversalTime().ToString('o')
        event = $Event
        message = Protect-LogText $Message
        data = $Data
    }
    try {
        ($record | ConvertTo-Json -Compress -Depth 8) | Add-Content -LiteralPath $script:RunJsonlPath -Encoding UTF8
    } catch { }
}

function Start-RunLogging {
    try {
        $directory = Get-RunLogDirectory
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $runId = (Get-Date).ToString('yyyyMMdd-HHmmss') + '-' + $PID
        $script:RunLogPath = Join-Path $directory ("run-$runId.log")
        $script:RunJsonlPath = Join-Path $directory ("run-$runId.jsonl")
        $script:RunSummaryPath = Join-Path $directory ("run-$runId-summary.json")
        $script:RunStarted = Get-Date
        Set-Content -LiteralPath $script:RunLogPath -Value ("llama.cpp AMD Command Center run $runId") -Encoding UTF8
        try {
            Start-Transcript -Path $script:RunLogPath -Append | Out-Null
            $script:RunTranscriptStarted = $true
        } catch {
            $script:RunTranscriptStarted = $false
        }
        Write-RunLogEvent -Event 'run_started' -Message 'Run started.' -Data @{
            action = $Action
            backend = $Backend
            model_id = $ModelId
            install_root = $InstallRoot
            port = $Port
            dry_run = [bool]$DryRun
            force = [bool]$Force
        }
    } catch {
        $script:RunLogPath = $null
        $script:RunJsonlPath = $null
        $script:RunSummaryPath = $null
    }
}

function Complete-RunLogging {
    param(
        [ValidateSet('completed', 'failed', 'cancelled')][string] $Status = 'completed',
        [AllowNull()][string] $Message = ''
    )
    if ([string]::IsNullOrWhiteSpace($script:RunLogPath)) { return }
    $ended = Get-Date
    Write-RunLogEvent -Event 'run_finished' -Message $Message -Data @{
        status = $Status
        duration_seconds = [Math]::Round(($ended - $script:RunStarted).TotalSeconds, 2)
    }
    if ($script:RunTranscriptStarted) {
        try { Stop-Transcript | Out-Null } catch { }
        $script:RunTranscriptStarted = $false
    }
    $summary = [ordered]@{
        run_id = [IO.Path]::GetFileNameWithoutExtension($script:RunLogPath)
        started_at = $script:RunStarted.ToUniversalTime().ToString('o')
        finished_at = $ended.ToUniversalTime().ToString('o')
        duration_seconds = [Math]::Round(($ended - $script:RunStarted).TotalSeconds, 2)
        status = $Status
        action = $Action
        backend = $Backend
        model_id = $ModelId
        install_root = $InstallRoot
        port = $Port
        log_file = $script:RunLogPath
        jsonl_file = $script:RunJsonlPath
        message = Protect-LogText $Message
    }
    try {
        $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:RunSummaryPath -Encoding UTF8
        Copy-Item -LiteralPath $script:RunLogPath -Destination (Join-Path (Get-RunLogDirectory) 'latest.log') -Force
        Copy-Item -LiteralPath $script:RunSummaryPath -Destination (Join-Path (Get-RunLogDirectory) 'latest-summary.json') -Force
    } catch { }
}

function Show-LatestRunLog {
    $directory = Get-RunLogDirectory
    $latest = Join-Path $directory 'latest.log'
    if ((-not [string]::IsNullOrWhiteSpace($script:RunLogPath)) -and (Test-Path -LiteralPath $script:RunLogPath -PathType Leaf)) {
        $latest = $script:RunLogPath
    }
    if (-not (Test-Path -LiteralPath $latest -PathType Leaf)) {
        $candidate = Get-ChildItem -LiteralPath $directory -Filter 'run-*.log' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($null -eq $candidate) {
            Write-Host '  No run log exists yet. Start the command center once to create one.' -ForegroundColor Yellow
            return
        }
        $latest = $candidate.FullName
    }
    Clear-Screen
    Show-Banner
    Write-Host "  LATEST RUN LOG" -ForegroundColor White
    Write-Host "  $latest" -ForegroundColor Cyan
    Write-Host "  Showing the final 80 lines. Full log: $latest" -ForegroundColor DarkGray
    Write-Host ''
    Get-Content -LiteralPath $latest -Tail 80 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_ }
}

function Write-Step {
    param([string] $Message)
    Write-RunLogEvent -Event 'step' -Message $Message
    if ($script:JsonDocumentsOnly) { return }
    Write-Host "`n  ║ " -NoNewline -ForegroundColor DarkCyan
    Write-Host $Message -ForegroundColor Cyan
}

function Write-Info {
    param([string] $Message)
    Write-RunLogEvent -Event 'info' -Message $Message
    if ($script:JsonDocumentsOnly) { return }
    Write-Host "  ║ " -NoNewline -ForegroundColor DarkGray
    Write-Host $Message -ForegroundColor Gray
}

function Write-Success {
    param([string] $Message)
    Write-RunLogEvent -Event 'success' -Message $Message
    if ($script:JsonDocumentsOnly) { return }
    Write-Host "  ║ " -NoNewline -ForegroundColor DarkGreen
    Write-Host $Message -ForegroundColor Green
}

function Write-WarnLine {
    param([string] $Message)
    Write-RunLogEvent -Event 'warning' -Message $Message
    if ($script:JsonDocumentsOnly) { return }
    Write-Host "  ║ " -NoNewline -ForegroundColor DarkYellow
    Write-Host $Message -ForegroundColor Yellow
}

function Limit-Text {
    param([AllowNull()][string] $Text, [int] $Length)
    if ($null -eq $Text) { return '' }
    $clean = $Text -replace '[\r\n\t]', ' '
    if ($clean.Length -le $Length) { return $clean }
    if ($Length -le 3) { return $clean.Substring(0, $Length) }
    return $clean.Substring(0, $Length - 3) + '...'
}

function Get-MemoryBar {
    param([double] $Value, [double] $Maximum, [int] $Width = 18)
    if ($Maximum -le 0) { $ratio = 0 } else { $ratio = $Value / $Maximum }
    if ($ratio -lt 0) { $ratio = 0 }
    if ($ratio -gt 1) { $ratio = 1 }
    $filled = [int][Math]::Round($ratio * $Width)
    return ('[' + ('█' * $filled) + ('░' * ($Width - $filled)) + ']')
}

function Format-Bytes {
    param([long] $Bytes)
    if ($Bytes -ge 1TB) { return ('{0:N2} TiB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N2} GiB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MiB' -f ($Bytes / 1MB)) }
    return ('{0:N0} bytes' -f $Bytes)
}

function Read-ConsoleLine {
    param([string] $Prompt = '')
    $value = Read-Host $Prompt
    if ($null -eq $value) { return '' }
    return ([string]$value).Trim()
}

function Pause-Screen {
    param([string] $Message = 'Press Enter to return to the command center')
    if ($Force) { return }
    Write-Host "`n  " -NoNewline
    [void](Read-ConsoleLine -Prompt $Message)
}

function Show-Banner {
    # Built from a fixed inner width so the right border always lines up.
    $inner = 80
    $h = [string][char]0x2550; $v = [string][char]0x2551; $dot = [string][char]0x2022
    $right = "LOCAL $dot PRIVATE $dot GPU+CPU  "
    $pad = $inner - 2 - 'LLAMA.CPP // AMD COMMAND CENTER'.Length - $right.Length
    Write-Host ('  ' + [char]0x2554 + ($h * $inner) + [char]0x2557) -ForegroundColor DarkCyan
    Write-Host "  $v  " -NoNewline -ForegroundColor DarkCyan
    Write-Host 'LLAMA.CPP' -NoNewline -ForegroundColor White
    Write-Host ' // ' -NoNewline -ForegroundColor DarkGray
    Write-Host 'AMD COMMAND CENTER' -NoNewline -ForegroundColor Magenta
    Write-Host ((' ' * $pad) + $right) -NoNewline -ForegroundColor DarkCyan
    Write-Host $v -ForegroundColor DarkCyan
    Write-Host ('  ' + [char]0x255A + ($h * $inner) + [char]0x255D) -ForegroundColor DarkCyan
    Write-Host '  Created by Matt Hurley - matthurley.dev' -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------
# Model catalog and hardware-aware recommendations
# ---------------------------------------------------------------------

function Get-ModelCatalog {
    # The nine models live in catalog/models.json (ADR-004): one versioned source
    # for the script, the tests and future tooling. Evidence for every file pin is
    # in tests/fixtures/catalog-evidence.json.
    return @((Get-CatalogJson -Name 'models.json').models)
}

function Get-DxgiGpuInventory {
    if ('LlamaCppAmd.DxgiInventory' -as [type]) {
        return @([LlamaCppAmd.DxgiInventory]::GetGpus())
    }
    $source = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace LlamaCppAmd
{
    [ComImport, Guid("aec22fb8-76f3-4639-9be0-28eb43a67a2e"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IDXGIObject
    {
        [PreserveSig] int SetPrivateData(ref Guid name, uint dataSize, IntPtr data);
        [PreserveSig] int SetPrivateDataInterface(ref Guid name, [MarshalAs(UnmanagedType.IUnknown)] object unknown);
        [PreserveSig] int GetPrivateData(ref Guid name, ref uint dataSize, IntPtr data);
        [PreserveSig] int GetParent(ref Guid iid, out IntPtr parent);
    }

    [ComImport, Guid("7b7166ec-21c7-44ae-b21a-c9ae321ae369"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IDXGIFactory : IDXGIObject
    {
        [PreserveSig] int EnumAdapters(uint index, out IntPtr adapter);
        [PreserveSig] int MakeWindowAssociation(IntPtr windowHandle, uint flags);
        [PreserveSig] int GetWindowAssociation(out IntPtr windowHandle);
        [PreserveSig] int CreateSwapChain(IntPtr device, IntPtr desc, out IntPtr swapChain);
        [PreserveSig] int CreateSoftwareAdapter(IntPtr module, out IntPtr adapter);
    }

    [ComImport, Guid("770aae78-f26f-4dba-a829-253c83d1b387"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IDXGIFactory1
    {
        [PreserveSig] int SetPrivateData(ref Guid name, uint dataSize, IntPtr data);
        [PreserveSig] int SetPrivateDataInterface(ref Guid name, [MarshalAs(UnmanagedType.IUnknown)] object unknown);
        [PreserveSig] int GetPrivateData(ref Guid name, ref uint dataSize, IntPtr data);
        [PreserveSig] int GetParent(ref Guid iid, out IntPtr parent);
        [PreserveSig] int EnumAdapters(uint index, out IntPtr adapter);
        [PreserveSig] int MakeWindowAssociation(IntPtr windowHandle, uint flags);
        [PreserveSig] int GetWindowAssociation(out IntPtr windowHandle);
        [PreserveSig] int CreateSwapChain(IntPtr device, IntPtr desc, out IntPtr swapChain);
        [PreserveSig] int CreateSoftwareAdapter(IntPtr module, out IntPtr adapter);
        [PreserveSig] int EnumAdapters1(uint index, out IDXGIAdapter1 adapter);
        [PreserveSig] int IsCurrent();
    }

    [ComImport, Guid("2411e7e1-12ac-4ccf-bd14-9798e8534dc0"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IDXGIAdapter : IDXGIObject
    {
        [PreserveSig] int EnumOutputs(uint index, out IntPtr output);
        [PreserveSig] int GetDesc(IntPtr description);
        [PreserveSig] int CheckInterfaceSupport(ref Guid guid, out long userModeDriverVersion);
    }

    [ComImport, Guid("29038f61-3839-4626-91fd-086879011a05"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IDXGIAdapter1
    {
        [PreserveSig] int SetPrivateData(ref Guid name, uint dataSize, IntPtr data);
        [PreserveSig] int SetPrivateDataInterface(ref Guid name, [MarshalAs(UnmanagedType.IUnknown)] object unknown);
        [PreserveSig] int GetPrivateData(ref Guid name, ref uint dataSize, IntPtr data);
        [PreserveSig] int GetParent(ref Guid iid, out IntPtr parent);
        [PreserveSig] int EnumOutputs(uint index, out IntPtr output);
        [PreserveSig] int GetDesc(IntPtr description);
        [PreserveSig] int CheckInterfaceSupport(ref Guid guid, out long userModeDriverVersion);
        [PreserveSig] int GetDesc1(IntPtr description);
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    internal struct AdapterDesc1
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Description;
        public uint VendorId;
        public uint DeviceId;
        public uint SubSysId;
        public uint Revision;
        public ulong DedicatedVideoMemory;
        public ulong DedicatedSystemMemory;
        public ulong SharedSystemMemory;
        public long AdapterLuid;
        public uint Flags;
    }

    public sealed class GpuInfo
    {
        public string Name { get; set; }
        public uint VendorId { get; set; }
        public ulong DedicatedVideoMemory { get; set; }
        public ulong SharedSystemMemory { get; set; }
    }

    public static class DxgiInventory
    {
        [DllImport("dxgi.dll", CallingConvention = CallingConvention.StdCall)]
        private static extern int CreateDXGIFactory1(ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out IDXGIFactory1 factory);

        public static List<GpuInfo> GetGpus()
        {
            var result = new List<GpuInfo>();
            IDXGIFactory1 factory;
            Guid iid = new Guid("770aae78-f26f-4dba-a829-253c83d1b387");
            if (CreateDXGIFactory1(ref iid, out factory) != 0 || factory == null) return result;
            try
            {
                for (uint index = 0; ; index++)
                {
                    IDXGIAdapter1 adapter;
                    if (factory.EnumAdapters1(index, out adapter) != 0 || adapter == null) break;
                    IntPtr description = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(AdapterDesc1)));
                    try
                    {
                        if (adapter.GetDesc1(description) == 0)
                        {
                            AdapterDesc1 desc = (AdapterDesc1)Marshal.PtrToStructure(description, typeof(AdapterDesc1));
                            result.Add(new GpuInfo {
                                Name = desc.Description == null ? "Unknown DXGI adapter" : desc.Description,
                                VendorId = desc.VendorId,
                                DedicatedVideoMemory = desc.DedicatedVideoMemory,
                                SharedSystemMemory = desc.SharedSystemMemory
                            });
                        }
                    }
                    finally
                    {
                        Marshal.FreeHGlobal(description);
                        Marshal.ReleaseComObject(adapter);
                    }
                }
            } finally { Marshal.ReleaseComObject(factory); }
            return result;
        }
    }
}
'@
    Add-Type -TypeDefinition $source -ErrorAction Stop
    return @([LlamaCppAmd.DxgiInventory]::GetGpus())
}

function Get-RegistryVideoMemoryMap {
    $map = @{}
    $classRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    try {
        foreach ($key in Get-ChildItem -LiteralPath $classRoot -ErrorAction SilentlyContinue) {
            $properties = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            if ($null -eq $properties -or [string]::IsNullOrWhiteSpace([string]$properties.DriverDesc)) { continue }
            $bytes = $properties.'HardwareInformation.MemorySize'
            $memory = 0L
            if ($bytes -is [byte[]] -and $bytes.Length -ge 8) {
                $memory = [BitConverter]::ToUInt64($bytes, 0)
            } elseif ($null -ne $bytes) {
                try { $memory = [long]$bytes } catch { $memory = 0L }
            }
            if ($memory -le 0) {
                $legacy = $properties.'HardwareInformation.qwMemorySize'
                if ($null -ne $legacy) { try { $memory = [long]$legacy } catch { } }
            }
            if ($memory -gt 0) { $map[[string]$properties.DriverDesc] = [Math]::Round(([double]$memory / 1GB), 1) }
        }
    } catch { }
    return $map
}

function Get-HardwareProfile {
    if ($env:OS -ne 'Windows_NT') { throw 'This command center only supports Windows.' }
    if (-not [Environment]::Is64BitOperatingSystem -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
        throw 'Run this script from 64-bit PowerShell on 64-bit Windows.'
    }
    if ([Environment]::OSVersion.Version -lt [Version]'10.0.19041') {
        throw 'Windows 10 build 19041 or newer is required for current Vulkan support.'
    }

    $cpuInfo = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
    $system = Get-CimInstance -ClassName Win32_ComputerSystem
    # Win32_VideoController.AdapterRAM is a uint32 and incorrectly caps many cards
    # at 4 GiB. DXGI reports true dedicated memory; registry/WMI are fast fallbacks.
    $registryMemory = Get-RegistryVideoMemoryMap
    $gpus = @()
    try {
        $gpus = @(Get-DxgiGpuInventory | ForEach-Object {
            $isAmd = $_.VendorId -eq 0x1002
            $isIntegrated = Test-IntegratedGpuName $_.Name
            [pscustomobject]@{
                Name = [string]$_.Name; IsAmd = $isAmd; IsIntegrated = $isIntegrated
                VramGiB = [Math]::Round(([double]$_.DedicatedVideoMemory / 1GB), 1)
                SharedGiB = [Math]::Round(([double]$_.SharedSystemMemory / 1GB), 1); Driver = ''
                Source = 'dxgi'; VramConfidence = 'high'
            }
        })
    } catch { $gpus = @() }

    if ($gpus.Count -eq 0) {
        $gpus = @(Get-CimInstance -ClassName Win32_VideoController | ForEach-Object {
            $name = [string]$_.Name
            $isAmd = ($name + ' ' + [string]$_.PNPDeviceID) -match '(?i)AMD|Radeon'
            $isIntegrated = Test-IntegratedGpuName $name
            $vram = 0.0
            foreach ($entry in $registryMemory.GetEnumerator()) {
                if ($name -like ('*' + $entry.Key + '*') -or $entry.Key -like ('*' + $name + '*')) {
                    if ($entry.Value -gt $vram) { $vram = [double]$entry.Value }
                }
            }
            $fromRegistry = $vram -gt 0
            if ($vram -le 0) { $vram = [Math]::Round(([double]$_.AdapterRAM / 1GB), 1) }
            [pscustomobject]@{
                Name = $name; IsAmd = $isAmd; IsIntegrated = $isIntegrated
                VramGiB = [Math]::Round($vram, 1)
                SharedGiB = if ($isIntegrated) { [Math]::Round(([double]$system.TotalPhysicalMemory / 1GB), 1) } else { 0 }
                Driver = [string]$_.DriverVersion
                Source = if ($fromRegistry) { 'registry' } else { 'wmi' }
                VramConfidence = if ($fromRegistry) { 'medium' } else { 'low' }
            }
        })
    }

    $amdGpus = @($gpus | Where-Object { $_.IsAmd })
    $maxVram = 0.0
    $amdIntegrated = $false
    foreach ($gpu in $amdGpus) {
        if ($gpu.VramGiB -gt $maxVram) { $maxVram = [double]$gpu.VramGiB }
        if ($gpu.IsIntegrated) { $amdIntegrated = $true }
    }
    if ($maxVram -le 0) { $maxVram = [Math]::Round(([double]$system.TotalPhysicalMemory / 1GB) * 0.45, 1) }

    $ramGiB = [Math]::Round(([double]$system.TotalPhysicalMemory / 1GB), 1)
    $hasAmdCpu = [string]$cpuInfo.Name -match '(?i)AMD|Ryzen|EPYC'
    $hasAmdGpu = $amdGpus.Count -gt 0
    $rocmProfiles = (Get-CatalogJson -Name 'hardware_profiles.json').rocm
    $rocmRecommendedGpu = @($amdGpus | Where-Object {
        $_.Name -match [string]$rocmProfiles.recommended_pattern
    }) | Select-Object -First 1
    $rocmRecommended = ($null -ne $rocmRecommendedGpu) -and (-not $rocmRecommendedGpu.IsIntegrated)
    $rocmReason = if ($rocmRecommended) {
        [string]$rocmProfiles.recommended_reason
    } elseif ($amdIntegrated) {
        [string]$rocmProfiles.integrated_reason
    } else {
        [string]$rocmProfiles.fallback_reason
    }
    $logical = [int]$cpuInfo.NumberOfLogicalProcessors
    $physical = [int]$cpuInfo.NumberOfCores

    $profileName = 'STARTER'
    if ($ramGiB -ge 60 -and $maxVram -ge 20) { $profileName = 'FLAGSHIP' }
    elseif ($ramGiB -ge 30 -and $maxVram -ge 10) { $profileName = 'HIGH-PERFORMANCE' }
    elseif ($ramGiB -ge 16) { $profileName = 'MAINSTREAM' }

    $modelBudget = $ramGiB * 0.78
    $executionMode = 'CPU + VULKAN'
    if ($hasAmdGpu -and $maxVram -ge 2) {
        $modelBudget = ($maxVram * 0.88) + ($ramGiB * 0.35)
        $executionMode = 'AMD dGPU OFFLOAD + CPU'
    } elseif ($hasAmdGpu) {
        $modelBudget = $ramGiB * 0.72
        $executionMode = 'UNIFIED MEMORY (iGPU + CPU)'
    }

    $hasDiscreteAmd = @($gpus | Where-Object { $_.IsAmd -and -not $_.IsIntegrated }).Count -gt 0
    $uniqueSources = @($gpus | ForEach-Object { [string]$_.Source } | Sort-Object -Unique)
    $gpuSource = if ($uniqueSources.Count -eq 0) { 'wmi' } elseif ($uniqueSources.Count -eq 1) { $uniqueSources[0] } else { 'mixed' }
    $detectionConfidence = 'high'
    if ($uniqueSources.Count -eq 0 -or $uniqueSources -contains 'wmi') { $detectionConfidence = 'low' }
    elseif ($uniqueSources -contains 'registry') { $detectionConfidence = 'medium' }

    $profile = [pscustomobject]@{
        CpuName = ([string]$cpuInfo.Name).Trim()
        CpuCores = $physical
        CpuThreads = $logical
        HasAmdCpu = $hasAmdCpu
        HasAmdGpu = $hasAmdGpu
        HasAmdIntegratedGpu = $amdIntegrated
        RocmRecommended = $rocmRecommended
        RocmGpu = if ($null -eq $rocmRecommendedGpu) { '' } else { $rocmRecommendedGpu.Name }
        RocmReason = $rocmReason
        RamGiB = $ramGiB
        MaxAmdVramGiB = $maxVram
        Gpus = $gpus
        Profile = $profileName
        ModelBudgetGiB = [Math]::Round($modelBudget, 1)
        ExecutionMode = $executionMode
        VulkanLoader = Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\vulkan-1.dll')
        HasDiscreteAmdGpu = $hasDiscreteAmd
        cpu = [pscustomobject]@{ name = ([string]$cpuInfo.Name).Trim(); cores = $physical; threads = $logical; vendor_amd = $hasAmdCpu }
        memory = [pscustomobject]@{ ram_gib = $ramGiB }
        detection = [pscustomobject]@{ gpu_source = $gpuSource; confidence = $detectionConfidence }
    }
    $profile | Add-Member -NotePropertyName 'support' -NotePropertyValue (Resolve-HardwareSupport -Hardware $profile -Confidence $detectionConfidence)
    $profile | Add-Member -NotePropertyName 'recommendation' -NotePropertyValue (Get-HardwareRecommendation -Hardware $profile -Confidence $detectionConfidence)
    return $profile
}

function Resolve-HardwareSupport {
    # Typed support verdict for the hardware profile: supported, warning or
    # unsupported, with plain-English reasons and how confident the detection was.
    # Mirrors Assert-HardwareForLlama: no Radeon at all means unsupported.
    param($Hardware, [string] $Confidence = 'high')
    $reasons = @()
    $level = 'supported'
    $names = @($Hardware.PSObject.Properties.Name)
    if (-not [bool]$Hardware.HasAmdGpu) {
        $level = 'unsupported'
        $reasons += 'No AMD Radeon graphics card was detected. This command center accelerates Radeon GPUs; CPU-only use is possible with -Force but is slow.'
    } else {
        # Partial hardware objects (foreign or minimal callers) omit the detailed
        # fields; never claim iGPU-only or a missing loader we were not told about.
        if (($names -contains 'HasDiscreteAmdGpu') -and -not [bool]$Hardware.HasDiscreteAmdGpu) {
            $level = 'warning'
            $reasons += 'Only an AMD integrated GPU was detected: models share system RAM, so large models will be slow or will not fit.'
        }
        if (($names -contains 'VulkanLoader') -and -not [bool]$Hardware.VulkanLoader) {
            if ($level -eq 'supported') { $level = 'warning' }
            $reasons += 'vulkan-1.dll was not found in System32: install a current AMD Adrenalin driver so the Vulkan fallback can run.'
        }
    }
    return [pscustomobject]@{
        level = $level
        confidence = $Confidence
        reasons = @($reasons)
    }
}

function Get-HardwareRecommendation {
    # What to install and run on this PC: the backend AMD's matrix supports, the
    # fittest model, and how confident the detection was. The reason reuses RocmReason
    # so the advice and its explanation never disagree.
    param($Hardware, [string] $Confidence = 'high')
    $backend = if ([bool]$Hardware.RocmRecommended) { 'ROCm' } else { 'Vulkan' }
    $recommendedModel = Get-RecommendedModel -Hardware $Hardware
    return [pscustomobject]@{
        backend = $backend
        model_id = if ($null -eq $recommendedModel) { '' } else { [string]$recommendedModel.Id }
        confidence = $Confidence
        reason = [string](Get-StateProperty -Object $Hardware -Name 'RocmReason' -Default '')
    }
}

function Get-ModelAssessment {
    param($Hardware)
    $catalog = @(Get-ModelCatalog | Sort-Object Rank -Descending)
    $assessments = @()
    foreach ($model in $catalog) {
        $headroom = [double]$Hardware.ModelBudgetGiB - [double]$model.ApproxGiB
        $vramHeadroom = Get-VramHeadroom -Model $model -Hardware $Hardware
        $status = 'NOT RECOMMENDED'
        $color = 'Red'
        $recommended = $false
        if ($headroom -ge 4) { $status = 'EXCELLENT'; $color = 'Green'; $recommended = $true }
        elseif ($headroom -ge 1) { $status = 'GOOD'; $color = 'Cyan'; $recommended = $true }
        elseif ($headroom -ge -1) { $status = 'TIGHT'; $color = 'Yellow'; $recommended = $true }
        # On a discrete Radeon, a model that spills out of VRAM still runs but much more
        # slowly; say so plainly rather than rating it EXCELLENT.
        if ($recommended -and $Hardware.HasAmdGpu -and $Hardware.MaxAmdVramGiB -ge 4 -and $vramHeadroom -lt 1.5) {
            $status = 'SLOWER'; $color = 'Yellow'
        }
        $assessments += [pscustomobject]@{
            Model = $model
            HeadroomGiB = [Math]::Round($headroom, 1)
            VramHeadroomGiB = [Math]::Round($vramHeadroom, 1)
            GpuResident = ($vramHeadroom -ge 1.5)
            Status = $status
            Color = $color
            Recommended = $recommended
        }
    }
    return $assessments
}

function Get-VramHeadroom {
    param($Model, $Hardware)
    # Spare dedicated VRAM after the weights; only meaningful for a discrete Radeon.
    if (-not $Hardware.HasAmdGpu -or $Hardware.MaxAmdVramGiB -lt 4) { return -1.0 }
    return ([double]$Hardware.MaxAmdVramGiB * 0.9) - [double]$Model.ApproxGiB
}

function Get-RecommendedModel {
    param($Hardware)
    $assessment = @(Get-ModelAssessment -Hardware $Hardware | Where-Object { $_.Recommended })
    # Agent use needs speed and a large context, so prefer the best tool-capable
    # model that stays entirely in VRAM over a larger model that spills to RAM.
    $resident = @($assessment | Where-Object { $_.GpuResident -and $_.Model.Tools } | Select-Object -First 1)
    if ($resident.Count -gt 0) { return $resident[0].Model }
    if ($assessment.Count -eq 0) { return (Get-ModelCatalog | Sort-Object ApproxGiB | Select-Object -First 1) }
    return $assessment[0].Model
}

function Get-SuggestedContext {
    param($Model, $Hardware)
    # VS Code Copilot Agent mode sends a large system prompt plus tool definitions.
    # Below roughly 32k tokens it cannot fit the prompt and fails with
    # "No lowest priority node found", so tool-capable models get at least 32k
    # whenever the KV cache has room.
    # KvGiBPer32k is the measured q8_0 KV cache (plus recurrent state) at 32k tokens.
    # Hybrid models such as Qwen3.5 need far less than dense ones; 2.5 GiB is a
    # conservative default for dense 4-12B models. 2 GiB is kept for compute buffers.
    $vramHeadroom = Get-VramHeadroom -Model $Model -Hardware $Hardware
    $kvPer32k = if ($Model.PSObject.Properties.Name -contains 'KvGiBPer32k') { [double]$Model.KvGiBPer32k } else { 2.5 }
    # The server keeps $script:ServerSlots conversations in one shared KV pool, so
    # each conversation's context must fit that many times over.
    $spare = $vramHeadroom - 2
    if ($spare -ge ($kvPer32k * 2 * $script:ServerSlots)) { return 65536 }
    if ($spare -ge ($kvPer32k * $script:ServerSlots)) { return 32768 }
    $budgetHeadroom = [double]$Hardware.ModelBudgetGiB - [double]$Model.ApproxGiB
    if ($Model.Tools -and $budgetHeadroom -ge 3 -and $Hardware.RamGiB -ge 30) { return 32768 }
    if ($vramHeadroom -ge 1.5 -or $Hardware.RamGiB -ge 16) { return 16384 }
    return 8192
}

function Get-UseCaseCatalog {
    return @(
        [pscustomobject]@{ Id = 'chat'; Title = 'Everyday chat and writing'; Detail = 'Questions, writing, summaries, brainstorming, video scripts.' },
        [pscustomobject]@{ Id = 'coding'; Title = 'Coding help in VS Code'; Detail = 'Writes, explains and fixes code, and can edit your files in Copilot Agent mode.' },
        [pscustomobject]@{ Id = 'images'; Title = 'Understanding pictures and screenshots'; Detail = 'Describes a photo, reads a screenshot, explains a chart.' },
        [pscustomobject]@{ Id = 'fast'; Title = 'Quick answers, easy on my PC'; Detail = 'A small, fast model that leaves most of your graphics memory free for games.' },
        [pscustomobject]@{ Id = 'quality'; Title = 'Best possible answers (slower)'; Detail = 'The biggest model your PC can hold. Replies take noticeably longer.' }
    )
}

function Resolve-UseCaseAnswer {
    param([string] $Answer)
    # Accepts the list number or the name; anything else (including Enter) means everyday chat.
    $cases = @(Get-UseCaseCatalog)
    $text = ([string]$Answer).Trim()
    $number = 0
    if ([int]::TryParse($text, [ref]$number) -and $number -ge 1 -and $number -le $cases.Count) { return [string]$cases[$number - 1].Id }
    $named = @($cases | Where-Object { $_.Id -ieq $text })
    if ($named.Count -gt 0) { return [string]$named[0].Id }
    return 'chat'
}

function Read-UseCaseChoice {
    $cases = @(Get-UseCaseCatalog)
    Write-Host "`n  What do you want to use your AI for? We suggest the model that suits it best on your PC." -ForegroundColor White
    for ($i = 0; $i -lt $cases.Count; $i++) {
        Write-Host ("    [{0}] {1}" -f ($i + 1), $cases[$i].Title) -ForegroundColor Cyan
        Write-Host "        $($cases[$i].Detail)" -ForegroundColor DarkGray
    }
    return (Resolve-UseCaseAnswer -Answer (Read-ConsoleLine -Prompt "  Choose 1-$($cases.Count), or press Enter for everyday chat"))
}

function Get-PlannedRuntime {
    param($Hardware)
    # The runtime that is installed, or the one setup would install, so a model that cannot load
    # on it is never suggested.
    $installed = Get-InstalledRuntime
    if ($null -ne $installed) { return $installed }
    if (($Hardware.PSObject.Properties.Name -contains 'RocmRecommended') -and [bool]$Hardware.RocmRecommended) {
        # The planned tag is the AMD package pinned in catalog/runtimes.json.
        return [pscustomobject]@{ backend = 'ROCm'; tag = [string](Get-CatalogJson -Name 'runtimes.json').amd_rocm_package.tag }
    }
    return $null
}

function Get-ModelForUseCase {
    param([string] $UseCase, $Hardware, $Runtime = $null)
    # Picks from the catalog by what the model can do and how well it fits this PC.
    # The assessment list is already ordered best first.
    $all = @(Get-ModelAssessment -Hardware $Hardware)
    $usable = @($all | Where-Object { $_.Recommended -and -not (Get-ModelRuntimeBlocker -Model $_.Model -Runtime $Runtime) })
    if ($usable.Count -eq 0) { $usable = @($all | Where-Object { -not (Get-ModelRuntimeBlocker -Model $_.Model -Runtime $Runtime) }) }
    $pick = $null
    switch ($UseCase) {
        'coding' {
            $pick = @($usable | Where-Object { $_.GpuResident -and $_.Model.Tools }) | Select-Object -First 1
            if ($null -eq $pick) { $pick = @($usable | Where-Object { $_.Model.Tools }) | Select-Object -First 1 }
        }
        'images' {
            $pick = @($usable | Where-Object { $_.GpuResident -and $_.Model.Vision }) | Select-Object -First 1
            if ($null -eq $pick) { $pick = @($usable | Where-Object { $_.Model.Vision }) | Select-Object -First 1 }
        }
        'fast' {
            $pick = @($usable | Where-Object { $_.Model.Tools } | Sort-Object { [double]$_.Model.ApproxGiB }) | Select-Object -First 1
            if ($null -eq $pick) { $pick = @($usable | Sort-Object { [double]$_.Model.ApproxGiB }) | Select-Object -First 1 }
        }
        'quality' { $pick = $usable | Select-Object -First 1 }
        default { $pick = @($usable | Where-Object { $_.GpuResident }) | Select-Object -First 1 }
    }
    if ($null -eq $pick) { $pick = $usable | Select-Object -First 1 }
    if ($null -eq $pick) { $pick = $all | Select-Object -First 1 }
    $why = switch ($UseCase) {
        'coding' { 'It can call tools, which lets Copilot Agent read and edit your files.' }
        'images' { 'It can look at pictures as well as read text.' }
        'fast' { 'It is small and quick, and leaves most of your graphics memory free for games.' }
        'quality' { 'It is the strongest model your PC can hold.' }
        default { 'A well-rounded model for questions, writing and summaries.' }
    }
    $where = if ($pick.GpuResident) { 'It fits in your graphics memory.' } else { 'Part of it runs from system RAM, so replies are slower.' }
    return [pscustomobject]@{
        UseCase = $UseCase
        Model = $pick.Model
        GpuResident = [bool]$pick.GpuResident
        Status = [string]$pick.Status
        Reason = "$why $where"
    }
}

function Get-ModelById {
    param([string] $Id)
    $found = @(Get-ModelCatalog | Where-Object { $_.Id -ieq $Id })
    if ($found.Count -eq 0) { throw "Unknown model id '$Id'. Run the model browser to see valid choices." }
    return $found[0]
}

# ---------------------------------------------------------------------
# Hardware intelligence layer (ADR-005): recommendation engine and runtime adapters
# ---------------------------------------------------------------------

function Resolve-RecommendationStatus {
    # Classifies one candidate for a tier: unsupported (blocked or does not fit),
    # experimental (catalogue flag), recommended (fits and fully GPU-resident),
    # supported (fits but spills into system RAM). Pure: catalogue + assessment only.
    param($Model, $Assessment, [string] $Blocker)
    if (-not [string]::IsNullOrWhiteSpace($Blocker)) { return 'unsupported' }
    if ($null -eq $Assessment -or -not [bool]$Assessment.Recommended) { return 'unsupported' }
    if ((@($Model.PSObject.Properties.Name) -contains 'Experimental') -and [bool]$Model.Experimental) { return 'experimental' }
    if ([bool]$Assessment.GpuResident) { return 'recommended' }
    return 'supported'
}

function Get-RecommendationConfidence {
    # How sure the engine is of this recommendation: detection provenance plus the
    # status verdict. No measurements are invented (ADR-005).
    param([string] $Status, [string] $DetectionConfidence)
    if ($DetectionConfidence -eq 'low' -or $Status -eq 'unsupported') { return 'low' }
    if ($DetectionConfidence -eq 'high' -and $Status -eq 'recommended') { return 'high' }
    return 'medium'
}

function Get-TierReason {
    # Plain-English reason built only from quantities the assessment already measured.
    param($Model, $Assessment, [string] $Status, [string] $Blocker)
    if ($Status -eq 'unsupported') {
        if (-not [string]::IsNullOrWhiteSpace($Blocker)) { return $Blocker }
        return "$($Model.Name) does not fit in the available memory budget (needs $($Model.ApproxGiB) GiB)."
    }
    if ($Status -eq 'experimental') {
        return "$($Model.Name) is marked experimental in the catalogue: publisher claims are not independently verified, and this project has not validated it end to end."
    }
    if ($Status -eq 'recommended') {
        # Residency is decided by graphics memory alone, so the claim and the number must both be VRAM.
        if ($null -ne $Assessment -and $Assessment.GpuResident) {
            if ($Assessment.PSObject.Properties.Name -contains 'VramHeadroomGiB') {
                return "The model stays entirely in VRAM, leaving about $($Assessment.VramHeadroomGiB) GiB after its weights for context and other apps."
            }
            return 'Stays entirely in VRAM.'
        }
        return "Fits this machine's memory budget."
    }
    return 'Runs, but slower: it does not fit entirely in graphics memory, so some of it runs from system RAM.'
}

function Get-WorkloadRecommendations {
    # The engine (ADR-005): fast/balanced/maximum picks derived purely from the
    # catalogue, the detected hardware and the planned runtime. No GPU names are
    # hardcoded - a behavioural test proves machines differing only in GPU name get
    # identical recommendations.
    param($Hardware, $Runtime = $null, [string] $DetectionConfidence = 'high')
    if ($null -eq $Runtime) { $Runtime = Get-PlannedRuntime -Hardware $Hardware }
    $budget = [double]$Hardware.ModelBudgetGiB
    $annotated = @()
    foreach ($entry in @(Get-ModelAssessment -Hardware $Hardware)) {
        $blocker = [string](Get-ModelRuntimeBlocker -Model $entry.Model -Runtime $Runtime)
        $annotated += [pscustomobject]@{ Entry = $entry; Blocker = $blocker }
    }
    $runnable = @($annotated | Where-Object { [string]::IsNullOrWhiteSpace($_.Blocker) })

    # fast: smallest tool-capable runnable model, else smallest runnable overall.
    $fastCandidates = @($runnable | Where-Object { [bool]$_.Entry.Model.Tools } | Sort-Object { [double]$_.Entry.Model.ApproxGiB })
    if ($fastCandidates.Count -eq 0) { $fastCandidates = @($runnable | Sort-Object { [double]$_.Entry.Model.ApproxGiB }) }
    $fast = if ($fastCandidates.Count -gt 0) { $fastCandidates[0] } else { @($annotated | Sort-Object { [double]$_.Entry.Model.ApproxGiB })[0] }

    # balanced: highest-ranked GPU-resident tool model, else highest-ranked recommended (Get-RecommendedModel rule).
    $balanced = $null
    $resident = @($runnable | Where-Object { $_.Entry.GpuResident -and $_.Entry.Model.Tools })
    if ($resident.Count -gt 0) { $balanced = $resident[0] }
    if ($null -eq $balanced) {
        $fitting = @($runnable | Where-Object { $_.Entry.Recommended })
        if ($fitting.Count -gt 0) { $balanced = $fitting[0] }
    }
    if ($null -eq $balanced) { $balanced = if ($runnable.Count -gt 0) { $runnable[0] } else { @($annotated)[0] } }

    # maximum: highest-ranked runnable model (assessment order is catalogue Rank order).
    $maximum = if ($runnable.Count -gt 0) { $runnable[0] } else { @($annotated)[0] }

    $tiers = @{}
    foreach ($pair in @(@('fast', $fast), @('balanced', $balanced), @('maximum', $maximum))) {
        $tierName = [string]$pair[0]
        $candidate = $pair[1]
        $model = $candidate.Entry.Model
        $assessment = $candidate.Entry
        $status = Resolve-RecommendationStatus -Model $model -Assessment $assessment -Blocker $candidate.Blocker
        $blockers = @()
        if ($status -eq 'unsupported') {
            if (-not [string]::IsNullOrWhiteSpace($candidate.Blocker)) { $blockers += [string]$candidate.Blocker }
            elseif ($null -ne $assessment) { $blockers += "Does not fit: needs $($model.ApproxGiB) GiB against a $budget GiB budget." }
        }
        $tiers[$tierName] = [pscustomobject]@{
            tier = $tierName
            model_id = [string]$model.Id
            model_name = [string]$model.Name
            status = $status
            confidence = Get-RecommendationConfidence -Status $status -DetectionConfidence $DetectionConfidence
            reason = Get-TierReason -Model $model -Assessment $assessment -Status $status -Blocker $candidate.Blocker
            gpu_resident = if ($null -eq $assessment) { $false } else { [bool]$assessment.GpuResident }
            blockers = @($blockers)
        }
    }
    $allBlockers = @(@($tiers['fast'].blockers) + @($tiers['balanced'].blockers) + @($tiers['maximum'].blockers) | Sort-Object -Unique)
    return [pscustomobject]@{
        schema_version = 1
        generated_at = (Get-Date).ToUniversalTime().ToString('o')
        detection_confidence = $DetectionConfidence
        recommended = [pscustomobject]@{
            fast = $tiers['fast']
            balanced = $tiers['balanced']
            maximum = $tiers['maximum']
        }
        blockers = @($allBlockers)
    }
}

function Get-RecommendationDocument {
    # -Action Recommend's document: never throws; a failed hardware scan degrades to
    # hardware_error with recommended = null (ADR-003 rule applied to the engine).
    $hardware = $null
    $hardwareError = $null
    try { $hardware = Get-HardwareProfile } catch { $hardwareError = [string]$_.Exception.Message }
    $tiers = $null
    $detection = $null
    $blockers = @()
    if ($null -ne $hardware) {
        $detection = 'high'
        if (@($hardware.PSObject.Properties.Name) -contains 'detection') { $detection = [string]$hardware.detection.confidence }
        $engine = Get-WorkloadRecommendations -Hardware $hardware -DetectionConfidence $detection
        $tiers = $engine.recommended
        $blockers = @($engine.blockers)
    }
    return [pscustomobject]@{
        schema_version = 1
        generated_at = (Get-Date).ToUniversalTime().ToString('o')
        command_center_version = [string]$script:CommandCenterVersion
        detection_confidence = $detection
        hardware_error = $hardwareError
        recommended = $tiers
        blockers = @($blockers)
    }
}

function Get-RuntimeAdapter {
    # Adapter descriptor from catalog/runtimes.json (data, not code). Unknown id throws.
    param([string] $Id = 'llamacpp')
    $adapters = @((Get-CatalogJson -Name 'runtimes.json').adapters)
    $found = @($adapters | Where-Object { [string]$_.id -eq $Id })
    if ($found.Count -eq 0) { throw "Unknown runtime adapter '$Id'. Known: $(@($adapters | ForEach-Object { $_.id }) -join ', ')." }
    $descriptor = $found[0]
    return [pscustomobject]@{
        id = [string]$descriptor.id
        display_name = [string]$descriptor.display_name
        status = [string]$descriptor.status
        description = [string]$descriptor.description
        unknowns = @($descriptor.unknowns)
    }
}

function Get-RuntimeAdapters {
    return @((Get-CatalogJson -Name 'runtimes.json').adapters | ForEach-Object {
        [pscustomobject]@{
            id = [string]$_.id
            display_name = [string]$_.display_name
            status = [string]$_.status
            description = [string]$_.description
            unknowns = @($_.unknowns)
        }
    })
}

function Get-LlamaServerHelpText {
    # One --help invocation shared by capability probing. Empty string when the
    # installed server cannot run (missing exe, spawn failure).
    param([string] $RuntimePath = '')
    $exe = if ([string]::IsNullOrWhiteSpace($RuntimePath)) { Get-RuntimeExecutablePath } else { Join-Path $RuntimePath 'llama-server.exe' }
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { return '' }
    $previous = $ErrorActionPreference
    $text = ''
    Push-Location (Split-Path -Parent $exe)
    try {
        $ErrorActionPreference = 'Continue'
        $text = (@(& $exe --help 2>&1 | ForEach-Object { [string]$_ }) -join "`n")
    } catch {
        $text = ''
    } finally {
        Pop-Location
        $ErrorActionPreference = $previous
    }
    return $text
}

function Get-RuntimeCapabilities {
    # Task 2: what the installed runtime can do, probed once against the flags the
    # catalogue declares. supported = true/false, or null when unknown (no exe).
    param([string] $AdapterId = 'llamacpp', [string] $RuntimePath = '')
    $adapter = Get-RuntimeAdapter -Id $AdapterId
    if ([string]$adapter.status -ne 'active') {
        return [pscustomobject]@{
            adapter = [string]$adapter.id
            available = $false
            confidence = 'none'
            capabilities = @()
            unknowns = @($adapter.unknowns)
        }
    }
    $declared = @((Get-CatalogJson -Name 'runtimes.json').llamacpp_capabilities)
    $exe = if ([string]::IsNullOrWhiteSpace($RuntimePath)) { Get-RuntimeExecutablePath } else { Join-Path $RuntimePath 'llama-server.exe' }
    $available = Test-Path -LiteralPath $exe -PathType Leaf
    $help = if ($available) { Get-LlamaServerHelpText -RuntimePath $RuntimePath } else { '' }
    $confidence = if (-not $available) { 'none' } elseif ($help -eq '') { 'low' } else { 'high' }
    $capabilities = @()
    foreach ($capability in $declared) {
        $supported = $null
        if ($help -ne '') { $supported = [bool]($help.Contains([string]$capability.flag)) }
        $capabilities += [pscustomobject]@{
            flag = [string]$capability.flag
            required = [bool]$capability.required
            router = (($capability.PSObject.Properties.Name -contains 'router') -and [bool]$capability.router)
            purpose = [string]$capability.purpose
            supported = $supported
        }
    }
    return [pscustomobject]@{
        adapter = 'llamacpp'
        available = $available
        confidence = $confidence
        capabilities = $capabilities
        unknowns = @()
    }
}

function Get-RuntimeCapabilitySummary {
    # Pure classification of one runtime's probe: the router is only declared ready when
    # every router flag in the catalogue was positively found in --help. A missing flag is
    # a warning, never a fabricated capability.
    param($Capabilities)
    $list = @($Capabilities)
    $router = @($list | Where-Object { ($_.PSObject.Properties.Name -contains 'router') -and ($_.router -eq $true) })
    $routerMissing = @($router | Where-Object { $_.supported -eq $false } | ForEach-Object { [string]$_.flag })
    $missing = @($list | Where-Object { $_.supported -eq $false } | ForEach-Object { [string]$_.flag })
    return [pscustomobject]@{
        router_ready = (($router.Count -gt 0) -and ($routerMissing.Count -eq 0))
        router_flags = @($router | ForEach-Object { [string]$_.flag })
        router_missing = @($routerMissing)
        missing = @($missing)
    }
}

function Get-RuntimeCapabilityReport {
    # `llama-server --help` per installed build, so a warning names the exact runtime and
    # flag. This is the primary check: build tags differ between channels (the AMD package
    # is b8407 and prints an internal 2500, so a numeric build comparison is not a gate).
    param([string] $Path, [string] $Backend)
    $installation = $null
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $manifest = Join-Path $Path 'installation.json'
        if (Test-Path -LiteralPath $manifest -PathType Leaf) { try { $installation = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json } catch { $installation = $null } }
    }
    $probe = Get-RuntimeCapabilities -RuntimePath $Path
    $summary = Get-RuntimeCapabilitySummary -Capabilities $probe.capabilities
    return [pscustomobject]@{
        backend = [string]$Backend
        tag = if ($null -ne $installation) { [string]$installation.tag } else { '' }
        available = [bool]$probe.available
        confidence = [string]$probe.confidence
        router_ready = [bool]$summary.router_ready
        router_flags = @($summary.router_flags)
        router_missing = @($summary.router_missing)
        missing = @($summary.missing)
        capabilities = @($probe.capabilities)
    }
}

function Test-RuntimeAdapter {
    # Task 2 (ValidateRuntime): a typed verdict, never a fabricated one. Stubs say
    # not_implemented with their catalogue unknowns instead of guessing.
    param([string] $AdapterId = 'llamacpp', $Hardware = $null)
    $adapter = Get-RuntimeAdapter -Id $AdapterId
    if ([string]$adapter.status -ne 'active') {
        return [pscustomobject]@{
            adapter = [string]$adapter.id
            ok = $false
            status = 'not_implemented'
            confidence = 'none'
            warnings = @()
            blockers = @("The $($adapter.display_name) adapter is a structured stub: this project has not implemented or validated it. No verdict is given.")
            unknowns = @($adapter.unknowns)
        }
    }
    $blockers = @()
    $warnings = @()
    $capabilities = Get-RuntimeCapabilities -AdapterId $AdapterId
    if (-not $capabilities.available) {
        $blockers += 'llama.cpp is not installed: llama-server.exe is missing from the install folder. Run setup first.'
    } else {
        foreach ($capability in @($capabilities.capabilities | Where-Object { $_.supported -eq $false })) {
            $message = "The installed llama-server does not support $($capability.flag): $($capability.purpose)"
            if ($capability.required) { $blockers += $message } else { $warnings += $message }
        }
        if ($capabilities.confidence -ne 'high') {
            $warnings += 'The installed server could not be queried for its capabilities; validation is incomplete.'
        }
    }
    $confidence = [string]$capabilities.confidence
    if ($null -ne $Hardware) {
        $hwDetection = 'high'
        if (@($Hardware.PSObject.Properties.Name) -contains 'detection') { $hwDetection = [string]$Hardware.detection.confidence }
        $support = Resolve-HardwareSupport -Hardware $Hardware -Confidence $hwDetection
        if ([string]$support.level -eq 'unsupported') {
            $blockers += @($support.reasons)
        } elseif ([string]$support.level -eq 'warning') {
            $warnings += @($support.reasons)
        }
        $levels = @($hwDetection, [string]$capabilities.confidence)
        $confidence = if (($levels -contains 'low') -or ($levels -contains 'none')) { 'low' } elseif ($levels -contains 'medium') { 'medium' } else { 'high' }
    } else {
        $warnings += 'Hardware was not supplied, so validation covers the runtime only.'
    }
    $status = 'validated'
    if ($blockers.Count -gt 0) { $status = 'blocked' }
    elseif ($warnings.Count -gt 0) { $status = 'degraded' }
    return [pscustomobject]@{
        adapter = 'llamacpp'
        ok = ($blockers.Count -eq 0)
        status = $status
        confidence = $confidence
        warnings = @($warnings)
        blockers = @($blockers)
        unknowns = @()
    }
}

function Start-Runtime {
    # Task 2: llama.cpp delegates to the proven start path (Start-ActiveServer) and
    # reports the outcome typed; stubs do nothing and say so.
    param([string] $AdapterId = 'llamacpp', $Hardware = $null)
    $adapter = Get-RuntimeAdapter -Id $AdapterId
    if ([string]$adapter.status -ne 'active') {
        return [pscustomobject]@{ schema_version = 1; adapter = [string]$adapter.id; status = 'not_implemented'; detail = "The $($adapter.display_name) adapter is a structured stub and was not started."; unknowns = @($adapter.unknowns) }
    }
    if ($null -eq $Hardware) { $Hardware = Get-HardwareProfile }
    $processes = @(Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue)
    $selection = $null
    try {
        # A running server can be stopped here only because this is an explicit start of a
        # model that prefers the other backend. The stop is limited to our install root.
        $selection = Select-RuntimeForActiveModel -Hardware $Hardware -AllowStop:($processes.Count -gt 0)
    } catch {
        Write-WarnLine "The backend preference could not be applied: $($_.Exception.Message)"
        $selection = $null
    }
    if ($null -ne $selection -and $selection.status -eq 'backend_not_installed') {
        return [pscustomobject]@{ schema_version = 1; adapter = 'llamacpp'; status = 'backend_not_installed'; detail = $selection.message; preferred_backend = $selection.preferred_backend; unknowns = @() }
    }
    if ($null -ne $selection -and $selection.status -eq 'not_installed') {
        return [pscustomobject]@{ schema_version = 1; adapter = 'llamacpp'; status = 'failed'; detail = 'llama.cpp is not installed. Run the installer first.'; unknowns = @() }
    }
    if ($null -ne $selection -and $selection.status -eq 'server_running') {
        return [pscustomobject]@{ schema_version = 1; adapter = 'llamacpp'; status = 'failed'; detail = $selection.message; unknowns = @() }
    }
    if ($null -ne $selection -and $selection.status -eq 'switched') {
        Write-Info $selection.message
        # Let the old listener leave the socket table before the new process binds it.
        $deadline = (Get-Date).AddSeconds(5)
        while ((Get-Date) -lt $deadline -and $null -ne (Get-PortListener -Port $Port)) { Start-Sleep -Milliseconds 200 }
    }
    $processes = @(Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue)
    $serverState = [string](Get-ServerState).state
    if ($processes.Count -gt 0 -and $serverState -eq 'running') {
        return [pscustomobject]@{ schema_version = 1; adapter = 'llamacpp'; status = 'already_running'; detail = 'The server is already up and healthy.'; unknowns = @() }
    }
    try {
        $started = Start-ActiveServer -Hardware $Hardware
        $detail = 'The server is running in this console.'
        if ($null -ne $selection -and $selection.status -eq 'switched') { $detail = "$($selection.message) $detail" }
        return [pscustomobject]@{ schema_version = 1; adapter = 'llamacpp'; status = 'started'; detail = $detail; switched_backend = ($null -ne $selection -and $selection.status -eq 'switched'); unknowns = @() }
    } catch {
        return [pscustomobject]@{ schema_version = 1; adapter = 'llamacpp'; status = 'failed'; detail = [string]$_.Exception.Message; unknowns = @() }
    }
}

function Stop-Runtime {
    # Task 2. CLAUDE.md contract: never stop the user's server without being asked.
    # No process -> not_running; process without -Force -> requires_confirmation
    # (nothing is killed); -Force -> the same process stop the window's fallback uses.
    param([string] $AdapterId = 'llamacpp', [switch] $Force)
    $adapter = Get-RuntimeAdapter -Id $AdapterId
    if ([string]$adapter.status -ne 'active') {
        return [pscustomobject]@{ schema_version = 1; adapter = [string]$adapter.id; status = 'not_implemented'; detail = "The $($adapter.display_name) adapter is a structured stub; nothing to stop."; killed = 0 }
    }
    $processes = @(Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue)
    if ($processes.Count -eq 0) {
        return [pscustomobject]@{ schema_version = 1; adapter = 'llamacpp'; status = 'not_running'; detail = 'No llama-server process is running.'; killed = 0 }
    }
    if (-not $Force) {
        return [pscustomobject]@{ schema_version = 1; adapter = 'llamacpp'; status = 'requires_confirmation'; detail = "$(@($processes).Count) llama-server process is running; pass -Force to stop it. Nothing was stopped."; killed = 0 }
    }
    # Router mode can publish a child process while the first snapshot is being stopped.
    # Keep taking snapshots briefly and verify the result instead of reporting success from
    # a one-shot kill list.
    # Count each process once: a killed process can still be listed for a moment, and the
    # retry loop would otherwise report "Stopped 6" for a router and one child.
    $stoppedIds = New-Object 'System.Collections.Generic.HashSet[int]'
    $deadline = (Get-Date).AddSeconds(8)
    while ((Get-Date) -lt $deadline) {
        $remaining = @(Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue)
        if ($remaining.Count -eq 0) { break }
        foreach ($serverProcess in $remaining) {
            try { Stop-Process -Id $serverProcess.Id -Force -ErrorAction Stop; [void]$stoppedIds.Add([int]$serverProcess.Id) } catch { }
        }
        Start-Sleep -Milliseconds 200
    }
    $killed = $stoppedIds.Count
    $left = @(Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue)
    if ($left.Count -eq 0) {
        return [pscustomobject]@{ schema_version = 1; adapter = 'llamacpp'; status = 'stopped'; detail = "Stopped $killed llama-server process(es)."; killed = $killed; remaining = 0 }
    }
    return [pscustomobject]@{ schema_version = 1; adapter = 'llamacpp'; status = 'stop_incomplete'; detail = "$($left.Count) llama-server process(es) could not be stopped."; killed = $killed; remaining = $left.Count; process_ids = @($left | ForEach-Object { $_.Id }) }
}

function Get-RuntimeHealth {
    # Task 2: live health for the adapter. llama.cpp uses the existing server probe;
    # stubs report unknown with why, never a made-up state.
    param([string] $AdapterId = 'llamacpp')
    $adapter = Get-RuntimeAdapter -Id $AdapterId
    if ([string]$adapter.status -ne 'active') {
        return [pscustomobject]@{ schema_version = 1; adapter = [string]$adapter.id; state = 'unknown'; ok = $false; confidence = 'none'; reason = "The $($adapter.display_name) adapter is a structured stub: no health surface exists."; process_ids = @(); port = 0; base_url = '' }
    }
    $server = Get-ServerState
    $asleep = @('asleep', 'unloaded') -contains [string]$server.model_state
    $reason = switch ([string]$server.state) {
        'running' { if ($asleep) { 'The server answers /health; the model is asleep and loads on your next message.' } else { 'The server answers /health with status ok.' } }
        'loading' { 'A llama-server process is up but not answering health checks yet.' }
        default { 'No llama-server process is running.' }
    }
    return [pscustomobject]@{
        schema_version = 1
        adapter = 'llamacpp'
        state = [string]$server.state
        ok = ([string]$server.state -eq 'running')
        confidence = 'high'
        reason = $reason
        process_ids = @($server.process_ids)
        port = [int]$server.port
        base_url = [string]$server.base_url
        model_state = [string]$server.model_state
    }
}

function Update-Runtime {
    # The adapter layer's update entry (ADR-005): the desktop window's "Update
    # runtime" button asks for the newest llama.cpp build that can load the models
    # its library says are blocked (for example Gemma 4 12B on the ROCm 7.2.1
    # package). It delegates to Ensure-LlamaCppInstalled - the single-source
    # updater with staged download, backup, and launcher rebuild - so the desktop
    # can never disagree with what the text menu's [5] does.
    # Confirmation contract: without -Force (or -AssumeYes, the Easy-start agenda)
    # nothing is downloaded and the result asks for confirmation — it never sits at
    # an interactive prompt a machine caller cannot answer. The desktop shows its
    # own confirm dialog first and sends -Force on YES; scripted CLI use passes
    # -Force for the same reason it always has. -Auto stays the persisted backend
    # choice, so this never silently swaps a working pick.
    param([string] $AdapterId = 'llamacpp', [string] $Backend = 'Auto', [switch] $Force)
    $adapter = Get-RuntimeAdapter -Id $AdapterId
    # The stub check comes first: a structured stub answers its own status before
    # anything asks about confirmation.
    if ([string]$adapter.status -ne 'active') {
        return [pscustomobject]@{ schema_version = 1; adapter = [string]$adapter.id; action = 'update'; status = 'not_implemented'; detail = "The $($adapter.display_name) adapter is a structured stub; no runtime update path exists."; unknowns = @($adapter.unknowns); tag = $null }
    }
    if (-not $Force -and -not $script:AssumeYes) {
        return [pscustomobject]@{ schema_version = 1; adapter = 'llamacpp'; action = 'update'; status = 'requires_confirmation'; detail = 'Updating downloads a new llama.cpp build (models are kept). Confirm in the window, or pass -Force for scripted use. Nothing was changed.'; unknowns = @(); tag = $null }
    }
    $processes = @(Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue)
    if ($processes.Count -gt 0) {
        return [pscustomobject]@{ schema_version = 1; adapter = 'llamacpp'; action = 'update'; status = 'server_running'; detail = 'Close every running llama-server.exe process before updating (or stop it from the window first). Nothing was changed.'; unknowns = @(); tag = $null }
    }
    try {
        $hardware = Get-HardwareProfile
        $before = Get-InstalledRuntime
        $tag = Ensure-LlamaCppInstalled -Hardware $hardware -RequestedBackend $Backend
        $after = Get-InstalledRuntime
        if ($null -eq $tag) {
            # User declined at the YES prompt, or ROCm-latest could not see the
            # Radeon and the previous build was restored. Both are refusals, not
            # failures, and the previous runtime is intact either way.
            return [pscustomobject]@{ schema_version = 1; adapter = 'llamacpp'; action = 'update'; status = 'declined'; detail = 'The update was cancelled or the new build was not kept; your previous llama.cpp is unchanged.'; unknowns = @(); tag = if ($null -ne $before) { [string]$before.tag } else { $null } }
        }
        return [pscustomobject]@{
            schema_version = 1
            adapter = 'llamacpp'
            action = 'update'
            status = 'updated'
            detail = "llama.cpp $tag ($($after.backend)) is installed. Launchers were rebuilt for the new build; downloaded models are kept."
            unknowns = @()
            tag = [string]$tag
            previous_tag = if ($null -ne $before) { [string]$before.tag } else { $null }
            backend = [string]$after.backend
        }
    } catch {
        return [pscustomobject]@{ schema_version = 1; adapter = 'llamacpp'; action = 'update'; status = 'failed'; detail = [string]$_.Exception.Message; unknowns = @(); tag = $null }
    }
}

function Find-RuntimeDependency {
    param([string] $Directory, [string] $Name, [string[]] $SearchPath)
    if ([string]::IsNullOrWhiteSpace($Directory) -or [string]::IsNullOrWhiteSpace($Name)) { return '' }
    if ($Name -match '\*') {
        $match = @(Get-ChildItem -LiteralPath $Directory -Filter $Name -File -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($match.Count -gt 0) { return $match[0].FullName }
    } else {
        $candidate = Join-Path $Directory $Name
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    foreach ($folder in @($SearchPath)) {
        if ([string]::IsNullOrWhiteSpace($folder)) { continue }
        $candidate = Join-Path $folder $Name
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        if ($Name -match '\*') {
            $match = @(Get-ChildItem -LiteralPath $folder -Filter $Name -File -ErrorAction SilentlyContinue | Select-Object -First 1)
            if ($match.Count -gt 0) { return $match[0].FullName }
        }
    }
    return ''
}

function Get-RuntimeDependencyReport {
    # Exactly which files one installed build is missing, and where to get them. The
    # ROCm 10 builds load hipBLAS/rocBLAS/rocSOLVER from a separately installed runtime;
    # the AMD-validated 7.2.1 ZIP bundles them. Both cases are described from the build's
    # own files, never from the tag alone.
    param([string] $Path, [string] $Backend, [string[]] $SearchPath = $null)
    if ($null -eq $SearchPath) { $SearchPath = @($env:PATH -split ';') }
    $family = Get-BackendFamily -Backend $Backend
    $required = @()
    if ($family -eq 'vulkan') {
        # ggml-vulkan.dll is runtime-local. Never accept a copy from an unrelated
        # runtime on PATH: that would let a broken build pass its rollback check.
        # vulkan-1.dll is the system loader, supplied by the driver in System32.
        $required = @('llama-server.exe', 'ggml-vulkan.dll', 'vulkan-1.dll')
        $SearchPath = @((Join-Path $env:SystemRoot 'System32'))
    } elseif ($family -eq 'rocm') {
        $required = @('llama-server.exe', 'ggml-hip.dll', 'amdhip64*.dll')
        try {
            $external = @((Get-CatalogJson -Name 'runtimes.json').ggml_org_rocm_windows.required_external_dlls)
            $required += $external
        } catch { }
    } else {
        $required = @('llama-server.exe')
    }
    $missing = @()
    $found = @()
    foreach ($name in $required) {
        $resolved = Find-RuntimeDependency -Directory $Path -Name $name -SearchPath $SearchPath
        if ([string]::IsNullOrWhiteSpace($resolved)) { $missing += $name } else { $found += [pscustomobject]@{ name = $name; path = $resolved } }
    }
    $where = ''
    if ($missing.Count -gt 0) {
        if ($family -eq 'rocm') {
            $where = "Install the AMD ROCm runtime (hipBLAS, rocBLAS, rocSOLVER) from https://rocm.docs.amd.com/projects/install-on-windows/en/latest/ , or use the AMD-validated package from $script:AmdRocmPage."
        } else {
            $where = 'Install or update the AMD Adrenalin driver from https://www.amd.com/en/support; it supplies vulkan-1.dll. Then reinstall this backend.'
        }
    }
    $asset = ''
    $manifest = Join-Path $Path 'installation.json'
    if (Test-Path -LiteralPath $manifest -PathType Leaf) {
        try { $asset = [string](Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json).asset } catch { $asset = '' }
    }
    $driverMinimum = $null
    $driverSource = ''
    $verifiedUsable = $null
    $verificationFinding = ''
    $requiredExternal = @()
    if ($family -eq 'rocm') {
        try {
            $info = Get-CatalogJson -Name 'runtimes.json'
            $requiredExternal = @($info.ggml_org_rocm_windows.required_external_dlls)
            if ($asset -match 'rocm-10\.0') {
                $driverMinimum = [string]$info.ggml_org_rocm_windows.min_adrenalin
                $driverSource = [string]$info.ggml_org_rocm_windows.min_adrenalin_source
                $machine = $info.ggml_org_rocm_windows.machine_verification
                if ($null -ne $machine) {
                    $verifiedUsable = [bool]$machine.verified_usable
                    $verificationFinding = [string]$machine.finding
                }
            }
        } catch { }
    }
    return [pscustomobject]@{
        backend = [string]$Backend
        path = [string]$Path
        installed = (Test-Path -LiteralPath (Join-Path $Path 'llama-server.exe') -PathType Leaf)
        status = if ($missing.Count -eq 0) { 'ok' } else { 'missing_files' }
        missing_files = @($missing)
        found_files = @($found)
        required_external_dlls = @($requiredExternal)
        verified_usable = $verifiedUsable
        verification_finding = $verificationFinding
        where_to_get = $where
        driver_min_version = $driverMinimum
        driver_min_source = $driverSource
        driver_requirement = if ($null -ne $driverMinimum) { "AMD's ROCm 10.0 matrix lists Adrenalin $driverMinimum for RX 9000. llama.cpp's own release notes state no driver minimum; treat this as guidance, not a hard gate." } else { '' }
    }
}

function Get-GpuDriverInfo {
    # Driver version from Windows itself; no vendor tool needed.
    try {
        $controllers = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop | Where-Object { $_.Name -match 'Radeon|AMD' -and $_.Name -notmatch 'Basic' })
        if ($controllers.Count -eq 0) { return $null }
        $controller = $controllers[0]
        $date = ''
        try { if ($null -ne $controller.DriverDate) { $date = ([datetime]$controller.DriverDate).ToString('yyyy-MM-dd') } } catch { $date = '' }
        return [pscustomobject]@{ name = [string]$controller.Name; version = [string]$controller.DriverVersion; date = $date; source = 'Win32_VideoController' }
    } catch { return $null }
}

function Get-DiagnosticReport {
    # Task 3: one typed diagnostics document. No string parsing, no GUI, never
    # throws: a failed section degrades to null + error (ADR-003/ADR-005).
    $generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    $core = $null
    $coreError = $null
    try { $core = Get-CoreApplicationState } catch { $coreError = [string]$_.Exception.Message }

    $hardware = $null
    $hardwareError = $null
    try { $hardware = Get-HardwareProfile } catch { $hardwareError = [string]$_.Exception.Message }
    $gpuDriver = Get-GpuDriverInfo
    $gpuPinning = $null
    try { $gpuPinning = Get-GpuPinningReport } catch { $gpuPinning = $null }

    # runtime health + validation + capabilities (adapter llamacpp)
    $runtimeHealth = $null
    $runtimeError = $null
    try {
        $health = Get-RuntimeHealth -AdapterId 'llamacpp'
        $validation = Test-RuntimeAdapter -AdapterId 'llamacpp' -Hardware $hardware
        $capabilities = Get-RuntimeCapabilities -AdapterId 'llamacpp'
        # Who holds the configured port right now (Gap 3). A foreign owner is a blocker:
        # the server cannot start on it and this tool will not kill it or move ports.
        $portOwner = Resolve-PortConflict -Port $Port -OwnedProcessIds @($health.process_ids)
        $runtimeHealth = [pscustomobject]@{
            adapter = 'llamacpp'
            state = [string]$health.state
            ok = [bool]$health.ok
            validation_status = [string]$validation.status
            capabilities_available = [bool]$capabilities.available
            confidence = [string]$validation.confidence
            port = [int]$Port
            port_owner = [pscustomobject]@{
                status = [string]$portOwner.status
                process_id = [int]$portOwner.process_id
                process_name = [string]$portOwner.process_name
                message = [string]$portOwner.message
            }
            warnings = @($validation.warnings)
            blockers = @($validation.blockers)
        }
        if ([string]$portOwner.status -eq 'conflict') { $runtimeHealth.blockers = @($runtimeHealth.blockers) + @($portOwner.message) }
        if ([string]$health.state -eq 'loading') {
            $runtimeHealth.warnings = @($runtimeHealth.warnings) + @('A llama-server process is up but not answering health checks yet.')
        }
    } catch { $runtimeError = [string]$_.Exception.Message }

    # hardware health
    $hardwareHealth = $null
    if ($null -ne $hardware) {
        $hardwareHealth = [pscustomobject]@{
            level = [string]$hardware.support.level
            confidence = [string]$hardware.support.confidence
            reasons = @($hardware.support.reasons)
            backend = [string]$hardware.recommendation.backend
            recommended_model = [string]$hardware.recommendation.model_id
            error = $null
        }
    } elseif ($null -ne $hardwareError) {
        $hardwareHealth = [pscustomobject]@{ level = $null; confidence = 'none'; reasons = @(); backend = ''; recommended_model = ''; error = $hardwareError }
    }

    # model health
    $modelHealth = $null
    $modelWarnings = @()
    $modelBlockers = @()
    if ($null -ne $core) {
        if ($null -eq $core.model) {
            $modelWarnings += 'No model is active yet.'
            $modelHealth = [pscustomobject]@{ id = ''; present = $false; fit = ''; blocker = ''; confidence = 'none'; warnings = @($modelWarnings); blockers = @() }
        } else {
            $activeId = [string]$core.model.id
            $fit = ''
            $assessment = @(
                if ($null -ne $hardware) {
                    Get-ModelAssessment -Hardware $hardware | Where-Object { [string]$_.Model.Id -eq $activeId }
                }
            ) | Select-Object -First 1
            if ($null -ne $assessment) { $fit = [string]$assessment.Status }
            if (-not [bool]$core.model.model_present) { $modelBlockers += "The active model file is missing from the models folder: $activeId." }
            if (-not [string]::IsNullOrWhiteSpace([string]$core.model.runtime_blocker)) { $modelBlockers += [string]$core.model.runtime_blocker }
            if ($fit -eq 'NOT RECOMMENDED') { $modelBlockers += "The active model does not fit the current memory budget ($activeId)." }
            elseif ($fit -eq 'SLOWER') { $modelWarnings += "The active model runs but spills out of VRAM ($activeId)." }
            $modelHealth = [pscustomobject]@{
                id = $activeId
                present = [bool]$core.model.model_present
                fit = $fit
                blocker = [string]$core.model.runtime_blocker
                confidence = if ($null -eq $hardware) { 'none' } else { [string]$hardware.detection.confidence }
                warnings = @($modelWarnings)
                blockers = @($modelBlockers)
            }
        }
    } elseif ($null -ne $coreError) {
        $modelHealth = [pscustomobject]@{ id = $null; present = $false; fit = ''; blocker = ''; confidence = 'none'; warnings = @(); blockers = @(); error = $coreError }
    }

    # editor health: direct reads, no string parsing of state lines
    $editorWarnings = @()
    $vscodeState = 'no'
    $alias = '-'
    if ($null -ne $core -and $null -ne $core.model) { $alias = [string]$core.model.alias }
    try { $vscodeState = Get-VsCodeChatState -Alias $alias } catch { }
    if ($vscodeState -eq 'stale') { $editorWarnings += 'VS Code is connected to a different model than the active one.' }
    $continuePresent = $false
    try {
        $continuePath = Get-ContinueConfigPath
        if (Test-Path -LiteralPath $continuePath -PathType Leaf) {
            $continuePresent = (Get-Content -LiteralPath $continuePath -Raw) -match 'managed block \(safe to delete\)'
        }
    } catch { }
    $llamaVscodeSet = $false
    try {
        $vscodeSettings = Get-LlamaVscodeSettingsPath
        if (Test-Path -LiteralPath $vscodeSettings -PathType Leaf) {
            $llamaVscodeSet = (Get-Content -LiteralPath $vscodeSettings -Raw) -match 'llama-vscode\.endpoint'
        }
    } catch { }
    $editorHealth = [pscustomobject]@{
        confidence = 'high'
        vscode = [pscustomobject]@{ state = $vscodeState; connected = ($vscodeState -eq 'yes') }
        ll_continue = [pscustomobject]@{ configured = [bool]$continuePresent }
        llama_vscode = [pscustomobject]@{ endpoint_set = [bool]$llamaVscodeSet }
        warnings = @($editorWarnings)
    }

    # Runtimes side by side: report each installed build's files, not just the active one.
    $runtimes = @()
    $runtimeCapabilityWarnings = @()
    foreach ($install in @(Get-RuntimeInstallations)) {
        try {
            $report = Get-RuntimeDependencyReport -Path ([string]$install.path) -Backend ([string]$install.backend)
            $capability = Get-RuntimeCapabilityReport -Path ([string]$install.path) -Backend ([string]$install.backend)
            $report | Add-Member -NotePropertyName capabilities -NotePropertyValue $capability -Force
            if ($capability.available -and -not $capability.router_ready) {
                $runtimeCapabilityWarnings += "llama.cpp $($install.tag) ($($install.backend)) cannot run router mode: its --help does not list $(@($capability.router_missing) -join ', '). Next step: update llama.cpp, or use a build that lists those flags."
            }
            $runtimes += $report
        }
        catch { $runtimes += [pscustomobject]@{ backend = [string]$install.backend; path = [string]$install.path; installed = [bool]$install.exe_present; status = 'unknown'; missing_files = @(); found_files = @(); where_to_get = ''; driver_min_version = $null; driver_min_source = ''; driver_requirement = ''; capabilities = $null } }
    }
    foreach ($familyName in @('Vulkan', 'ROCm')) {
        if (@($runtimes | Where-Object { (Get-BackendFamily -Backend $_.backend) -eq (Get-BackendFamily -Backend $familyName) }).Count -eq 0) {
            $runtimes += [pscustomobject]@{
                backend = $familyName; path = ''; installed = $false; status = 'not_installed'; missing_files = @(); found_files = @()
                where_to_get = "Install it from Install/update with Backend $familyName; runtimes are kept side by side."; driver_min_version = $null; driver_min_source = ''; driver_requirement = ''
            }
        }
    }

    # ROCm 10: the catalogue carries the checked machine finding. Report it explicitly
    # even when no ROCmLatest runtime is installed, and do not call the entry usable
    # merely because the driver is recent enough.
    $rocmLatest = $null
    try {
        $rocmCatalog = Get-CatalogJson -Name 'runtimes.json'
        $rocmInfo = $rocmCatalog.ggml_org_rocm_windows
        $machine = $rocmInfo.machine_verification
        $required = @($rocmInfo.required_external_dlls)
        $search = @($env:PATH -split ';')
        $present = @()
        $missingExternal = @()
        foreach ($name in $required) {
            $resolved = Find-RuntimeDependency -Directory '' -Name $name -SearchPath $search
            if ([string]::IsNullOrWhiteSpace($resolved)) { $missingExternal += $name } else { $present += [pscustomobject]@{ name = $name; path = $resolved } }
        }
        $installedRocm10 = @($runtimes | Where-Object { [string]$_.backend -eq 'ROCmLatest' })
        $rocmLatest = [pscustomobject]@{
            entry = 'ggml_org_rocm_windows'
            rocm_version = [string]$rocmInfo.rocm_version
            min_adrenalin = [string]$rocmInfo.min_adrenalin
            min_adrenalin_source = [string]$rocmInfo.min_adrenalin_source
            required_external_dlls = @($required)
            present_external_dlls = @($present)
            missing_external_dlls = @($missingExternal)
            installed = ($installedRocm10.Count -gt 0)
            installed_paths = @($installedRocm10 | ForEach-Object { [string]$_.path })
            verified_usable_on_this_machine = if ($null -ne $machine) { [bool]$machine.verified_usable } else { $false }
            finding = if ($null -ne $machine) { [string]$machine.finding } else { 'No machine verification is recorded for this catalogue entry.' }
            checked_on = if ($null -ne $machine) { [string]$machine.checked_on } else { '' }
            source = if ($null -ne $machine) { [string]$machine.source } else { '' }
        }
        if ($installedRocm10.Count -gt 0 -and $missingExternal.Count -gt 0) {
            $warnings += "ROCm 10 is installed but not usable on this machine: missing $($missingExternal -join ', '). $($rocmLatest.finding)"
        }
    } catch { $rocmLatest = [pscustomobject]@{ verified_usable_on_this_machine = $false; finding = 'ROCm 10 verification could not be read from the catalogue.' } }

    # roll-up: any blocker -> broken, else any warning -> degraded, else ok
    $blockers = @()
    $warnings = @()
    if ($null -ne $runtimeHealth) { $blockers += @($runtimeHealth.blockers); $warnings += @($runtimeHealth.warnings) }
    elseif ($null -ne $runtimeError) { $blockers += "Runtime health could not be collected: $runtimeError" }
    if ($null -ne $hardwareHealth) {
        if ([string]$hardwareHealth.level -eq 'unsupported') { $blockers += @($hardwareHealth.reasons) }
        elseif ([string]$hardwareHealth.level -eq 'warning') { $warnings += @($hardwareHealth.reasons) }
        if (-not [string]::IsNullOrEmpty([string]$hardwareHealth.error)) { $blockers += "Hardware scan failed: $($hardwareHealth.error)" }
    }
    if ($null -ne $modelHealth) {
        $warnings += @($modelHealth.warnings)
        $blockers += @($modelHealth.blockers)
    }
    $warnings += @($editorHealth.warnings)
    $warnings += @($runtimeCapabilityWarnings)
    if ($null -ne $gpuPinning -and $gpuPinning.status -eq 'integrated_only') {
        $warnings += "GPU pinning: $($gpuPinning.reason) The start action refuses to fall back to the iGPU; connect a discrete Radeon or set an explicit --device in server-args.user.json."
    }
    $overall = if ($blockers.Count -gt 0) { 'broken' } elseif ($warnings.Count -gt 0) { 'degraded' } else { 'ok' }
    $overallConfidence = if ($null -ne $hardware) { [string]$hardware.detection.confidence } else { 'low' }
    if ($null -eq $runtimeHealth -or $null -eq $core) { $overallConfidence = 'low' }

    return [pscustomobject]@{
        schema_version = 1
        generated_at = $generatedAt
        command_center_version = [string]$script:CommandCenterVersion
        install_root = [string]$InstallRoot
        runtime_health = $runtimeHealth
        runtimes = @($runtimes)
        rocm_latest = $rocmLatest
        gpu_pinning = $gpuPinning
        gpu_driver = $gpuDriver
        hardware_health = $hardwareHealth
        model_health = $modelHealth
        editor_health = $editorHealth
        warnings = @($warnings | Sort-Object -Unique)
        blockers = @($blockers | Sort-Object -Unique)
        overall = [pscustomobject]@{ status = $overall; confidence = $overallConfidence }
    }
}

function Show-HardwareAdvisor {
    param($Hardware)
    $ramBar = Get-MemoryBar -Value $Hardware.RamGiB -Maximum 128
    $gpuBar = Get-MemoryBar -Value $Hardware.MaxAmdVramGiB -Maximum 48
    $assessment = @(Get-ModelAssessment -Hardware $Hardware)
    $recommended = Get-RecommendedModel -Hardware $Hardware

    Clear-Screen
    Show-Banner
    Write-Host '  ┌─ HARDWARE TELEMETRY ───────────────────────────────────────────────────────────┐' -ForegroundColor DarkCyan
    Write-Host '  │ CPU  ' -NoNewline -ForegroundColor DarkGray; Write-Host (Limit-Text $Hardware.CpuName 57) -ForegroundColor White
    Write-Host '  │      ' -NoNewline -ForegroundColor DarkGray; Write-Host ("$($Hardware.CpuCores) cores / $($Hardware.CpuThreads) threads") -ForegroundColor Gray
    Write-Host '  │ RAM  ' -NoNewline -ForegroundColor DarkGray; Write-Host ("$ramBar  $([Math]::Round($Hardware.RamGiB,1)) GiB") -ForegroundColor Cyan
    Write-Host '  │ VRAM ' -NoNewline -ForegroundColor DarkGray; Write-Host ("$gpuBar  $([Math]::Round($Hardware.MaxAmdVramGiB,1)) GiB AMD maximum") -ForegroundColor Magenta
    Write-Host '  │ MODE ' -NoNewline -ForegroundColor DarkGray; Write-Host (Limit-Text $Hardware.ExecutionMode 55) -ForegroundColor Green
    Write-Host '  │ TIER ' -NoNewline -ForegroundColor DarkGray; Write-Host $Hardware.Profile -ForegroundColor Yellow
    Write-Host '  └───────────────────────────────────────────────────────────────────────────────┘' -ForegroundColor DarkCyan

    Write-Host "`n  GPUs DETECTED" -ForegroundColor White
    if ($Hardware.Gpus.Count -eq 0) {
        Write-WarnLine 'No display adapters were reported.'
    } else {
        foreach ($gpu in $Hardware.Gpus) {
            $label = if ($gpu.IsAmd) { 'AMD' } else { 'OTHER' }
            $type = if ($gpu.Name -match '(?i)Basic Render|Software') { 'SOFTWARE' } elseif ($gpu.IsIntegrated) { 'iGPU/UMA' } else { 'dGPU' }
            Write-Host ('    {0,-5} {1,-8} {2,5:N1} GiB  ' -f $label, $type, $gpu.VramGiB) -NoNewline -ForegroundColor DarkGray
            Write-Host (Limit-Text $gpu.Name 43) -ForegroundColor White
        }
    }

    $ignoredIntel = @($Hardware.Gpus | Where-Object { -not $_.IsAmd -and $_.Name -match '(?i)Intel' })
    if ($ignoredIntel.Count -gt 0) {
        Write-Host "`n  Ignored graphics: Intel integrated graphics is outside this project's acceleration scope." -ForegroundColor DarkGray
    }

    Write-Host "`n  MODEL FIT ANALYSIS" -ForegroundColor White
    foreach ($item in ($assessment | Select-Object -First 6)) {
        $badge = $item.Status.PadRight(17)
        Write-Host ('    {0} ' -f $badge) -NoNewline -ForegroundColor $item.Color
        Write-Host ('{0,-25}' -f $item.Model.Name) -NoNewline -ForegroundColor White
        $placement = if ($item.GpuResident) { 'fits in VRAM' } else { 'VRAM + system RAM (slower)' }
        Write-Host ('{0,6:N1} GiB  headroom {1,5:N1} GiB  {2}' -f $item.Model.ApproxGiB, $item.HeadroomGiB, $placement) -ForegroundColor DarkGray
    }

    Write-Host "`n  ╭─ RECOMMENDED FOR THIS MACHINE ───────────────────────────────────────────────╮" -ForegroundColor DarkGreen
    Write-Host "  │  ◆ $($recommended.Name)  [$($recommended.Tag)]" -ForegroundColor Green
    Write-Host "  │  $(Limit-Text $recommended.Description 76)" -ForegroundColor Gray
    $context = Get-SuggestedContext -Model $recommended -Hardware $Hardware
    Write-Host "  │  Suggested start: $context context tokens, Q4/Q8 weights, Flash Attention on." -ForegroundColor DarkGray
    $larger = @($assessment | Where-Object { $_.Recommended -and -not $_.GpuResident -and $_.Model.Rank -gt $recommended.Rank } | Select-Object -First 1)
    if ($larger.Count -gt 0) {
        Write-Host "  │  QUALITY OPTION: $($larger[0].Model.Name) is stronger but spills into system RAM; expect much slower replies." -ForegroundColor Cyan
    }
    Write-Host "  │  Backend: $(if ($Hardware.RocmRecommended) { 'AMD ROCm 7.2.1 (validated Windows package)' } else { 'Vulkan (portable AMD fallback)' })" -ForegroundColor $(if ($Hardware.RocmRecommended) { 'Green' } else { 'Cyan' })
    Write-Host "  │  $(Limit-Text $Hardware.RocmReason 76)" -ForegroundColor DarkGray
    if ($recommended.ApproxGiB -gt ($Hardware.RamGiB * 0.75)) {
        Write-WarnLine 'This is an ambitious fit. Expect CPU/UMA participation and reduced speed.'
    }
    if (-not $Hardware.HasAmdCpu) { Write-WarnLine 'AMD CPU was not detected; the dashboard can still run on an AMD GPU.' }
    if (-not $Hardware.HasAmdGpu) { Write-WarnLine 'AMD GPU was not detected. llama.cpp will fall back to its CPU backend.' }
    if (-not $Hardware.VulkanLoader) { Write-WarnLine 'Vulkan loader is missing; install the current AMD Adrenalin driver if you select Vulkan.' }
    Write-Host '  ╰──────────────────────────────────────────────────────────────────────────────╯' -ForegroundColor DarkGreen
}

# ---------------------------------------------------------------------
# Download verification and installation
# ---------------------------------------------------------------------

function Test-FileDigest {
    param([string] $Path, [string] $ExpectedSha256)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ieq $ExpectedSha256
}

function Get-DownloadStagingDirectory {
    # Downloads land here, never at their final path. The staging folder sits under the
    # install root, so it is on the same volume as models\ and downloads\: promoting a
    # verified file is a rename (atomic), and a half-finished file can never be mistaken
    # for a finished one.
    return (Join-Path (Join-Path $InstallRoot 'downloads') 'staging')
}

function Invoke-CurlDownload {
    # The one real downloader, kept separate from Get-VerifiedDownload so the staging,
    # resume and checksum rules are testable without touching the network.
    # Returns curl's exit code: 0 ok, 33 the server cannot resume this file.
    param([string] $Url, [string] $Target, [bool] $Resume)
    $curlArgs = @(
        '--location', '--fail', '--show-error', '--retry', '8', '--retry-all-errors',
        '--retry-delay', '3'
    )
    if ($Resume) { $curlArgs += @('--continue-at', '-') }
    $curlArgs += @('--output', $Target, $Url)
    & curl.exe @curlArgs
    return [int]$LASTEXITCODE
}

function Get-ArchiveLocalHash {
    # Local identity for a package whose publisher has no digest (AMD). Prefers the
    # sidecar written at download time, then hashes the archive and writes that sidecar.
    param([string] $ArchivePath)
    if ([string]::IsNullOrWhiteSpace($ArchivePath) -or -not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) { return '' }
    $sidecar = "$ArchivePath.sha256"
    if (Test-Path -LiteralPath $sidecar -PathType Leaf) {
        $parts = @(([string](Get-Content -LiteralPath $sidecar -Raw)).Trim() -split '\s+')
        if ($parts.Count -gt 0 -and $parts[0] -match '^[0-9a-fA-F]{64}$') { return $parts[0].ToLowerInvariant() }
    }
    $hash = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath $sidecar -Value "$hash  $([IO.Path]::GetFileName($ArchivePath))" -Encoding ASCII
    return $hash
}

function Get-VerifiedDownload {
    param(
        [string] $Url,
        [string] $Destination,
        [long] $ExpectedSize,
        [string] $ExpectedSha256,
        [scriptblock] $Downloader = $null
    )
    if ($null -eq $Downloader) {
        $Downloader = { param($Address, $Target, $Resume) Invoke-CurlDownload -Url $Address -Target $Target -Resume $Resume }
    }
    $fileName = [IO.Path]::GetFileName($Destination)

    # An already-promoted file is trusted only when its size and hash both agree.
    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        $existing = Get-Item -LiteralPath $Destination
        if ($existing.Length -eq $ExpectedSize) {
            if ([string]::IsNullOrWhiteSpace($ExpectedSha256)) {
                Write-Step "Checking existing $fileName"
                Write-Success 'Existing AMD package size matches.'
                # AMD publishes no digest, so the recorded local hash is the only identity
                # this file has. Return it so the installer can store it in installation.json.
                $sidecar = "$Destination.sha256"
                $knownHash = ''
                if (Test-Path -LiteralPath $sidecar -PathType Leaf) {
                    $knownHash = ([string](Get-Content -LiteralPath $sidecar -Raw)).Trim().Split(' ')[0]
                }
                if ([string]::IsNullOrWhiteSpace($knownHash)) {
                    $knownHash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
                    Set-Content -LiteralPath $sidecar -Value "$knownHash  $fileName" -Encoding ASCII
                }
                return $knownHash
            }
            Write-Step "Verifying existing $fileName"
            if (Test-FileDigest -Path $Destination -ExpectedSha256 $ExpectedSha256) {
                Write-Success 'Already installed and verified.'
                return ([string]$ExpectedSha256).ToLowerInvariant()
            }
            Write-WarnLine 'Checksum mismatch; the managed copy will be downloaded again.'
        } else {
            Write-WarnLine 'File size mismatch; the managed copy will be downloaded again.'
        }
        Remove-Item -LiteralPath $Destination -Force
    }

    $stagingDir = Get-DownloadStagingDirectory
    New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null
    $staged = Join-Path $stagingDir $fileName
    # Older versions resumed a "<name>.part" next to the destination. Adopt it so an
    # interrupted download is not thrown away by the upgrade.
    $legacyPartial = "$Destination.part"
    if ((Test-Path -LiteralPath $legacyPartial -PathType Leaf) -and -not (Test-Path -LiteralPath $staged)) {
        Move-Item -LiteralPath $legacyPartial -Destination $staged -Force
    }
    if ((Test-Path -LiteralPath $staged -PathType Leaf) -and (Get-Item -LiteralPath $staged).Length -ge $ExpectedSize) {
        # Same size or larger and still not verified: nothing left to resume.
        Remove-Item -LiteralPath $staged -Force
    }

    Write-Step "Downloading $fileName  ($([Math]::Round($ExpectedSize / 1GB, 2)) GiB)"
    Write-Info $Url
    $resume = Test-Path -LiteralPath $staged -PathType Leaf
    if ($resume) { Write-Info 'Resuming the incomplete download left by an earlier run.' }
    $code = [int](& $Downloader $Url $staged $resume)
    if ($resume -and $code -eq 33) {
        # curl 33: the server does not support byte ranges. Start over instead of pretending.
        Write-WarnLine 'The server cannot resume this file; downloading it again from the start.'
        Remove-Item -LiteralPath $staged -Force
        $code = [int](& $Downloader $Url $staged $false)
    }
    if ($code -ne 0) {
        throw "Download failed (curl exit code $code) for $fileName. The part already received is kept in $stagingDir; run this again to resume it."
    }

    $actualSize = (Get-Item -LiteralPath $staged).Length
    if ($actualSize -ne $ExpectedSize) {
        Remove-Item -LiteralPath $staged -Force
        throw "Size verification failed for $fileName : expected $ExpectedSize bytes, received $actualSize. Nothing was installed and the staged file was deleted."
    }

    Write-Step "SHA-256 verification: $fileName"
    $actualHash = (Get-FileHash -LiteralPath $staged -Algorithm SHA256).Hash.ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($ExpectedSha256)) {
        Write-WarnLine 'AMD does not publish a SHA-256 sidecar for this package; recording the downloaded hash locally.'
        Move-Item -LiteralPath $staged -Destination $Destination -Force
        Set-Content -LiteralPath "$Destination.sha256" -Value "$actualHash  $fileName" -Encoding ASCII
        Write-Success "Downloaded from AMD's official repository. Recorded SHA-256: $actualHash"
        return $actualHash
    }
    $expected = ([string]$ExpectedSha256).ToLowerInvariant()
    if ($actualHash -ine $expected) {
        Remove-Item -LiteralPath $staged -Force
        throw "SHA-256 verification failed for $fileName. Expected $expected, got $actualHash. Nothing was installed and the staged file was deleted."
    }
    # Checksum passed: promote the staged file to its real path by rename.
    Move-Item -LiteralPath $staged -Destination $Destination -Force
    Write-Success 'Verified successfully.'
    return $expected
}

function Get-HfRepository {
    param([string] $Repo)
    $cacheKey = $Repo.ToLowerInvariant()
    if ($script:HfRepositoryCache.ContainsKey($cacheKey)) { return $script:HfRepositoryCache[$cacheKey] }
    $modelInfo = Invoke-RestMethod -Uri ($script:HfApi + '/' + $Repo) -Headers @{ 'User-Agent' = 'llamacpp-amd-command-center' }
    $revision = [string]$modelInfo.sha
    $tree = Invoke-RestMethod -Uri ($script:HfApi + '/' + $Repo + '/tree/' + $revision + '?recursive=true&expand=true') -Headers @{ 'User-Agent' = 'llamacpp-amd-command-center' }
    $result = [pscustomobject]@{ Repo = $Repo; Revision = $revision; Tree = @($tree) }
    $script:HfRepositoryCache[$cacheKey] = $result
    return $result
}

function Get-HfFileDescriptor {
    param([string] $Repo, [string] $FileName)
    $repository = Get-HfRepository -Repo $Repo
    $entry = @($repository.Tree | Where-Object { $_.path -ceq $FileName }) | Select-Object -First 1
    if ($null -eq $entry) { throw "File '$FileName' was not found in Hugging Face repository '$Repo'." }
    if ($null -eq $entry.lfs -or [string]::IsNullOrWhiteSpace([string]$entry.lfs.oid)) {
        throw "File '$FileName' does not publish Git LFS SHA-256 metadata; refusing to download it."
    }
    $encodedFile = [Uri]::EscapeDataString($FileName)
    return [pscustomobject]@{
        Url = 'https://huggingface.co/' + $Repo + '/resolve/' + $repository.Revision + '/' + $encodedFile
        Size = [long]$entry.lfs.size
        Sha256 = ([string]$entry.lfs.oid).ToLowerInvariant()
        Revision = $repository.Revision
    }
}

function Get-InstallDrive {
    $drive = (Split-Path -Qualifier ([IO.Path]::GetFullPath($InstallRoot))).TrimEnd(':')
    if ($drive.Length -eq 0) { $drive = $env:SystemDrive.TrimEnd(':') }
    return $drive
}

function Assert-ModelDiskSpace {
    param([double] $RequiredGiB)
    $free = (Get-PSDrive -Name (Get-InstallDrive)).Free
    $reserve = [Math]::Max(3, [Math]::Ceiling($RequiredGiB * 0.08))
    $needed = ($RequiredGiB + $reserve) * 1GB
    if ($free -lt $needed) {
        throw ('Model needs about {0:N1} GiB plus {1:N0} GiB reserve, but the install drive has only {2} free. Move -InstallRoot to a larger drive.' -f $RequiredGiB, $reserve, (Format-Bytes $free))
    }
}

function Add-UserPathEntry {
    param([string] $Directory)
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $entries = @()
    if (-not [string]::IsNullOrWhiteSpace($userPath)) {
        $entries = @($userPath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    if ($null -eq ($entries | Where-Object { $_.Trim().TrimEnd('\') -ieq $Directory.Trim().TrimEnd('\') } | Select-Object -First 1)) {
        [Environment]::SetEnvironmentVariable('Path', ((@($entries) + $Directory) -join ';') + ';', 'User')
    }
}

function Remove-UserPathEntry {
    param([string] $Directory)
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ([string]::IsNullOrWhiteSpace($userPath)) { return }
    $kept = @($userPath -split ';' | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_) -and $_.Trim().TrimEnd('\') -ine $Directory.Trim().TrimEnd('\')
    })
    $newPath = $kept -join ';'
    if ($newPath.Length -gt 0) { $newPath += ';' }
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
}

function Assert-HardwareForLlama {
    param($Hardware)
    # The Radeon GPU is what this project accelerates; the host CPU vendor never
    # gates that. An Intel CPU paired with a Radeon dGPU is a normal, fully
    # supported configuration and must not be treated as a warning condition.
    if ((-not $Hardware.HasAmdGpu) -and -not $Force) {
        throw 'No AMD Radeon Vulkan GPU was detected. Use -Force only if DXGI inventory is incorrect.'
    }
    if (-not $Hardware.HasAmdCpu) {
        Write-Info 'Intel host CPU detected. Intel CPUs are fully supported; Intel GPU acceleration is not part of this project.'
    }
}

function Get-AmdRocmAsset {
    Write-Step 'Using AMD validated ROCm package'
    Write-Info $script:AmdRocmPage
    # Every AMD package field comes from catalog/runtimes.json. The tag used to be
    # hardcoded here and the name/url/size lived in script variables, which made three
    # sources of truth that could drift.
    $amd = (Get-CatalogJson -Name 'runtimes.json').amd_rocm_package
    return [pscustomobject]@{
        Release = [pscustomobject]@{
            tag_name = [string]$amd.tag
            html_url = [string]$amd.page
        }
        Asset = [pscustomobject]@{
            name = [string]$amd.name
            browser_download_url = [string]$amd.url
            size = [long]$amd.size
            digest = ''
            officialUnverified = $true
        }
    }
}

function Get-RocmLatestRequirementText {
    return @(
        'ADVANCED: this is llama.cpp''s own ROCm build, newer than AMD''s validated package.',
        'It needs AMD''s ROCm runtime (hipBLAS/rocBLAS) installed separately and a recent Adrenalin driver.',
        'It has not been tested by this project on every Radeon. After install, setup checks that it can',
        'see your GPU; if not, it removes the new build and keeps your current llama.cpp.'
    )
}

function Get-LatestLlamaCppVulkanAsset {
    return Get-LatestLlamaCppAsset -Label 'Vulkan' -Pattern '^llama-.*-bin-win-vulkan-x64\.zip$'
}

function Get-LatestLlamaCppRocmAsset {
    # ggml-org's own Windows ROCm build (llama-bXXXX-bin-win-rocm-<ver>-x64.zip). The ROCm
    # version in the name changes between releases, so match any version.
    return Get-LatestLlamaCppAsset -Label 'ROCm' -Pattern '^llama-.*-bin-win-rocm-[0-9.]+-x64\.zip$'
}

function Get-LatestLlamaCppAsset {
    param([string] $Label, [string] $Pattern)
    Write-Step "Resolving the latest official llama.cpp Windows $Label release"
    $stable = Invoke-RestMethod -Uri ($script:GitHubApi + '/latest') -Headers $script:GitHubHeaders
    $asset = @($stable.assets | Where-Object {
        $_.name -match $Pattern -and $_.name -notmatch '^cudart-'
    }) | Select-Object -First 1

    if ($null -ne $asset) {
        Write-Info "Stable $($stable.tag_name) / $($asset.name)"
        return [pscustomobject]@{ Release = $stable; Asset = $asset }
    }

    $tagAsset = @($stable.assets | Where-Object { $_.name -eq 'nightly-tag.txt' }) | Select-Object -First 1
    if ($null -eq $tagAsset) { throw "The latest llama.cpp release exposes no Windows $Label build or nightly tag." }
    $tagResponse = Invoke-WebRequest -Uri $tagAsset.browser_download_url -UseBasicParsing
    if ($tagResponse.Content -is [byte[]]) {
        $tag = [Text.Encoding]::UTF8.GetString($tagResponse.Content).Trim()
    } else {
        $tag = ([string]$tagResponse.Content).Trim()
    }
    if ($tag -notmatch '^b[0-9]+$') { throw "Malformed llama.cpp nightly tag: '$tag'." }
    $build = Invoke-RestMethod -Uri ($script:GitHubApi + '/tags/' + $tag) -Headers $script:GitHubHeaders
    $asset = @($build.assets | Where-Object {
        $_.name -match $Pattern -and $_.name -notmatch '^cudart-'
    }) | Select-Object -First 1
    if ($null -eq $asset) { throw "llama.cpp build $tag has no Windows x64 $Label ZIP." }
    Write-Info "Selected $tag / $($asset.name)"
    return [pscustomobject]@{ Release = $build; Asset = $asset }
}

function Ensure-LlamaCppInstalled {
    param($Hardware, [ValidateSet('Auto', 'Vulkan', 'ROCm', 'ROCmLatest')] [string] $RequestedBackend = 'Auto')
    Assert-HardwareForLlama -Hardware $Hardware
    $running = Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue
    if ($null -ne $running) { throw 'Close every running llama-server.exe process before installing or updating.' }
    # Migrate a legacy current\ install once, before anything looks for the active build.
    [void](Initialize-RuntimeLayout)

    $backendChoice = Resolve-BackendChoice -RequestedBackend $RequestedBackend -Hardware $Hardware -Runtime (Get-InstalledRuntime)
    if ($backendChoice -eq 'Vulkan' -and $Hardware.RocmRecommended) {
        Write-WarnLine 'This Radeon supports ROCm, which is the stable choice. On an RX 9070 XT the Vulkan build lost the GPU'
        Write-WarnLine 'during long Agent sessions and once crashed Windows. Use Vulkan here only for short tests.'
    }
    Write-RunLogEvent -Event 'backend_selected' -Message "Selected backend: $backendChoice" -Data @{
        requested = $RequestedBackend
        selected = $backendChoice
        rocm_recommended = [bool]$Hardware.RocmRecommended
        gpu = [string]$Hardware.RocmGpu
    }
    if (($backendChoice -eq 'ROCm') -and (-not $Hardware.RocmRecommended) -and -not $Force) {
        throw 'ROCm was requested, but this Radeon is not in the current AMD Windows ROCm matrix. Use -Backend Vulkan or -Force.'
    }
    if ($backendChoice -eq 'ROCm') {
        $selected = Get-AmdRocmAsset
    } elseif ($backendChoice -eq 'ROCmLatest') {
        $selected = Get-LatestLlamaCppRocmAsset
    } else {
        $selected = Get-LatestLlamaCppVulkanAsset
    }
    $asset = $selected.Asset
    $tag = [string]$selected.Release.tag_name
    $digest = [string]$asset.digest
    if ($digest -match '^sha256:([0-9a-fA-F]{64})$') {
        $digest = $Matches[1].ToLowerInvariant()
    } elseif ($backendChoice -ne 'ROCm') {
        throw 'GitHub did not publish a SHA-256 digest for the llama.cpp archive.'
    } else {
        $digest = ''
        Write-WarnLine 'AMD publishes the official ROCm ZIP over HTTPS but no SHA-256 sidecar; the downloaded hash will be recorded locally.'
    }

    $downloadRoot = Join-Path $InstallRoot 'downloads'
    $archive = Join-Path $downloadRoot $asset.name
    $extract = Join-Path $InstallRoot ('.extract-' + [Guid]::NewGuid().ToString('N'))
    $stage = Join-Path $InstallRoot ('.runtime-new-' + [Guid]::NewGuid().ToString('N'))
    $backup = Join-Path $InstallRoot ('.backup-' + [Guid]::NewGuid().ToString('N'))
    $relative = Get-RuntimeFolderName -Backend $backendChoice -Tag $tag
    $target = Join-Path (Get-RuntimesRoot) ($relative -replace '/', '\')
    New-Item -ItemType Directory -Path $downloadRoot -Force | Out-Null

    # The same backend and tag already installed: select it and stop. Reinstalling the
    # same build must never re-download it, and this is what makes a switch back cheap.
    $targetManifest = Join-Path $target 'installation.json'
    if ((Test-Path -LiteralPath $targetManifest -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $target 'llama-server.exe') -PathType Leaf)) {
        $existingInstallation = $null
        try { $existingInstallation = Get-Content -LiteralPath $targetManifest -Raw | ConvertFrom-Json } catch { $existingInstallation = $null }
        if ($null -ne $existingInstallation) {
            $recordedSha = [string]$existingInstallation.sha256
            if ([string]::IsNullOrWhiteSpace($recordedSha)) {
                # Old AMD installs stored an empty hash. Backfill it from the archive that is
                # already in downloads\ (or its .sha256 sidecar) without touching the build.
                $recordedSha = Get-ArchiveLocalHash -ArchivePath (Join-Path $downloadRoot $asset.name)
                if (-not [string]::IsNullOrWhiteSpace($recordedSha)) {
                    $existingInstallation | Add-Member -NotePropertyName 'sha256' -NotePropertyValue $recordedSha -Force
                    $existingInstallation | Add-Member -NotePropertyName 'sha256_source' -NotePropertyValue 'local' -Force
                    $existingInstallation | ConvertTo-Json | Set-Content -LiteralPath $targetManifest -Encoding UTF8
                }
            }
            Set-ActiveRuntime -Path $target
            if (-not $NoPath) {
                Add-UserPathEntry -Directory $target
                Remove-UserPathEntry -Directory (Join-Path $InstallRoot 'current')
            }
            Write-Success "llama.cpp $tag ($backendChoice) is already installed at $target; no download was needed."
            $active = Get-ActiveModel
            if ($null -ne $active) {
                New-Launchers -ActiveModel $active -EffectiveContext ([int]$active.context_size)
                Write-Info 'Server launcher rebuilt for the active runtime.'
            }
            return $tag
        }
    }

    if (-not ($Force -or $script:AssumeYes)) {
        $sizeGiB =[Math]::Round(([double]$asset.size / 1GB), 2)
        $sourceHost = ([Uri][string]$asset.browser_download_url).Host
        Write-Host "`n  About to download llama.cpp ($backendChoice build $tag, ~$sizeGiB GiB) from $sourceHost." -ForegroundColor Yellow
        Write-Host "  It is installed to $target. Downloaded models are kept." -ForegroundColor DarkGray
        if ($backendChoice -eq 'ROCmLatest') {
            foreach ($line in (Get-RocmLatestRequirementText)) { Write-Host "  $line" -ForegroundColor Yellow }
        }
        if ((Read-ConsoleLine -Prompt '  Type YES to continue') -ine 'YES') {
            Write-WarnLine 'llama.cpp download cancelled. Nothing was downloaded.'
            return $null
        }
    }

    $archiveHash = Get-VerifiedDownload -Url $asset.browser_download_url -Destination $archive -ExpectedSize ([long]$asset.size) -ExpectedSha256 $digest
    New-Item -ItemType Directory -Path $extract -Force | Out-Null
    try {
        Write-Step "Extracting $($asset.name)"
        Expand-Archive -LiteralPath $archive -DestinationPath $extract -Force
        $server = Get-ChildItem -LiteralPath $extract -Filter 'llama-server.exe' -File -Recurse | Select-Object -First 1
        if ($null -eq $server) { throw 'llama-server.exe was not found in the official archive.' }
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
        New-Item -ItemType Directory -Path $stage -Force | Out-Null
        Copy-Item -Path (Join-Path $server.Directory.FullName '*') -Destination $stage -Recurse -Force
        [ordered]@{
            tag = $tag; release_url = $selected.Release.html_url; asset = $asset.name
            sha256 = $archiveHash; sha256_source = $(if ([string]::IsNullOrWhiteSpace($digest)) { 'local' } else { 'publisher' })
            installed_at = (Get-Date).ToUniversalTime().ToString('o'); backend = $backendChoice
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stage 'installation.json') -Encoding UTF8

        if (Test-Path -LiteralPath $target) { Move-Item -LiteralPath $target -Destination $backup }
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        try {
            Move-Item -LiteralPath $stage -Destination $target
        } catch {
            if ((Test-Path -LiteralPath $backup) -and -not (Test-Path -LiteralPath $target)) {
                Move-Item -LiteralPath $backup -Destination $target
            }
            throw
        }
        if ($backendChoice -eq 'ROCmLatest') {
            # This build loads AMD's ROCm libraries from the PC; without them llama.cpp
            # quietly runs on the CPU. Keep it only if it actually lists a ROCm GPU.
            $foundDevices = Get-LlamaDeviceList -Directory $target
            $rocmDevices = @($foundDevices | Where-Object { $_.Id -match '^ROCm' -and -not $_.Integrated })
            Write-RunLogEvent -Event 'rocm_latest_check' -Message "ROCm devices found: $($rocmDevices.Count)" -Data @{ tag = $tag; devices = @($rocmDevices | ForEach-Object { $_.Name }) }
            if ($rocmDevices.Count -eq 0) {
                Remove-Item -LiteralPath $target -Recurse -Force
                if (Test-Path -LiteralPath $backup) { Move-Item -LiteralPath $backup -Destination $target }
                Write-WarnLine "llama.cpp $tag (ROCm) could not see your Radeon, so it was not kept. Your previous llama.cpp is unchanged."
                Write-WarnLine 'This build needs AMD''s ROCm runtime libraries installed separately. Use the AMD ROCm 7.2.1 or Vulkan backend instead.'
                return $null
            }
            Write-Success "ROCm GPU found: $($rocmDevices[0].Name)"
        }
        if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Recurse -Force }
    } finally {
        if (Test-Path -LiteralPath $extract) { Remove-Item -LiteralPath $extract -Recurse -Force }
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    }

    if (-not $NoPath) {
        Add-UserPathEntry -Directory $target
        # A migrated install leaves its old current\ entry in PATH; drop it.
        Remove-UserPathEntry -Directory (Join-Path $InstallRoot 'current')
    }
    Set-ActiveRuntime -Path $target
    $pruned = Remove-OldRuntimeBuilds -BackendFamily (Get-BackendFamily -Backend $backendChoice) -ActivePath $target
    if (@($pruned).Count -gt 0) { Write-Info "Kept the newest two $backendChoice builds; removed $($pruned -join ', ')." }
    Write-Success "llama.cpp $tag ($backendChoice) is installed at $target and is the active runtime."
    # Device names differ between builds (ROCm0 vs Vulkan0), so rebuild the launcher
    # for the new build instead of leaving one that names a device it cannot find.
    $active = Get-ActiveModel
    if ($null -ne $active) {
        New-Launchers -ActiveModel $active -EffectiveContext ([int]$active.context_size)
        Write-Info 'Server launcher rebuilt for the new llama.cpp build.'
    }
    return $tag
}

# ---------------------------------------------------------------------
# Model installation, activation, launchers, and server
# ---------------------------------------------------------------------

function Get-ActiveModel {
    $statePath = Join-Path $InstallRoot 'active-model.json'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json } catch { return $null }
}

function Get-UserArgsOverridePath {
    Join-Path $InstallRoot 'server-args.user.json'
}

function Get-UserServerArgOverrides {
    # A user-owned, update-safe override file: a JSON array of strings, each a flag
    # or a flag's value (e.g. ["--threads", "12", "--no-mmap"]). Never written by this
    # script; only read and merged last, so it is never overwritten by an update.
    $path = Get-UserArgsOverridePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return ,@() }
    try {
        $raw = Get-Content -LiteralPath $path -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) { return ,@() }
        $parsed = $raw | ConvertFrom-Json
    } catch {
        Write-WarnLine "server-args.user.json is not valid JSON; ignoring it until it is fixed. ($($_.Exception.Message))"
        return ,@()
    }
    $items = @($parsed)
    foreach ($item in $items) {
        if ($item -isnot [string]) {
            Write-WarnLine 'server-args.user.json must be a JSON array of strings (flags and their values); ignoring it.'
            return ,@()
        }
    }
    return ,@($items)
}

function Merge-ServerArguments {
    param([string[]] $Base, [string[]] $Overrides)
    # User overrides win: drop any base flag (and its paired value) that an override
    # also sets, then append the overrides so they apply last.
    if ($null -eq $Overrides -or $Overrides.Count -eq 0) { return ,@($Base) }
    $overrideFlags = @($Overrides | Where-Object { $_.StartsWith('--') })
    $result = New-Object System.Collections.Generic.List[string]
    $i = 0
    while ($i -lt $Base.Count) {
        $flag = $Base[$i]
        if ($flag.StartsWith('--') -and ($overrideFlags -contains $flag)) {
            $i++
            if ($i -lt $Base.Count -and -not $Base[$i].StartsWith('--')) { $i++ }
            continue
        }
        $result.Add($flag)
        $i++
    }
    $result.AddRange([string[]]$Overrides)
    return ,@($result.ToArray())
}

function Test-IntegratedGpuName {
    param([string] $Name)
    return ($Name -match '(?i)Radeon.*(Graphics|780M|680M|660M|610M|760M|8060S)' -and $Name -notmatch '(?i)\bRX\b|Radeon Pro')
}

function ConvertFrom-LlamaDeviceList {
    param([string[]] $Lines)
    # llama-server --list-devices prints "  Vulkan0: AMD Radeon RX 9070 XT (16304 MiB, 15416 MiB free)".
    $devices = @()
    foreach ($line in $Lines) {
        $m = [regex]::Match([string]$line, '^\s+([A-Za-z]+[0-9]+):\s+(.+?)\s+\(([0-9]+) MiB')
        if ($m.Success) {
            $devices += [pscustomobject]@{
                Id = $m.Groups[1].Value; Name = $m.Groups[2].Value
                MiB = [int]$m.Groups[3].Value; Integrated = (Test-IntegratedGpuName $m.Groups[2].Value)
            }
        }
    }
    return ,@($devices)
}

function Get-GpuDeviceSelection {
    param($Devices)
    # Choose the dedicated Radeon by name heuristic and largest dedicated VRAM, never a
    # fixed Vulkan0/ROCm0 index: driver updates can reorder devices. The typed result lets
    # the start path refuse an iGPU-only machine instead of silently falling back to it.
    $all = @($Devices)
    if ($all.Count -eq 0) {
        return [pscustomobject]@{ status = 'no_devices'; device = ''; reason = 'llama-server listed no GPU devices.'; devices = @() }
    }
    $dedicated = @($all | Where-Object { -not [bool]$_.Integrated } | Sort-Object MiB -Descending)
    if ($dedicated.Count -eq 0) {
        $names = @($all | ForEach-Object { [string]$_.Name }) -join ', '
        return [pscustomobject]@{ status = 'integrated_only'; device = ''; reason = "Only AMD integrated graphics were listed ($names); the discrete Radeon was not found."; devices = @($all) }
    }
    $chosen = $dedicated[0]
    return [pscustomobject]@{
        status = 'pinned'
        device = [string]$chosen.Id
        reason = "Pinned $($chosen.Name) ($($chosen.MiB) MiB) as $($chosen.Id)."
        devices = @($all)
    }
}

function Select-PrimaryLlamaDevice {
    param($Devices)
    return [string](Get-GpuDeviceSelection -Devices $Devices).device
}

function Get-PrimaryLlamaDevice {
    return [string](Get-GpuPinningReport).device
}

function Get-GpuPinningReport {
    # The device inventory of the active build, as a typed selection. No runtime is not an
    # error: the caller (launcher generation) simply has no device to pin yet.
    param([string] $RuntimePath = '')
    if ([string]::IsNullOrWhiteSpace($RuntimePath)) { $RuntimePath = Split-Path -Parent (Get-RuntimeExecutablePath) }
    if ([string]::IsNullOrWhiteSpace($RuntimePath) -or -not (Test-Path -LiteralPath (Join-Path $RuntimePath 'llama-server.exe') -PathType Leaf)) {
        return [pscustomobject]@{ status = 'no_runtime'; device = ''; reason = 'No llama.cpp build is installed to ask for its devices.'; devices = @() }
    }
    return Get-GpuDeviceSelection -Devices (Get-LlamaDeviceList -Directory $RuntimePath)
}

function Assert-DiscreteGpuForStart {
    # Start guard: an iGPU-only machine must not silently run on the Ryzen iGPU. A user who
    # explicitly passes --device in server-args.user.json has made that choice, so the
    # override is honoured instead of blocked.
    $overrides = Get-UserServerArgOverrides
    if (@($overrides | Where-Object { [string]$_ -eq '--device' }).Count -gt 0) { return $null }
    $selection = Get-GpuPinningReport
    if ($selection.status -eq 'integrated_only') {
        throw "Only AMD integrated graphics were found. This tool will not silently start on the iGPU; connect a discrete Radeon or add an explicit --device to server-args.user.json."
    }
    return $selection
}

function Get-LlamaDeviceList {
    param([string] $Directory, [ValidateSet('llama-server.exe', 'llama-bench.exe')] [string] $Executable = 'llama-server.exe')
    $exe = Join-Path $Directory $Executable
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { return ,@() }
    $previous = $ErrorActionPreference
    $lines = @()
    Push-Location (Split-Path -Parent $exe)
    try {
        $ErrorActionPreference = 'Continue'
        $lines = @(& $exe --list-devices 2>&1 | ForEach-Object { [string]$_ })
    } catch {
        $lines = @()
    } finally {
        Pop-Location
        $ErrorActionPreference = $previous
    }
    return ,(ConvertFrom-LlamaDeviceList -Lines $lines)
}

function Get-ServerArguments {
    param($ActiveModel, [int] $EffectiveContext, [string] $Device = '')
    # Single source of truth for both the generated launcher and Start-ActiveServer.
    # A selected Tune preset is opt-in: with no selection this function is byte-for-byte
    # the same argument list as before. The preset may also raise the per-slot context
    # for the Long context tier; it is still bounded by the fit estimate that produced it.
    $serverContext = [int]$EffectiveContext
    $tunePreset = Get-TunePresetForModel -ModelId ([string]$ActiveModel.id)
    if ($null -ne $tunePreset -and [int]$tunePreset.context_size -gt 0) { $serverContext = [int]$tunePreset.context_size }
    $arguments = @(
        '--model', [string]$ActiveModel.model_path
    )
    if (-not [string]::IsNullOrWhiteSpace([string]$ActiveModel.mmproj_path)) {
        $arguments += @('--mmproj', [string]$ActiveModel.mmproj_path)
    }
    $arguments += @(
        '--alias', [string]$ActiveModel.alias,
        '--host', '127.0.0.1',
        '--port', [string]$Port,
        '--gpu-layers', 'auto',
        '--fit', 'on',
        '--fit-target', '1024',
        '--parallel', [string]$script:ServerSlots,
        '--ctx-size', [string]($serverContext * $script:ServerSlots),
        '--flash-attn', 'on',
        '--cache-type-k', 'q8_0',
        '--cache-type-v', 'q8_0',
        '--jinja',
        # N-gram speculative drafting: llama.cpp guesses the next few tokens from
        # patterns already in this conversation and verifies them, so replies are
        # unchanged. Newer llama.cpp builds gain speed on repeated output (code,
        # lists). AMD's ROCm 7.2.1 package (b8407) cannot combine it with
        # hybrid-attention models such as Qwen3.5: it logs "speculative decoding not
        # supported by this context" and does nothing (measured: no effect either
        # way). Opt out with server-args.user.json: ["--spec-type", "none"].
        '--spec-type', 'ngram-mod'
    )
    if ($null -ne $tunePreset) {
        $arguments += @('--batch-size', [string]$tunePreset.batch_size, '--ubatch-size', [string]$tunePreset.ubatch_size)
    }
    # Opt-in MoE expert offload: only a layer count the user chose for this model (settings
    # moe_cpu_layers). Nothing is written by default; server-args.user.json still wins below.
    $moeLayers = Get-MoeCpuLayers -ModelId ([string]$ActiveModel.id)
    if ($null -ne $moeLayers) { $arguments += @('--n-cpu-moe', [string]$moeLayers) }
    if (-not [string]::IsNullOrWhiteSpace($Device)) { $arguments += @('--device', $Device) }
    if (Test-ThinkingEnabled -ActiveModel $ActiveModel) {
        $arguments += @('--reasoning', 'on', '--reasoning-format', 'deepseek', '--reasoning-budget', '2048')
    } elseif ([bool]$ActiveModel.reasoning) {
        # Qwen reasoning models often place the tool call inside the thinking block;
        # the server then returns it as reasoning with no content and no tool_calls,
        # and VS Code reports "Sorry, no response was returned".
        $arguments += @('--reasoning', 'off')
    }
    $idleSeconds = Get-IdleSleepSeconds
    if ($idleSeconds -gt 0) {
        # Unloads the model from VRAM after this much idle time and reloads it on the next
        # request, so a gamer gets their graphics memory back without stopping anything.
        $arguments += @('--sleep-idle-seconds', [string]$idleSeconds)
    }
    $arguments += '--metrics'
    return ,(Merge-ServerArguments -Base $arguments -Overrides (Get-UserServerArgOverrides))
}

# ---- Router mode and game pause -------------------------------------------------
# The server runs as llama.cpp's router with one preset section: the model's own flags live
# in server-preset.ini (generated from Get-ServerArguments, so the launcher and the direct
# start cannot disagree), and the router owns the port. The router is what makes unloading
# possible: POST /models/unload frees the model's memory, and the next request loads it again.
# Single-model mode has no such route (verified: 404). Idle sleep stays per model, because a
# router-level --sleep-idle-seconds does not unload (verified on the installed build).

function Get-ServerPresetPath {
    return (Join-Path $InstallRoot 'server-preset.ini')
}

function Split-ServerArguments {
    # Pairs each flag with its value (a flag without one is a switch). Returns the router's
    # own flags and the model's flags, each in the original order.
    param([string[]] $Arguments)
    $router = New-Object System.Collections.Generic.List[string]
    $model = New-Object System.Collections.Generic.List[string]
    $i = 0
    while ($i -lt $Arguments.Count) {
        $flag = [string]$Arguments[$i]
        $pair = @($flag)
        if (($i + 1) -lt $Arguments.Count -and -not ([string]$Arguments[$i + 1]).StartsWith('--')) {
            $pair += [string]$Arguments[$i + 1]
            $i++
        }
        $i++
        if (@('--host', '--port', '--metrics') -contains $flag) { $router.AddRange([string[]]$pair) } else { $model.AddRange([string[]]$pair) }
    }
    return [pscustomobject]@{ Router = @($router.ToArray()); Model = @($model.ToArray()) }
}

function Get-InstallRelativePath {
    # The server runs with the install folder as its working directory (the launcher and the
    # direct start both push there), so a model file inside the folder is written relative to
    # it, with forward slashes. That keeps the folder movable. Anything outside stays absolute.
    param([string] $Path)
    $root = ([string]$InstallRoot).TrimEnd('\') + '\'
    if ($Path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { return ($Path.Substring($root.Length) -replace '\\', '/') }
    return $Path
}

function ConvertTo-ServerPresetText {
    # INI for the router: one section named after the alias (the name clients send as
    # "model"), one key per flag without its dashes, and a switch written as "true".
    # load-on-startup keeps the old behaviour: the model is in memory when the server answers.
    param([string] $Alias, [string[]] $ModelArguments)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("[$Alias]")
    $i = 0
    while ($i -lt $ModelArguments.Count) {
        $key = ([string]$ModelArguments[$i]).Substring(2)
        if (($i + 1) -lt $ModelArguments.Count -and -not ([string]$ModelArguments[$i + 1]).StartsWith('--')) {
            $value = [string]$ModelArguments[$i + 1]
            if (@('model', 'mmproj') -contains $key) { $value = Get-InstallRelativePath -Path $value }
            $lines.Add("$key = $value")
            $i += 2
        } else {
            $lines.Add("$key = true")
            $i++
        }
    }
    $lines.Add('load-on-startup = true')
    return (($lines -join "`n") + "`n")
}

function Write-ServerPreset {
    # Writes server-preset.ini and returns the router's own command line. Launchers and the
    # direct start both come through here, so the preset and the command line always come
    # from the same Get-ServerArguments list (single source of truth, as before).
    param($ActiveModel, [int] $EffectiveContext, $Device = $null)
    # Assigned, not wrapped in @(): Get-ServerArguments returns its list through ,(...), and @()
    # would wrap that once more, so the whole list would arrive as a single item.
    if ($null -eq $Device) { $Device = (Get-GpuPinningReport).device }
    $all = Get-ServerArguments -ActiveModel $ActiveModel -EffectiveContext $EffectiveContext -Device ([string]$Device)
    $split = Split-ServerArguments -Arguments ([string[]]$all)
    $text = ConvertTo-ServerPresetText -Alias ([string]$ActiveModel.alias) -ModelArguments $split.Model
    New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
    [IO.File]::WriteAllText((Get-ServerPresetPath), $text, (New-Object System.Text.UTF8Encoding($false)))
    return ,@($split.Router + @('--models-preset', (Get-ServerPresetPath), '--models-max', '1'))
}

function Resolve-RouterModelState {
    # Pure: the router's /models status plus the model process's own sleep flag from /props.
    # 'loaded' with is_sleeping means the model is asleep (memory released, wakes on the next request).
    param([string] $RouterStatus, $IsSleeping = $null)
    switch ($RouterStatus) {
        'loaded' { if ($IsSleeping -eq $true) { return 'asleep' } return 'loaded' }
        'loading' { return 'loading' }
        'unloaded' { return 'unloaded' }
        default { return 'unknown' }
    }
}

function Get-RouterModelState {
    param([string] $Alias)
    if ([string]::IsNullOrWhiteSpace($Alias)) { return 'unknown' }
    $status = ''
    try {
        $models = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/models" -TimeoutSec 2
        $entry = @($models.data | Where-Object { [string]$_.id -eq $Alias } | Select-Object -First 1)
        if ($entry.Count -gt 0 -and $entry[0].PSObject.Properties.Name -contains 'status') { $status = [string]$entry[0].status.value }
    } catch { return 'unknown' }
    $sleeping = $null
    if ($status -eq 'loaded') {
        try {
            $props = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/props?model=$([uri]::EscapeDataString($Alias))" -TimeoutSec 2
            if ($props.PSObject.Properties.Name -contains 'is_sleeping') { $sleeping = [bool]$props.is_sleeping }
        } catch { $sleeping = $null }
    }
    return (Resolve-RouterModelState -RouterStatus $status -IsSleeping $sleeping)
}

function Get-ServerRequestsProcessing {
    # -1 when unknown: the watcher then treats the model as busy and does not unload.
    param([string] $Alias)
    try {
        $text = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/metrics?model=$([uri]::EscapeDataString($Alias))" -TimeoutSec 2
        $match = [regex]::Match([string]$text, '(?m)^llamacpp:requests_processing\s+([0-9.]+)')
        if ($match.Success) { return [int][double]$match.Groups[1].Value }
    } catch { }
    return -1
}

function Invoke-ModelUnload {
    param([string] $Alias)
    $body = ConvertTo-Json -InputObject @{ model = $Alias } -Compress
    Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$Port/models/unload" -ContentType 'application/json' -Body $body -TimeoutSec 60 | Out-Null
}

function Invoke-ModelWarmup {
    # A one-token request: the router loads the model on demand, so this is the wake-up.
    param([string] $Alias)
    $body = ConvertTo-Json -InputObject @{
        model = $Alias
        messages = @(@{ role = 'user'; content = 'Reply with OK.' })
        max_tokens = 1
        stream = $false
        chat_template_kwargs = @{ enable_thinking = $false }
    } -Depth 6 -Compress
    Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$Port/v1/chat/completions" -ContentType 'application/json' -Body $body -TimeoutSec 600 | Out-Null
}

function Get-GamePauseGiB {
    # 0 = off (the default, opt-in like idle unload). When on, the model unloads while another
    # program holds at least this much graphics memory.
    $settings = Get-AppSettings
    if (-not $settings.ContainsKey('game_pause_gib')) { return 0 }
    $gib = 0
    if (-not [int]::TryParse([string]$settings['game_pause_gib'], [ref]$gib)) { return 0 }
    if ($gib -lt 4) { return 0 }
    return [Math]::Min($gib, 40)
}

function Get-GamePauseStep {
    # One watcher tick as a pure function, so the tests can drive it with a sequence of samples.
    # Unload only after two high samples in a row and only while no request is running, so a
    # brief spike or a chat in progress never flaps the model. Wake only after a full minute of
    # low use, with a 3 GiB gap below the threshold as hysteresis.
    param([hashtable] $State, [bool] $ModelLoaded, [int] $RequestsProcessing, [double] $TotalGiB, [double] $EstimateGiB, [double] $ThresholdGiB, [int] $TickSeconds = 5)
    $next = @{ high = [int]$State['high']; low = [int]$State['low']; paused = [bool]$State['paused'] }
    $otherGiB = $TotalGiB
    if ($ModelLoaded) { $otherGiB = $TotalGiB - $EstimateGiB }
    $action = 'none'
    if ($ModelLoaded -and $otherGiB -ge $ThresholdGiB) { $next['high'] = $next['high'] + 1 } else { $next['high'] = 0 }
    if ($next['high'] -ge 2 -and $RequestsProcessing -eq 0) {
        $action = 'unload'
        $next['paused'] = $true
        $next['high'] = 0
        $next['low'] = 0
    } elseif ($next['paused']) {
        if ($otherGiB -le ($ThresholdGiB - 3)) { $next['low'] = $next['low'] + $TickSeconds } else { $next['low'] = 0 }
        if ($next['low'] -ge 60) {
            if (-not $ModelLoaded) { $action = 'wake' }
            $next['paused'] = $false
            $next['low'] = 0
        }
    }
    return @{ action = $action; state = $next; other_gib = [Math]::Round($otherGiB, 1) }
}

function Copy-WatcherTools {
    # The install folder keeps its own copy of this script and its catalogue, so the generated
    # launchers and the watcher keep working after the extracted ZIP folder is moved or deleted.
    New-Item -ItemType Directory -Path (Join-Path (Join-Path $InstallRoot 'tools') 'catalog') -Force | Out-Null
    $toolsScript = Join-Path (Join-Path $InstallRoot 'tools') 'Install-LlamaCpp-AMD.ps1'
    Copy-Item -LiteralPath $script:ScriptSource -Destination $toolsScript -Force
    Copy-Item -Path (Join-Path (Get-CatalogDirectory) '*.json') -Destination (Join-Path (Join-Path $InstallRoot 'tools') 'catalog') -Force
    return $toolsScript
}

function Write-WatchLog {
    param([string] $Message)
    $logDir = Join-Path $InstallRoot 'logs'
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    $line = "$((Get-Date).ToString('s')) $Message`r`n"
    [IO.File]::AppendAllText((Join-Path $logDir 'game-watch.log'), $line, (New-Object System.Text.UTF8Encoding($false)))
}

function Start-GameWatchIfEnabled {
    # Direct starts (the window, the text menu, the desktop) launch the watcher here; generated
    # launchers start the same copy with a line of their own.
    if ((Get-GamePauseGiB) -le 0) { return }
    $toolsScript = Copy-WatcherTools
    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $toolsScript, '-Action', 'GameWatch', '-InstallRoot', $InstallRoot) | Out-Null
}

function Invoke-GameWatch {
    # Background helper (-Action GameWatch). Samples the graphics memory every 5 s and unloads
    # or wakes the model through the router. It exits on its own after the server has been gone
    # for 15 s, and a second copy exits at once, so it never outlives the server.
    $lockPath = Join-Path (Join-Path $InstallRoot 'logs') 'game-watch.pid'
    New-Item -ItemType Directory -Path (Join-Path $InstallRoot 'logs') -Force | Out-Null
    if (Test-Path -LiteralPath $lockPath -PathType Leaf) {
        $otherPid = 0
        if ([int]::TryParse((Get-Content -LiteralPath $lockPath -Raw).Trim(), [ref]$otherPid) -and $otherPid -ne $PID -and $null -ne (Get-Process -Id $otherPid -ErrorAction SilentlyContinue)) { return 0 }
    }
    Set-Content -LiteralPath $lockPath -Value ([string]$PID) -Encoding ASCII
    $hardware = Get-HardwareProfile
    $total = [double]$hardware.MaxAmdVramGiB
    if (-not $hardware.HasAmdGpu -or $total -lt 4) { Write-WatchLog 'Game pause needs a discrete Radeon with at least 4 GiB of graphics memory; exiting.'; Remove-Item -LiteralPath $lockPath -Force; return 0 }
    Write-WatchLog "Game pause watching $total GiB of graphics memory."
    $state = @{ high = 0; low = 0; paused = $false }
    $absent = 0
    try {
        while ($true) {
            Start-Sleep -Seconds 5
            $threshold = [double](Get-GamePauseGiB)
            if ($threshold -le 0) { Write-WatchLog 'Game pause is off; exiting.'; break }
            $server = Get-ServerState
            if (@($server.process_ids).Count -eq 0) { $absent++; if ($absent -ge 3) { Write-WatchLog 'The server is gone; exiting.'; break }; continue }
            $absent = 0
            $active = Get-ActiveModel
            if ($null -eq $active) { continue }
            $alias = [string]$active.alias
            $usage = Get-GpuMemoryUsage -TotalGiB $total
            if ($null -eq $usage) { continue }
            $modelState = Get-RouterModelState -Alias $alias
            if ($modelState -eq 'loading') { continue }
            $catalogModel = Get-ModelById -Id ([string]$active.id)
            $estimate = 0.0
            if ($null -ne $catalogModel) { $estimate = [double](Get-VramPreflight -Model $catalogModel -Hardware $hardware -Context ([int]$active.context_size) -UsedGiB 0).NeededGiB }
            $requests = Get-ServerRequestsProcessing -Alias $alias
            $step = Get-GamePauseStep -State $state -ModelLoaded ($modelState -eq 'loaded') -RequestsProcessing $requests -TotalGiB ([double]$usage.UsedGiB) -EstimateGiB $estimate -ThresholdGiB $threshold
            $state = $step.state
            if ($step.action -eq 'unload') {
                Invoke-ModelUnload -Alias $alias
                Write-WatchLog "Unloaded ${alias}: another program holds about $($step.other_gib) GiB of graphics memory."
            } elseif ($step.action -eq 'wake') {
                Invoke-ModelWarmup -Alias $alias
                Write-WatchLog "Loaded $alias again: the other program has gone."
            }
        }
    } finally {
        Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
    }
    return 0
}

function Test-ThinkingEnabled {
    param($ActiveModel)
    if ($ActiveModel.PSObject.Properties.Name -contains 'thinking') { return [bool]$ActiveModel.thinking }
    if ($ActiveModel -is [System.Collections.IDictionary] -and $ActiveModel.Contains('thinking')) { return [bool]$ActiveModel['thinking'] }
    # Older active-model.json files predate the setting: keep thinking only for non-tool models.
    $tools = if ($ActiveModel.PSObject.Properties.Name -contains 'tool_calling') { [bool]$ActiveModel.tool_calling } else { $false }
    return ([bool]$ActiveModel.reasoning -and -not $tools)
}

function ConvertTo-LauncherArgument {
    # Generated .cmd launchers are written as ASCII, so they must never embed the install
    # root's own characters: a folder named with spaces or a non-Latin character would be
    # written as '?' and the launcher would point at nothing. Every launcher sits in the
    # install root, so an absolute path inside it collapses to %~dp0 plus the remainder,
    # which cmd expands at run time from its own location.
    param([string] $Value)
    if ([string]::IsNullOrEmpty($Value) -or [string]::IsNullOrWhiteSpace($InstallRoot)) { return $Value }
    $root = $InstallRoot.TrimEnd('\')
    if ($Value.Length -le $root.Length -or -not $Value.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { return $Value }
    $rest = $Value.Substring($root.Length)
    if (-not $rest.StartsWith('\')) { return $Value }
    return '%~dp0' + $rest.TrimStart('\')
}

function New-Launchers {
    param($ActiveModel, $EffectiveContext)

    # Get-ServerArguments returns its list through the ,@() idiom, so a pipeline would see
    # it as one object; iterate it with foreach instead of piping it.
    # The router's command line; the model's own flags go to server-preset.ini (Write-ServerPreset).
    $gpuSelection = Get-GpuPinningReport
    $rawArgs = Write-ServerPreset -ActiveModel $ActiveModel -EffectiveContext $EffectiveContext -Device $gpuSelection.device
    $serverArgs = @()
    foreach ($arg in $rawArgs) { $serverArgs += ConvertTo-LauncherArgument -Value ([string]$arg) }

    # Pair each flag with its value on one line. Every line except the last ends
    # with a caret; a blank line inside a caret continuation would split the
    # command, so optional arguments must never leave an empty line behind.
    $lines = @()
    for ($i = 0; $i -lt $serverArgs.Count; $i++) {
        $line = $serverArgs[$i]
        if (($i + 1) -lt $serverArgs.Count -and -not $serverArgs[$i + 1].StartsWith('--')) {
            $value = $serverArgs[$i + 1]
            # A %~dp0 path is quoted too: unquoted, a spaced install folder would split it.
            if ($value -match '[\s\\%]') { $value = "`"$value`"" }
            $line = "$line $value"
            $i++
        }
        $lines += "  $line"
    }
    $argumentBlock = $lines -join " ^`r`n"

    # Game pause: the watcher runs from the install folder's own copy, minimised, and exits by
    # itself when the server stops. Only written when the setting is on.
    $gameWatchLine = ''
    if ((Get-GamePauseGiB) -gt 0) {
        Copy-WatcherTools | Out-Null
        $gameWatchLine = 'if exist "%~dp0tools\Install-LlamaCpp-AMD.ps1" start "llama.cpp game watch" /min powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\Install-LlamaCpp-AMD.ps1" -Action GameWatch -InstallRoot "%~dp0."'
    }
    $gpuWarningLine = ''
    if ($gpuSelection.status -eq 'integrated_only') {
        $gpuWarningLine = 'echo WARNING: only AMD integrated graphics were detected. The command center refuses to start on the iGPU unless --device is set in server-args.user.json.'
    }

    $runtimePath = Get-ActiveRuntimePath
    $serverTarget = if (-not [string]::IsNullOrWhiteSpace($runtimePath)) { Join-Path $runtimePath 'llama-server.exe' } else { Join-Path (Join-Path $InstallRoot 'current') 'llama-server.exe' }
    $serverLauncher = ConvertTo-LauncherArgument -Value $serverTarget
    $runtimeFolderLauncher = ConvertTo-LauncherArgument -Value (Split-Path -Parent $serverTarget)

    $start = @"
@echo off
setlocal
title llama.cpp - $($ActiveModel.name) - AMD backend
$gameWatchLine
$gpuWarningLine
pushd "%~dp0"
"$serverLauncher" ^
$argumentBlock
set "LLAMA_EXIT=%ERRORLEVEL%"
popd
echo.
echo llama-server exited with code %LLAMA_EXIT%.
pause
"@
    Set-Content -LiteralPath (Join-Path $InstallRoot 'Start-LlamaCpp.cmd') -Value $start -Encoding ASCII

    $devices = @"
@echo off
pushd "$runtimeFolderLauncher"
"$serverLauncher" --list-devices
echo.
echo Add --device DEVICE --split-mode none to select one GPU.
pause
popd
"@
    Set-Content -LiteralPath (Join-Path $InstallRoot 'Start-Devices.cmd') -Value $devices -Encoding ASCII

    $open = @"
@echo off
start "" "http://127.0.0.1:$Port/"
"@
    Set-Content -LiteralPath (Join-Path $InstallRoot 'Open-WebUI.cmd') -Value $open -Encoding ASCII

    # Chat.cmd and Gaming-Mode.cmd live next to the server launcher, not in the ZIP folder,
    # so the desktop shortcuts keep working if the downloaded folder is moved or deleted.
    # Plain batch, no delayed expansion. Chat.cmd prefers an app-style Edge or Chrome window
    # (no tabs or address bar) and falls back to the default browser.
    $chat = @"
@echo off
setlocal EnableExtensions
title Local AI chat
set "URL=http://127.0.0.1:$Port"
call :ready
if "%READY%"=="1" goto open
tasklist /fi "imagename eq llama-server.exe" 2>nul | find /i "llama-server.exe" >nul
if errorlevel 1 start "llama.cpp AI server" /min "%~dp0Start-LlamaCpp.cmd"
echo.
echo   Starting your local AI. The first load can take a minute or two.
<nul set /p "=  Please wait "
set /a WAITED=0
:wait
call :ready
if "%READY%"=="1" goto open
set /a WAITED+=2
if %WAITED% geq 240 goto slow
<nul set /p "=."
ping -n 3 127.0.0.1 >nul
goto wait
:open
echo.
set "APPBROWSER="
if exist "%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe" set "APPBROWSER=%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe"
if not defined APPBROWSER if exist "%ProgramFiles%\Microsoft\Edge\Application\msedge.exe" set "APPBROWSER=%ProgramFiles%\Microsoft\Edge\Application\msedge.exe"
if not defined APPBROWSER if exist "%ProgramFiles%\Google\Chrome\Application\chrome.exe" set "APPBROWSER=%ProgramFiles%\Google\Chrome\Application\chrome.exe"
if not defined APPBROWSER if exist "%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe" set "APPBROWSER=%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe"
if not defined APPBROWSER if exist "%LocalAppData%\Google\Chrome\Application\chrome.exe" set "APPBROWSER=%LocalAppData%\Google\Chrome\Application\chrome.exe"
if defined APPBROWSER goto appwindow
start "" "%URL%/"
goto opened
:appwindow
start "" "%APPBROWSER%" --app=%URL%/ --window-size=1100,800
:opened
echo   Your AI is ready. Everything stays on this PC.
if not defined LLAMACPP_NO_PAUSE ping -n 4 127.0.0.1 >nul
exit /b 0
:slow
echo.
echo   The AI has not finished loading after 4 minutes.
echo   Look at the "llama.cpp AI server" window for an error, or run the Command Center health check.
if not defined LLAMACPP_NO_PAUSE pause
exit /b 1
:ready
set "READY=0"
rem The router answers /health while its model is still loading, so ready means the model is loaded.
curl.exe -s -m 2 "%URL%/models" 2>nul | findstr /r /c:"value.:.loaded" >nul && set "READY=1"
exit /b 0
"@
    Set-Content -LiteralPath (Join-Path $InstallRoot 'Chat.cmd') -Value $chat -Encoding ASCII

    $gaming = @"
@echo off
setlocal
title AI off - gaming mode
tasklist /fi "imagename eq llama-server.exe" 2>nul | find /i "llama-server.exe" >nul
if errorlevel 1 goto already
taskkill /im llama-server.exe /f >nul 2>&1
ping -n 2 127.0.0.1 >nul
taskkill /f /im cmd.exe /fi "windowtitle eq llama.cpp - *" >nul 2>&1
echo.
echo   The AI is off and your graphics memory is free. Enjoy the game.
echo   Double-click "AI Chat" (or Chat.cmd) when you want it back.
goto end
:already
echo.
echo   The AI was not running, so your graphics memory is already free.
:end
if not defined LLAMACPP_NO_PAUSE ping -n 5 127.0.0.1 >nul
exit /b 0
"@
    Set-Content -LiteralPath (Join-Path $InstallRoot 'Gaming-Mode.cmd') -Value $gaming -Encoding ASCII

    if ($ActiveModel.Id -eq 'qwen3.8-27b') {
        Copy-Item -LiteralPath (Join-Path $InstallRoot 'Start-LlamaCpp.cmd') -Destination (Join-Path $InstallRoot 'Start-Qwen3.8.cmd') -Force
    }

    $uninstallPs = @'
param([switch] $Force)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootPrefix = $root.TrimEnd('\') + '\'
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not [string]::IsNullOrWhiteSpace($userPath)) {
    $kept = @($userPath -split ';' | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_) -and -not $_.TrimEnd('\').StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)
    })
    [Environment]::SetEnvironmentVariable('Path', ($kept -join ';'), 'User')
}
$running = Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue
if (($null -ne $running) -and -not $Force) { throw 'Stop llama-server before uninstalling.' }
Remove-Item -LiteralPath $root -Recurse -Force
Write-Host 'llama.cpp command center installation removed.'
'@
    Set-Content -LiteralPath (Join-Path $InstallRoot 'Uninstall.ps1') -Value $uninstallPs -Encoding UTF8

    $uninstallCmd = @"
@echo off
setlocal
set "ROOT=%~dp0"
echo This removes llama.cpp, all downloaded models, launchers, and the user PATH entry.
set /p "CONFIRM=Type YES to continue: "
if /I not "%CONFIRM%"=="YES" exit /b 1
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%Uninstall.ps1"
pause
"@
    Set-Content -LiteralPath (Join-Path $InstallRoot 'Uninstall.cmd') -Value $uninstallCmd -Encoding ASCII
}

function Set-ActiveModel {
    param($Model, $EffectiveContext, [switch] $SkipVerification)
    $modelsRoot = Join-Path $InstallRoot 'models'
    $modelPath = Join-Path $modelsRoot $Model.File
    if (-not $SkipVerification -and -not (Test-Path -LiteralPath $modelPath -PathType Leaf)) {
        throw "Model file is not installed: $modelPath"
    }
    $mmprojPath = ''
    if (-not [string]::IsNullOrWhiteSpace([string]$Model.Projector)) {
        $mmprojPath = Join-Path $modelsRoot (Get-ProjectorLocalName $Model)
        if (-not $SkipVerification -and -not (Test-Path -LiteralPath $mmprojPath -PathType Leaf)) {
            throw "Vision projector is not installed: $mmprojPath"
        }
    }
    $state = [ordered]@{
        id = $Model.Id
        name = $Model.Name
        alias = $Model.Alias
        repo = $Model.Repo
        model_file = $Model.File
        model_path = $modelPath
        mmproj_path = $mmprojPath
        reasoning = [bool]$Model.Reasoning
        tool_calling = [bool]$Model.Tools
        thinking = switch ($Thinking) {
            'On' { [bool]$Model.Reasoning }
            'Off' { $false }
            default { [bool]$Model.Reasoning -and -not [bool]$Model.Tools }
        }
        vision = [bool]$Model.Vision
        context_size = $EffectiveContext
        port = $Port
        activated_at = (Get-Date).ToUniversalTime().ToString('o')
    }
    New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
    $state | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $InstallRoot 'active-model.json') -Encoding UTF8
    New-Launchers -ActiveModel $state -EffectiveContext $EffectiveContext
}

# ---- Side-by-side runtimes -------------------------------------------------------
# Every downloaded build lives under <install root>\runtimes\<backend>\<tag>\. Settings
# key active_runtime names the one in use, so Vulkan and ROCm can be installed side by
# side and switched without downloading again. Legacy installs that still have current\
# are migrated by Initialize-RuntimeLayout (a move, never a re-download).

function Get-RuntimesRoot {
    return (Join-Path $InstallRoot 'runtimes')
}

function Get-RuntimeFolderName {
    # Relative folder for one build. The tag is sanitised because it comes from a
    # release name; the backend decides the first level.
    param([string] $Backend, [string] $Tag)
    $family = switch ($Backend) {
        'Vulkan' { 'vulkan' }
        'ROCm' { 'rocm' }
        'ROCmLatest' { 'rocm' }
        default { 'unknown' }
    }
    $safeTag = ([string]$Tag) -replace '[^A-Za-z0-9._-]', '_'
    if ([string]::IsNullOrWhiteSpace($safeTag)) { $safeTag = 'build' }
    return "$family/$safeTag"
}

function Get-BackendFamily {
    param([string] $Backend)
    if ($Backend -in @('ROCm', 'ROCmLatest')) { return 'rocm' }
    if ($Backend -eq 'Vulkan') { return 'vulkan' }
    return ([string]$Backend).ToLowerInvariant()
}

function Get-RuntimeInstallations {
    # Every installed build, newest folder order irrelevant: callers pick by backend/tag.
    $items = @()
    $root = Get-RuntimesRoot
    if (Test-Path -LiteralPath $root -PathType Container) {
        foreach ($backendDir in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            foreach ($buildDir in @(Get-ChildItem -LiteralPath $backendDir.FullName -Directory -ErrorAction SilentlyContinue)) {
                $manifestPath = Join-Path $buildDir.FullName 'installation.json'
                if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { continue }
                $installation = $null
                try { $installation = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json } catch { continue }
                $items += [pscustomobject]@{
                    path = $buildDir.FullName
                    relative_path = Get-InstallRelativePath -Path $buildDir.FullName
                    backend = [string]$installation.backend
                    tag = [string]$installation.tag
                    installation = $installation
                    exe_present = Test-Path -LiteralPath (Join-Path $buildDir.FullName 'llama-server.exe') -PathType Leaf
                }
            }
        }
    }
    # Legacy current\ stays visible to readers until migration moves it.
    $legacy = Join-Path $InstallRoot 'current'
    $legacyManifest = Join-Path $legacy 'installation.json'
    if (Test-Path -LiteralPath $legacyManifest -PathType Leaf) {
        $installation = $null
        try { $installation = Get-Content -LiteralPath $legacyManifest -Raw | ConvertFrom-Json } catch { $installation = $null }
        if ($null -ne $installation) {
            $items += [pscustomobject]@{
                path = $legacy
                relative_path = 'current'
                backend = [string]$installation.backend
                tag = [string]$installation.tag
                installation = $installation
                exe_present = Test-Path -LiteralPath (Join-Path $legacy 'llama-server.exe') -PathType Leaf
            }
        }
    }
    return @($items)
}

function Get-ActiveRuntimePath {
    # Settings choose the active build. A legacy current\ is still honoured so an old
    # install keeps working until the next install/start migrates it.
    $settings = Get-AppSettings
    if ($settings.ContainsKey('active_runtime')) {
        $relative = ([string]$settings['active_runtime']).Trim()
        if (-not [string]::IsNullOrWhiteSpace($relative)) {
            $candidate = Join-Path $InstallRoot ($relative -replace '/', '\')
            if (Test-Path -LiteralPath (Join-Path $candidate 'installation.json') -PathType Leaf) { return $candidate }
        }
    }
    $legacy = Join-Path $InstallRoot 'current'
    if (Test-Path -LiteralPath (Join-Path $legacy 'installation.json') -PathType Leaf) { return $legacy }
    $installs = @(Get-RuntimeInstallations | Where-Object { $_.relative_path -ne 'current' })
    if ($installs.Count -eq 1) { return [string]$installs[0].path }
    return $null
}

function Set-ActiveRuntime {
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    Set-AppSetting -Name 'active_runtime' -Value (Get-InstallRelativePath -Path $Path)
}

function Initialize-RuntimeLayout {
    # One-way, no-download migration of current\ into runtimes\<backend>\<tag>\. Safe to
    # call repeatedly; a move on the same volume keeps every file and hash intact.
    $legacy = Join-Path $InstallRoot 'current'
    $legacyManifest = Join-Path $legacy 'installation.json'
    if (-not (Test-Path -LiteralPath $legacyManifest -PathType Leaf)) { return (Get-ActiveRuntimePath) }
    $installation = $null
    try { $installation = Get-Content -LiteralPath $legacyManifest -Raw | ConvertFrom-Json } catch { return $null }
    if ($null -eq $installation) { return $null }
    $relative = Get-RuntimeFolderName -Backend ([string]$installation.backend) -Tag ([string]$installation.tag)
    $target = Join-Path (Get-RuntimesRoot) ($relative -replace '/', '\')
    if (-not (Test-Path -LiteralPath $target)) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        try {
            Move-Item -LiteralPath $legacy -Destination $target
        } catch {
            # A running server or another program holds the folder: keep using the legacy
            # location rather than leaving an unmetadata'd half-move behind.
            Set-ActiveRuntime -Path $legacy
            return $legacy
        }
    }
    Set-ActiveRuntime -Path $target
    return $target
}

function Get-RuntimeExecutablePath {
    $runtimePath = Get-ActiveRuntimePath
    if (-not [string]::IsNullOrWhiteSpace($runtimePath)) { return (Join-Path $runtimePath 'llama-server.exe') }
    # Legacy fallback only: current\ is used until the next install/start migrates it.
    return (Join-Path (Join-Path $InstallRoot 'current') 'llama-server.exe')
}

function Get-InstalledRuntime {
    $runtimePath = Get-ActiveRuntimePath
    if ([string]::IsNullOrWhiteSpace($runtimePath)) { return $null }
    $path = Join-Path $runtimePath 'installation.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try {
        $runtime = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $runtime | Add-Member -NotePropertyName 'path' -NotePropertyValue $runtimePath -Force
        $runtime | Add-Member -NotePropertyName 'relative_path' -NotePropertyValue (Get-InstallRelativePath -Path $runtimePath) -Force
        if (@($runtime.PSObject.Properties.Name) -notcontains 'sha256_source') {
            # Old installations omit sha256 entirely; under StrictMode a direct read throws,
            # which used to make this function return null for a perfectly good runtime.
            $savedSha = if (@($runtime.PSObject.Properties.Name) -contains 'sha256') { [string]$runtime.sha256 } else { '' }
            $source = if ([string]::IsNullOrWhiteSpace($savedSha)) { '' } else { 'local' }
            $runtime | Add-Member -NotePropertyName 'sha256_source' -NotePropertyValue $source -Force
        }
        return $runtime
    } catch { return $null }
}

function Get-RuntimeUpdateCachePath {
    return (Join-Path $InstallRoot 'runtime-update-cache.json')
}

function Get-RuntimeUpdateCache {
    $cache = @{}
    $path = Get-RuntimeUpdateCachePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $cache }
    try {
        $parsed = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        foreach ($property in $parsed.PSObject.Properties) { $cache[$property.Name] = $property.Value }
    } catch { $cache = @{} }
    return $cache
}

function Set-RuntimeUpdateCacheEntry {
    param([string] $Family, $Entry)
    try {
        $cache = Get-RuntimeUpdateCache
        $cache[$Family] = $Entry
        $json = ConvertTo-Json -InputObject ([pscustomobject]$cache) -Depth 6
        [IO.File]::WriteAllText((Get-RuntimeUpdateCachePath), $json, (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

function Get-RuntimeCacheAgeMinutes {
    param($CheckedAt)
    if ([string]::IsNullOrWhiteSpace([string]$CheckedAt)) { return [double]::MaxValue }
    try { return ((Get-Date).ToUniversalTime() - ([datetime]$CheckedAt).ToUniversalTime()).TotalMinutes } catch { return [double]::MaxValue }
}

function Test-RuntimeTagNewer {
    # Only one tag scheme is actually comparable: ggml-org's bNNNN builds. AMD's package tag
    # (rocm-7.2.1-b8407) is a packaging label, so it is compared as an opaque string only.
    param([string] $Installed, [string] $Latest)
    if ([string]::IsNullOrWhiteSpace($Installed) -or [string]::IsNullOrWhiteSpace($Latest)) { return $false }
    $a = [regex]::Match([string]$Installed, '^b([0-9]+)$')
    $b = [regex]::Match([string]$Latest, '^b([0-9]+)$')
    if ($a.Success -and $b.Success) { return ([long]$b.Groups[1].Value -gt [long]$a.Groups[1].Value) }
    return ([string]$Installed -ne [string]$Latest)
}

function Get-RuntimeLatestReleaseInfo {
    param([string] $Backend, [string] $InstalledTag)
    $family = Get-BackendFamily -Backend $Backend
    if ($family -eq 'vulkan') {
        $selected = Get-LatestLlamaCppVulkanAsset
        return [pscustomobject]@{ tag = [string]$selected.Release.tag_name; channel = 'ggml-org Vulkan'; source = ($script:GitHubApi + '/latest') }
    }
    if ($family -eq 'rocm') {
        if ([string]$InstalledTag -match '^b[0-9]+$') {
            $selected = Get-LatestLlamaCppRocmAsset
            return [pscustomobject]@{ tag = [string]$selected.Release.tag_name; channel = 'ggml-org ROCm'; source = ($script:GitHubApi + '/latest') }
        }
        $amd = (Get-CatalogJson -Name 'runtimes.json').amd_rocm_package
        return [pscustomobject]@{ tag = [string]$amd.tag; channel = 'AMD validated ROCm'; source = [string]$amd.page }
    }
    throw "Unknown runtime backend '$Backend'."
}

function Get-RuntimeUpdateStatus {
    # Read-only newest-available check. Cached for six hours; a failed GitHub call is cached
    # for ten minutes so an offline machine keeps working and does not hammer the API.
    param([string] $Backend = 'Vulkan', [string] $InstalledTag = '', [switch] $ForceRefresh)
    $family = Get-BackendFamily -Backend $Backend
    $cache = Get-RuntimeUpdateCache
    $entry = if ($cache.ContainsKey($family)) { $cache[$family] } else { $null }
    $age = if ($null -ne $entry) { Get-RuntimeCacheAgeMinutes -CheckedAt $entry.checked_at } else { [double]::MaxValue }
    $hasError = ($null -ne $entry) -and (-not [string]::IsNullOrWhiteSpace([string]$entry.error))
    if (-not $ForceRefresh -and $null -ne $entry) {
        if ((-not $hasError -and $age -lt 360) -or ($hasError -and $age -lt 10)) {
            $latest = [string]$entry.latest_tag
            return [pscustomobject]@{
                backend = [string]$Backend; family = $family; installed_tag = [string]$InstalledTag
                latest_tag = $latest; channel = [string]$entry.channel; source = [string]$entry.source
                checked_at = [string]$entry.checked_at; cached = $true; stale = ($age -ge 360)
                update_available = (Test-RuntimeTagNewer -Installed $InstalledTag -Latest $latest)
                error = [string]$entry.error
            }
        }
    }
    $previousQuiet = $script:JsonDocumentsOnly
    $script:JsonDocumentsOnly = $true
    try {
        try {
            $info = Get-RuntimeLatestReleaseInfo -Backend $Backend -InstalledTag $InstalledTag
            $newEntry = [pscustomobject]@{
                latest_tag = [string]$info.tag; channel = [string]$info.channel; source = [string]$info.source
                checked_at = (Get-Date).ToUniversalTime().ToString('o'); error = ''
            }
            Set-RuntimeUpdateCacheEntry -Family $family -Entry $newEntry
            return [pscustomobject]@{
                backend = [string]$Backend; family = $family; installed_tag = [string]$InstalledTag
                latest_tag = [string]$info.tag; channel = [string]$info.channel; source = [string]$info.source
                checked_at = [string]$newEntry.checked_at; cached = $false; stale = $false
                update_available = (Test-RuntimeTagNewer -Installed $InstalledTag -Latest ([string]$info.tag))
                error = ''
            }
        } catch {
            $message = [string]$_.Exception.Message
            $newEntry = [pscustomobject]@{
                latest_tag = if ($null -ne $entry) { [string]$entry.latest_tag } else { '' }
                channel = if ($null -ne $entry) { [string]$entry.channel } else { '' }
                source = if ($null -ne $entry) { [string]$entry.source } else { '' }
                checked_at = (Get-Date).ToUniversalTime().ToString('o'); error = $message
            }
            Set-RuntimeUpdateCacheEntry -Family $family -Entry $newEntry
            return [pscustomobject]@{
                backend = [string]$Backend; family = $family; installed_tag = [string]$InstalledTag
                latest_tag = [string]$newEntry.latest_tag; channel = [string]$newEntry.channel; source = [string]$newEntry.source
                checked_at = [string]$newEntry.checked_at; cached = ($null -ne $entry); stale = $true
                update_available = (Test-RuntimeTagNewer -Installed $InstalledTag -Latest ([string]$newEntry.latest_tag))
                error = $message
            }
        }
    } finally {
        $script:JsonDocumentsOnly = $previousQuiet
    }
}

function Get-RuntimeUpdateReport {
    # One entry per installed backend family: the active build for that family, else its newest.
    param([switch] $ForceRefresh)
    $chosen = @{}
    $active = Get-InstalledRuntime
    if ($null -ne $active) {
        $family = Get-BackendFamily -Backend ([string]$active.backend)
        $chosen[$family] = [pscustomobject]@{ backend = [string]$active.backend; tag = [string]$active.tag }
    }
    foreach ($install in @(Get-RuntimeInstallations)) {
        $family = Get-BackendFamily -Backend ([string]$install.backend)
        if ($chosen.ContainsKey($family)) { continue }
        $chosen[$family] = [pscustomobject]@{ backend = [string]$install.backend; tag = [string]$install.tag }
    }
    $updates = @()
    foreach ($family in @($chosen.Keys | Sort-Object)) {
        $item = $chosen[$family]
        $updates += Get-RuntimeUpdateStatus -Backend $item.backend -InstalledTag $item.tag -ForceRefresh:$ForceRefresh
    }
    return [pscustomobject]@{
        schema_version = 1
        generated_at = (Get-Date).ToUniversalTime().ToString('o')
        updates = @($updates)
    }
}

function Remove-OldRuntimeBuilds {
    # Keep the newest N builds per backend family (default 2). The active build is never
    # deleted even if its installed_at is older, so a manual switch cannot strand you.
    param([string] $BackendFamily, [int] $Keep = 2, [string] $ActivePath = '')
    if ($Keep -lt 1) { $Keep = 1 }
    if ([string]::IsNullOrWhiteSpace($ActivePath)) { $ActivePath = [string](Get-ActiveRuntimePath) }
    $installs = @(Get-RuntimeInstallations | Where-Object {
        ((Get-BackendFamily -Backend ([string]$_.backend)) -eq $BackendFamily) -and ([string]$_.relative_path -ne 'current')
    })
    $sorted = @($installs | Sort-Object -Property @{ Expression = {
        $stamp = [string](Get-StateProperty -Object $_.installation -Name 'installed_at' -Default '')
        try { [datetime]$stamp } catch { [datetime]::MinValue }
    } } -Descending)
    $keepPaths = @($sorted | Select-Object -First $Keep | ForEach-Object { [string]$_.path })
    if (-not [string]::IsNullOrWhiteSpace($ActivePath) -and ($keepPaths -notcontains $ActivePath)) { $keepPaths += $ActivePath }
    $removed = @()
    foreach ($install in $sorted) {
        if ($keepPaths -contains [string]$install.path) { continue }
        try {
            Remove-Item -LiteralPath ([string]$install.path) -Recurse -Force
            $removed += [string]$install.tag
        } catch {
            Write-WarnLine "Could not remove the old runtime $($install.tag): $($_.Exception.Message)"
        }
    }
    return ,@($removed)
}

function Get-RuntimeRollbackTarget {
    param([string] $BackendFamily)
    $activePath = Get-ActiveRuntimePath
    if ([string]::IsNullOrWhiteSpace($activePath)) { return $null }
    $candidates = @(Get-RuntimeInstallations | Where-Object {
        ((Get-BackendFamily -Backend ([string]$_.backend)) -eq $BackendFamily) -and ([string]$_.relative_path -ne 'current') -and ([string]$_.path -ne $activePath)
    })
    $sorted = @($candidates | Sort-Object -Property @{ Expression = {
        $stamp = [string](Get-StateProperty -Object $_.installation -Name 'installed_at' -Default '')
        try { [datetime]$stamp } catch { [datetime]::MinValue }
    } } -Descending)
    if ($sorted.Count -eq 0) { return $null }
    return $sorted[0]
}

function Invoke-RuntimeRollback {
    # Repoint the active runtime to the previous build for its backend, rebuild launchers,
    # and restart only if a server was running. A missing or broken target is refused before
    # settings change. Typed result; never throws.
    param([string] $Backend = 'Auto')
    try {
        $active = Get-InstalledRuntime
        if ($null -eq $active) {
            return [pscustomobject]@{ schema_version = 1; action = 'rollback'; status = 'no_runtime'; detail = 'No active llama.cpp runtime is installed.'; backend = ''; from_tag = ''; to_tag = ''; restarted = $false }
        }
        $family = if ([string]::IsNullOrWhiteSpace($Backend) -or $Backend -eq 'Auto') { Get-BackendFamily -Backend ([string]$active.backend) } else { Get-BackendFamily -Backend $Backend }
        if ((Get-BackendFamily -Backend ([string]$active.backend)) -ne $family) {
            return [pscustomobject]@{ schema_version = 1; action = 'rollback'; status = 'wrong_backend'; detail = "The active runtime is $($active.backend); select the $Backend runtime before rolling it back."; backend = $family; from_tag = [string]$active.tag; to_tag = ''; restarted = $false }
        }
        $target = Get-RuntimeRollbackTarget -BackendFamily $family
        if ($null -eq $target) {
            return [pscustomobject]@{ schema_version = 1; action = 'rollback'; status = 'no_previous'; detail = 'No previous build is installed for this backend; two builds are needed to roll back.'; backend = $family; from_tag = [string]$active.tag; to_tag = ''; restarted = $false }
        }
        if (-not (Test-Path -LiteralPath ([string]$target.path) -PathType Container)) {
            return [pscustomobject]@{ schema_version = 1; action = 'rollback'; status = 'refused_missing'; detail = "The previous build folder is missing: $($target.path). Nothing was changed."; backend = $family; from_tag = [string]$active.tag; to_tag = [string]$target.tag; restarted = $false }
        }
        $dependency = Get-RuntimeDependencyReport -Path ([string]$target.path) -Backend ([string]$target.backend)
        if (-not $dependency.installed -or [string]$dependency.status -ne 'ok') {
            $missing = @($dependency.missing_files) -join ', '
            return [pscustomobject]@{ schema_version = 1; action = 'rollback'; status = 'refused_broken'; detail = "The previous build fails the file check ($missing). Nothing was changed."; backend = $family; from_tag = [string]$active.tag; to_tag = [string]$target.tag; missing_files = @($dependency.missing_files); restarted = $false }
        }
        $server = Get-ServerState
        $wasRunning = (@('running', 'loading') -contains [string]$server.state) -or (@($server.process_ids).Count -gt 0)
        if ($wasRunning) {
            foreach ($processId in @($server.process_ids)) { Stop-Process -Id ([int]$processId) -Force -ErrorAction SilentlyContinue }
            $deadline = (Get-Date).AddSeconds(10)
            while ((Get-Date) -lt $deadline -and $null -ne (Get-PortListener -Port $Port)) { Start-Sleep -Milliseconds 200 }
        }
        Set-ActiveRuntime -Path ([string]$target.path)
        $model = Get-ActiveModel
        if ($null -ne $model -and (Test-Path -LiteralPath (Get-RuntimeExecutablePath) -PathType Leaf)) {
            New-Launchers -ActiveModel $model -EffectiveContext ([int]$model.context_size)
        }
        $restarted = $false
        $restartError = ''
        if ($wasRunning) {
            $launcher = Join-Path $InstallRoot 'Start-LlamaCpp.cmd'
            if (Test-Path -LiteralPath $launcher -PathType Leaf) {
                try {
                    Start-Process -FilePath $launcher -WorkingDirectory $InstallRoot -WindowStyle Minimized
                    $deadline = (Get-Date).AddSeconds(90)
                    while ((Get-Date) -lt $deadline) {
                        try {
                            if ((Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 2).status -eq 'ok') { $restarted = $true; break }
                        } catch { }
                        Start-Sleep -Seconds 2
                    }
                } catch { $restartError = [string]$_.Exception.Message }
            } else { $restartError = 'Start-LlamaCpp.cmd was not found, so the server was not restarted.' }
        }
        $detail = "Rolled back from $($active.tag) to $($target.tag)."
        if ($wasRunning -and $restarted) { $detail = "$detail The server was restarted." }
        elseif ($wasRunning -and -not $restarted) { $detail = "$detail The server did not answer after the restart; start it from the window." }
        return [pscustomobject]@{
            schema_version = 1; action = 'rollback'; status = 'rolled_back'; detail = $detail; backend = $family
            from_tag = [string]$active.tag; to_tag = [string]$target.tag; path = [string]$target.path
            was_running = $wasRunning; restarted = $restarted; restart_error = $restartError
        }
    } catch {
        return [pscustomobject]@{ schema_version = 1; action = 'rollback'; status = 'failed'; detail = [string]$_.Exception.Message; backend = ''; from_tag = ''; to_tag = ''; restarted = $false }
    }
}

function Get-ModelRuntimeBlocker {
    param($Model, $Runtime)
    # Which runtimes cannot load which models lives in catalog/compatibility.json
    # (ADR-004), with the evidence for each rule recorded next to it: Ornith's GGUF
    # carries a trailing MTP block that b8407 cannot load, and Gemma 4 (April 2026)
    # is newer than AMD's ROCm 7.2.1 package (March 2026).
    $names = $Model.PSObject.Properties.Name
    $flags = @()
    if (($names -contains 'NeedsMtpLoader') -and [bool]$Model.NeedsMtpLoader) { $flags += 'NeedsMtpLoader' }
    if (($names -contains 'NeedsCurrentLlamaCpp') -and [bool]$Model.NeedsCurrentLlamaCpp) { $flags += 'NeedsCurrentLlamaCpp' }
    if ($flags.Count -eq 0 -or $null -eq $Runtime) { return '' }
    foreach ($rule in @(Get-CatalogJson -Name 'compatibility.json').rules) {
        $runtimeMatches = ([string]$Runtime.backend -eq [string]$rule.backend) -and ([string]$Runtime.tag -match [string]$rule.tag_regex)
        $flagMatches = @(@($rule.model_flags) | Where-Object { $flags -contains $_ }).Count -gt 0
        if ($runtimeMatches -and $flagMatches) {
            return ([string]$rule.message_template).Replace('{model_name}', [string]$Model.Name)
        }
    }
    return ''
}

function Get-RuntimeUpdateUnlock {
    # Which models a newer llama.cpp build would unblock, straight from the
    # compatibility catalogue (ADR-004: never hardcoded). A model is unlockable
    # when its blocker comes from a catalogue rule that names a specific runtime
    # stage (backend + tag_regex) — a newer build with a different tag simply no
    # longer matches that rule, so the blocker clears. Models whose blocker is
    # absent or generic are never counted: only stage rules unlock by updating.
    param($Runtime)
    $unlocked = @()
    # NOTE: a plain `return @()` collapses to $null, and a null property serializes
    # as {} not [] in ConvertTo-Json — callers and the desktop need a real array.
    if ($null -eq $Runtime) { return ,@() }
    $rules = @(@(Get-CatalogJson -Name 'compatibility.json').rules) | Where-Object {
        ([string]$_.backend -eq [string]$Runtime.backend) -and ([string]$Runtime.tag -match [string]$_.tag_regex)
    }
    if (@($rules).Count -eq 0) { return ,@() }
    foreach ($model in @(Get-ModelCatalog)) {
        $names = $model.PSObject.Properties.Name
        $flags = @()
        if (($names -contains 'NeedsMtpLoader') -and [bool]$model.NeedsMtpLoader) { $flags += 'NeedsMtpLoader' }
        if (($names -contains 'NeedsCurrentLlamaCpp') -and [bool]$model.NeedsCurrentLlamaCpp) { $flags += 'NeedsCurrentLlamaCpp' }
        if ($flags.Count -eq 0) { continue }
        $stageRule = @(@($rules) | Where-Object { @(@($_.model_flags) | Where-Object { $flags -contains $_ }).Count -gt 0 }) | Select-Object -First 1
        if ($null -ne $stageRule) { $unlocked += [pscustomobject]@{ id = [string]$model.Id; name = [string]$model.Name } }
    }
    # ,@() preserves array-ness (that empty list must reach the document as [], not {})
    return ,@($unlocked)
}

function Get-ProjectorLocalName {
    # Local file name for a model's vision projector. Some repos share a generic name
    # (both Gemma 3 repos publish mmproj-model-f16.gguf), so those models set
    # LocalProjector to keep one from overwriting the other in the models folder.
    param($Model)
    if ($Model.PSObject.Properties.Name -contains 'LocalProjector') { return [string]$Model.LocalProjector }
    return [string]$Model.Projector
}

function Remove-DownloadedModel {
    # Deletes one downloaded model's files. Refuses the active model, and keeps a vision
    # projector that another downloaded model still uses.
    param($Model)
    $active = Get-ActiveModel
    if ($null -ne $active -and [string]$active.id -eq $Model.Id) {
        throw "$($Model.Name) is the active model. Switch to another model first, then remove it."
    }
    $modelsRoot = Join-Path $InstallRoot 'models'
    $paths = @(Join-Path $modelsRoot $Model.File)
    if (-not [string]::IsNullOrWhiteSpace([string]$Model.Projector)) {
        $projectorName = Get-ProjectorLocalName $Model
        $sharedBy = @(Get-InstalledModels | Where-Object { $_.Id -ne $Model.Id -and -not [string]::IsNullOrWhiteSpace([string]$_.Projector) -and (Get-ProjectorLocalName $_) -eq $projectorName })
        if ($sharedBy.Count -eq 0) { $paths += Join-Path $modelsRoot $projectorName }
    }
    $existing = @($paths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    if ($existing.Count -eq 0) { throw "$($Model.Name) is not downloaded." }
    $bytes = 0L
    foreach ($path in $existing) { $bytes += (Get-Item -LiteralPath $path).Length }
    if (-not $Force) {
        Write-Host "`n  About to delete $($Model.Name) ($(Format-Bytes $bytes)):" -ForegroundColor Yellow
        foreach ($path in $existing) { Write-Host "    $path" -ForegroundColor White }
        Write-Host '  You can download it again later from the model browser.' -ForegroundColor DarkGray
        if ((Read-ConsoleLine -Prompt "  Type YES to delete $($Model.Name)") -ine 'YES') {
            Write-WarnLine 'Nothing was deleted.'
            return $false
        }
    }
    foreach ($path in $existing) { Remove-Item -LiteralPath $path -Force }
    Write-Success "Removed $($Model.Name) and freed $(Format-Bytes $bytes)."
    return $true
}

function Select-ModelToRemove {
    $candidates = @(Get-InstalledModels)
    $active = Get-ActiveModel
    $activeId = if ($null -ne $active) { [string]$active.id } else { '' }
    Clear-Screen
    Show-Banner
    Write-Host '  REMOVE A DOWNLOADED MODEL' -ForegroundColor White
    if ($candidates.Count -eq 0) { Write-WarnLine 'No models are downloaded.'; return $null }
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        $model = $candidates[$i]
        $size = (Get-Item -LiteralPath (Join-Path (Join-Path $InstallRoot 'models') $model.File)).Length
        $note = if ($model.Id -eq $activeId) { '  (active - switch away first)' } else { '' }
        Write-Host ('  [{0}] {1,-25} {2,10}{3}' -f ($i + 1), $model.Name, (Format-Bytes $size), $note) -ForegroundColor $(if ($note) { 'DarkGray' } else { 'White' })
    }
    $answer = Read-ConsoleLine -Prompt "`n  Choose 1-$($candidates.Count), or 0 to return"
    $number = 0
    if (-not [int]::TryParse($answer, [ref]$number) -or $number -lt 1 -or $number -gt $candidates.Count) { return $null }
    return $candidates[$number - 1]
}

function Get-InstalledModels {
    # Catalog models whose files are already downloaded. Local only: no network, no hashing.
    $modelsRoot = Join-Path $InstallRoot 'models'
    return @(Get-ModelCatalog | Where-Object {
        (Test-Path -LiteralPath (Join-Path $modelsRoot $_.File) -PathType Leaf) -and
        ([string]::IsNullOrWhiteSpace([string]$_.Projector) -or (Test-Path -LiteralPath (Join-Path $modelsRoot (Get-ProjectorLocalName $_)) -PathType Leaf))
    })
}

function Get-InstalledModelStates {
    # Downloaded models with their state, as objects. Shared by the batch menu's list
    # line and -Action State (ADR-003) so the two contracts cannot drift.
    # state: active, blocked (cannot run on the installed llama.cpp build) or ready.
    $active = Get-ActiveModel
    $activeId = if ($null -ne $active) { [string]$active.id } else { '' }
    $runtime = Get-InstalledRuntime
    $items = @()
    foreach ($model in (Get-InstalledModels)) {
        $state = 'ready'
        if (Get-ModelRuntimeBlocker -Model $model -Runtime $runtime) { $state = 'blocked' }
        elseif ($model.Id -eq $activeId) { $state = 'active' }
        $items += [pscustomobject]@{ id = [string]$model.Id; name = [string]$model.Name; state = $state }
    }
    # Plain return (not ,@()): every caller wraps with @(), and a leading comma
    # would nest the array inside the caller's array instead of filling it.
    return $items
}

function Get-InstalledModelList {
    # One line per downloaded model for the batch menu: number|id|name|state.
    $lines = @()
    $number = 0
    foreach ($item in @(Get-InstalledModelStates)) {
        $number++
        $lines += "$number|$($item.id)|$($item.name)|$($item.state)"
    }
    return $lines
}

function Switch-InstalledModel {
    # Instant, offline switch between downloaded models. Files were verified against
    # their published SHA-256 when downloaded, so this does not re-hash gigabytes.
    param($Model, $Hardware)
    $installed = @(Get-InstalledModels | Where-Object { $_.Id -eq $Model.Id })
    if ($installed.Count -eq 0) { throw "$($Model.Name) is not downloaded yet. Use the model browser to download it." }
    $blocker = Get-ModelRuntimeBlocker -Model $Model -Runtime (Get-InstalledRuntime)
    if ($blocker) { throw $blocker }
    $context = $ContextSize
    if ($context -eq 0) { $context = Get-SuggestedContext -Model $Model -Hardware $Hardware }
    Set-ActiveModel -Model $Model -EffectiveContext $context
    Write-Success "$($Model.Name) is now the active model (context $context)."
    $selection = Select-RuntimeForActiveModel -Hardware $Hardware
    if ($selection.status -eq 'switched') { Write-Info $selection.message }
    elseif ($selection.status -eq 'backend_not_installed') { Write-WarnLine $selection.message }
    Sync-VsCodeChatEndpoint
}

function Resolve-BackendChoice {
    param([string] $RequestedBackend, $Hardware, $Runtime)
    if ($RequestedBackend -ne 'Auto') { return $RequestedBackend }
    # Auto keeps the backend already installed, so an update never silently swaps a
    # working choice (for example Vulkan picked for Ornith) back to the recommendation.
    if ($null -ne $Runtime -and @('ROCm', 'ROCmLatest', 'Vulkan') -contains [string]$Runtime.backend) { return [string]$Runtime.backend }
    if ($Hardware.RocmRecommended) { return 'ROCm' }
    return 'Vulkan'
}

# ---- Per-model backend preference ------------------------------------------------
# The choice is a preference, not a lock: a user override always wins, and the default
# only says which installed runtime this model should use. Router mode still runs one
# runtime at a time, so starting a model that prefers the other backend stops our
# server, selects the other runtime, and starts again under it.

function Get-ModelBackendMap {
    $settings = Get-AppSettings
    $map = @{}
    if (-not $settings.ContainsKey('model_backends')) { return $map }
    $value = $settings['model_backends']
    if ($null -eq $value) { return $map }
    if ($value -is [System.Collections.IDictionary]) {
        foreach ($key in $value.Keys) { $map[[string]$key] = [string]$value[$key] }
        return $map
    }
    foreach ($property in $value.PSObject.Properties) { $map[[string]$property.Name] = [string]$property.Value }
    return $map
}

function Get-MoeCpuLayers {
    # The opt-in number of MoE expert layers kept on the CPU for a model; $null when unset.
    param([string] $ModelId)
    $settings = Get-AppSettings
    if ([string]::IsNullOrWhiteSpace($ModelId) -or -not $settings.ContainsKey('moe_cpu_layers') -or $null -eq $settings['moe_cpu_layers']) { return $null }
    $value = Get-TuneValue -Object $settings['moe_cpu_layers'] -Name $ModelId -Default $null
    $parsed = 0
    if ($null -eq $value -or -not [int]::TryParse([string]$value, [ref]$parsed) -or $parsed -lt 0) { return $null }
    return [int]$parsed
}

function Set-MoeCpuLayers {
    # $null clears the choice for that model.
    param([string] $ModelId, $Layers)
    $settings = Get-AppSettings
    $map = @{}
    if ($settings.ContainsKey('moe_cpu_layers') -and $null -ne $settings['moe_cpu_layers']) {
        foreach ($property in $settings['moe_cpu_layers'].PSObject.Properties) { $map[$property.Name] = $property.Value }
    }
    if ($null -eq $Layers) { [void]$map.Remove($ModelId) } else { $map[$ModelId] = [int]$Layers }
    Set-AppSetting -Name 'moe_cpu_layers' -Value ([pscustomobject]$map)
}

function Get-ModelBackendOverride {
    param([string] $ModelId)
    $map = Get-ModelBackendMap
    if ($map.ContainsKey($ModelId)) { return [string]$map[$ModelId] }
    return ''
}

function Set-ModelBackendOverride {
    param([string] $ModelId, [string] $Backend)
    $map = Get-ModelBackendMap
    if ([string]::IsNullOrWhiteSpace($Backend) -or $Backend -eq 'Auto') { [void]$map.Remove($ModelId) }
    else { $map[$ModelId] = $Backend }
    Set-AppSetting -Name 'model_backends' -Value ([pscustomobject]$map)
}

function Get-DefaultModelBackend {
    # Policy from the Phase 1 plan, not a measured speed claim: Vulkan for small,
    # 7B-14B and mixture-of-experts models; ROCm for dense models at 18 GiB and up.
    param($Model, $Hardware)
    $supportsRocm = ($null -ne $Hardware) -and (@($Hardware.PSObject.Properties.Name) -contains 'RocmRecommended') -and [bool]$Hardware.RocmRecommended
    $isMoe = (@($Model.PSObject.Properties.Name) -contains 'Moe') -and [bool]$Model.Moe
    $gib = [double]$Model.ApproxGiB
    if (-not $supportsRocm) {
        return [pscustomobject]@{ backend = 'Vulkan'; reason = 'ROCm is not recommended for this GPU, so Vulkan is the default.' }
    }
    if ($isMoe) {
        return [pscustomobject]@{ backend = 'Vulkan'; reason = 'Mixture-of-experts models use Vulkan by default on this PC.' }
    }
    if ($gib -ge 18.0) {
        return [pscustomobject]@{ backend = 'ROCm'; reason = 'Dense models at 18 GiB or more use ROCm by default on this Radeon.' }
    }
    if ($gib -ge 7.0) {
        return [pscustomobject]@{ backend = 'Vulkan'; reason = '7B-14B models use Vulkan by default on this PC.' }
    }
    return [pscustomobject]@{ backend = 'Vulkan'; reason = 'Models below 7 GiB use Vulkan by default on this PC.' }
}

function Get-ModelBackendPreference {
    param($Model, $Hardware)
    $override = Get-ModelBackendOverride -ModelId ([string]$Model.Id)
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        return [pscustomobject]@{ backend = $override; source = 'user'; reason = "You chose $override for this model." }
    }
    $default = Get-DefaultModelBackend -Model $Model -Hardware $Hardware
    return [pscustomobject]@{ backend = [string]$default.backend; source = 'default'; reason = [string]$default.reason }
}

function Get-RuntimeForBackend {
    param([string] $Backend)
    $wanted = Get-BackendFamily -Backend $Backend
    $installs = @(Get-RuntimeInstallations | Where-Object { $_.exe_present -and (Get-BackendFamily -Backend $_.backend) -eq $wanted })
    if ($installs.Count -eq 0) { return $null }
    $activePath = Get-ActiveRuntimePath
    if (-not [string]::IsNullOrWhiteSpace($activePath)) {
        $activeMatch = @($installs | Where-Object { $_.path -ieq $activePath }) | Select-Object -First 1
        if ($null -ne $activeMatch) { return $activeMatch }
    }
    # Prefer the AMD-validated tag for ROCm; otherwise keep the first installed build.
    try {
        $amdTag = [string](Get-CatalogJson -Name 'runtimes.json').amd_rocm_package.tag
        $amdMatch = @($installs | Where-Object { $_.tag -eq $amdTag }) | Select-Object -First 1
        if ($null -ne $amdMatch) { return $amdMatch }
    } catch { }
    return ($installs | Select-Object -First 1)
}

function Stop-OwnedLlamaServer {
    # Only processes whose executable lives under this install root. A llama-server the
    # user started from somewhere else is never touched by a backend switch.
    $stopped = @()
    $rootPrefix = ([string]$InstallRoot).TrimEnd('\') + '\'
    foreach ($serverProcess in @(Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue)) {
        $executablePath = ''
        try { $executablePath = [string]$serverProcess.Path } catch { $executablePath = '' }
        if ([string]::IsNullOrWhiteSpace($executablePath)) {
            try { $executablePath = [string](Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $($serverProcess.Id)" -ErrorAction Stop).ExecutablePath } catch { $executablePath = '' }
        }
        if (-not [string]::IsNullOrWhiteSpace($executablePath) -and $executablePath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            Stop-Process -Id $serverProcess.Id -Force -ErrorAction SilentlyContinue
            $stopped += $serverProcess.Id
        }
    }
    if ($stopped.Count -gt 0) { Start-Sleep -Milliseconds 900 }
    return @($stopped)
}

function Select-RuntimeForActiveModel {
    param($Hardware, [switch] $AllowStop)
    $active = Get-ActiveModel
    if ($null -eq $active) { return [pscustomobject]@{ status = 'no_model'; changed = $false; message = '' } }
    $model = $null
    try { $model = Get-ModelById -Id ([string]$active.id) } catch { $model = $null }
    if ($null -eq $model) { return [pscustomobject]@{ status = 'unknown_model'; changed = $false; message = 'The active model is not in the catalogue.' } }
    $preference = Get-ModelBackendPreference -Model $model -Hardware $Hardware
    $current = Get-InstalledRuntime
    if ($null -eq $current) {
        return [pscustomobject]@{ status = 'not_installed'; changed = $false; message = 'No llama.cpp runtime is installed.'; preferred_backend = $preference.backend }
    }
    if ((Get-BackendFamily -Backend $current.backend) -eq (Get-BackendFamily -Backend $preference.backend)) {
        return [pscustomobject]@{ status = 'current'; changed = $false; message = ''; preferred_backend = $preference.backend; backend = $current.backend }
    }
    $target = Get-RuntimeForBackend -Backend $preference.backend
    if ($null -eq $target) {
        return [pscustomobject]@{
            status = 'backend_not_installed'; changed = $false; preferred_backend = $preference.backend
            message = "This model prefers the $($preference.backend) backend, but no $($preference.backend) runtime is installed. Install it from Install/update with Backend $($preference.backend); it will sit beside the current runtime."
        }
    }
    if (-not $AllowStop -and @(Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue).Count -gt 0) {
        return [pscustomobject]@{ status = 'switch_deferred'; changed = $false; preferred_backend = $preference.backend; target = $target.path; message = "A server is running; the switch to $($preference.backend) waits for the next start." }
    }
    if ($AllowStop) {
        [void](Stop-OwnedLlamaServer)
        if (@(Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue).Count -gt 0) {
            return [pscustomobject]@{ status = 'server_running'; changed = $false; preferred_backend = $preference.backend; target = $target.path; message = 'A llama-server process that this tool does not own is still running, so the runtime was not switched.' }
        }
    }
    $fromBackend = [string]$current.backend
    Set-ActiveRuntime -Path ([string]$target.path)
    New-Launchers -ActiveModel $active -EffectiveContext ([int]$active.context_size)
    $message = "Switching to $($preference.backend) for this model (was $fromBackend): $($target.tag)."
    Write-RunLogEvent -Event 'runtime_switch' -Message $message -Data @{ model_id = [string]$model.Id; from = $fromBackend; to = $preference.backend; tag = [string]$target.tag }
    return [pscustomobject]@{ status = 'switched'; changed = $true; from_backend = $fromBackend; to_backend = $preference.backend; tag = [string]$target.tag; target = [string]$target.path; message = $message }
}

function Install-Model {
    param($Model, $Hardware)
    $blocker = Get-ModelRuntimeBlocker -Model $Model -Runtime (Get-InstalledRuntime)
    if ($blocker) { throw $blocker }
    $assessment = @(Get-ModelAssessment -Hardware $Hardware | Where-Object { $_.Model.Id -eq $Model.Id }) | Select-Object -First 1
    if ($null -ne $assessment) { Write-Info "Fit: $($assessment.Status), headroom $($assessment.HeadroomGiB) GiB" }
    Assert-ModelDiskSpace -RequiredGiB ([double]$Model.ApproxGiB)
    $modelsRoot = Join-Path $InstallRoot 'models'
    New-Item -ItemType Directory -Path $modelsRoot -Force | Out-Null

    Write-Step "Resolving verified model metadata for $($Model.Name)"
    $descriptor = Get-HfFileDescriptor -Repo $Model.Repo -FileName $Model.File
    Write-Info "Revision $($descriptor.Revision.Substring(0,12)); SHA-256 $($descriptor.Sha256.Substring(0,12))..."
    Write-RunLogEvent -Event 'model_metadata' -Message "Resolved model metadata for $($Model.Name)" -Data @{
        model_id = $Model.Id
        repo = $Model.Repo
        file = $Model.File
        projector = [string]$Model.Projector
        revision = $descriptor.Revision
        sha256 = $descriptor.Sha256
        size_bytes = $descriptor.Size
    }
    Get-VerifiedDownload -Url $descriptor.Url -Destination (Join-Path $modelsRoot $Model.File) -ExpectedSize $descriptor.Size -ExpectedSha256 $descriptor.Sha256

    if (-not [string]::IsNullOrWhiteSpace([string]$Model.Projector)) {
        $projector = Get-HfFileDescriptor -Repo $Model.Repo -FileName $Model.Projector
        Get-VerifiedDownload -Url $projector.Url -Destination (Join-Path $modelsRoot (Get-ProjectorLocalName $Model)) -ExpectedSize $projector.Size -ExpectedSha256 $projector.Sha256
    }

    $context = $ContextSize
    if ($context -eq 0) { $context = Get-SuggestedContext -Model $Model -Hardware $Hardware }
    Set-ActiveModel -Model $Model -EffectiveContext $context
    Write-Success "$($Model.Name) is installed and active at context $context."
    Sync-VsCodeChatEndpoint
}

function Sync-VsCodeChatEndpoint {
    # Once you have connected VS Code, every model switch updates its entry to the model the
    # server will actually load. It never adds the entry on its own: that stays opt-in via [6].
    $configPath = Join-Path $env:APPDATA "Code\User\chatLanguageModels.json"
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { return }
    try {
        $connected = @(Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json | ForEach-Object { $_ } | Where-Object { $null -ne $_ -and @("llama.cpp local", "llama.cpp ROCm") -contains $_.name }).Count -gt 0
    } catch { Write-WarnLine "VS Code Chat was not synced: its settings file is not valid JSON."; return }
    if (-not $connected) { return }
    if (Install-VsCodeChatEndpoint -NoPrompt) { Write-Info "VS Code Chat now lists the active model. Reload the VS Code window to see it." }
}

function Confirm-ModelDownload {
    param($Model, $Hardware)
    $blocker = Get-ModelRuntimeBlocker -Model $Model -Runtime (Get-InstalledRuntime)
    if ($blocker) { Write-WarnLine $blocker; return $false }
    if ($Force -or $script:AssumeYes) { return $true }
    $assessment = @(Get-ModelAssessment -Hardware $Hardware | Where-Object { $_.Model.Id -eq $Model.Id }) | Select-Object -First 1
    $status = if ($null -eq $assessment) { 'UNKNOWN' } else { $assessment.Status }
    $modelsRoot = Join-Path $InstallRoot 'models'
    $modelPath = Join-Path $modelsRoot $Model.File
    $projectorPath = if ([string]::IsNullOrWhiteSpace([string]$Model.Projector)) { '' } else { Join-Path $modelsRoot (Get-ProjectorLocalName $Model) }
    $filesPresent = (Test-Path -LiteralPath $modelPath -PathType Leaf) -and ([string]::IsNullOrWhiteSpace($projectorPath) -or (Test-Path -LiteralPath $projectorPath -PathType Leaf))
    if ($filesPresent) {
        Write-Host "`n  $($Model.Name) is already downloaded. The next step will verify the existing files and activate them." -ForegroundColor Green
        $answer = Read-ConsoleLine -Prompt '  Type YES to verify and activate'
    } else {
        Write-Host "`n  About to download $($Model.Name): ~$([Math]::Round($Model.ApproxGiB,2)) GiB [$status]" -ForegroundColor Yellow
        $answer = Read-ConsoleLine -Prompt '  Type YES to continue'
    }
    return ($answer -ieq 'YES')
}

function Select-ModelInteractively {
    param($Hardware)
    $assessment = @(Get-ModelAssessment -Hardware $Hardware)
    $runtime = Get-InstalledRuntime
    Clear-Screen
    Show-Banner
    Write-Host '  MODEL BROWSER — sizes include the vision projector where applicable' -ForegroundColor White
    for ($i = 0; $i -lt $assessment.Count; $i++) {
        $item = $assessment[$i]
        $installed = Test-Path -LiteralPath (Join-Path (Join-Path $InstallRoot 'models') $item.Model.File)
        $mark = if ($installed) { '✓' } else { ' ' }
        Write-Host ("  [{0}] {1} " -f ($i + 1), $mark) -NoNewline -ForegroundColor White
        Write-Host ('{0,-25}' -f $item.Model.Name) -NoNewline -ForegroundColor $item.Color
        $placement = if ($item.GpuResident) { 'VRAM' } else { 'VRAM+RAM' }
        Write-Host ('{0,6:N1} GiB  {1,-10} {2,-9} {3}' -f $item.Model.ApproxGiB, $item.Status, $placement, $item.Model.Tag) -ForegroundColor DarkGray
        Write-Host "      $(Limit-Text $item.Model.Description 92)" -ForegroundColor DarkGray
        if (Get-ModelRuntimeBlocker -Model $item.Model -Runtime $runtime) {
            Write-Host '      [BLOCKED] Needs a newer llama.cpp than the ROCm package; use the Vulkan backend.' -ForegroundColor Yellow
        }
    }
    $answer = Read-ConsoleLine -Prompt "`n  Choose 1-$($assessment.Count), or 0 to return"
    $number = 0
    if (-not [int]::TryParse($answer, [ref]$number) -or $number -lt 1 -or $number -gt $assessment.Count) {
        Write-WarnLine 'No model selected.'
        return $null
    }
    return $assessment[$number - 1].Model
}

function Write-NativeCommandOutput {
    param(
        [Parameter(Mandatory = $true)][string] $FilePath,
        [string[]] $Arguments = @()
    )
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $FilePath @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    foreach ($line in $output) { Write-Host ([string]$line) }
    return $exitCode
}

function Test-LlamaCppRuntime {
    $server = Get-RuntimeExecutablePath
    if (-not (Test-Path -LiteralPath $server -PathType Leaf)) { return $false }
    Push-Location (Split-Path -Parent $server)
    try {
        $exitCode = Write-NativeCommandOutput -FilePath $server -Arguments @('--list-devices')
        return ($exitCode -eq 0)
    } finally { Pop-Location }
}

function Get-RocmPackageFreshness {
    # Warn-only, time-based staleness reminder. It never fetches AMD's page: it
    # just flags when the hardcoded ROCm package hasn't been hand-checked in a
    # while, so a stale package is a visible reminder rather than a silent risk.
    $ageDays = [Math]::Floor(([DateTime]::UtcNow - $script:AmdRocmPackageCheckedOn).TotalDays)
    return [pscustomobject]@{
        AgeDays = $ageDays
        Stale = ($ageDays -gt $script:AmdRocmPackageFreshnessDays)
        CheckedOn = $script:AmdRocmPackageCheckedOn
    }
}

function Show-Diagnostics {
    param($Hardware)
    Clear-Screen
    Show-Banner
    Write-Host '  DIAGNOSTICS' -ForegroundColor White
    Write-Host "  OS: $([Environment]::OSVersion.VersionString)" -ForegroundColor Gray
    Write-Host "  PowerShell: $($PSVersionTable.PSVersion)" -ForegroundColor Gray
    Write-Host "  Vulkan loader (for Vulkan backend): $($Hardware.VulkanLoader)" -ForegroundColor $(if ($Hardware.VulkanLoader) { 'Green' } else { 'Yellow' })
    Write-Host "  Install root: $InstallRoot" -ForegroundColor Gray
    $driver = Get-GpuDriverInfo
    if ($null -ne $driver) { Write-Host "  AMD driver: $($driver.version) ($($driver.date)) - $($driver.name)" -ForegroundColor Gray }
    foreach ($install in @(Get-RuntimeInstallations)) {
        $dependency = Get-RuntimeDependencyReport -Path ([string]$install.path) -Backend ([string]$install.backend)
        Write-Host "  Runtime $($install.backend) $($install.tag): $($install.path)" -ForegroundColor Gray
        if ($dependency.status -eq 'ok') {
            Write-Success '    all required files are present.'
        } else {
            Write-WarnLine "    missing: $(@($dependency.missing_files) -join ', ')"
            if (-not [string]::IsNullOrWhiteSpace($dependency.where_to_get)) { Write-Info "    $($dependency.where_to_get)" }
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$dependency.driver_requirement)) { Write-Info "    $($dependency.driver_requirement)" }
    }
    $freshness = Get-RocmPackageFreshness
    if ($freshness.Stale) {
        Write-WarnLine "The pinned ROCm package was last hand-checked $($freshness.AgeDays) days ago ($($freshness.CheckedOn.ToString('yyyy-MM-dd'))). Check $script:AmdRocmPage for a newer validated Windows package."
    }
    $server = Get-RuntimeExecutablePath
    if (-not (Test-Path -LiteralPath $server -PathType Leaf)) {
        Write-WarnLine 'llama.cpp is not installed yet. Choose Install/update from the dashboard.'
        return
    }
    Push-Location (Split-Path -Parent $server)
    try {
        Write-Step 'llama.cpp version'
        $versionExit = Write-NativeCommandOutput -FilePath $server -Arguments @('--version')
        if ($versionExit -ne 0) { Write-WarnLine "llama-server --version exited with code $versionExit." }
        Write-Step 'llama.cpp devices'
        $deviceExit = Write-NativeCommandOutput -FilePath $server -Arguments @('--list-devices')
        if ($deviceExit -eq 0) {
            Write-Info 'ROCm/HIP device lines are informational when a device is listed and the exit code is 0.'
            $primary = Get-PrimaryLlamaDevice
            if ($primary) { Write-Success "The server is pinned to $primary (the dedicated Radeon). Integrated graphics is never used automatically." }
            else { Write-Info 'Only one GPU is visible to this build, so no device pin is needed.' }
        } else {
            Write-WarnLine "llama-server --list-devices exited with code $deviceExit."
        }
        $active = Get-ActiveModel
        if ($null -eq $active) {
            Write-WarnLine 'No active model is configured.'
        } else {
            Write-Success "Active model: $($active.name)"
            Write-Info "Model file exists: $(Test-Path -LiteralPath ([string]$active.model_path))"
        }
    } finally { Pop-Location }
}

function Select-PortListenerRow {
    # Get-NetTCPConnection -LocalPort returns every socket on the port: the listener (remote
    # port 0), live connections from clients, and TIME_WAIT/CLOSED leftovers whose owner is 0.
    # Taking the first row picked a leftover about half the time, so our own healthy server
    # looked like an unknown program holding its port (measured 2026-11-07, 3 of 3 Diagnose runs).
    param($Rows)
    $rows = @($Rows)
    if ($rows.Count -eq 0) { return $null }
    $listener = @($rows | Where-Object { [int]$_.RemotePort -eq 0 -and [int]$_.OwningProcess -gt 0 }) | Select-Object -First 1
    if ($null -ne $listener) { return $listener }
    $owned = @($rows | Where-Object { [int]$_.OwningProcess -gt 0 }) | Select-Object -First 1
    if ($null -ne $owned) { return $owned }
    return ($rows | Select-Object -First 1)
}

function Get-PortListener {
    # Who is listening on this port, if anyone. Strictly read-only: it looks at the
    # socket table and the owning process, and never sends a signal of any kind.
    #
    # Do not filter on -State: on this project's RX 9070 XT machine Get-NetTCPConnection
    # returns a live loopback listener with an EMPTY State, so a -State Listen filter
    # found nothing and a busy port was reported as free (measured, 2026-11-05). Two
    # independent views are used instead: GetActiveTcpListeners confirms the port is
    # listening, then a port-only lookup supplies the owner PID. A port-only row with
    # RemotePort 0 is also a listener when the first view misses it.
    param([int] $Port)
    $listening = $false
    try {
        $listening = @([System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() | Where-Object { [int]$_.Port -eq $Port }).Count -gt 0
    } catch { $listening = $false }

    $rows = @()
    try { $rows = @(Get-NetTCPConnection -LocalPort $Port -ErrorAction Stop) } catch { $rows = @() }
    if (-not $listening) {
        foreach ($row in $rows) {
            $stateText = [string]$row.State
            if ($stateText -eq 'Listen' -or ([string]::IsNullOrWhiteSpace($stateText) -and [int]$row.RemotePort -eq 0)) {
                $listening = $true
                break
            }
        }
    }
    if (-not $listening) { return $null }

    $connection = Select-PortListenerRow -Rows $rows
    $owner = 0
    if ($null -ne $connection) {
        $candidate = [int]$connection.OwningProcess
        if ($candidate -gt 0) { $owner = $candidate }
    }
    $name = ''
    if ($owner -gt 0) {
        try { $name = [string](Get-Process -Id $owner -ErrorAction Stop).ProcessName } catch { $name = 'unknown' }
    }
    return [pscustomobject]@{
        port = $Port
        process_id = $owner
        process_name = $name
        local_address = if ($null -ne $connection) { [string]$connection.LocalAddress } else { '' }
        owner_known = ($owner -gt 0)
    }
}

function Resolve-PortConflict {
    # Decides, before anything is launched, who holds the configured port. Three outcomes:
    #   free     - nothing is listening; start normally.
    #   owned    - our own llama-server already holds it; treat the server as running or
    #              still loading and poll its health instead of starting a second copy.
    #   conflict - an unrelated program holds it. Never killed, and no other port is tried
    #              silently: the caller gets the port, the PID and the process name.
    param([int] $Port, [int[]] $OwnedProcessIds = @(), [string[]] $OwnedProcessNames = @('llama-server'))
    $listener = Get-PortListener -Port $Port
    if ($null -eq $listener) {
        return [pscustomobject]@{ status = 'free'; port = $Port; process_id = 0; process_name = ''; message = '' }
    }
    $owned = (@($OwnedProcessIds) -contains $listener.process_id) -or (@($OwnedProcessNames | Where-Object { $_ -ieq $listener.process_name }).Count -gt 0)
    if ($owned) {
        return [pscustomobject]@{
            status = 'owned'; port = $Port; process_id = $listener.process_id; process_name = $listener.process_name
            message = "llama-server (PID $($listener.process_id)) is already listening on port $Port."
        }
    }
    $ownerText = if ([bool]$listener.owner_known) { "$($listener.process_name) (PID $($listener.process_id))" } else { 'another program (the owner could not be identified)' }
    return [pscustomobject]@{
        status = 'conflict'; port = $Port; process_id = $listener.process_id; process_name = $listener.process_name
        message = "Port $Port is already in use by $ownerText, which this tool does not own. Close that program, or start this one with a different -Port. Nothing was killed and no other port is tried automatically."
    }
}

function Assert-PortAvailableForStart {
    # Start-path guard (Gap 3): returns the owned-listener result when our own server
    # already holds the port, and throws with the port and PID when someone else does.
    # Throwing, rather than picking another port, is deliberate: a chat client pointed at
    # port 8080 must not silently get a server somewhere else.
    param([int] $Port, [int[]] $OwnedProcessIds = @())
    $conflict = Resolve-PortConflict -Port $Port -OwnedProcessIds $OwnedProcessIds
    if ($conflict.status -eq 'conflict') { throw $conflict.message }
    return $conflict
}

function Start-ActiveServer {
    param($Hardware)
    if ($null -eq $Hardware) { $Hardware = Get-HardwareProfile }
    $selection = Select-RuntimeForActiveModel -Hardware $Hardware
    if ($selection.status -eq 'backend_not_installed') { throw $selection.message }
    if ($selection.status -eq 'server_running') { throw $selection.message }
    $server = Get-RuntimeExecutablePath
    if (-not (Test-Path -LiteralPath $server -PathType Leaf)) { throw 'llama.cpp is not installed. Run the installer first.' }
    $active = Get-ActiveModel
    if ($null -eq $active) { throw 'No model is active. Use the model browser to install and activate one.' }
    if (-not (Test-Path -LiteralPath ([string]$active.model_path) -PathType Leaf)) { throw 'The active model file is missing. Reinstall it from the model browser.' }
    # Pin the discrete Radeon before doing any work; an iGPU-only machine is refused here
    # unless the user explicitly passed --device in server-args.user.json.
    $gpuSelection = Assert-DiscreteGpuForStart

    # Never start a second server on a port someone already holds.
    $serverState = Get-ServerState
    $portOwner = Assert-PortAvailableForStart -Port $Port -OwnedProcessIds @($serverState.process_ids)
    if ($portOwner.status -eq 'owned') {
        if ($serverState.state -eq 'running') {
            Write-Success "The AI is already running at http://127.0.0.1:$Port/ - nothing new was started."
            return [pscustomobject]@{ status = 'already_running'; port = $Port; process_id = $portOwner.process_id; health = 'ok' }
        }
        Write-Info "llama-server (PID $($portOwner.process_id)) is already listening on port $Port and is still starting; waiting for it instead of starting a second copy."
        return [pscustomobject]@{ status = 'already_running'; port = $Port; process_id = $portOwner.process_id; health = $serverState.state }
    }

    Write-RunLogEvent -Event 'server_start' -Message "Starting active model: $($active.name)" -Data @{
        model_id = [string]$active.id
        alias = [string]$active.alias
        context_size = [int]$active.context_size
        port = $Port
    }

    $context = if ($ContextSize -gt 0) { $ContextSize } else { [int]$active.context_size }
    $arguments = Write-ServerPreset -ActiveModel $active -EffectiveContext $context -Device $(if ($null -ne $gpuSelection) { $gpuSelection.device } else { $null })

    Clear-Screen
    Show-Banner
    Write-Host "  STARTING $($active.name)" -ForegroundColor Green
    Write-Info "Context: $context | API/Web UI: http://127.0.0.1:$Port/"
    Write-Info 'Open Open-WebUI.cmd in another terminal or paste the URL after startup.'
    Write-Info 'Press Ctrl+C in this terminal to stop the server.'
    Start-GameWatchIfEnabled
    # The install folder is the working directory: the preset's relative model paths resolve from it.
    Push-Location $InstallRoot
    try { & $server @arguments } finally { Pop-Location }
}

function Get-ServerState {
    # Read-only server snapshot shared by the status line and -Action State (ADR-003).
    # state: running (health ok), loading (process up, not answering yet) or stopped.
    $processes = @(Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue)
    $state = 'stopped'
    # model_state: loaded, asleep, unloaded, loading or unknown. The router answers /health
    # while its model is still loading, so a loading model keeps the server state at 'loading'.
    $modelState = 'unknown'
    if ($processes.Count -gt 0) {
        $state = 'loading'
        try {
            if ((Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 2).status -eq 'ok') { $state = 'running' }
        } catch { }
        if ($state -eq 'running') {
            $active = Get-ActiveModel
            $modelState = Get-RouterModelState -Alias $(if ($null -ne $active) { [string]$active.alias } else { '' })
            if ($modelState -eq 'loading') { $state = 'loading' }
        }
    }
    return [pscustomobject]@{
        state = $state
        port = [int]$Port
        base_url = "http://127.0.0.1:$Port"
        process_ids = @($processes | ForEach-Object { $_.Id })
        model_state = $modelState
    }
}

function Get-VsCodeChatState {
    # yes: the model named by $Alias is configured in VS Code Copilot Chat; stale: only
    # a different model is; no: no local provider entry. Shared by status and State.
    param([string] $Alias = '-')
    $state = 'no'
    $configPath = Join-Path $env:APPDATA 'Code\User\chatLanguageModels.json'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { return 'no' }
    try {
        $parsed = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        $local = @($parsed | Where-Object { $null -ne $_ -and $_.name -eq 'llama.cpp local' } | Select-Object -First 1)
        if ($local.Count -gt 0) {
            $ids = @($local[0].models | ForEach-Object { $_.id })
            $state = if ($ids -contains $Alias) { 'yes' } else { 'stale' }
        }
    } catch { $state = 'no' }
    return $state
}

function Get-DesktopShortcutState {
    # 'yes' when at least one of this install's shortcuts is on the desktop.
    $desktop = Get-DesktopFolder
    # Some sessions (CI runners, redirected profiles) have no desktop folder: that means no shortcuts.
    if ([string]::IsNullOrWhiteSpace($desktop)) { return 'no' }
    foreach ($spec in (Get-ShortcutSpecs)) {
        if (Test-Path -LiteralPath (Join-Path $desktop $spec.Name) -PathType Leaf) { return 'yes' }
    }
    return 'no'
}

function Get-CommandCenterStatus {
    # The batch menu's pipe line is a projection of the core state (ADR-003):
    # cmd.exe cannot parse JSON, so the line stays as its serialization, but no
    # state logic lives here. Fields: alias|name|context|server|vscode|idle|shortcuts.
    # '-' marks an empty field: cmd's for /f collapses consecutive delimiters.
    $core = Get-CoreApplicationState
    $alias = '-'; $name = '-'; $context = '-'
    if ($null -ne $core.model) {
        $alias = [string]$core.model.alias
        $name = [string]$core.model.name
        $context = [string]$core.model.context_size
    }
    return "$alias|$name|$context|$($core.server.state)|$($core.editors.vscode)|$($core.idle_minutes)|$($core.desktop_shortcuts)"
}

function Get-StateProperty {
    # StrictMode throws on a property a PSCustomObject lacks; state files written by
    # older versions may lack newer fields, so read them defensively.
    param($Object, [string] $Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $names = @()
    if ($null -ne $Object.PSObject.Properties) { foreach ($property in $Object.PSObject.Properties) { $names += [string]$property.Name } }
    if ($names -contains $Name) { return $Object.$Name }
    return $Default
}

function Get-CoreApplicationState {
    # The authoritative typed state for everything except the hardware scan (which is
    # slow): -Action State wraps it with hardware, the status line serialises it for
    # cmd.exe, and the window reads it directly. One source, three projections.
    $active = Get-ActiveModel
    $runtime = Get-InstalledRuntime

    $alias = '-'
    if ($null -ne $active) { $alias = [string](Get-StateProperty -Object $active -Name 'alias' -Default '-') }

    $runtimeState = $null
    if ($null -ne $runtime) {
        $runtimeState = [pscustomobject]@{
            tag = [string](Get-StateProperty -Object $runtime -Name 'tag')
            backend = [string](Get-StateProperty -Object $runtime -Name 'backend')
            installed_at = [string](Get-StateProperty -Object $runtime -Name 'installed_at')
            path = [string](Get-StateProperty -Object $runtime -Name 'path' -Default '')
            sha256 = [string](Get-StateProperty -Object $runtime -Name 'sha256' -Default '')
            sha256_source = [string](Get-StateProperty -Object $runtime -Name 'sha256_source' -Default '')
            exe_present = Test-Path -LiteralPath (Get-RuntimeExecutablePath) -PathType Leaf
        }
    }

    $modelState = $null
    if ($null -ne $active) {
        $modelId = [string](Get-StateProperty -Object $active -Name 'id')
        $modelPresent = $false
        $blocker = ''
        $catalogModel = $null
        try { $catalogModel = Get-ModelById -Id $modelId } catch { $catalogModel = $null }
        if ($null -ne $catalogModel) {
            $modelPresent = Test-Path -LiteralPath (Join-Path (Join-Path $InstallRoot 'models') $catalogModel.File) -PathType Leaf
            $blocker = [string](Get-ModelRuntimeBlocker -Model $catalogModel -Runtime $runtime)
        }
        $modelState = [pscustomobject]@{
            id = $modelId
            alias = $alias
            name = [string](Get-StateProperty -Object $active -Name 'name')
            context_size = [int](Get-StateProperty -Object $active -Name 'context_size' -Default 0)
            port = [int](Get-StateProperty -Object $active -Name 'port' -Default 0)
            model_present = $modelPresent
            runtime_blocker = $blocker
        }
    }

    $appSettings = Get-AppSettings
    $idleSetting = $null
    if ($appSettings.ContainsKey('idle_sleep_minutes')) { $idleSetting = $appSettings['idle_sleep_minutes'] }
    $useCaseSetting = $null
    if ($appSettings.ContainsKey('use_case')) { $useCaseSetting = $appSettings['use_case'] }

    return [pscustomobject]@{
        command_center_version = [string]$script:CommandCenterVersion
        install_root = [string]$InstallRoot
        runtime = $runtimeState
        model = $modelState
        server = (Get-ServerState)
        models = @(Get-InstalledModelStates)
        settings = [pscustomobject]@{ idle_sleep_minutes = $idleSetting; use_case = $useCaseSetting }
        idle_minutes = [int]((Get-IdleSleepSeconds) / 60)
        editors = [pscustomobject]@{ vscode = (Get-VsCodeChatState -Alias $alias) }
        desktop_shortcuts = (Get-DesktopShortcutState)
    }
}

function Get-ApplicationState {
    # One JSON document describing the whole installation for scripts and the desktop
    # window (ADR-003). schema_version starts at 1 and only changes on a breaking
    # change; consumers must ignore fields they do not know. Strictly read-only: it
    # never downloads, installs, starts or stops anything, and never throws - a failed
    # section degrades to null plus an error string. The document is the core state
    # plus the hardware scan; core fields are copied straight across, so the two
    # documents can never disagree.
    $core = Get-CoreApplicationState

    $hardware = $null
    $hardwareError = $null
    try { $hardware = Get-HardwareProfile } catch { $hardwareError = [string]$_.Exception.Message }

    $document = [ordered]@{
        schema_version = 1
        generated_at = (Get-Date).ToUniversalTime().ToString('o')
    }
    foreach ($property in $core.PSObject.Properties) {        $document[$property.Name] = $property.Value
    }
    $document['hardware'] = $hardware
    $document['hardware_error'] = $hardwareError
    $document['vram_estimate'] = Get-VramEstimateDocument -Hardware $hardware
    return [pscustomobject]$document
}

function Get-StateSnapshotDirectory {
    return (Join-Path $InstallRoot 'state-history')
}

function Save-StateSnapshot {
    # Persist the application state for diagnostics, rollback forensics and future
    # benchmarking. Captured automatically before state-changing actions and on
    # demand via -Action Snapshot. Never throws: history must never break the change
    # it records. Keeps the newest $script:StateSnapshotKeep files.
    param([string] $Reason = 'manual', $State = $null)
    try {
        if ($null -eq $State) { $State = Get-ApplicationState }
        $directory = Get-StateSnapshotDirectory
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss-fff')
        $path = Join-Path $directory "state-$stamp.json"
        $suffix = 0
        # A same-millisecond save must stay sortable: '_' sorts after the '.' of the
        # plain name, so the base file (written first) still sorts before its twin.
        while (Test-Path -LiteralPath $path) { $suffix++; $path = Join-Path $directory ("state-$stamp" + '_' + $suffix + '.json') }
        $document = [ordered]@{}
        foreach ($property in $State.PSObject.Properties) { $document[$property.Name] = $property.Value }
        $document['snapshot_reason'] = [string]$Reason
        $json = ConvertTo-Json -InputObject ([pscustomobject]$document) -Depth 8
        [IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
        $keep = [Math]::Max(1, [int]$script:StateSnapshotKeep)
        $existing = @(Get-ChildItem -LiteralPath $directory -Filter 'state-*.json' -File | Sort-Object Name)
        if ($existing.Count -gt $keep) {
            foreach ($stale in $existing[0..($existing.Count - $keep - 1)]) { Remove-Item -LiteralPath $stale.FullName -Force }
        }
        return $path
    } catch {
        return $null
    }
}

function Get-StateSnapshots {
    # Saved snapshots, newest first, with enough metadata to find the right one.
    $directory = Get-StateSnapshotDirectory
    $snapshots = @()
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { return $snapshots }
    foreach ($file in @(Get-ChildItem -LiteralPath $directory -Filter 'state-*.json' -File | Sort-Object Name -Descending)) {
        $document = $null
        try { $document = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json } catch { }
        $snapshots += [pscustomobject]@{
            Path = $file.FullName
            GeneratedAt = if ($null -eq $document) { '' } else { [string](Get-StateProperty -Object $document -Name 'generated_at') }
            SchemaVersion = if ($null -eq $document) { 0 } else { [int](Get-StateProperty -Object $document -Name 'schema_version' -Default 0) }
            Reason = if ($null -eq $document) { '' } else { [string](Get-StateProperty -Object $document -Name 'snapshot_reason') }
            Valid = ($null -ne $document)
        }
    }
    return $snapshots
}

# ---------------------------------------------------------------------
# Gaming mode, desktop shortcuts, and Easy start
# ---------------------------------------------------------------------

function Get-AppSettingsPath {
    return (Join-Path $InstallRoot 'settings.json')
}

function Get-AppSettings {
    # settings.json is managed by this project (unlike server-args.user.json, which is yours).
    # A missing or malformed file simply means "all defaults".
    $settings = @{}
    $path = Get-AppSettingsPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $settings }
    try {
        $parsed = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        foreach ($property in $parsed.PSObject.Properties) { $settings[$property.Name] = $property.Value }
    } catch { $settings = @{} }
    return $settings
}

function Set-AppSetting {
    param([string] $Name, $Value)
    $settings = Get-AppSettings
    $settings[$Name] = $Value
    New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
    # Tune presets carry a receipt one level deeper than the simple settings; keep the
    # whole document instead of truncating the evidence that justified a preset.
    $json = ConvertTo-Json -InputObject ([pscustomobject]$settings) -Depth 12
    [IO.File]::WriteAllText((Get-AppSettingsPath), $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-IdleSleepSeconds {
    $settings = Get-AppSettings
    if (-not $settings.ContainsKey('idle_sleep_minutes')) { return 0 }
    $minutes = 0
    if (-not [int]::TryParse([string]$settings['idle_sleep_minutes'], [ref]$minutes)) { return 0 }
    if ($minutes -lt 1) { return 0 }
    return ([Math]::Min($minutes, 1440) * 60)
}

function Test-LlamaServerSupports {
    param([string] $Flag)
    $exe = Get-RuntimeExecutablePath
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { return $false }
    $previous = $ErrorActionPreference
    $text = ''
    Push-Location (Split-Path -Parent $exe)
    try {
        $ErrorActionPreference = 'Continue'
        $text = (@(& $exe --help 2>&1 | ForEach-Object { [string]$_ }) -join "`n")
    } catch {
        $text = ''
    } finally {
        Pop-Location
        $ErrorActionPreference = $previous
    }
    return $text.Contains($Flag)
}

function Set-IdleSleep {
    param([int] $Minutes)
    if ($Minutes -gt 0 -and -not (Test-LlamaServerSupports -Flag '--sleep-idle-seconds')) {
        Write-WarnLine 'The installed llama.cpp is too old to unload the model when idle. Update llama.cpp from the setup screen first.'
        return $false
    }
    Set-AppSetting -Name 'idle_sleep_minutes' -Value $Minutes
    $active = Get-ActiveModel
    if ($null -ne $active -and (Test-Path -LiteralPath (Get-RuntimeExecutablePath) -PathType Leaf)) {
        New-Launchers -ActiveModel $active -EffectiveContext ([int]$active.context_size)
    }
    if ($Minutes -gt 0) {
        Write-Success "Idle unload is on: after $Minutes idle minutes the model leaves graphics memory and returns on your next message."
    } else {
        Write-Success 'Idle unload is off: the model stays in graphics memory until you stop the server.'
    }
    Write-Info 'This applies the next time the AI server starts.'
    return $true
}

function Set-GamePause {
    # Opt-in, like idle unload. Turning it on needs router mode; the change reaches the
    # running server only after the next start, because the launchers are rebuilt here.
    param([int] $Gib)
    if ($Gib -ne 0 -and ($Gib -lt 4 -or $Gib -gt 40)) {
        Write-WarnLine 'Game pause must be 0 (off) or a whole number from 4 to 40 GiB.'
        return $false
    }
    if ($Gib -gt 0 -and -not (Test-LlamaServerSupports -Flag '--models-preset')) {
        Write-WarnLine 'The installed llama.cpp is too old for game pause (it needs router mode). Update llama.cpp from the setup screen first.'
        return $false
    }
    Set-AppSetting -Name 'game_pause_gib' -Value $Gib
    $active = Get-ActiveModel
    if ($null -ne $active -and (Test-Path -LiteralPath (Get-RuntimeExecutablePath) -PathType Leaf)) {
        New-Launchers -ActiveModel $active -EffectiveContext ([int]$active.context_size)
    }
    if ($Gib -gt 0) {
        Write-Success "Game pause is on: when other programs hold $Gib GiB or more of graphics memory, the model unloads and loads again on your next message."
    } else {
        Write-Success 'Game pause is off.'
    }
    Write-Info 'This applies the next time the AI server starts.'
    return $true
}

function Get-GpuMemoryUsage {
    param([double] $TotalGiB)
    # Windows' own GPU counters; they need no driver tools. On a non-English Windows the
    # counter names differ and this returns $null, so the check is silently skipped.
    try {
        $adapters = @((Get-Counter -Counter '\GPU Adapter Memory(*)\Dedicated Usage' -ErrorAction Stop).CounterSamples | Sort-Object CookedValue -Descending)
        if ($adapters.Count -eq 0) { return $null }
        $used = [double]$adapters[0].CookedValue / 1GB
    } catch { return $null }
    $apps = @()
    try {
        $perApp = @{}
        foreach ($sample in (Get-Counter -Counter '\GPU Process Memory(*)\Dedicated Usage' -ErrorAction Stop).CounterSamples) {
            if ($sample.CookedValue -lt 300MB -or ($sample.CookedValue / 1GB) -gt $TotalGiB) { continue }
            if ($sample.InstanceName -notmatch 'pid_(\d+)_') { continue }
            $process = Get-Process -Id ([int]$Matches[1]) -ErrorAction SilentlyContinue
            if ($null -eq $process -or @('dwm', 'System', 'Idle', 'llama-server') -contains $process.ProcessName) { continue }
            if (-not $perApp.ContainsKey($process.ProcessName) -or $perApp[$process.ProcessName] -lt $sample.CookedValue) { $perApp[$process.ProcessName] = $sample.CookedValue }
        }
        # Names only: per-process figures from these counters are not reliable enough to print.
        $apps = @($perApp.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 3 | ForEach-Object { $_.Key })
    } catch { $apps = @() }
    return [pscustomobject]@{ UsedGiB = [Math]::Round($used, 1); Apps = $apps }
}

function Read-GgufStringValue {
    param([IO.BinaryReader] $Reader, [int] $Version)
    $length = if ($Version -eq 1) { [long]$Reader.ReadUInt32() } else { [long]$Reader.ReadUInt64() }
    if ($length -lt 0 -or $length -gt 104857600) { throw "Invalid GGUF string length $length." }
    $bytes = $Reader.ReadBytes([int]$length)
    return [Text.Encoding]::UTF8.GetString($bytes)
}

function Read-GgufScalarValue {
    param([IO.BinaryReader] $Reader, [int] $Type, [int] $Version)
    switch ($Type) {
        0 { return [int]$Reader.ReadByte() }
        1 { return [int]$Reader.ReadSByte() }
        2 { return [int]$Reader.ReadUInt16() }
        3 { return [int]$Reader.ReadInt16() }
        4 { return [long]$Reader.ReadUInt32() }
        5 { return [int]$Reader.ReadInt32() }
        6 { return [double]$Reader.ReadSingle() }
        7 { return [bool]$Reader.ReadBoolean() }
        8 { return (Read-GgufStringValue -Reader $Reader -Version $Version) }
        10 { return [long]$Reader.ReadUInt64() }
        11 { return [long]$Reader.ReadInt64() }
        12 { return [double]$Reader.ReadDouble() }
        default { throw "Unsupported GGUF value type $Type." }
    }
}

function Skip-GgufScalarValue {
    param([IO.BinaryReader] $Reader, [int] $Type, [int] $Version)
    switch ($Type) {
        0 { [void]$Reader.ReadByte() }
        1 { [void]$Reader.ReadSByte() }
        2 { [void]$Reader.ReadUInt16() }
        3 { [void]$Reader.ReadInt16() }
        4 { [void]$Reader.ReadUInt32() }
        5 { [void]$Reader.ReadInt32() }
        6 { [void]$Reader.ReadSingle() }
        7 { [void]$Reader.ReadBoolean() }
        8 { [void](Read-GgufStringValue -Reader $Reader -Version $Version) }
        10 { [void]$Reader.ReadUInt64() }
        11 { [void]$Reader.ReadInt64() }
        12 { [void]$Reader.ReadDouble() }
        default { throw "Unsupported GGUF value type $Type." }
    }
}

function Skip-GgufArrayValue {
    param([IO.BinaryReader] $Reader, [int] $ItemType, [long] $Count, [int] $Version)
    $fixed = @{ 0 = 1; 1 = 1; 2 = 2; 3 = 2; 4 = 4; 5 = 4; 6 = 4; 7 = 1; 10 = 8; 11 = 8; 12 = 8 }
    if ($fixed.ContainsKey($ItemType)) {
        $bytes = [long]$Count * [long]$fixed[$ItemType]
        if ($bytes -gt 0) { [void]$Reader.BaseStream.Seek($bytes, [IO.SeekOrigin]::Current) }
        return
    }
    for ($i = 0; $i -lt $Count; $i++) {
        if ($ItemType -eq 8) { [void](Read-GgufStringValue -Reader $Reader -Version $Version) }
        elseif ($ItemType -eq 9) {
            $nestedType = [int]$Reader.ReadUInt32()
            $nestedCount = if ($Version -eq 1) { [long]$Reader.ReadUInt32() } else { [long]$Reader.ReadUInt64() }
            Skip-GgufArrayValue -Reader $Reader -ItemType $nestedType -Count $nestedCount -Version $Version
        } else { throw "Unsupported GGUF array item type $ItemType." }
    }
}

function Read-GgufMetadata {
    # Header-only reader: tensor data is never touched, so a 30 GB GGUF costs milliseconds.
    # Only the keys the fit estimate needs are materialised; tokenizer arrays are skipped.
    param([string] $Path)
    $meta = @{}
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $meta }
    $stream = $null
    $reader = $null
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $reader = New-Object IO.BinaryReader($stream)
        $magic = [Text.Encoding]::ASCII.GetString($reader.ReadBytes(4))
        if ($magic -ne 'GGUF') { return $meta }
        $version = [int]$reader.ReadUInt32()
        [void]$reader.ReadUInt64()
        $kvCount = [long]$reader.ReadUInt64()
        $wanted = '(?i)(architecture|block_count|attention|expert|embedding_length|context_length|full_attention|recurrent|head_count|key_length|value_length|rope\.dimension_count|ssm\.)'
        for ($i = 0; $i -lt $kvCount; $i++) {
            $key = Read-GgufStringValue -Reader $reader -Version $version
            $type = [int]$reader.ReadUInt32()
            $keep = $key -match $wanted
            if ($type -eq 9) {
                $itemType = [int]$reader.ReadUInt32()
                $count = if ($version -eq 1) { [long]$reader.ReadUInt32() } else { [long]$reader.ReadUInt64() }
                if ($keep -and $count -le 512 -and $itemType -ne 8 -and $itemType -ne 9) {
                    $values = @()
                    for ($j = 0; $j -lt $count; $j++) { $values += Read-GgufScalarValue -Reader $reader -Type $itemType -Version $version }
                    $meta[$key] = @($values)
                } else {
                    Skip-GgufArrayValue -Reader $reader -ItemType $itemType -Count $count -Version $version
                }
            } elseif ($keep) {
                $meta[$key] = Read-GgufScalarValue -Reader $reader -Type $type -Version $version
            } else {
                Skip-GgufScalarValue -Reader $reader -Type $type -Version $version
            }
        }
    } catch {
        return $meta
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
    return $meta
}

function Get-GgufNumber {
    param($Metadata, [string] $Key, [double] $Default = 0)
    if ($null -eq $Metadata -or -not $Metadata.ContainsKey($Key)) { return $Default }
    $value = $Metadata[$Key]
    if ($value -is [array]) {
        if (@($value).Count -eq 0) { return $Default }
        $value = @($value)[0]
    }
    try { return [double]$value } catch { return $Default }
}

function Get-KvCacheGiB {
    # KV bytes per token = layers x KV heads x (K dim + V dim) x bytes per element.
    # q8_0 stores 32 values in 34 bytes (one 2-byte scale per block); f16 is 2 bytes.
    param([int] $FullAttentionLayers, [int] $KvHeads, [int] $KeyLength, [int] $ValueLength, [long] $Context, [string] $CacheType = 'q8_0')
    if ($FullAttentionLayers -le 0 -or $KvHeads -le 0 -or $KeyLength -le 0 -or $ValueLength -le 0 -or $Context -le 0) { return 0.0 }
    $bytesPer = if ($CacheType -eq 'f16') { 2.0 } elseif ($CacheType -eq 'q8_0') { 34.0 / 32.0 } else { 2.0 }
    return ([double]$FullAttentionLayers * $KvHeads * ($KeyLength + $ValueLength) * $bytesPer * $Context) / 1GB
}

function Get-VramEstimate {
    # Estimate only: weights (real file sizes), KV cache (GGUF metadata), compute buffers and
    # headroom. Hybrid architectures use full_attention_interval; the linear-attention state
    # is deliberately not counted, which is why hybrid estimates are medium confidence.
    param($Model, $Hardware, [int] $Context, [double] $UsedGiB = 0, [string] $CacheType = 'q8_0', [int] $Slots = 0, [switch] $BenchmarkOnly)
    # The server estimator multiplies per-slot context by the number of conversation
    # slots. llama-bench has no slots: callers that estimate a benchmark pass Slots 1
    # and BenchmarkOnly, which also leaves the vision projector out of the weight total.
    $slots = if ($Slots -gt 0) { $Slots } else { [Math]::Max(1, [int]$script:ServerSlots) }
    $contextTokens = [long]([Math]::Max(1, $Context) * $slots)
    $modelPath = if ($Model.PSObject.Properties.Name -contains 'model_path') { [string]$Model.model_path } else { Join-Path (Join-Path $InstallRoot 'models') ([string]$Model.File) }
    $projectorPath = ''
    if ($Model.PSObject.Properties.Name -contains 'mmproj_path') { $projectorPath = [string]$Model.mmproj_path }
    elseif (($Model.PSObject.Properties.Name -contains 'Projector') -and -not [string]::IsNullOrWhiteSpace([string]$Model.Projector)) {
        $projectorPath = Join-Path (Join-Path $InstallRoot 'models') (Get-ProjectorLocalName -Model $Model)
    }
    $meta = Read-GgufMetadata -Path $modelPath
    $weights = 0.0
    $weightFiles = @($modelPath)
    if (-not $BenchmarkOnly) { $weightFiles += $projectorPath }
    foreach ($file in $weightFiles) {
        if (-not [string]::IsNullOrWhiteSpace([string]$file) -and (Test-Path -LiteralPath ([string]$file) -PathType Leaf)) {
            try { $weights += ([double](Get-Item -LiteralPath ([string]$file)).Length / 1GB) } catch { }
        }
    }
    if ($weights -le 0) { $weights = [double]$Model.ApproxGiB }
    $arch = if ($meta.ContainsKey('general.architecture')) { [string]$meta['general.architecture'] } else { '' }
    $block = [int](Get-GgufNumber -Metadata $meta -Key "$arch.block_count" -Default 0)
    $embedding = [int](Get-GgufNumber -Metadata $meta -Key "$arch.embedding_length" -Default 0)
    $heads = [int](Get-GgufNumber -Metadata $meta -Key "$arch.attention.head_count" -Default 0)
    $kvHeads = [int](Get-GgufNumber -Metadata $meta -Key "$arch.attention.head_count_kv" -Default 0)
    $keyLength = [int](Get-GgufNumber -Metadata $meta -Key "$arch.attention.key_length" -Default 0)
    $valueLength = [int](Get-GgufNumber -Metadata $meta -Key "$arch.attention.value_length" -Default 0)
    if ($keyLength -le 0 -and $heads -gt 0) { $keyLength = [int][Math]::Round($embedding / $heads) }
    if ($valueLength -le 0) { $valueLength = $keyLength }
    $interval = [int](Get-GgufNumber -Metadata $meta -Key "$arch.full_attention_interval" -Default 0)
    $hybrid = ($interval -gt 1)
    $fullLayers = if ($hybrid -and $block -gt 0) { [int][Math]::Ceiling($block / $interval) } else { $block }
    $kv = Get-KvCacheGiB -FullAttentionLayers $fullLayers -KvHeads $kvHeads -KeyLength $keyLength -ValueLength $valueLength -Context $contextTokens -CacheType $CacheType
    $kvFromMetadata = ($kv -gt 0)
    if (-not $kvFromMetadata -and ($Model.PSObject.Properties.Name -contains 'KvGiBPer32k')) {
        $kv = [double]$Model.KvGiBPer32k * ($contextTokens / 32768.0)
    }
    # Calibrated on this machine (2026-11-04): Qwen3.5 9B at 131072 total context used
    # 8.36 GiB above idle; weights + KV account for 8.27 GiB, leaving ~0.09 GiB of
    # compute buffers. Keep a 0.2 GiB allowance plus the intentional 1 GiB headroom.
    $compute = 0.2
    $headroom = 1.0
    $needed = $weights + $kv + $compute + $headroom
    $total = [double]$Hardware.MaxAmdVramGiB
    $free = [Math]::Max(0.0, $total - $UsedGiB)
    $verdict = if ($needed -gt $total) { 'will_not_fit' } elseif ($needed -gt ($total * 0.9)) { 'tight' } else { 'fits' }
    $confidence = if (-not $kvFromMetadata -or $block -le 0) { 'low' } elseif ($hybrid) { 'medium' } else { 'high' }
    $expertCount = [int](Get-GgufNumber -Metadata $meta -Key "$arch.expert_count" -Default 0)
    $moe = ($expertCount -gt 1) -or (($Model.PSObject.Properties.Name -contains 'Moe') -and [bool]$Model.Moe)
    $warnings = @()
    if (-not $kvFromMetadata) { $warnings += 'GGUF metadata could not supply the attention shape; the KV figure falls back to the catalogue per-32k estimate.' }
    if ($hybrid) { $warnings += "Hybrid attention: only $fullLayers of $block layers hold a full KV cache; linear-attention state is not counted, so the KV figure is an estimate." }
    if ($moe) { $warnings += 'MoE: partial expert offload (--n-cpu-moe) is a cliff, not a slope. Removing one expert layer from the GPU can collapse prompt speed several times over; no offload setting was changed.' }
    $overrides = Get-UserServerArgOverrides
    if (@($overrides | Where-Object { [string]$_ -eq '--n-cpu-moe' }).Count -gt 0) {
        $warnings += 'server-args.user.json sets --n-cpu-moe; treat that offload as experimental and re-check prompt speed against a fully resident run.'
    }
    return [pscustomobject]@{
        estimate = $true
        architecture = $arch
        block_count = $block
        full_attention_layers = $fullLayers
        kv_heads = $kvHeads
        key_length = $keyLength
        value_length = $valueLength
        hybrid = $hybrid
        moe = $moe
        context_tokens = $contextTokens
        slots = $slots
        benchmark_only = [bool]$BenchmarkOnly
        cache_type = $CacheType
        weights_gib = [Math]::Round($weights, 2)
        kv_gib = [Math]::Round($kv, 2)
        compute_gib = [Math]::Round($compute, 2)
        headroom_gib = [Math]::Round($headroom, 2)
        needed_gib = [Math]::Round($needed, 2)
        total_gib = [Math]::Round($total, 2)
        used_gib = [Math]::Round($UsedGiB, 2)
        free_gib = [Math]::Round($free, 2)
        verdict = $verdict
        confidence = $confidence
        warnings = @($warnings)
    }
}

function Get-VramPreflight {
    param($Model, $Hardware, [int] $Context, [double] $UsedGiB)
    $estimate = Get-VramEstimate -Model $Model -Hardware $Hardware -Context $Context -UsedGiB $UsedGiB
    $total = [double]$estimate.total_gib
    $needed = [double]$estimate.needed_gib
    $free = [double]$estimate.free_gib
    # Only warn when the model would fit on an empty card: a model that is meant to spill
    # into system RAM would otherwise warn on every start.
    return [pscustomobject]@{
        TotalGiB = $total
        UsedGiB = $UsedGiB
        FreeGiB = [Math]::Round($free, 1)
        NeededGiB = [Math]::Round($needed, 1)
        WeightsGiB = [double]$estimate.weights_gib
        KvGiB = [double]$estimate.kv_gib
        ComputeGiB = [double]$estimate.compute_gib
        HeadroomGiB = [double]$estimate.headroom_gib
        Verdict = [string]$estimate.verdict
        Confidence = [string]$estimate.confidence
        Hybrid = [bool]$estimate.hybrid
        Moe = [bool]$estimate.moe
        Warnings = @($estimate.warnings)
        Estimate = $estimate
        Low = (($needed -le $total) -and ($free -lt $needed))
    }
}

function Get-VramEstimateDocument {
    # State's typed fit estimate for the active model. Null when there is no active model or
    # no Radeon; always labelled an estimate. The same math feeds Get-VramPreflight, so the
    # warning and the document cannot disagree.
    param($Hardware)
    if ($null -eq $Hardware -or -not [bool]$Hardware.HasAmdGpu) { return $null }
    try {
        $active = Get-ActiveModel
        if ($null -eq $active) { return $null }
        $model = @(Get-ModelCatalog | Where-Object { $_.Id -ieq [string]$active.id }) | Select-Object -First 1
        if ($null -eq $model) { return $null }
        $usage = Get-GpuMemoryUsage -TotalGiB ([double]$Hardware.MaxAmdVramGiB)
        $used = if ($null -ne $usage) { [double]$usage.UsedGiB } else { 0.0 }
        return (Get-VramEstimate -Model $model -Hardware $Hardware -Context ([int]$active.context_size) -UsedGiB $used)
    } catch {
        return [pscustomobject]@{ estimate = $true; available = $false; confidence = 'none'; error = [string]$_.Exception.Message }
    }
}

function Show-VramPreflight {
    param($Hardware)
    # Returns $true when something else is using enough graphics memory to slow the model down.
    $active = Get-ActiveModel
    if ($null -eq $active -or -not $Hardware.HasAmdGpu -or $Hardware.MaxAmdVramGiB -lt 4) { return $false }
    $model = @(Get-ModelCatalog | Where-Object { $_.Id -ieq [string]$active.id }) | Select-Object -First 1
    if ($null -eq $model) { return $false }
    $usage = Get-GpuMemoryUsage -TotalGiB ([double]$Hardware.MaxAmdVramGiB)
    if ($null -eq $usage) { return $false }
    $check = Get-VramPreflight -Model $model -Hardware $Hardware -Context ([int]$active.context_size) -UsedGiB $usage.UsedGiB
    Write-RunLogEvent -Event 'vram_preflight' -Message "Graphics memory in use: $($usage.UsedGiB) GiB of $($check.TotalGiB) GiB" -Data @{ free_gib = $check.FreeGiB; needed_gib = $check.NeededGiB; low = $check.Low }
    if (-not $check.Low) { return $false }
    Write-WarnLine "Only $($check.FreeGiB) GiB of your $([Math]::Round($check.TotalGiB, 1)) GiB graphics memory is free; $($model.Name) wants about $($check.NeededGiB) GiB."
    if (@($usage.Apps).Count -gt 0) { Write-WarnLine "Apps using graphics memory right now include: $(@($usage.Apps) -join ', ')." }
    Write-WarnLine 'It will still run, but part of the model will sit in system RAM and replies will be slower. Closing a game or browser first helps.'
    return $true
}

function Get-DesktopFolder {
    return [Environment]::GetFolderPath('Desktop')
}

function Get-ShortcutSpecs {
    return @(
        [pscustomobject]@{ Name = 'AI Chat (local).lnk'; Script = 'Chat.cmd'; Description = 'Start your local AI and open the chat window'; Style = 1; Icon = '' },
        [pscustomobject]@{ Name = 'AI Off (gaming mode).lnk'; Script = 'Gaming-Mode.cmd'; Description = 'Turn the local AI off and free your graphics memory'; Style = 7; Icon = "$env:SystemRoot\System32\shell32.dll,27" }
    )
}

function New-DesktopShortcuts {
    param([string] $DesktopPath = (Get-DesktopFolder))
    # Callers wrap the result in @(...); a leading comma here would nest the array inside it.
    if (-not (Test-Path -LiteralPath $DesktopPath -PathType Container)) { return @() }
    $shell = New-Object -ComObject WScript.Shell
    $created = @()
    foreach ($spec in (Get-ShortcutSpecs)) {
        $target = Join-Path $InstallRoot $spec.Script
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { continue }
        $link = $shell.CreateShortcut((Join-Path $DesktopPath $spec.Name))
        $link.TargetPath = $target
        $link.WorkingDirectory = $InstallRoot
        $link.Description = $spec.Description
        $link.WindowStyle = $spec.Style
        if (-not [string]::IsNullOrWhiteSpace($spec.Icon)) { $link.IconLocation = $spec.Icon }
        $link.Save()
        $created += $spec.Name
    }
    return $created
}

function Remove-DesktopShortcuts {
    param([string] $DesktopPath = (Get-DesktopFolder))
    # Only deletes shortcuts that still point into this install, never a same-named file you made.
    $removed = 0
    if (-not (Test-Path -LiteralPath $DesktopPath -PathType Container)) { return $removed }
    $shell = New-Object -ComObject WScript.Shell
    foreach ($spec in (Get-ShortcutSpecs)) {
        $path = Join-Path $DesktopPath $spec.Name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        try { $target = [string]$shell.CreateShortcut($path).TargetPath } catch { continue }
        if ($target -ieq (Join-Path $InstallRoot $spec.Script)) {
            Remove-Item -LiteralPath $path -Force
            $removed++
        }
    }
    return $removed
}

function Invoke-EasyStart {
    param($Hardware)
    # One guided path: set up whatever is missing after a single YES, then the menu starts
    # the AI and opens the chat. Returns $false when the user cancelled.
    $server = Get-RuntimeExecutablePath
    $active = Get-ActiveModel
    $needsRuntime = -not (Test-Path -LiteralPath $server -PathType Leaf)
    $needsModel = ($null -eq $active) -or -not (Test-Path -LiteralPath ([string]$active.model_path) -PathType Leaf)

    if ($needsRuntime -or $needsModel) {
        Assert-HardwareForLlama -Hardware $Hardware
        $model = $null
        if ($null -ne $active) { $model = @(Get-ModelCatalog | Where-Object { $_.Id -ieq [string]$active.id }) | Select-Object -First 1 }
        $chosenUseCase = ''
        $useCaseReason = ''
        if ($null -eq $model) {
            # An explicit -UseCase wins, then the saved answer; otherwise ask once (never under -Force).
            $chosenUseCase = $UseCase
            if (-not $chosenUseCase) {
                $saved = Get-AppSettings
                if ($saved.ContainsKey('use_case')) { $chosenUseCase = [string]$saved['use_case'] }
            }
            if (-not $chosenUseCase -and -not $Force) { $chosenUseCase = Read-UseCaseChoice }
            if ($chosenUseCase) {
                $suggestion = Get-ModelForUseCase -UseCase $chosenUseCase -Hardware $Hardware -Runtime (Get-PlannedRuntime -Hardware $Hardware)
                $model = $suggestion.Model
                $useCaseReason = $suggestion.Reason
            } else {
                $model = Get-RecommendedModel -Hardware $Hardware
            }
        }
        $backendChoice = Resolve-BackendChoice -RequestedBackend $Backend -Hardware $Hardware -Runtime (Get-InstalledRuntime)
        $assessment = @(Get-ModelAssessment -Hardware $Hardware | Where-Object { $_.Model.Id -eq $model.Id } | Select-Object -First 1)
        $gpuName = if (@($Hardware.Gpus).Count -gt 0) { [string]@($Hardware.Gpus)[0].Name } else { 'your Radeon' }

        Write-Host "`n  EASY START" -ForegroundColor White
        Write-Info "Your PC: $gpuName, $([Math]::Round($Hardware.MaxAmdVramGiB, 1)) GiB graphics memory, $([Math]::Round($Hardware.RamGiB, 1)) GiB RAM"
        $fit = if ($assessment.Count -gt 0) { " [$($assessment[0].Status)]" } else { '' }
        Write-Info "Best match for it: $($model.Name)$fit"
        if ($useCaseReason) { Write-Info $useCaseReason }
        Write-Host '  What happens next:' -ForegroundColor Yellow
        $step = 1
        if ($needsRuntime) { Write-Host "    $step. Download the AMD AI engine (llama.cpp, $backendChoice build)." -ForegroundColor Gray; $step++ }
        if ($needsModel) { Write-Host "    $step. Download $($model.Name), about $([Math]::Round($model.ApproxGiB, 1)) GB, and check it against its published fingerprint." -ForegroundColor Gray; $step++ }
        Write-Host "    $step. Start it on your graphics card and open a chat window." -ForegroundColor Gray
        Write-Host '  Everything stays on this PC. Allow about 10 to 20 minutes, mostly download time.' -ForegroundColor DarkGray
        if (-not $Force) {
            if ((Read-ConsoleLine -Prompt '  Type YES to begin') -ine 'YES') {
                Write-WarnLine 'Easy start cancelled. Nothing was downloaded.'
                return $false
            }
        }
        if ($chosenUseCase) { Set-AppSetting -Name 'use_case' -Value $chosenUseCase }
        $script:AssumeYes = $true
        try {
            if ($needsRuntime) {
                $tag = Ensure-LlamaCppInstalled -Hardware $Hardware -RequestedBackend $Backend
                if ($null -eq $tag) { return $false }
            }
            if ($needsModel) {
                if (-not (Confirm-ModelDownload -Model $model -Hardware $Hardware)) { return $false }
                Install-Model -Model $model -Hardware $Hardware
            }
        } finally {
            $script:AssumeYes = $false
        }
        $active = Get-ActiveModel
    }

    # Installs made before Chat.cmd existed get it (and the other launchers) rebuilt here.
    if ($null -ne $active -and -not (Test-Path -LiteralPath (Join-Path $InstallRoot 'Chat.cmd') -PathType Leaf)) {
        New-Launchers -ActiveModel $active -EffectiveContext ([int]$active.context_size)
    }

    if (-not $Force -and -not (Get-AppSettings).ContainsKey('easy_extras_done')) {
        Write-Host "`n  Two optional extras (you can change both later under [G] Gaming mode):" -ForegroundColor White
        if ((Read-ConsoleLine -Prompt '  Add "AI Chat" and "AI Off (gaming mode)" shortcuts to your desktop? [Y/n]') -notmatch '^(n|no)$') {
            $made = @(New-DesktopShortcuts)
            if ($made.Count -gt 0) { Write-Success "Desktop shortcuts added: $($made -join ', ')" }
        }
        if ((Read-ConsoleLine -Prompt '  Hand graphics memory back automatically after 15 idle minutes? Good if you game. [Y/n]') -notmatch '^(n|no)$') {
            [void](Set-IdleSleep -Minutes 15)
        }
        Set-AppSetting -Name 'easy_extras_done' -Value $true
    }
    return $true
}

function Test-LocalServer {
    # Plain-language end-to-end check: server, model, chat reply, tool call, context.
    $base = "http://127.0.0.1:$Port"
    $active = Get-ActiveModel
    $alias = if ($null -ne $active) { [string]$active.alias } else { '' }
    $results = @()
    function Send-Json($Uri, $Body, $Timeout) {
        $json = $Body | ConvertTo-Json -Depth 12
        return Invoke-RestMethod -Method Post -Uri $Uri -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec $Timeout
    }
    function Write-Check([string] $Label, [bool] $Ok, [string] $Detail) {
        $badge = if ($Ok) { ' PASS ' } else { ' FAIL ' }
        Write-Host '  ' -NoNewline
        Write-Host $badge -NoNewline -ForegroundColor Black -BackgroundColor $(if ($Ok) { 'Green' } else { 'Red' })
        Write-Host ("  {0,-22}" -f $Label) -NoNewline -ForegroundColor White
        Write-Host $Detail -ForegroundColor $(if ($Ok) { 'Gray' } else { 'Yellow' })
    }

    Write-Host ''
    Write-Host '  Checking the local AI server step by step...' -ForegroundColor Cyan
    Write-Host ''

    $healthy = $false
    try { $healthy = ((Invoke-RestMethod -Uri "$base/health" -TimeoutSec 5).status -eq 'ok') } catch { }
    Write-Check 'Server is running' $healthy $(if ($healthy) { "$base" } else { 'Not reachable. Start it with menu option [2] and wait until it says READY.' })
    if (-not $healthy) { return $false }

    $modelOk = $false; $served = ''
    try { $served = [string]((Invoke-RestMethod -Uri "$base/v1/models" -TimeoutSec 10).data[0].id); $modelOk = -not [string]::IsNullOrWhiteSpace($served) } catch { }
    Write-Check 'Model is loaded' $modelOk $(if ($modelOk) { $served } else { 'The server did not report a model. Restart it with [3] then [2].' })
    if (-not $modelOk) { return $false }

    $chatOk = $false; $chatDetail = ''
    try {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Send-Json "$base/v1/chat/completions" @{ model = $served; max_tokens = 32; messages = @(@{ role = 'user'; content = 'Reply with exactly one word: READY' }) } 120
        $sw.Stop()
        $text = [string]$r.choices[0].message.content
        $chatOk = -not [string]::IsNullOrWhiteSpace($text)
        $speed = if ($r.PSObject.Properties.Name -contains 'timings') { " at $([Math]::Round($r.timings.predicted_per_second)) tokens/s" } else { '' }
        $chatDetail = if ($chatOk) { "replied `"$($text.Trim())`" in $([Math]::Round($sw.Elapsed.TotalSeconds,1)) s$speed" } else { 'Empty reply. Re-activate the model from [1] so the launcher is regenerated.' }
    } catch { $chatDetail = "Request failed: $($_.Exception.Message)" }
    Write-Check 'Chat reply' $chatOk $chatDetail

    $toolOk = $false; $toolDetail = ''
    $toolCapable = ($null -eq $active) -or -not ($active.PSObject.Properties.Name -contains 'tool_calling') -or [bool]$active.tool_calling
    if ($toolCapable) {
        try {
            $tools = @(@{ type = 'function'; function = @{ name = 'get_weather'; description = 'Get the current weather for a city'; parameters = @{ type = 'object'; properties = @{ city = @{ type = 'string' } }; required = @('city') } } })
            $r = Send-Json "$base/v1/chat/completions" @{ model = $served; max_tokens = 256; tools = $tools; messages = @(@{ role = 'user'; content = 'What is the weather in London? Use the tool.' }) } 120
            $message = $r.choices[0].message
            $calls = @(if ($message.PSObject.Properties.Name -contains 'tool_calls') { $message.tool_calls })
            $toolOk = $calls.Count -gt 0
            $toolDetail = if ($toolOk) { "called $($calls[0].function.name) $($calls[0].function.arguments)" } else { 'No tool call returned. VS Code Agent mode needs this; re-activate the model from [1].' }
        } catch { $toolDetail = "Request failed: $($_.Exception.Message)" }
        Write-Check 'Tool calling (Agent)' $toolOk $toolDetail
    } else {
        $toolOk = $true
        Write-Host '  ' -NoNewline; Write-Host ' SKIP ' -NoNewline -ForegroundColor Black -BackgroundColor DarkGray
        Write-Host '  Tool calling (Agent)   This model is not tool-capable; use it for chat only.' -ForegroundColor Gray
    }

    $contextOk = $false; $contextDetail = ''
    try {
        $props = Invoke-RestMethod -Uri "$base/props" -TimeoutSec 10
        $perConversation = [int]$props.default_generation_settings.n_ctx
        $slots = if ($props.PSObject.Properties.Name -contains 'total_slots') { [int]$props.total_slots } else { 1 }
        $contextOk = $perConversation -ge 32768
        $contextDetail = "$perConversation tokens per conversation, $slots at once"
        if (-not $contextOk) { $contextDetail += ' (VS Code Agent mode needs 32768 or more; re-activate with -ContextSize 65536)' }
    } catch { $contextDetail = 'Could not read server settings.' }
    Write-Check 'Room for Agent mode' $contextOk $contextDetail

    $all = $healthy -and $modelOk -and $chatOk -and $toolOk -and $contextOk
    Write-Host ''
    if ($all) {
        Write-Host "  All checks passed. VS Code can use $served." -ForegroundColor Green
    } else {
        Write-Host '  Some checks failed. Follow the hint next to each FAIL, then run this test again.' -ForegroundColor Yellow
    }
    if ($alias -and $served -and $alias -ne $served) {
        Write-Host "  Note: the server is running $served, but the active model is $alias. Stop and start the server to switch." -ForegroundColor Yellow
    }
    return $all
}

function Install-VsCodeChatEndpoint {
    param([switch] $NoPrompt)
    $active = Get-ActiveModel
    if ($null -eq $active) {
        throw 'No model is active. Choose the model browser and install a model before configuring VS Code.'
    }

    $vsCodeRoot = Join-Path $env:APPDATA 'Code\User'
    $configPath = Join-Path $vsCodeRoot 'chatLanguageModels.json'
    $backupPath = $configPath + '.command-center.bak'
    $context = [int]$active.context_size
    if ($context -lt 2048) { $context = 8192 }
    $maxOutputTokens = [Math]::Min(8192, [Math]::Max(1024, [int]($context / 8)))
    $maxInputTokens = $context - $maxOutputTokens
    $toolCalling = if ($active.PSObject.Properties.Name -contains 'tool_calling') {
        [bool]$active.tool_calling
    } else {
        $catalogModel = @(Get-ModelCatalog | Where-Object { $_.Id -eq [string]$active.id } | Select-Object -First 1)
        if ($catalogModel.Count -gt 0) { [bool]$catalogModel[0].Tools } else { [bool]$active.reasoning }
    }
    if ($toolCalling -and $context -lt 32768) {
        Write-WarnLine "The active model runs with a $context-token context. VS Code Agent mode needs about 32768;"
        Write-WarnLine 'below that it fails with "No lowest priority node found". Re-activate the model with -ContextSize 32768.'
    }
    $modelConfig = [pscustomobject]@{
        id = [string]$active.alias
        name = [string]$active.name + ' - llama.cpp local'
        url = "http://127.0.0.1:$Port/v1/chat/completions"
        toolCalling = $toolCalling
        vision = [bool]$active.vision
        maxInputTokens = $maxInputTokens
        maxOutputTokens = $maxOutputTokens
        streaming = $true
    }
    $providerName = 'llama.cpp local'
    # Earlier releases named the provider after the ROCm backend; replace it too.
    $managedNames = @($providerName, 'llama.cpp ROCm')
    $provider = [pscustomobject]@{
        name = $providerName
        vendor = 'customendpoint'
        apiKey = 'local'
        apiType = 'chat-completions'
        models = @($modelConfig)
    }

    $configs = @()
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        try {
            $raw = Get-Content -LiteralPath $configPath -Raw
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $parsed = $raw | ConvertFrom-Json
                $configs = @($parsed | Where-Object { $null -ne $_ })
            }
        } catch {
            throw "VS Code's chatLanguageModels.json is not valid JSON. Fix or remove it, then run option [5] again. Existing file was not changed: $configPath"
        }
    }

    $existing = @($configs | Where-Object { $managedNames -contains $_.name })
    if ($existing.Count -gt 0 -and -not ($Force -or $NoPrompt)) {
        Write-Host "`n  This will update the existing llama.cpp provider in:" -ForegroundColor Yellow
        Write-Host "    $configPath" -ForegroundColor White
        Write-Host '  Your Copilot and unrelated custom providers will be preserved.' -ForegroundColor Gray
        if ((Read-ConsoleLine -Prompt '  Type YES to update VS Code Chat') -ine 'YES') {
            Write-WarnLine 'VS Code Chat configuration cancelled.'
            return $false
        }
    } elseif (-not ($Force -or $NoPrompt)) {
        Write-Host "`n  About to configure VS Code Chat with:" -ForegroundColor Yellow
        Write-Host "    Model:  $($active.alias)" -ForegroundColor White
        Write-Host "    API:    http://127.0.0.1:$Port/v1/chat/completions" -ForegroundColor White
        Write-Host "    Config: $configPath" -ForegroundColor DarkGray
        if ((Read-ConsoleLine -Prompt '  Type YES to configure VS Code Chat') -ine 'YES') {
            Write-WarnLine 'VS Code Chat configuration cancelled.'
            return $false
        }
    }

    New-Item -ItemType Directory -Path $vsCodeRoot -Force | Out-Null
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        Copy-Item -LiteralPath $configPath -Destination $backupPath -Force
    }
    $kept = @($configs | Where-Object { $managedNames -notcontains $_.name })
    $updated = @($kept + $provider)
    # -InputObject keeps a one-element list as a JSON array in Windows PowerShell 5.1,
    # and VS Code expects the file without a byte-order mark.
    $json = ConvertTo-Json -InputObject $updated -Depth 20
    [System.IO.File]::WriteAllText($configPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    Write-Success "VS Code Chat endpoint configured for $($active.alias) ($maxInputTokens input / $maxOutputTokens output tokens)."
    if (Test-Path -LiteralPath $backupPath -PathType Leaf) { Write-Info "Backup: $backupPath" }
    Write-Info 'In VS Code: run Developer: Reload Window, then select the model from Chat: Manage Language Models.'
    Write-Info 'The model remains local; the API key value is only a placeholder.'
    return $true
}

function Remove-VsCodeChatEndpoint {
    # Uninstall counterpart to Install-VsCodeChatEndpoint: removes only the entry
    # this project manages, backs up first, and never throws (best-effort cleanup).
    try {
        $configPath = Join-Path $env:APPDATA 'Code\User\chatLanguageModels.json'
        if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { return }
        $raw = Get-Content -LiteralPath $configPath -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) { return }
        $parsed = $raw | ConvertFrom-Json
        $configs = @($parsed | Where-Object { $null -ne $_ })
        $managedNames = @('llama.cpp local', 'llama.cpp ROCm')
        $kept = @($configs | Where-Object { $managedNames -notcontains $_.name })
        if ($kept.Count -eq $configs.Count) { return }
        Copy-Item -LiteralPath $configPath -Destination ($configPath + '.command-center.bak') -Force
        $json = ConvertTo-Json -InputObject $kept -Depth 20
        [System.IO.File]::WriteAllText($configPath, $json, (New-Object System.Text.UTF8Encoding($false)))
        Write-Info 'Removed the llama.cpp entry from VS Code Chat (backup kept next to the file).'
    } catch {
        Write-WarnLine "Could not clean up VS Code Chat settings; leaving them as they are. ($($_.Exception.Message))"
    }
}

function Remove-Installation {
    $running = Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue
    if (($null -ne $running) -and -not $Force) { throw 'Stop llama-server.exe before uninstalling.' }
    Remove-VsCodeChatEndpoint
    Remove-ContinueConfig
    Remove-LlamaVscodeSettings
    [void](Remove-DesktopShortcuts)
    Remove-UserPathEntry -Directory (Join-Path $InstallRoot 'current')
    $activePath = Get-ActiveRuntimePath
    if (-not [string]::IsNullOrWhiteSpace($activePath)) { Remove-UserPathEntry -Directory $activePath }
    if (Test-Path -LiteralPath $InstallRoot) { Remove-Item -LiteralPath $InstallRoot -Recurse -Force }
    Write-Success 'llama.cpp, downloaded models, launchers, and the user PATH entry were removed.'
}

# ---------------------------------------------------------------------
# Other-editor integrations: llama-vscode and Continue.
# Each: detect, back up, merge only the keys this project owns, and
# never touch a file it cannot safely parse (falls back to instructions).
# ---------------------------------------------------------------------

function Get-ContinueConfigPath {
    Join-Path $env:USERPROFILE '.continue\config.yaml'
}

function Get-ContinueManagedBlock {
    param($ActiveModel)
    @"
# >>> llama.cpp command center managed block (safe to delete) >>>
models:
  - name: $($ActiveModel.name) - llama.cpp local
    provider: llama.cpp
    model: $($ActiveModel.alias)
    apiBase: http://127.0.0.1:$Port
# <<< llama.cpp command center managed block <<<
"@
}

function Install-ContinueConfig {
    # Continue's config.yaml has one top-level `models:` list. If the user already
    # has one (their own cloud models, for example), inserting a second top-level
    # `models:` key would be invalid YAML and could silently hide their models, so
    # that case is instructions-only rather than a risky automatic merge.
    $active = Get-ActiveModel
    if ($null -eq $active) { throw 'No model is active. Install and activate a model first.' }
    $path = Get-ContinueConfigPath
    $block = Get-ContinueManagedBlock -ActiveModel $active

    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        if (-not $Force) {
            Write-Host "`n  About to create Continue's config file:" -ForegroundColor Yellow
            Write-Host "    $path" -ForegroundColor White
            if ((Read-ConsoleLine -Prompt '  Type YES to create it') -ine 'YES') {
                Write-WarnLine 'Continue configuration cancelled.'
                return $false
            }
        }
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        $content = "name: Local llama.cpp`r`nversion: 0.0.1`r`nschema: v1`r`n$block"
        [System.IO.File]::WriteAllText($path, $content, (New-Object System.Text.UTF8Encoding($false)))
        Write-Success "Created Continue's config file for $($active.alias)."
        Write-Info "$path"
        return $true
    }

    $existing = Get-Content -LiteralPath $path -Raw
    $hasManagedBlock = $existing -match '(?m)^# >>> llama\.cpp command center managed block'
    $hasOwnModelsKey = (-not $hasManagedBlock) -and ($existing -match '(?m)^models:\s*$')
    if ($hasOwnModelsKey) {
        Write-WarnLine "Continue's config.yaml already has its own models: list; leaving it unchanged so your other models are not hidden."
        Write-Host "`n  Add this under your existing models: list instead:" -ForegroundColor Yellow
        Write-Host "    - name: $($active.name) - llama.cpp local" -ForegroundColor White
        Write-Host '      provider: llama.cpp' -ForegroundColor White
        Write-Host "      model: $($active.alias)" -ForegroundColor White
        Write-Host "      apiBase: http://127.0.0.1:$Port" -ForegroundColor White
        return $false
    }

    if (-not $Force) {
        Write-Host "`n  About to update the managed llama.cpp block in:" -ForegroundColor Yellow
        Write-Host "    $path" -ForegroundColor White
        Write-Host '  Everything else in the file is left untouched.' -ForegroundColor Gray
        if ((Read-ConsoleLine -Prompt '  Type YES to continue') -ine 'YES') {
            Write-WarnLine 'Continue configuration cancelled.'
            return $false
        }
    }
    Copy-Item -LiteralPath $path -Destination ($path + '.command-center.bak') -Force
    if ($hasManagedBlock) {
        $updated = [regex]::Replace($existing, '(?s)# >>> llama\.cpp command center managed block.*?# <<< llama\.cpp command center managed block <<<\r?\n?', ($block + "`r`n"))
    } else {
        $separator = if ($existing.TrimEnd().Length -gt 0) { "`r`n`r`n" } else { '' }
        $updated = $existing.TrimEnd() + $separator + $block
    }
    [System.IO.File]::WriteAllText($path, $updated, (New-Object System.Text.UTF8Encoding($false)))
    Write-Success "Updated Continue's managed block for $($active.alias)."
    Write-Info "Backup: $path.command-center.bak"
    return $true
}

function Remove-ContinueConfig {
    try {
        $path = Get-ContinueConfigPath
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
        $existing = Get-Content -LiteralPath $path -Raw
        if ($existing -notmatch '(?m)^# >>> llama\.cpp command center managed block') { return }
        Copy-Item -LiteralPath $path -Destination ($path + '.command-center.bak') -Force
        $updated = [regex]::Replace($existing, '(?s)\r?\n?# >>> llama\.cpp command center managed block.*?# <<< llama\.cpp command center managed block <<<\r?\n?', '')
        [System.IO.File]::WriteAllText($path, $updated, (New-Object System.Text.UTF8Encoding($false)))
        Write-Info 'Removed the llama.cpp managed block from Continue''s config.yaml (backup kept).'
    } catch {
        Write-WarnLine "Could not clean up Continue's config.yaml; leaving it as it is. ($($_.Exception.Message))"
    }
}

function Test-JsonHasComments {
    param([string] $Text)
    # A quick, conservative heuristic: VS Code's settings.json commonly allows
    # // and /* */ comments (JSONC), which ConvertFrom-Json cannot parse and
    # ConvertTo-Json cannot reproduce. Detect them outside of string literals
    # well enough to be safe, erring toward "has comments" when unsure.
    $stripped = [regex]::Replace($Text, '"(?:[^"\\]|\\.)*"', '""')
    return ($stripped -match '//' -or $stripped -match '/\*')
}

function Get-LlamaVscodeSettingsPath {
    Join-Path $env:APPDATA 'Code\User\settings.json'
}

function Install-LlamaVscodeSettings {
    # llama-vscode.endpoint / endpoint_chat / endpoint_tools are documented
    # extension settings (ggml-org.llama-vscode) that point it at an
    # already-running llama.cpp server; this never sets launch_* commands,
    # so the extension never starts its own server.
    $active = Get-ActiveModel
    if ($null -eq $active) { throw 'No model is active. Install and activate a model first.' }
    $path = Get-LlamaVscodeSettingsPath
    $base = "http://127.0.0.1:$Port"
    $desired = [ordered]@{
        'llama-vscode.endpoint' = $base
        'llama-vscode.endpoint_chat' = $base
    }
    if ([bool]$active.tool_calling) { $desired['llama-vscode.endpoint_tools'] = $base }

    $raw = ''
    if (Test-Path -LiteralPath $path -PathType Leaf) { $raw = Get-Content -LiteralPath $path -Raw }
    if ((-not [string]::IsNullOrWhiteSpace($raw)) -and (Test-JsonHasComments -Text $raw)) {
        Write-WarnLine 'settings.json contains comments, which this project will not silently strip. Add these lines yourself instead:'
        foreach ($key in $desired.Keys) { Write-Host ('    "{0}": "{1}"' -f $key, $desired[$key]) -ForegroundColor White }
        return $false
    }

    $settings = [ordered]@{}
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
        try {
            $parsedRaw = $raw | ConvertFrom-Json
        } catch {
            throw "VS Code's settings.json is not valid JSON. Fix or remove it, then try again. Existing file was not changed: $path"
        }
        foreach ($property in $parsedRaw.PSObject.Properties) { $settings[$property.Name] = $property.Value }
    }

    if (-not $Force) {
        Write-Host "`n  About to set llama-vscode endpoints in:" -ForegroundColor Yellow
        Write-Host "    $path" -ForegroundColor White
        Write-Host '  Every other setting is preserved.' -ForegroundColor Gray
        if ((Read-ConsoleLine -Prompt '  Type YES to continue') -ine 'YES') {
            Write-WarnLine 'llama-vscode configuration cancelled.'
            return $false
        }
    }

    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    if (Test-Path -LiteralPath $path -PathType Leaf) { Copy-Item -LiteralPath $path -Destination ($path + '.command-center.bak') -Force }
    foreach ($key in $desired.Keys) { $settings[$key] = $desired[$key] }
    $json = ConvertTo-Json -InputObject $settings -Depth 20
    [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
    Write-Success "Configured llama-vscode to use $($active.alias) at $base."
    Write-Info 'Install the llama-vscode extension (ggml-org.llama-vscode) if you have not already, then reload VS Code.'
    return $true
}

function Remove-LlamaVscodeSettings {
    try {
        $path = Get-LlamaVscodeSettingsPath
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
        $raw = Get-Content -LiteralPath $path -Raw
        if ([string]::IsNullOrWhiteSpace($raw) -or (Test-JsonHasComments -Text $raw)) { return }
        $parsedRaw = $raw | ConvertFrom-Json
        $managedKeys = @('llama-vscode.endpoint', 'llama-vscode.endpoint_chat', 'llama-vscode.endpoint_tools')
        $hasAny = @($parsedRaw.PSObject.Properties | Where-Object { $managedKeys -contains $_.Name }).Count -gt 0
        if (-not $hasAny) { return }
        $settings = [ordered]@{}
        foreach ($property in $parsedRaw.PSObject.Properties) {
            if ($managedKeys -contains $property.Name) { continue }
            $settings[$property.Name] = $property.Value
        }
        Copy-Item -LiteralPath $path -Destination ($path + '.command-center.bak') -Force
        $json = ConvertTo-Json -InputObject $settings -Depth 20
        [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
        Write-Info 'Removed llama-vscode endpoint settings (backup kept).'
    } catch {
        Write-WarnLine "Could not clean up llama-vscode settings; leaving them as they are. ($($_.Exception.Message))"
    }
}

# ---------------------------------------------------------------------
# Command-center self-update check (never auto-updates; informational only)
# ---------------------------------------------------------------------

function Compare-SemVer {
    param([string] $A, [string] $B)
    function Get-VersionParts([string] $Value) {
        $clean = $Value.TrimStart('v', 'V')
        $numeric = ($clean -split '-')[0]
        return @($numeric -split '\.' | ForEach-Object { $n = 0; [void][int]::TryParse($_, [ref]$n); $n })
    }
    $partsA = @(Get-VersionParts $A)
    $partsB = @(Get-VersionParts $B)
    $length = [Math]::Max($partsA.Count, $partsB.Count)
    for ($i = 0; $i -lt $length; $i++) {
        $x = if ($i -lt $partsA.Count) { $partsA[$i] } else { 0 }
        $y = if ($i -lt $partsB.Count) { $partsB[$i] } else { 0 }
        if ($x -ne $y) { return [Math]::Sign($x - $y) }
    }
    return 0
}

function Test-CommandCenterUpdate {
    # Best-effort only: any failure (offline, rate limit) is reported, never thrown.
    try {
        $latest = Invoke-RestMethod -Uri ("https://api.github.com/repos/$script:CommandCenterRepo/releases/latest") -Headers $script:GitHubHeaders -TimeoutSec 5
        $tag = [string]$latest.tag_name
        $cmp = Compare-SemVer -A $tag -B $script:CommandCenterVersion
        return [pscustomobject]@{
            Checked = $true; Current = $script:CommandCenterVersion; Latest = $tag
            UpdateAvailable = ($cmp -gt 0); Url = [string]$latest.html_url; Error = ''
        }
    } catch {
        return [pscustomobject]@{
            Checked = $false; Current = $script:CommandCenterVersion; Latest = ''
            UpdateAvailable = $false; Url = ''; Error = $_.Exception.Message
        }
    }
}

# ---------------------------------------------------------------------
# Live monitor
# ---------------------------------------------------------------------

function Get-ServerMetricsSnapshot {
    $base = "http://127.0.0.1:$Port"
    $snapshot = [pscustomobject]@{ Health = $null; Props = $null; PromptTokPerSec = $null; GenerationTokPerSec = $null }
    try { $snapshot.Health = Invoke-RestMethod -Uri "$base/health" -TimeoutSec 3 } catch { }
    try { $snapshot.Props = Invoke-RestMethod -Uri "$base/props" -TimeoutSec 3 } catch { }
    try {
        $metricsText = Invoke-RestMethod -Uri "$base/metrics" -TimeoutSec 3
        $text = [string]$metricsText
        $pp = [regex]::Match($text, 'llamacpp:prompt_tokens_seconds\s+([0-9.eE+-]+)')
        $tg = [regex]::Match($text, 'llamacpp:predicted_tokens_seconds\s+([0-9.eE+-]+)')
        if ($pp.Success) { $snapshot.PromptTokPerSec = [double]$pp.Groups[1].Value }
        if ($tg.Success) { $snapshot.GenerationTokPerSec = [double]$tg.Groups[1].Value }
    } catch { }
    return $snapshot
}

# ---------------------------------------------------------------------
# Benchmark
# ---------------------------------------------------------------------

function Get-BenchmarkHistoryPath {
    return Join-Path (Get-RunLogDirectory) 'benchmark-history.jsonl'
}

function Add-BenchmarkRecord {
    # Appends one JSON line per run (UTF-8 without BOM) so speeds can be compared
    # across models, quants and settings over time.
    param($Record, [string] $Path = '')
    if ([string]::IsNullOrWhiteSpace($Path)) { $Path = Get-BenchmarkHistoryPath }
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $line = ($Record | ConvertTo-Json -Compress -Depth 6)
    [IO.File]::AppendAllText($Path, $line + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-BenchmarkHistory {
    # Saved runs, oldest first, capped at $Max. A missing file or a malformed line
    # is never fatal: history is a convenience, not a requirement.
    param([string] $Path = '', [int] $Max = 10)
    if ([string]::IsNullOrWhiteSpace($Path)) { $Path = Get-BenchmarkHistoryPath }
    $records = @()
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        foreach ($entry in @(Get-Content -LiteralPath $Path)) {
            if ([string]::IsNullOrWhiteSpace($entry)) { continue }
            try { $records += @($entry | ConvertFrom-Json) } catch { }
        }
    }
    if ($records.Count -gt $Max) { $records = @($records | Select-Object -Last $Max) }
    return ,@($records)
}

function Invoke-BenchmarkRequest {
    # One measured request against a running server; returns its timings payload.
    param([string] $ServedModel)
    $base = "http://127.0.0.1:$Port"
    function Send-Chat($Body, [int] $TimeoutSec) {
        $json = $Body | ConvertTo-Json -Depth 12
        return Invoke-RestMethod -Method Post -Uri "$base/v1/chat/completions" -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec $TimeoutSec
    }
    # Warm-up: the first request after start-up pays one-time costs (KV allocation,
    # sampler setup) that would otherwise skew the measurement.
    [void](Send-Chat @{ model = $ServedModel; max_tokens = 16; messages = @(@{ role = 'user'; content = 'Reply with one word: ready' }) } 120)
    $prompt = 'Explain in two short paragraphs why the sky is blue, then list three fun facts about rainbows.'
    $response = Send-Chat @{
        model = $ServedModel
        messages = @(@{ role = 'user'; content = $prompt })
        max_tokens = 256
        temperature = 0
        stream = $false
    } 300
    if ($response.PSObject.Properties.Name -notcontains 'timings') { throw 'The server did not report timings for the benchmark request.' }
    return $response.timings
}

function Invoke-ModelBenchmark {
    # Runs the fixed benchmark against the running server, saves it, shows history.
    $active = Get-ActiveModel
    if ($null -eq $active) {
        Write-WarnLine 'No active model yet. Choose [1] Setup and models first.'
        return $false
    }
    $base = "http://127.0.0.1:$Port"
    $healthy = $false
    try { $healthy = ((Invoke-RestMethod -Uri "$base/health" -TimeoutSec 5).status -eq 'ok') } catch { }
    if (-not $healthy) {
        Write-WarnLine 'The AI server is not running. Choose [2] Start AI server and wait for READY, then try again.'
        return $false
    }
    $served = ''
    try { $served = [string]((Invoke-RestMethod -Uri "$base/v1/models" -TimeoutSec 10).data[0].id) } catch { }
    if ([string]::IsNullOrWhiteSpace($served)) { $served = [string]$active.alias }
    if ($served -ne [string]$active.alias) {
        Write-WarnLine "The server is running '$served' but the active model is '$($active.alias)'. The result applies to what is running."
    }

    Write-Host "`n  Running the benchmark: a warm-up, then a fixed prompt with 256 new tokens..." -ForegroundColor White
    $timings = Invoke-BenchmarkRequest -ServedModel $served
    $runtime = Get-InstalledRuntime
    $record = [pscustomobject][ordered]@{
        at = (Get-Date).ToUniversalTime().ToString('o')
        model_id = [string]$active.id
        alias = [string]$active.alias
        context = [int]$active.context_size
        backend = if ($null -ne $runtime) { [string]$runtime.backend } else { 'unknown' }
        build = if ($null -ne $runtime) { [string]$runtime.tag } else { '' }
        prompt_tokens = [int]$timings.prompt_n
        prompt_tps = [Math]::Round([double]$timings.prompt_per_second, 1)
        gen_tokens = [int]$timings.predicted_n
        gen_tps = [Math]::Round([double]$timings.predicted_per_second, 1)
    }
    Add-BenchmarkRecord -Record $record
    Write-RunLogEvent -Event 'benchmark' -Message "Benchmark $($record.alias): $($record.gen_tps) generation tokens/s" -Data @{
        model_id = $record.model_id
        prompt_tps = $record.prompt_tps
        prompt_tokens = $record.prompt_tokens
        gen_tps = $record.gen_tps
        gen_tokens = $record.gen_tokens
    }
    Show-BenchmarkHistory -Current $record
    return $true
}

function Show-BenchmarkHistory {
    # Current run first, then saved runs newest first, with a plain-English reading.
    param($Current)
    Write-Host ''
    Write-Host ('  BENCHMARK RESULT  {0}  (context {1} tokens)' -f $Current.alias, $Current.context) -ForegroundColor White
    Write-Host ('    Prompt processing  {0,7:N1} tokens/s   ({1} tokens read)' -f $Current.prompt_tps, $Current.prompt_tokens) -ForegroundColor Cyan
    Write-Host ('    Generation         {0,7:N1} tokens/s   ({1} tokens written)' -f $Current.gen_tps, $Current.gen_tokens) -ForegroundColor Cyan
    Write-Host ('    About {0} words per second of text.' -f [int][Math]::Round([double]$Current.gen_tps * 0.75)) -ForegroundColor DarkGray

    $history = Get-BenchmarkHistory
    $earlier = @($history | Where-Object { [string]$_.at -ne [string]$Current.at })
    if ($earlier.Count -eq 0) {
        Write-Host ''
        Write-Host '  First result saved. Run the benchmark again after changing model or settings to compare.' -ForegroundColor DarkGray
        return
    }
    Write-Host ''
    Write-Host '  SAVED RUNS (newest first)' -ForegroundColor White
    $shown = @($history | Select-Object -Last 8)
    [array]::Reverse($shown)
    foreach ($row in $shown) {
        $when = '?'
        try { $when = ([DateTime]::Parse([string]$row.at)).ToLocalTime().ToString('yyyy-MM-dd HH:mm') } catch { }
        $isCurrent = ([string]$row.at -eq [string]$Current.at)
        $marker = if ($isCurrent) { '>' } else { ' ' }
        $color = if ($isCurrent) { 'Cyan' } else { 'Gray' }
        Write-Host ('  {0} {1}  {2,-16} {3,8:N1} prompt  {4,8:N1} generation' -f $marker, $when, [string]$row.alias, [double]$row.prompt_tps, [double]$row.gen_tps) -ForegroundColor $color
    }
    $sameModel = @($earlier | Where-Object { [string]$_.model_id -eq [string]$Current.model_id })
    if ($sameModel.Count -gt 0) {
        $best = @($sameModel | Sort-Object -Property gen_tps | Select-Object -Last 1)[0]
        if ([double]$best.gen_tps -gt [double]$Current.gen_tps) {
            Write-Host ('  Best earlier run for this model: {0:N1} tokens/s.' -f [double]$best.gen_tps) -ForegroundColor DarkGray
        }
    }
}

function Show-LiveMonitor {
    Write-Host "`n  LIVE MONITOR — refreshes every 2 seconds. Type Q then Enter to return." -ForegroundColor White
    while ($true) {
        $active = Get-ActiveModel
        $process = Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue
        $snapshot = Get-ServerMetricsSnapshot

        Clear-Screen
        Show-Banner
        Write-Host '  LIVE MONITOR' -ForegroundColor White

        $statusLabel = if ($null -ne $snapshot.Health) { '[RUNNING]' } elseif ($null -ne $process) { '[STARTING]' } else { '[OFFLINE]' }
        $statusColor = if ($null -ne $snapshot.Health) { 'Green' } elseif ($null -ne $process) { 'Yellow' } else { 'Red' }
        Write-Host ('  Server status   {0}' -f $statusLabel) -ForegroundColor $statusColor
        if ($null -ne $process) { Write-Host ('  Process ID      {0}  (started {1:g})' -f $process.Id, $process.StartTime) -ForegroundColor Gray }
        # Report the installed build only. Whether layers actually landed on the GPU is
        # in the server window's load log; the HTTP API does not expose it.
        $runtimePath = Get-ActiveRuntimePath
        $installInfo = if (-not [string]::IsNullOrWhiteSpace($runtimePath)) { Join-Path $runtimePath 'installation.json' } else { Join-Path $InstallRoot 'current\installation.json' }
        $backendText = 'unknown'
        if (Test-Path -LiteralPath $installInfo -PathType Leaf) {
            try { $info = Get-Content -LiteralPath $installInfo -Raw | ConvertFrom-Json; $backendText = "$($info.backend) build $($info.tag)" } catch { }
        }
        Write-Host ('  Installed build {0}  (GPU layer placement: see the server window log)' -f $backendText) -ForegroundColor Gray
        if ($null -ne $active) {
            Write-Host ('  Active model    {0}  (alias {1})' -f $active.name, $active.alias) -ForegroundColor White
            Write-Host ('  Context         {0} tokens x {1} slots' -f $active.context_size, $script:ServerSlots) -ForegroundColor Gray
        } else {
            Write-Host '  Active model    none configured' -ForegroundColor Yellow
        }
        Write-Host ('  API / Web UI    http://127.0.0.1:{0}/' -f $Port) -ForegroundColor Gray
        if ($null -ne $snapshot.Props -and ($snapshot.Props.PSObject.Properties.Name -contains 'total_slots')) {
            Write-Host ('  Server slots    {0}' -f $snapshot.Props.total_slots) -ForegroundColor Gray
        }
        if ($null -ne $snapshot.PromptTokPerSec) { Write-Host ('  Prompt speed    {0:N1} tok/s' -f $snapshot.PromptTokPerSec) -ForegroundColor Cyan }
        if ($null -ne $snapshot.GenerationTokPerSec) { Write-Host ('  Generation      {0:N1} tok/s' -f $snapshot.GenerationTokPerSec) -ForegroundColor Cyan }
        if ($null -ne $snapshot.Health -and $null -eq $snapshot.PromptTokPerSec -and $null -eq $snapshot.GenerationTokPerSec) {
            Write-Host '  Speed           no requests served yet in this run' -ForegroundColor DarkGray
        }
        if ($null -eq $snapshot.Health) {
            Write-Host "`n  Start the server from the dashboard [3] to see live figures here." -ForegroundColor DarkGray
        }
        Write-Host "`n  Refreshing every 2s. Type Q then Enter to return to the menu." -ForegroundColor DarkGray

        for ($tick = 0; $tick -lt 20; $tick++) {
            Start-Sleep -Milliseconds 100
            if ([Console]::IsInputRedirected) { return }
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($key.KeyChar -ieq 'q') { return }
            }
        }
    }
}

# ---------------------------------------------------------------------
# Dashboard
# ---------------------------------------------------------------------

function Select-BackendInteractively {
    Clear-Screen
    Show-Banner
    Write-Host '  BACKEND SELECTOR' -ForegroundColor White
    Write-Host '  [1] Auto — AMD ROCm for supported Radeon dGPUs; Vulkan otherwise (Recommended)' -ForegroundColor Green
    Write-Host '  [2] Vulkan — widest AMD compatibility, including Ryzen iGPUs and older Radeon cards' -ForegroundColor Cyan
    Write-Host '  [3] AMD ROCm 7.2.1 — validated Windows package for supported Radeon dGPUs' -ForegroundColor Magenta
    Write-Host '  [4] llama.cpp ROCm (latest, advanced) — newest llama.cpp; runs Gemma 4 and Ornith on ROCm' -ForegroundColor Yellow
    Write-Host '  [0] Return' -ForegroundColor DarkGray
    $choice = Read-ConsoleLine -Prompt '  Select backend'
    if ($choice -eq '1') { $script:Backend = 'Auto'; Write-Success 'Backend set to Auto.' }
    elseif ($choice -eq '2') { $script:Backend = 'Vulkan'; Write-Success 'Backend set to Vulkan.' }
    elseif ($choice -eq '3') { $script:Backend = 'ROCm'; Write-WarnLine 'ROCm selected. Installation will stop if the Radeon is not in AMD Windows matrix.' }
    elseif ($choice -eq '4') {
        $script:Backend = 'ROCmLatest'
        foreach ($line in (Get-RocmLatestRequirementText)) { Write-WarnLine $line }
        Write-Info 'Now choose [5] Update llama.cpp to install it.'
    }
}

# ---------------------------------------------------------------------
# Window (WPF): the friendly front door. Everything it does is also available
# from the text menu and the -Action switches; it only calls the same functions.
# ---------------------------------------------------------------------

function Get-GuiXaml {
    return @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="llama.cpp AMD Command Center" Width="940" Height="780" MinWidth="820" MinHeight="620"
        WindowStartupLocation="CenterScreen" Background="#0B1020" FontFamily="Segoe UI" FontSize="14"
        UseLayoutRounding="True" SnapsToDevicePixels="True" TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <Style x:Key="BtnBase" TargetType="Button">
      <Setter Property="Foreground" Value="#EDF3FF"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="18,11"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="10" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Opacity" Value="0.88"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="Bd" Property="Opacity" Value="0.7"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Bd" Property="Opacity" Value="0.4"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="#55E6FF"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="PrimaryBtn" TargetType="Button" BasedOn="{StaticResource BtnBase}">
      <Setter Property="Background" Value="#FF7A4D"/>
      <Setter Property="BorderBrush" Value="#FF7A4D"/>
      <Setter Property="Foreground" Value="#1A0B06"/>
      <Setter Property="FontSize" Value="17"/>
      <Setter Property="Padding" Value="28,14"/>
    </Style>
    <Style x:Key="GhostBtn" TargetType="Button" BasedOn="{StaticResource BtnBase}">
      <Setter Property="Background" Value="#17213F"/>
      <Setter Property="BorderBrush" Value="#2C3C64"/>
    </Style>
    <Style x:Key="DangerBtn" TargetType="Button" BasedOn="{StaticResource BtnBase}">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="#FF8A8A"/>
      <Setter Property="Foreground" Value="#FF8A8A"/>
      <Setter Property="Padding" Value="22,14"/>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#EDF3FF"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,6,0,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Border x:Name="Track" Width="44" Height="24" CornerRadius="12" Background="#2C3C64" VerticalAlignment="Center">
                <Ellipse x:Name="Knob" Width="18" Height="18" Fill="#EDF3FF" HorizontalAlignment="Left" Margin="3,0,0,0"/>
              </Border>
              <ContentPresenter Margin="14,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Track" Property="Background" Value="#72F1A6"/>
                <Setter TargetName="Knob" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="Knob" Property="Margin" Value="0,0,3,0"/>
                <Setter TargetName="Knob" Property="Fill" Value="#0B1020"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ProgressBar">
      <Setter Property="Height" Value="10"/>
      <Setter Property="Foreground" Value="#72F1A6"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Grid>
              <Border Background="#1B2647" CornerRadius="5"/>
              <Border x:Name="PART_Track"/>
              <Border x:Name="PART_Indicator" HorizontalAlignment="Left" Background="{TemplateBinding Foreground}" CornerRadius="5"/>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="UcRadio" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#EDF3FF"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,0,8"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="Bd" Background="#17213F" BorderBrush="#2C3C64" BorderThickness="1" CornerRadius="10" Padding="14,10">
              <StackPanel Orientation="Horizontal">
                <Grid Width="18" Height="18" Margin="0,0,14,0" VerticalAlignment="Center">
                  <Ellipse Stroke="#6F7FA6" StrokeThickness="2"/>
                  <Ellipse x:Name="Dot" Width="8" Height="8" Fill="#FF7A4D" Visibility="Collapsed"/>
                </Grid>
                <ContentPresenter VerticalAlignment="Center"/>
              </StackPanel>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Opacity" Value="0.9"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="#FF7A4D"/>
                <Setter TargetName="Bd" Property="Background" Value="#1E2850"/>
                <Setter TargetName="Dot" Property="Visibility" Value="Visible"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="#121A31"/>
      <Setter Property="BorderBrush" Value="#26335A"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="14"/>
      <Setter Property="Padding" Value="18,16"/>
    </Style>
    <Style x:Key="Label" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#AAB8D6"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="Glyph" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
  </Window.Resources>
  <Grid>
  <ScrollViewer VerticalScrollBarVisibility="Auto" Background="#0B1020">
    <Grid x:Name="Root" Margin="30,24,30,18">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <Grid Grid.Row="0" Margin="0,0,0,20">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <Border Width="60" Height="60" CornerRadius="14" ClipToBounds="True" Background="#05070F" Margin="0,0,16,0" VerticalAlignment="Center">
          <Image x:Name="LogoImg" Stretch="UniformToFill"/>
        </Border>
        <StackPanel Grid.Column="1" VerticalAlignment="Center">
          <TextBlock Text="AI on your Radeon" FontSize="26" FontWeight="Bold" Foreground="#EDF3FF"/>
          <TextBlock Text="Private. Runs on your own graphics card. No cloud, no subscription." Foreground="#AAB8D6" Margin="0,2,0,0"/>
        </StackPanel>
        <TextBlock x:Name="VersionText" Grid.Column="2" VerticalAlignment="Top" Foreground="#6F7FA6" FontSize="12"/>
      </Grid>

      <Border Grid.Row="1" Style="{StaticResource Card}" Padding="26,24" Margin="0,0,0,16">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <StackPanel>
            <StackPanel Orientation="Horizontal">
              <Ellipse x:Name="StatusDot" Width="14" Height="14" Fill="#6F7FA6" VerticalAlignment="Center" Margin="0,3,12,0"/>
              <TextBlock x:Name="HeroTitle" Text="Checking your PC..." FontSize="28" FontWeight="Bold" Foreground="#EDF3FF"/>
            </StackPanel>
            <TextBlock x:Name="HeroDetail" Foreground="#AAB8D6" FontSize="15" TextWrapping="Wrap" Margin="26,8,20,0" MaxWidth="520"/>
          </StackPanel>
          <StackPanel Grid.Column="1" VerticalAlignment="Center" MinWidth="250">
            <Button x:Name="PrimaryBtn" Style="{StaticResource PrimaryBtn}" IsEnabled="False">
              <StackPanel Orientation="Horizontal">
                <TextBlock x:Name="PrimaryIcon" Style="{StaticResource Glyph}" Text="&#xE768;" FontSize="16" Margin="0,0,12,0"/>
                <TextBlock x:Name="PrimaryText" Text="Please wait..."/>
              </StackPanel>
            </Button>
            <Button x:Name="OffBtn" Style="{StaticResource DangerBtn}" Margin="0,10,0,0" Visibility="Collapsed">
              <StackPanel Orientation="Horizontal">
                <TextBlock Style="{StaticResource Glyph}" Text="&#xE7FC;" FontSize="16" Margin="0,0,12,0"/>
                <TextBlock Text="Turn off - free my GPU for a game"/>
              </StackPanel>
            </Button>
          </StackPanel>
        </Grid>
      </Border>

      <Grid Grid.Row="2" Margin="0,0,0,16">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="1.15*"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Border Style="{StaticResource Card}" Margin="0,0,8,0">
          <StackPanel>
            <TextBlock Style="{StaticResource Label}" Text="YOUR AI MODEL"/>
            <TextBlock x:Name="ModelName" FontSize="19" FontWeight="SemiBold" Foreground="#EDF3FF" Margin="0,8,0,0" TextWrapping="Wrap"/>
            <TextBlock x:Name="ModelDetail" Foreground="#AAB8D6" Margin="0,4,0,0" TextWrapping="Wrap"/>
          </StackPanel>
        </Border>
        <Border Grid.Column="1" Style="{StaticResource Card}" Margin="8,0,8,0">
          <StackPanel>
            <TextBlock Style="{StaticResource Label}" Text="GRAPHICS MEMORY (VRAM) IN USE"/>
            <TextBlock x:Name="MemValue" FontSize="19" FontWeight="SemiBold" Foreground="#EDF3FF" Margin="0,8,0,8"/>
            <ProgressBar x:Name="MemBar" Minimum="0" Maximum="100" Value="0"/>
            <TextBlock x:Name="MemHint" Foreground="#AAB8D6" Margin="0,10,0,0" TextWrapping="Wrap"/>
          </StackPanel>
        </Border>
        <Border Grid.Column="2" Style="{StaticResource Card}" Margin="8,0,0,0">
          <StackPanel>
            <TextBlock Style="{StaticResource Label}" Text="RUNS ON"/>
            <TextBlock x:Name="GpuName" FontSize="19" FontWeight="SemiBold" Foreground="#EDF3FF" Margin="0,8,0,0" TextWrapping="Wrap"/>
            <TextBlock x:Name="EngineDetail" Foreground="#AAB8D6" Margin="0,4,0,0" TextWrapping="Wrap"/>
          </StackPanel>
        </Border>
      </Grid>

      <Border Grid.Row="3" Style="{StaticResource Card}" Margin="0,0,0,16">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <StackPanel Margin="0,0,16,0">
            <TextBlock Style="{StaticResource Label}" Text="GAMING"/>
            <TextBlock Text="Share your graphics card with games" FontSize="16" FontWeight="SemiBold" Foreground="#EDF3FF" Margin="0,8,0,2"/>
            <TextBlock x:Name="GamingHint" Foreground="#AAB8D6" TextWrapping="Wrap"/>
          </StackPanel>
          <StackPanel Grid.Column="1" VerticalAlignment="Center">
            <CheckBox x:Name="IdleCheck" Content="Unload the AI after 15 idle minutes"/>
            <CheckBox x:Name="ShortcutCheck" Content="Desktop shortcuts: AI Chat and AI Off"/>
          </StackPanel>
        </Grid>
      </Border>

      <WrapPanel Grid.Row="4" Margin="0,0,0,10">
        <Button x:Name="HealthBtn" Style="{StaticResource GhostBtn}" Margin="0,0,10,10">
          <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Glyph}" Text="&#xE73E;" Margin="0,0,10,0"/><TextBlock Text="Check it works"/></StackPanel>
        </Button>
        <Button x:Name="ModelsBtn" Style="{StaticResource GhostBtn}" Margin="0,0,10,10">
          <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Glyph}" Text="&#xE896;" Margin="0,0,10,0"/><TextBlock Text="Choose a different model"/></StackPanel>
        </Button>
        <Button x:Name="VsCodeBtn" Style="{StaticResource GhostBtn}" Margin="0,0,10,10">
          <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Glyph}" Text="&#xE943;" Margin="0,0,10,0"/><TextBlock Text="Use it in VS Code"/></StackPanel>
        </Button>
        <Button x:Name="MoreBtn" Style="{StaticResource GhostBtn}" Margin="0,0,10,10">
          <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Glyph}" Text="&#xE713;" Margin="0,0,10,0"/><TextBlock Text="More options"/></StackPanel>
        </Button>
        <Button x:Name="HelpBtn" Style="{StaticResource GhostBtn}" Margin="0,0,0,10">
          <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource Glyph}" Text="&#xE897;" Margin="0,0,10,0"/><TextBlock Text="Help"/></StackPanel>
        </Button>
      </WrapPanel>

      <Border x:Name="BusyBanner" Grid.Row="5" Style="{StaticResource Card}" Background="#2A2210" BorderBrush="#7A5F1E" Visibility="Collapsed" Margin="0,0,0,10">
        <TextBlock x:Name="BusyText" Foreground="#FFD166" TextWrapping="Wrap"/>
      </Border>
      <TextBlock x:Name="NextStep" Grid.Row="5" Foreground="#6F7FA6" FontSize="12" TextWrapping="Wrap" VerticalAlignment="Bottom" Margin="2,6,0,0"/>
    </Grid>
  </ScrollViewer>

  <Grid x:Name="UseCaseOverlay" Visibility="Collapsed" Background="#E6070B16">
    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalAlignment="Center" VerticalAlignment="Center" MaxWidth="660" Margin="24">
      <Border Style="{StaticResource Card}" Padding="28,26">
        <StackPanel>
          <TextBlock Text="What do you want to use it for?" FontSize="23" FontWeight="Bold" Foreground="#EDF3FF"/>
          <TextBlock Text="Pick the closest one. We suggest the model that suits it best on your PC." Foreground="#AAB8D6" Margin="0,6,0,16" TextWrapping="Wrap"/>
          <RadioButton x:Name="Uc_chat" Tag="chat" GroupName="uc" Style="{StaticResource UcRadio}" IsChecked="True">
            <StackPanel><TextBlock Text="Everyday chat and writing" FontWeight="SemiBold" FontSize="15"/><TextBlock Text="Questions, writing, summaries, brainstorming, video scripts." Foreground="#AAB8D6" FontSize="12.5" TextWrapping="Wrap"/></StackPanel>
          </RadioButton>
          <RadioButton x:Name="Uc_coding" Tag="coding" GroupName="uc" Style="{StaticResource UcRadio}">
            <StackPanel><TextBlock Text="Coding help in VS Code" FontWeight="SemiBold" FontSize="15"/><TextBlock Text="Writes, explains and fixes code, and can edit your files in Copilot Agent mode." Foreground="#AAB8D6" FontSize="12.5" TextWrapping="Wrap"/></StackPanel>
          </RadioButton>
          <RadioButton x:Name="Uc_images" Tag="images" GroupName="uc" Style="{StaticResource UcRadio}">
            <StackPanel><TextBlock Text="Understanding pictures and screenshots" FontWeight="SemiBold" FontSize="15"/><TextBlock Text="Describes a photo, reads a screenshot, explains a chart." Foreground="#AAB8D6" FontSize="12.5" TextWrapping="Wrap"/></StackPanel>
          </RadioButton>
          <RadioButton x:Name="Uc_fast" Tag="fast" GroupName="uc" Style="{StaticResource UcRadio}">
            <StackPanel><TextBlock Text="Quick answers, easy on my PC" FontWeight="SemiBold" FontSize="15"/><TextBlock Text="A small, fast model that leaves most of your graphics memory free for games." Foreground="#AAB8D6" FontSize="12.5" TextWrapping="Wrap"/></StackPanel>
          </RadioButton>
          <RadioButton x:Name="Uc_quality" Tag="quality" GroupName="uc" Style="{StaticResource UcRadio}">
            <StackPanel><TextBlock Text="Best possible answers (slower)" FontWeight="SemiBold" FontSize="15"/><TextBlock Text="The biggest model your PC can hold. Replies take noticeably longer." Foreground="#AAB8D6" FontSize="12.5" TextWrapping="Wrap"/></StackPanel>
          </RadioButton>
          <Border Background="#0E1530" BorderBrush="#2C3C64" BorderThickness="1" CornerRadius="12" Padding="16,14" Margin="0,10,0,0">
            <StackPanel>
              <TextBlock Style="{StaticResource Label}" Text="BEST MATCH FOR YOUR PC"/>
              <TextBlock x:Name="UcModelName" FontSize="19" FontWeight="SemiBold" Foreground="#EDF3FF" Margin="0,6,0,0" TextWrapping="Wrap"/>
              <TextBlock x:Name="UcModelDetail" Foreground="#AAB8D6" TextWrapping="Wrap" Margin="0,4,0,0"/>
            </StackPanel>
          </Border>
          <WrapPanel Margin="0,18,0,0" HorizontalAlignment="Right">
            <Button x:Name="UcCancelBtn" Style="{StaticResource GhostBtn}" Margin="0,0,10,0"><TextBlock Text="Cancel"/></Button>
            <Button x:Name="UcBrowseBtn" Style="{StaticResource GhostBtn}" Margin="0,0,10,0"><TextBlock Text="See every model"/></Button>
            <Button x:Name="UcUseBtn" Style="{StaticResource PrimaryBtn}" FontSize="14" Padding="24,11"><TextBlock x:Name="UcUseText" Text="Use this model"/></Button>
          </WrapPanel>
        </StackPanel>
      </Border>
    </ScrollViewer>
  </Grid>
  </Grid>
</Window>
'@
}

function New-GuiWindow {
    param([string] $LogoPath = '', [string] $Version = '')
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    $window = [Windows.Markup.XamlReader]::Load([Xml.XmlReader]::Create((New-Object IO.StringReader (Get-GuiXaml))))
    $controls = @{}
    foreach ($name in 'Root', 'LogoImg', 'VersionText', 'StatusDot', 'HeroTitle', 'HeroDetail', 'PrimaryBtn', 'PrimaryIcon', 'PrimaryText', 'OffBtn',
                      'ModelName', 'ModelDetail', 'MemValue', 'MemBar', 'MemHint', 'GpuName', 'EngineDetail', 'GamingHint', 'IdleCheck', 'ShortcutCheck',
                      'HealthBtn', 'ModelsBtn', 'VsCodeBtn', 'MoreBtn', 'HelpBtn', 'BusyBanner', 'BusyText', 'NextStep',
                      'UseCaseOverlay', 'Uc_chat', 'Uc_coding', 'Uc_images', 'Uc_fast', 'Uc_quality', 'UcModelName', 'UcModelDetail',
                      'UcUseBtn', 'UcUseText', 'UcBrowseBtn', 'UcCancelBtn') {
        $controls[$name] = $window.FindName($name)
    }
    $controls.VersionText.Text = if ($Version) { "v$Version" } else { '' }
    if ($LogoPath -and (Test-Path -LiteralPath $LogoPath -PathType Leaf)) {
        try {
            $bitmap = New-Object Windows.Media.Imaging.BitmapImage
            $bitmap.BeginInit()
            $bitmap.UriSource = New-Object Uri ([IO.Path]::GetFullPath($LogoPath))
            $bitmap.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $bitmap.EndInit()
            $controls.LogoImg.Source = $bitmap
            $window.Icon = $bitmap
        } catch { }
    }
    return [pscustomobject]@{ Window = $window; Controls = $controls }
}

function Get-GuiState {
    param($Hardware, $UsedGiB)
    # Everything the window shows, gathered into one object so the display code is pure.
    # Reads the core state directly (ADR-003) - no more splitting the status line.
    $core = Get-CoreApplicationState
    $exe = Get-RuntimeExecutablePath
    $hasModel = ($null -ne $core.model)
    $mode = 'off'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf) -or -not $hasModel) { $mode = 'setup' }
    elseif ($core.server.state -eq 'running') { $mode = 'on' }
    elseif ($core.server.state -eq 'loading') { $mode = 'loading' }

    $runtime = $core.runtime
    $backend = if ($null -eq $runtime) { '' } elseif ([string]$runtime.backend -eq 'ROCmLatest') { 'llama.cpp ROCm' } else { [string]$runtime.backend }
    $total = 0.0; $gpu = ''
    if ($null -ne $Hardware) {
        $total = [double]$Hardware.MaxAmdVramGiB
        if (@($Hardware.Gpus).Count -gt 0) { $gpu = [string]@($Hardware.Gpus)[0].Name }
    }
    $needed = 0.0; $low = $false
    if ($hasModel -and $total -ge 4 -and $null -ne $UsedGiB) {
        $model = @(Get-ModelCatalog | Where-Object { $_.Id -ieq $core.model.id }) | Select-Object -First 1
        if ($null -ne $model) {
            $check = Get-VramPreflight -Model $model -Hardware $Hardware -Context ([int]$core.model.context_size) -UsedGiB ([double]$UsedGiB)
            $needed = $check.NeededGiB; $low = $check.Low
        }
    }
    return [pscustomobject]@{
        Mode = $mode
        ModelName = if ($hasModel) { [string]$core.model.name } else { '' }
        ContextTokens = if ($hasModel) { [int]$core.model.context_size } else { 0 }
        IdleMinutes = [int]$core.idle_minutes
        Shortcuts = ($core.desktop_shortcuts -eq 'yes')
        Backend = $backend
        GpuName = $gpu
        TotalGiB = $total
        UsedGiB = $UsedGiB
        NeededGiB = $needed
        Low = $low
        Scanning = ($null -eq $Hardware)
    }
}

function Set-GuiState {
    param($Controls, $State)
    $c = $Controls
    $green = '#72F1A6'; $yellow = '#FFD166'; $red = '#FF8A8A'; $grey = '#6F7FA6'; $orange = '#FF7A4D'
    $brush = { param($hex) New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($hex)) }

    $modelText = if ($State.ModelName) { $State.ModelName } else { 'Not chosen yet' }
    switch ($State.Mode) {
        'setup' {
            $c.HeroTitle.Text = "Let's set up your AI"
            $c.HeroDetail.Text = "One click checks your PC, downloads what is needed, and opens a private chat. You confirm before anything downloads."
            $c.StatusDot.Fill = & $brush $orange
            $c.PrimaryIcon.Text = [string][char]0xE896; $c.PrimaryText.Text = 'Set up and start'; $c.PrimaryBtn.IsEnabled = -not $State.Scanning
            $c.OffBtn.Visibility = 'Collapsed'
        }
        'off' {
            $c.HeroTitle.Text = 'Your AI is off'
            $c.HeroDetail.Text = "Your graphics card is free for games. Start the AI when you want to chat."
            $c.StatusDot.Fill = & $brush $grey
            $c.PrimaryIcon.Text = [string][char]0xE768; $c.PrimaryText.Text = 'Start AI and open chat'; $c.PrimaryBtn.IsEnabled = $true
            $c.OffBtn.Visibility = 'Collapsed'
        }
        'loading' {
            $c.HeroTitle.Text = 'Starting up...'
            $c.HeroDetail.Text = "Loading $modelText onto your graphics card. The first start can take a minute or two."
            $c.StatusDot.Fill = & $brush $yellow
            $c.PrimaryIcon.Text = [string][char]0xE768; $c.PrimaryText.Text = 'Starting...'; $c.PrimaryBtn.IsEnabled = $false
            $c.OffBtn.Visibility = 'Visible'
        }
        'on' {
            $c.HeroTitle.Text = 'Your AI is on'
            $c.HeroDetail.Text = "Running privately on your Radeon. Nothing you type leaves this PC."
            $c.StatusDot.Fill = & $brush $green
            $c.PrimaryIcon.Text = [string][char]0xE8BD; $c.PrimaryText.Text = 'Open chat'; $c.PrimaryBtn.IsEnabled = $true
            $c.OffBtn.Visibility = 'Visible'
        }
    }

    $c.ModelName.Text = $modelText
    $c.ModelDetail.Text = if ($State.ContextTokens -gt 0) { "Remembers about $([Math]::Round($State.ContextTokens / 1024))k tokens of conversation" } else { 'Easy start picks the best one for your PC.' }

    if ($State.Scanning -or $State.TotalGiB -le 0) {
        $c.MemValue.Text = 'Scanning your PC...'; $c.MemBar.Value = 0; $c.MemHint.Text = ''
    } elseif ($null -eq $State.UsedGiB) {
        $c.MemValue.Text = "$([Math]::Round($State.TotalGiB, 1)) GiB total"; $c.MemBar.Value = 0; $c.MemHint.Text = 'Reading usage...'
    } else {
        $ratio = [Math]::Min(1.0, [double]$State.UsedGiB / $State.TotalGiB)
        $c.MemValue.Text = "$([Math]::Round([double]$State.UsedGiB, 1)) of $([Math]::Round($State.TotalGiB, 1)) GiB"
        $c.MemBar.Value = [Math]::Round($ratio * 100)
        # While the AI is running, its own memory is part of the bar, so only a nearly full card is a warning.
        $hex = if ($State.Mode -eq 'on' -or $State.Mode -eq 'loading') { if ($ratio -ge 0.95) { $red } else { $green } }
               elseif ($ratio -ge 0.85) { $red } elseif ($ratio -ge 0.6) { $yellow } else { $green }
        $c.MemBar.Foreground = & $brush $hex
        if ($State.Mode -eq 'off' -and $State.Low) {
            $c.MemHint.Text = "Another app is using a lot of it. The AI wants about $($State.NeededGiB) GiB, so it may run slower."
            $c.MemHint.Foreground = & $brush $yellow
        } elseif ($State.Mode -eq 'off' -and $State.NeededGiB -gt 0) {
            $c.MemHint.Text = 'Plenty of room for your AI.'
            $c.MemHint.Foreground = & $brush $green
        } else {
            $c.MemHint.Text = if ($State.Mode -eq 'on') { 'Includes your AI. Turn it off to free this for a game.' } else { '' }
            $c.MemHint.Foreground = & $brush '#AAB8D6'
        }
    }

    $c.GpuName.Text = if ($State.GpuName) { $State.GpuName } elseif ($State.Scanning) { 'Scanning...' } else { 'Radeon graphics' }
    $c.EngineDetail.Text = if ($State.Backend) { "$($State.Backend) engine" } else { 'Engine installs during setup.' }

    $c.GamingHint.Text = if ($State.Mode -eq 'on') {
        'Playing a game? Use "Turn off" above, or let it unload by itself when idle.'
    } else {
        'Games and the AI both want graphics memory. These switches hand it back to games for you.'
    }
    $c.IdleCheck.IsChecked = ($State.IdleMinutes -gt 0)
    $c.ShortcutCheck.IsChecked = [bool]$State.Shortcuts

    $c.NextStep.Text = switch ($State.Mode) {
        'setup' { 'Next step: press the orange button. It asks for one YES before downloading anything.' }
        'off' { 'Next step: press the orange button to start chatting.' }
        'loading' { 'Almost there. The chat opens by itself when the AI is ready.' }
        'on' { 'All set. Press Open chat any time, or use the model from VS Code.' }
    }
}

function Set-GuiUseCaseSuggestion {
    param($Controls, $Suggestion, [bool] $Downloaded, [bool] $IsCurrent, [bool] $Scanning, [string] $Purpose)
    $c = $Controls
    if ($Scanning -or $null -eq $Suggestion) {
        $c.UcModelName.Text = 'Still scanning your PC...'
        $c.UcModelDetail.Text = 'This takes a few seconds, then the suggestion appears here.'
        $c.UcUseBtn.IsEnabled = $false
        return
    }
    $model = $Suggestion.Model
    $c.UcModelName.Text = [string]$model.Name
    $c.UcModelDetail.Text = if ($IsCurrent) {
        "This is the model you already use. $($Suggestion.Reason)"
    } elseif ($Downloaded) {
        "Already downloaded. $($Suggestion.Reason)"
    } else {
        "About $([Math]::Round([double]$model.ApproxGiB, 1)) GB to download. $($Suggestion.Reason)"
    }
    $c.UcUseText.Text = if ($Purpose -eq 'setup') { 'Continue' } else { 'Use this model' }
    $c.UcUseBtn.IsEnabled = -not ($IsCurrent -and $Purpose -ne 'setup')
}

function Write-GuiErrorLog {
    param([string] $Message)
    # Plain text next to the run logs so a user can send it along when asking for help.
    try {
        $directory = Join-Path $InstallRoot 'logs'
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        Add-Content -LiteralPath (Join-Path $directory 'gui-error.log') -Value ('{0}  {1}' -f (Get-Date -Format 's'), (Protect-LogText $Message)) -Encoding UTF8
    } catch { }
}

function Show-CommandCenterWindow {
    $scriptFile = $PSCommandPath
    $scriptDir = Split-Path -Parent $scriptFile
    $ui = New-GuiWindow -LogoPath (Join-Path $scriptDir 'logo.png') -Version $script:CommandCenterVersion
    $win = $ui.Window; $c = $ui.Controls
    $state = @{ Used = $null; Hardware = $null; Pending = $null; Gui = $null; UcPurpose = 'setup' }

    # Graphics memory is read on a worker thread: the Windows counter takes about 2 seconds.
    $sync = [hashtable]::Synchronized(@{ Used = $null; Stop = $false })
    $worker = [powershell]::Create()
    [void]$worker.AddScript({
        param($sync)
        while (-not $sync.Stop) {
            try {
                $adapters = @((Get-Counter -Counter '\GPU Adapter Memory(*)\Dedicated Usage' -ErrorAction Stop).CounterSamples | Sort-Object CookedValue -Descending)
                if ($adapters.Count -gt 0) { $sync.Used = [double]$adapters[0].CookedValue / 1GB }
            } catch { }
            Start-Sleep -Seconds 3
        }
    }).AddArgument($sync)
    [void]$worker.BeginInvoke()

    $refresh = {
        $state.Gui = Get-GuiState -Hardware $state.Hardware -UsedGiB $sync.Used
        Set-GuiState -Controls $c -State $state.Gui
        $busy = ($null -ne $state.Pending)
        $c.BusyBanner.Visibility = if ($busy) { 'Visible' } else { 'Collapsed' }
        $c.NextStep.Visibility = if ($busy) { 'Collapsed' } else { 'Visible' }
        if ($busy) { $c.PrimaryBtn.IsEnabled = $false }
        foreach ($name in 'OffBtn', 'HealthBtn', 'ModelsBtn', 'VsCodeBtn', 'MoreBtn', 'IdleCheck', 'ShortcutCheck') { $c[$name].IsEnabled = -not $busy }
    }

    # Steps that need typing (YES prompts, the model list) run in a normal console window;
    # this window waits, then carries on. The pause only appears if the step reported a problem.
    $runConsole = {
        param([string] $Arguments, [string] $Message, [scriptblock] $Then)
        $inner = "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$scriptFile`" $Arguments"
        $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', "title llama.cpp Command Center & $inner & if errorlevel 1 pause") -PassThru
        $c.BusyText.Text = $Message
        $state.Pending = @{ Proc = $proc; Then = $Then }
        & $refresh
    }

    $startChat = {
        $chat = Join-Path $InstallRoot 'Chat.cmd'
        if (-not (Test-Path -LiteralPath $chat -PathType Leaf)) {
            [void][Windows.MessageBox]::Show($win, 'Set up your AI first (the orange button).', 'Not ready yet', 'OK', 'Information')
            return
        }
        $g = $state.Gui
        if ($g.Mode -eq 'off' -and $g.Low) {
            $answer = [Windows.MessageBox]::Show($win, "Another app is using a lot of your graphics memory. The AI wants about $($g.NeededGiB) GiB, so it will run slower until you close it.`n`nStart it anyway?", 'Graphics memory is tight', 'YesNo', 'Warning')
            if ($answer -ne 'Yes') { return }
        }
        Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', "set LLAMACPP_NO_PAUSE=1&& `"$chat`"") -WindowStyle Hidden
        $c.NextStep.Text = 'Starting... the chat opens by itself when the AI is ready.'
    }

    # "What do you want to use it for?" is a panel over this window, not a second window.
    $selectedUseCase = {
        foreach ($name in 'chat', 'coding', 'images', 'fast', 'quality') { if ($c["Uc_$name"].IsChecked) { return $name } }
        return 'chat'
    }
    $updateSuggestion = {
        $useCase = & $selectedUseCase
        if ($null -eq $state.Hardware) {
            Set-GuiUseCaseSuggestion -Controls $c -Suggestion $null -Downloaded $false -IsCurrent $false -Scanning $true -Purpose $state.UcPurpose
            return
        }
        $suggestion = Get-ModelForUseCase -UseCase $useCase -Hardware $state.Hardware -Runtime (Get-PlannedRuntime -Hardware $state.Hardware)
        $model = $suggestion.Model
        $modelsDir = Join-Path $InstallRoot 'models'
        $have = (Test-Path -LiteralPath (Join-Path $modelsDir $model.File) -PathType Leaf) -and
            ([string]::IsNullOrWhiteSpace([string]$model.Projector) -or (Test-Path -LiteralPath (Join-Path $modelsDir (Get-ProjectorLocalName $model)) -PathType Leaf))
        $active = Get-ActiveModel
        $isCurrent = ($null -ne $active) -and ([string]$active.id -ieq [string]$model.Id)
        Set-GuiUseCaseSuggestion -Controls $c -Suggestion $suggestion -Downloaded $have -IsCurrent $isCurrent -Scanning $false -Purpose $state.UcPurpose
    }
    $openUseCases = {
        param([string] $Purpose)
        $state.UcPurpose = $Purpose
        $saved = Get-AppSettings
        $previous = if ($saved.ContainsKey('use_case')) { [string]$saved['use_case'] } else { 'chat' }
        if (-not $c.ContainsKey("Uc_$previous")) { $previous = 'chat' }
        $c["Uc_$previous"].IsChecked = $true
        & $updateSuggestion
        $c.UseCaseOverlay.Visibility = 'Visible'
    }
    foreach ($name in 'chat', 'coding', 'images', 'fast', 'quality') { $c["Uc_$name"].Add_Checked({ & $updateSuggestion }) }
    $c.UcCancelBtn.Add_Click({ $c.UseCaseOverlay.Visibility = 'Collapsed' })
    $win.Add_PreviewKeyDown({
        param($sender, $e)
        if ($e.Key -eq 'Escape' -and "$($c.UseCaseOverlay.Visibility)" -eq 'Visible') { $c.UseCaseOverlay.Visibility = 'Collapsed' }
    })
    $c.UcBrowseBtn.Add_Click({
        $c.UseCaseOverlay.Visibility = 'Collapsed'
        & $runConsole '-Action Models' 'Pick a model in the black window. This window continues when it closes.' {}
    })
    $c.UcUseBtn.Add_Click({
        $useCase = & $selectedUseCase
        $c.UseCaseOverlay.Visibility = 'Collapsed'
        if ($state.UcPurpose -eq 'setup') {
            & $runConsole "-Action Easy -UseCase $useCase" 'Finish the steps in the black window. This window continues by itself when it closes.' {
                if ($state.Gui.Mode -ne 'setup') { & $startChat }
            }
        } else {
            Set-AppSetting -Name 'use_case' -Value $useCase
            $suggestion = Get-ModelForUseCase -UseCase $useCase -Hardware $state.Hardware -Runtime (Get-PlannedRuntime -Hardware $state.Hardware)
            & $runConsole "-Action Models -ModelId $($suggestion.Model.Id)" 'Confirm the download in the black window. This window continues when it closes.' {}
        }
    })

    $c.PrimaryBtn.Add_Click({
        if ($state.Gui.Mode -eq 'setup') { & $openUseCases 'setup' } else { & $startChat }
    })
    $c.OffBtn.Add_Click({
        $answer = [Windows.MessageBox]::Show($win, "Turn the AI off? Anything using it right now, such as a chat in VS Code, will stop getting replies.", 'Turn the AI off', 'YesNo', 'Question')
        if ($answer -ne 'Yes') { return }
        $helper = Join-Path $InstallRoot 'Gaming-Mode.cmd'
        if (Test-Path -LiteralPath $helper -PathType Leaf) {
            Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', "set LLAMACPP_NO_PAUSE=1&& `"$helper`"") -WindowStyle Hidden
        } else {
            Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue | Stop-Process -Force
        }
    })
    $c.HealthBtn.Add_Click({ & $runConsole '-Action SelfTest' 'The health check is running in the black window.' {} })
    $c.ModelsBtn.Add_Click({ & $openUseCases 'switch' })
    $c.VsCodeBtn.Add_Click({ & $runConsole '-Action VSCodeChat' 'Connecting VS Code in the black window.' {} })
    $c.MoreBtn.Add_Click({
        Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', "set LLAMACPP_TEXT_MENU=1&& `"$(Join-Path $scriptDir 'Start-LlamaCpp.cmd')`"")
    })
    $c.HelpBtn.Add_Click({ Start-Process "https://github.com/$($script:CommandCenterRepo)#readme" })
    $c.IdleCheck.Add_Click({
        $win.Cursor = [Windows.Input.Cursors]::Wait
        try {
            $minutes = if ($c.IdleCheck.IsChecked) { 15 } else { 0 }
            if (-not (Set-IdleSleep -Minutes $minutes 6> $null)) { $c.IdleCheck.IsChecked = $false }
        } finally { $win.Cursor = $null }
        & $refresh
    })
    $c.ShortcutCheck.Add_Click({
        if ($c.ShortcutCheck.IsChecked) {
            if (@(New-DesktopShortcuts).Count -eq 0) {
                [void][Windows.MessageBox]::Show($win, 'Set up your AI first so the shortcuts have something to start.', 'Not ready yet', 'OK', 'Information')
                $c.ShortcutCheck.IsChecked = $false
            }
        } else { [void](Remove-DesktopShortcuts) }
        & $refresh
    })

    # A failing button must never take the window down. The error is logged and the window carries on.
    $win.Dispatcher.Add_UnhandledException({
        param($sender, $e)
        Write-GuiErrorLog -Message "$($e.Exception.GetType().Name): $($e.Exception.Message)"
        $e.Handled = $true
        $state.Pending = $null
        $c.NextStep.Text = 'Something went wrong with that button. You can keep using the window; details are in logs\gui-error.log.'
        $c.NextStep.Visibility = 'Visible'
        $c.BusyBanner.Visibility = 'Collapsed'
    })

    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds(2)
    # WPF stops a DispatcherTimer for good if its Tick throws, which would freeze the window on stale
    # information. So nothing may escape this handler: failures are logged and the next tick tries again.
    $timer.Add_Tick({
        try {
            if ($null -ne $state.Pending -and $state.Pending.Proc.HasExited) {
                $then = $state.Pending.Then
                $state.Pending = $null
                & $refresh
                if ($null -ne $then) { & $then }
            } else { & $refresh }
        } catch {
            Write-GuiErrorLog -Message "Refresh failed: $($_.Exception.Message)"
        }
    })
    $win.Add_Loaded({
        $win.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Background, [Action]{
            try {
                & $refresh
                $state.Hardware = Get-HardwareProfile
                & $refresh
            } catch {
                Write-GuiErrorLog -Message "Startup scan failed: $($_.Exception.Message)"
            } finally {
                $timer.Start()
            }
        }) | Out-Null
    })
    $win.Add_Closed({
        $timer.Stop()
        $sync.Stop = $true
        $worker.Dispose()
    })
    [void]$win.ShowDialog()
}

function Show-Dashboard {
    $updateCheck = Test-CommandCenterUpdate
    while ($true) {
        $hardware = Get-HardwareProfile
        $recommended = Get-RecommendedModel -Hardware $hardware
        $runtime = Get-InstalledRuntime
        $backendLabel = if ($null -ne $runtime) { "$(if ([string]$runtime.backend -eq 'ROCmLatest') { 'llama.cpp ROCm' } else { $runtime.backend }) $($runtime.tag)" } elseif ($Backend -eq 'Auto') { if ($hardware.RocmRecommended) { 'AMD ROCm 7.2.1' } else { 'Vulkan' } } else { $Backend }
        $assessment = @(Get-ModelAssessment -Hardware $hardware | Where-Object { $_.Model.Id -eq $recommended.Id } | Select-Object -First 1)
        $active = Get-ActiveModel
        $installed = Test-Path -LiteralPath (Get-RuntimeExecutablePath)
        $ramBar = Get-MemoryBar -Value $hardware.RamGiB -Maximum 96
        $vramBar = Get-MemoryBar -Value $hardware.MaxAmdVramGiB -Maximum 32
        $budgetBar = Get-MemoryBar -Value $hardware.ModelBudgetGiB -Maximum 32

        Clear-Screen
        Show-Banner
        Write-Host '  ┌─ SYSTEM PROFILE ──────────────────┬─ MEMORY / MODEL BUDGET ──────────────────┐' -ForegroundColor DarkCyan
        Write-Host '  │ CPU  ' -NoNewline -ForegroundColor DarkGray; Write-Host (Limit-Text $hardware.CpuName 29) -ForegroundColor White
        Write-Host '  │      ' -NoNewline -ForegroundColor DarkGray; Write-Host ("$($hardware.CpuCores)C/$($hardware.CpuThreads)T") -NoNewline -ForegroundColor Gray
        Write-Host '              │ RAM  ' -NoNewline -ForegroundColor DarkGray; Write-Host ("$ramBar $([Math]::Round($hardware.RamGiB,1)) GiB") -ForegroundColor Cyan
        Write-Host '  │ GPU  ' -NoNewline -ForegroundColor DarkGray; Write-Host (Limit-Text (($hardware.Gpus | Select-Object -First 1).Name) 29) -ForegroundColor White
        Write-Host '  │ MODE ' -NoNewline -ForegroundColor DarkGray; Write-Host (Limit-Text $hardware.ExecutionMode 29) -ForegroundColor Green
        Write-Host '  │ TIER ' -NoNewline -ForegroundColor DarkGray; Write-Host ('{0,-30}' -f $hardware.Profile) -NoNewline -ForegroundColor Yellow; Write-Host '               │ VRAM ' -NoNewline -ForegroundColor DarkGray; Write-Host ("$vramBar $([Math]::Round($hardware.MaxAmdVramGiB,1)) GiB") -ForegroundColor Magenta
        Write-Host '  │ BACKEND ' -NoNewline -ForegroundColor DarkGray; Write-Host ('{0,-30}' -f $backendLabel) -NoNewline -ForegroundColor Green; Write-Host '               │ FIT  ' -NoNewline -ForegroundColor DarkGray; Write-Host ("$budgetBar $([Math]::Round($hardware.ModelBudgetGiB,1)) GiB") -ForegroundColor DarkCyan
        Write-Host '  │ STATE ' -NoNewline -ForegroundColor DarkGray; Write-Host $(if ($installed) { 'llama.cpp installed' } else { 'llama.cpp not installed' }) -ForegroundColor $(if ($installed) { 'Green' } else { 'Yellow' })
        Write-Host '  └────────────────────────────────────┴─────────────────────────────────────────┘' -ForegroundColor DarkCyan

        Write-Host "`n  ✦ YOUR BEST MATCH" -ForegroundColor White
        Write-Host "    ◆ $($recommended.Name)  " -NoNewline -ForegroundColor Green
        Write-Host ('[{0}]' -f $assessment.Status) -ForegroundColor $assessment.Color
        Write-Host "      $($recommended.Description)" -ForegroundColor DarkGray
        Write-Host "      Download ~$([Math]::Round($recommended.ApproxGiB,2)) GiB • suggested context $(Get-SuggestedContext -Model $recommended -Hardware $hardware)" -ForegroundColor DarkGray
        if ($null -ne $active) { Write-Host "    ACTIVE: $($active.name) • context $($active.context_size) • port $Port" -ForegroundColor Cyan }

        Write-Host "`n  FIRST-TIME USER? [1] is the guided path: it explains each choice and asks before downloading." -ForegroundColor Yellow
        Write-Host '  Already installed? [3] starts the active model. GitHub Copilot can stay installed and enabled.' -ForegroundColor DarkGray

        if ((-not $hardware.VulkanLoader) -or (-not $hardware.HasAmdGpu)) {
            Write-WarnLine 'ACTION REQUIRED: update the AMD Adrenalin driver, reboot, then run diagnostics.'
        }
        if ($hardware.HasAmdIntegratedGpu -and $hardware.MaxAmdVramGiB -lt 2) {
            Write-Info 'APU detected: UMA memory is shared with system RAM; BIOS UMA size should normally stay Auto.'
        }
        if ($updateCheck.UpdateAvailable) {
            Write-Host "  [UPDATE] Command center $($updateCheck.Latest) is available (you have v$($updateCheck.Current)) — $($updateCheck.Url)" -ForegroundColor Yellow
        }

        Write-Host "`n  ═══════════════════════════════════ COMMAND MENU ═══════════════════════════════════" -ForegroundColor DarkCyan
        Write-Host '   [1]  ✨ First-time setup — install llama.cpp + recommended model (asks first)' -ForegroundColor White
        Write-Host '   [2]  ◈ Model browser — compare, download, and activate a model' -ForegroundColor White
        Write-Host '   [3]  ▶  Launch active model server + Web UI' -ForegroundColor White
        Write-Host '   [4]  ✦ Hardware & model advisor' -ForegroundColor White
        Write-Host '   [5]  ↑  Update llama.cpp — preserves every model' -ForegroundColor White
        Write-Host '   [6]  ⚙  Full diagnostics' -ForegroundColor White
        Write-Host '   [7]  ×  Uninstall command center' -ForegroundColor White
        Write-Host '   [8]  ⚡ Backend selector — ROCm / Vulkan / llama.cpp ROCm' -ForegroundColor White
        Write-Host '   [9]  📄 View latest run log' -ForegroundColor White
        Write-Host '   [10] 📡 Live monitor — health, speed, and context in real time' -ForegroundColor White
        Write-Host '   [11] 🗑  Remove a downloaded model — frees disk space (asks first)' -ForegroundColor White
        Write-Host '   [12] 📊  Benchmark — measure prompt and generation speed (server running)' -ForegroundColor White
        Write-Host '   [0]  Exit' -ForegroundColor DarkGray
        Write-Host '  ═══════════════════════════════════════════════════════════════════════════════════' -ForegroundColor DarkCyan

        $choice = Read-ConsoleLine -Prompt '  Select'
        Write-RunLogEvent -Event 'menu_choice' -Message "Dashboard selection: $choice"
        try {
            switch ($choice) {
                '1' {
                    if (Test-Path -LiteralPath (Get-RuntimeExecutablePath)) {
                        Write-Info 'llama.cpp is already installed, so setup goes straight to the model. Use [5] to update llama.cpp.'
                        $tag = 'installed'
                    } else {
                        $tag = Ensure-LlamaCppInstalled -Hardware $hardware -RequestedBackend $Backend
                    }
                    if ($null -eq $tag) {
                        Write-WarnLine 'Setup cancelled. Nothing was changed.'
                    } elseif (Confirm-ModelDownload -Model $recommended -Hardware $hardware) {
                        Install-Model -Model $recommended -Hardware $hardware
                        Write-Success "Ready: llama.cpp $tag + $($recommended.Name)"
                    } else { Write-WarnLine 'Model download cancelled; llama.cpp remains installed.' }
                    Pause-Screen
                }
                '2' {
                    $selected = Select-ModelInteractively -Hardware $hardware
                    if ($null -ne $selected) {
                        $ready = $true
                        if (-not (Test-Path -LiteralPath (Get-RuntimeExecutablePath))) {
                            $ready = $null -ne (Ensure-LlamaCppInstalled -Hardware $hardware -RequestedBackend $Backend)
                        }
                        if (-not $ready) {
                            Write-WarnLine 'llama.cpp is needed before a model can be activated. Nothing was changed.'
                        } elseif (Confirm-ModelDownload -Model $selected -Hardware $hardware) {
                            Install-Model -Model $selected -Hardware $hardware
                        } else { Write-WarnLine 'Download cancelled.' }
                    }
                    Pause-Screen
                }
                '3' { Start-ActiveServer -Hardware $hardware; Pause-Screen 'Press Enter after stopping the server' }
                '4' { Show-HardwareAdvisor -Hardware $hardware; Pause-Screen }
                '5' { [void](Ensure-LlamaCppInstalled -Hardware $hardware -RequestedBackend $Backend); Pause-Screen }
                '6' { Show-Diagnostics -Hardware $hardware; Pause-Screen }
                '7' {
                    $answer = Read-ConsoleLine -Prompt '  Type DELETE to remove llama.cpp and ALL downloaded models'
                    if ($answer -ceq 'DELETE') { Remove-Installation; Pause-Screen 'Press Enter to exit' ; break }
                    Write-WarnLine 'Uninstall cancelled.'; Pause-Screen
                }
                '8' { Select-BackendInteractively }
                '9' { Show-LatestRunLog; Pause-Screen }
                '10' { Show-LiveMonitor; Pause-Screen }
                '12' { [void](Invoke-ModelBenchmark); Pause-Screen }
                '11' {
                    $toRemove = Select-ModelToRemove
                    if ($null -ne $toRemove) { [void](Remove-DownloadedModel -Model $toRemove) }
                    Pause-Screen
                }
                '0' { return }
                default { Write-WarnLine 'Choose a menu number.'; Start-Sleep -Milliseconds 400 }
            }
        } catch {
            Write-Host "`n  ERROR: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host '  First try: choose [6] Full diagnostics. Do not delete files until you have read the diagnostic output.' -ForegroundColor Yellow
            Pause-Screen
        }
    }
}

function Write-Utf8StdoutLine {
    # JSON documents and printed paths are a machine contract for scripts and the window
    # (ADR-003/ADR-005). Writing them through the console encoder corrupted non-ASCII
    # bytes on the way out (measured: an install path's 'o-umlaut' became one byte and
    # a CJK character became '?'), so write to the standard output stream as UTF-8 bytes
    # and bypass the console code page entirely. UTF-8 without a BOM is the contract.
    param([string] $Line)
    $stream = [Console]::OpenStandardOutput()
    $writer = New-Object System.IO.StreamWriter($stream, (New-Object System.Text.UTF8Encoding($false)))
    try {
        $writer.WriteLine($Line)
        $writer.Flush()
    } finally {
        $writer.Dispose()
    }
}

function Get-SettingsDocument {
    # One typed document describing the user-changeable settings (ADR-003: read-only, one
    # document, additive evolution). The idle capability is a fact about the installed
    # llama.cpp, probed with --help, never assumed.
    $settings = Get-AppSettings
    $idleSaved = $null
    if ($settings.ContainsKey('idle_sleep_minutes')) { $idleSaved = $settings['idle_sleep_minutes'] }
    $useCaseSaved = $null
    if ($settings.ContainsKey('use_case')) { $useCaseSaved = $settings['use_case'] }
    $idleCapable = Test-LlamaServerSupports -Flag '--sleep-idle-seconds'
    $installed = @(Get-InstalledModelStates)
    # VRAM facts for the settings display: the active model's catalogue size and the
    # discrete Radeon's VRAM, both straight from the existing sources (catalog + sensor
    # scan). The display turns these into "how much VRAM stays free" wording; nothing is
    # estimated here beyond what Get-VramHeadroom already assumes in Recommend.
    $vramGiB = $null
    $activeGib = $null
    $footprintGib = $null
    try {
        $hardware = Get-HardwareProfile
        if ($hardware.HasAmdGpu -and $hardware.MaxAmdVramGiB -ge 4) { $vramGiB = [double]$hardware.MaxAmdVramGiB }
    } catch { $vramGiB = $null }
    $activeModel = Get-ActiveModel
    if ($null -ne $activeModel) {
        $catalogModel = @(Get-ModelCatalog | Where-Object { $_.Id -ieq [string]$activeModel.id } | Select-Object -First 1)
        if ($null -ne $catalogModel) { $activeGib = [double]$catalogModel.ApproxGiB }
        # What unloading actually frees: weights plus KV cache and compute buffers (an estimate),
        # not the weights alone.
        try {
            if ($null -ne $catalogModel -and $null -ne $vramGiB) {
                $estimate = Get-VramEstimate -Model $catalogModel -Hardware $hardware -Context ([int]$activeModel.context_size) -UsedGiB 0
                $footprintGib = [Math]::Round([double]$estimate.needed_gib - [double]$estimate.headroom_gib, 1)
            }
        } catch { $footprintGib = $null }
    }
    return [pscustomobject]@{
        schema_version = 1
        generated_at = (Get-Date).ToUniversalTime().ToString('o')
        command_center_version = [string]$script:CommandCenterVersion
        install_root = [string]$InstallRoot
        gpu_vram_gib = $vramGiB
        active_model_gib = $activeGib
        active_model_footprint_gib = $footprintGib
        idle_unload = [pscustomobject]@{
            minutes = $idleSaved
            capable = $idleCapable
            installed_models = $installed.Count
        }
        use_case = [pscustomobject]@{
            saved = $useCaseSaved
            allowed = @('chat', 'coding', 'images', 'fast', 'quality')
        }
        game_pause = [pscustomobject]@{
            gib = [int](Get-GamePauseGiB)
            capable = Test-LlamaServerSupports -Flag '--models-preset'
            min = 4
            max = 40
        }
        active_runtime = if ($null -ne (Get-InstalledRuntime)) { [pscustomobject]@{ backend = [string](Get-InstalledRuntime).backend; tag = [string](Get-InstalledRuntime).tag; path = [string](Get-InstalledRuntime).path } } else { $null }
        tune_presets = [pscustomobject]@{
            models = if ($settings.ContainsKey('tune_presets')) { $settings['tune_presets'] } else { [pscustomobject]@{} }
            selection = if ($settings.ContainsKey('tune_preset_selection')) { $settings['tune_preset_selection'] } else { [pscustomobject]@{} }
            note = 'Tune presets are opt-in. An empty selection leaves the launch arguments unchanged.'
        }
        model_backends = Get-ModelBackendMap
        moe_cpu_layers = $(if ($settings.ContainsKey('moe_cpu_layers') -and $null -ne $settings['moe_cpu_layers']) { $settings['moe_cpu_layers'] } else { [pscustomobject]@{} })
    }
}

function Set-SettingsFromDocument {
    # The write side of the Settings surface (ADR-003: additive, one document). Every write
    # goes through the existing single-source helpers, so generated launchers and the WPF
    # window can never disagree with what the desktop window saved. Returns one typed
    # result document; it never partially applies a rejected value. The patch text
    # comes in as $SettingsPatchText: a lowercase $patch local would be the SAME
    # variable (PowerShell is case-insensitive) and would wipe it before any parse.
    param([string] $SettingsPatchText)
    $result = [ordered]@{
        schema_version = 1
        generated_at = (Get-Date).ToUniversalTime().ToString('o')
        command_center_version = [string]$script:CommandCenterVersion
        applied = @()
        rejected = @()
        settings = $null
    }
    # PS naming: the incoming parameter is $SettingsPatchText; a lowercase $patch local
    # would be the SAME variable (PowerShell is case-insensitive) and would wipe the
    # parameter before any parse. Measured with a probe: `$patch = $null` empties $Patch.
    $parsed = $null
    try { $parsed = ConvertFrom-Json -InputObject ([string]$SettingsPatchText) } catch {
        $result['rejected'] += @([pscustomobject]@{ field = 'patch'; reason = 'The change was not valid JSON.' })
        $result['settings'] = Get-SettingsDocument
        return [pscustomobject]$result
    }
    if ($null -eq $parsed -or $parsed.PSObject.Properties.Name -notcontains 'idle_unload') {
        $result['rejected'] += @([pscustomobject]@{ field = 'idle_unload'; reason = 'The change did not say what to do with idle unload.' })
    } else {
        $idle = $parsed.idle_unload
        if ($idle.PSObject.Properties.Name -notcontains 'minutes' -or $null -eq $idle.minutes) {
            $result['rejected'] += @([pscustomobject]@{ field = 'idle_unload.minutes'; reason = 'No minutes value was sent.' })
        } else {
            $minutes = -1
            if (-not [int]::TryParse([string]$idle.minutes, [ref]$minutes) -or $minutes -lt 0 -or $minutes -gt 1440) {
                $result['rejected'] += @([pscustomobject]@{ field = 'idle_unload.minutes'; reason = 'Minutes must be a whole number from 0 to 1440.' })
            } else {
                if ([int]$minutes -eq (Get-IdleSleepSeconds / 60) -and (Get-AppSettings).ContainsKey('idle_sleep_minutes') -and [string]$minutes -eq [string](Get-AppSettings)['idle_sleep_minutes']) {
                    # Same value: report it without rewriting, so a save that changes nothing
                    # cannot fail because the installed llama.cpp is too old (Set-IdleSleep
                    # returns $false there).
                    $result['applied'] += @([pscustomobject]@{ field = 'idle_unload.minutes'; value = $minutes; note = 'already'; triple = $null })
                } elseif (Set-IdleSleep -Minutes ([int]$minutes)) {
                    $result['applied'] += @([pscustomobject]@{ field = 'idle_unload.minutes'; value = $minutes; note = 'set'; triple = $null })
                } else {
                    $result['rejected'] += @([pscustomobject]@{ field = 'idle_unload.minutes'; reason = 'The installed llama.cpp is too old to unload the model when idle.' })
                }
            }
        }
    }
    if ($null -eq $parsed -or $parsed.PSObject.Properties.Name -notcontains 'use_case') {
        $result['rejected'] += @([pscustomobject]@{ field = 'use_case'; reason = 'The change did not say which use case to save.' })
    } else {
        $useCase = [string]$parsed.use_case
        $allowed = @('chat', 'coding', 'images', 'fast', 'quality')
        if ($allowed -notcontains $useCase) {
            $result['rejected'] += @([pscustomobject]@{ field = 'use_case'; reason = "Unknown use case '$useCase'." })
        } elseif ((Get-AppSettings).ContainsKey('use_case') -and [string](Get-AppSettings)['use_case'] -ieq $useCase) {
            $result['applied'] += @([pscustomobject]@{ field = 'use_case'; value = $useCase; note = 'already'; triple = $null })
        } else {
            Set-AppSetting -Name 'use_case' -Value $useCase
            $result['applied'] += @([pscustomobject]@{ field = 'use_case'; value = $useCase; note = 'set'; triple = $null })
        }
    }
    # Optional: a patch without game_pause leaves it alone.
    if ($null -ne $parsed -and $parsed.PSObject.Properties.Name -contains 'game_pause') {
        $pauseGib = -1
        $pause = $parsed.game_pause
        if ($null -eq $pause -or $pause.PSObject.Properties.Name -notcontains 'gib' -or -not [int]::TryParse([string]$pause.gib, [ref]$pauseGib) -or ($pauseGib -ne 0 -and ($pauseGib -lt 4 -or $pauseGib -gt 40))) {
            $result['rejected'] += @([pscustomobject]@{ field = 'game_pause.gib'; reason = 'Game pause must be 0 (off) or a whole number from 4 to 40 GiB.' })
        } elseif ($pauseGib -eq (Get-GamePauseGiB)) {
            $result['applied'] += @([pscustomobject]@{ field = 'game_pause.gib'; value = $pauseGib; note = 'already'; triple = $null })
        } elseif (Set-GamePause -Gib $pauseGib) {
            $result['applied'] += @([pscustomobject]@{ field = 'game_pause.gib'; value = $pauseGib; note = 'set'; triple = $null })
        } else {
            $result['rejected'] += @([pscustomobject]@{ field = 'game_pause.gib'; reason = 'The installed llama.cpp is too old for game pause (it needs router mode). Update llama.cpp first.' })
        }
    }
    # Optional: per-model backend preferences. Auto clears the override; anything else
    # is a preference the start path may switch to, never a forced lock.
    if ($null -ne $parsed -and $parsed.PSObject.Properties.Name -contains 'model_backends') {
        $map = $parsed.model_backends
        if ($null -eq $map) {
            $result['rejected'] += @([pscustomobject]@{ field = 'model_backends'; reason = 'model_backends must be an object of model id to Auto, Vulkan or ROCm.' })
        } else {
            foreach ($property in $map.PSObject.Properties) {
                $modelId = [string]$property.Name
                $requested = [string]$property.Value
                $known = @(Get-ModelCatalog | Where-Object { $_.Id -eq $modelId }).Count -gt 0
                if (-not $known) {
                    $result['rejected'] += @([pscustomobject]@{ field = "model_backends.$modelId"; reason = 'Unknown model id.' })
                    continue
                }
                if (@('Auto', 'Vulkan', 'ROCm') -notcontains $requested) {
                    $result['rejected'] += @([pscustomobject]@{ field = "model_backends.$modelId"; reason = 'Backend must be Auto, Vulkan or ROCm.' })
                    continue
                }
                Set-ModelBackendOverride -ModelId $modelId -Backend $requested
                $result['applied'] += @([pscustomobject]@{ field = "model_backends.$modelId"; value = $requested; note = 'set'; triple = $null })
            }
        }
    }
    # Optional: MoE expert layers kept on the CPU, per MoE model. A whole number from 0 up,
    # or null/"auto" to clear it (llama.cpp's own fit decides again).
    if ($null -ne $parsed -and $parsed.PSObject.Properties.Name -contains 'moe_cpu_layers') {
        $moeMap = $parsed.moe_cpu_layers
        if ($null -eq $moeMap) {
            $result['rejected'] += @([pscustomobject]@{ field = 'moe_cpu_layers'; reason = 'moe_cpu_layers must be an object of model id to a layer count or auto.' })
        } else {
            foreach ($property in $moeMap.PSObject.Properties) {
                $modelId = [string]$property.Name
                $entry = @(Get-ModelCatalog | Where-Object { $_.Id -eq $modelId } | Select-Object -First 1)
                if ($entry.Count -eq 0 -or -not ($entry[0].PSObject.Properties.Name -contains 'Moe' -and [bool]$entry[0].Moe)) {
                    $result['rejected'] += @([pscustomobject]@{ field = "moe_cpu_layers.$modelId"; reason = 'Only a mixture-of-experts model in the catalogue has expert layers to offload.' })
                    continue
                }
                if ($null -eq $property.Value -or [string]$property.Value -eq 'auto') {
                    Set-MoeCpuLayers -ModelId $modelId -Layers $null
                    $result['applied'] += @([pscustomobject]@{ field = "moe_cpu_layers.$modelId"; value = 'auto'; note = 'set'; triple = $null })
                    continue
                }
                $layers = -1
                if (-not [int]::TryParse([string]$property.Value, [ref]$layers) -or $layers -lt 0 -or $layers -gt 512) {
                    $result['rejected'] += @([pscustomobject]@{ field = "moe_cpu_layers.$modelId"; reason = 'Expert layers on the CPU must be a whole number from 0 to 512, or auto.' })
                    continue
                }
                Set-MoeCpuLayers -ModelId $modelId -Layers $layers
                $result['applied'] += @([pscustomobject]@{ field = "moe_cpu_layers.$modelId"; value = $layers; note = 'set'; triple = $null })
            }
        }
    }
    # Optional: opt-in Tune preset selection. 'none' clears that model's selection; an
    # unknown model or preset is rejected without changing anything else in the patch.
    if ($null -ne $parsed -and $parsed.PSObject.Properties.Name -contains 'tune_preset_selection') {
        $selection = $parsed.tune_preset_selection
        if ($null -eq $selection) {
            $result['rejected'] += @([pscustomobject]@{ field = 'tune_preset_selection'; reason = 'tune_preset_selection must be an object of model id to preset name or none.' })
        } else {
            foreach ($property in $selection.PSObject.Properties) {
                $modelId = [string]$property.Name
                $presetName = [string]$property.Value
                try {
                    Set-TunePresetSelection -ModelId $modelId -Preset $presetName
                    $result['applied'] += @([pscustomobject]@{ field = "tune_preset_selection.$modelId"; value = $presetName; note = 'set'; triple = $null })
                } catch {
                    $result['rejected'] += @([pscustomobject]@{ field = "tune_preset_selection.$modelId"; reason = [string]$_.Exception.Message })
                }
            }
        }
    }
    $result['settings'] = Get-SettingsDocument
    return [pscustomobject]$result
}

function Get-ModelReceipts {
    # "Tested on this PC": the benchmark numbers Tune measured here, read straight from the
    # saved results (never edited, never invented). Smoke runs and rows that did not run
    # are ignored; per model and backend the newest completed run wins. Read-only, and a
    # missing or malformed file just contributes nothing.
    $byModel = @{}
    $caveat = ''
    $root = Get-TuneJobRoot
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return [pscustomobject]@{ models = $byModel; caveat = $caveat } }
    $jobs = @(Get-ChildItem -LiteralPath $root -Directory -Filter 'tune-*' -ErrorAction SilentlyContinue | Sort-Object Name)
    foreach ($job in $jobs) {
        $results = Read-TuneJson -Path (Join-Path $job.FullName 'results.json')
        if ($null -eq $results -or $results.PSObject.Properties.Name -notcontains 'stage1') { continue }
        if (($results.PSObject.Properties.Name -contains 'smoke') -and [bool]$results.smoke) { continue }
        if ($results.PSObject.Properties.Name -contains 'comparison_caveat') { $caveat = [string]$results.comparison_caveat }
        foreach ($entry in @($results.stage1)) {
            if ([string]$entry.status -ne 'ok' -or -not [bool]$entry.device_verified) { continue }
            $prompt = @()
            $decode = $null
            $layers = $null
            $unreliable = $false
            foreach ($row in @($entry.rows)) {
                if ($null -eq $layers -and ($row.PSObject.Properties.Name -contains 'n_gpu_layers')) { $layers = [int]$row.n_gpu_layers }
                if (($row.PSObject.Properties.Name -contains 'unreliable') -and [bool]$row.unreliable) { $unreliable = $true }
                $noisy = (($row.PSObject.Properties.Name -contains 'noisy') -and [bool]$row.noisy)
                $item = [pscustomobject]@{ tokens = [int]$row.n; tokens_per_second = [Math]::Round([double]$row.mean, 1); noisy = $noisy }
                if ([string]$row.kind -eq 'prompt') { $prompt += $item } elseif ([string]$row.kind -eq 'decode') { $decode = $item }
            }
            if ($prompt.Count -eq 0 -and $null -eq $decode) { continue }
            $modelId = [string]$entry.model_id
            if (-not $byModel.ContainsKey($modelId)) { $byModel[$modelId] = @{} }
            # Jobs are visited oldest first, so a later job replaces an earlier one.
            $byModel[$modelId][[string]$entry.backend] = [pscustomobject]@{
                backend = [string]$entry.backend
                runtime_tag = [string]$entry.runtime_tag
                job_id = [string]$job.Name
                measured_at = if ($results.PSObject.Properties.Name -contains 'generated_at') { [string]$results.generated_at } else { '' }
                gpu_layers = $layers
                prompt = @($prompt)
                decode = $decode
                unreliable = $unreliable
            }
        }
        # A MoE sweep contributes its fastest-generation point as that model's receipt, with
        # how many expert layers stayed on the CPU. Same rules: verified device, never invented.
        foreach ($sweep in @(Get-TuneValue -Object $results -Name 'moe_sweep' -Default @())) {
            $bestAt = [int](Get-TuneValue -Object $sweep -Name 'best_cpu_moe' -Default -1)
            $best = @($sweep.points | Where-Object { [int]$_.cpu_moe -eq $bestAt -and [string]$_.status -eq 'ok' -and [bool]$_.device_verified } | Select-Object -First 1)
            if ($best.Count -eq 0) { continue }
            $prompt = @(); $decode = $null; $unreliable = $false
            foreach ($row in @($best[0].rows)) {
                if (($row.PSObject.Properties.Name -contains 'unreliable') -and [bool]$row.unreliable) { $unreliable = $true }
                $item = [pscustomobject]@{ tokens = [int]$row.n; tokens_per_second = [Math]::Round([double]$row.mean, 1); noisy = (($row.PSObject.Properties.Name -contains 'noisy') -and [bool]$row.noisy) }
                if ([string]$row.kind -eq 'prompt') { $prompt += $item } elseif ([string]$row.kind -eq 'decode') { $decode = $item }
            }
            if ($prompt.Count -eq 0 -and $null -eq $decode) { continue }
            $modelId = [string]$sweep.model_id
            if (-not $byModel.ContainsKey($modelId)) { $byModel[$modelId] = @{} }
            $byModel[$modelId][[string]$sweep.backend] = [pscustomobject]@{
                backend = [string]$sweep.backend
                runtime_tag = [string]$sweep.runtime_tag
                job_id = [string]$job.Name
                measured_at = if ($results.PSObject.Properties.Name -contains 'generated_at') { [string]$results.generated_at } else { '' }
                gpu_layers = $null
                cpu_moe_layers = $bestAt
                prompt = @($prompt)
                decode = $decode
                unreliable = $unreliable
            }
        }
    }
    return [pscustomobject]@{ models = $byModel; caveat = $caveat }
}

function Get-LibraryDocument {
    # One typed document describing every catalog model and its local state (ADR-003:
    # read-only, additive). Model facts come from the catalogue; local facts (downloaded,
    # active, fit, blockers) are computed, never guessed. Hardware may fail: it degrades
    # to null + error like -Action State.
    $active = Get-ActiveModel
    $activeId = if ($null -ne $active) { [string]$active.id } else { '' }
    $runtime = Get-InstalledRuntime
    $hardware = $null
    $hardwareError = $null
    try { $hardware = Get-HardwareProfile } catch { $hardwareError = [string]$_.Exception.Message }
    $installed = @(Get-InstalledModels | ForEach-Object { [string]$_.Id })
    $receipts = Get-ModelReceipts
    $models = @()
    $diskBusy = $false
    foreach ($model in @(Get-ModelCatalog | Sort-Object Rank -Descending)) {
        $downloaded = $installed -contains [string]$model.Id
        $blocker = [string](Get-ModelRuntimeBlocker -Model $model -Runtime $runtime)
        $assessment = $null
        if ($null -ne $hardware) {
            $assessment = @(Get-ModelAssessment -Hardware $hardware | Where-Object { $_.Model.Id -eq $model.Id } | Select-Object -First 1)
        }
        $preference = Get-ModelBackendPreference -Model $model -Hardware $hardware
        $models += [pscustomobject]@{
            id = [string]$model.Id
            name = [string]$model.Name
            alias = [string]$model.Alias
            approx_gib = [double]$model.ApproxGiB
            tools = [bool]$model.Tools
            vision = [bool]$model.Vision
            experimental = if ($model.PSObject.Properties.Name -contains 'Experimental') { [bool]$model.Experimental } else { $false }
            downloaded = $downloaded
            active = ([string]$model.Id -eq $activeId)
            runtime_blocker = $blocker
            fit_status = if ($null -ne $assessment) { [string]$assessment[0].Status } else { '' }
            gpu_resident = ($null -ne $assessment -and [bool]$assessment[0].GpuResident)
            preferred_backend = [string]$preference.backend
            backend_source = [string]$preference.source
            backend_reason = [string]$preference.reason
            backend_override = Get-ModelBackendOverride -ModelId ([string]$model.Id)
            receipts = @(if ($receipts.models.ContainsKey([string]$model.Id)) { @($receipts.models[[string]$model.Id].Values | Sort-Object backend) } else { @() })
        }
    }
    return [pscustomobject]@{
        schema_version = 1
        generated_at = (Get-Date).ToUniversalTime().ToString('o')
        command_center_version = [string]$script:CommandCenterVersion
        install_root = [string]$InstallRoot
        active_model_id = $activeId
        active_backend = if ($null -ne $runtime) { [string]$runtime.backend } else { '' }
        models = $models
        unlocked_models = Get-RuntimeUpdateUnlock -Runtime $runtime
        receipts_caveat = [string]$receipts.caveat
        hardware_error = $hardwareError
    }
}

function Invoke-LibraryAction {
    # The write side of the model library for the desktop window: download, activate or
    # remove one catalog model, then answer with one typed result document. Every change
    # goes through the existing single-source actions (Install-Model /
    # Switch-InstalledModel / Remove-DownloadedModel) so the launcher, editor
    # integrations and the WPF window can never disagree with what the desktop did.
    # Downloads are long: the caller (desktop supervisor) runs them in a detached console
    # window and polls State; this read-validate-wait path is for activate and remove.
    param([string] $LibraryAction, [string] $ModelIdRequested)
    $result = [ordered]@{
        schema_version = 1
        generated_at = (Get-Date).ToUniversalTime().ToString('o')
        command_center_version = [string]$script:CommandCenterVersion
        action = [string]$LibraryAction
        model_id = [string]$ModelIdRequested
        status = ''
        detail = ''
        library = $null
    }
    try {
        if ($LibraryAction -eq 'activate') {
            if ([string]::IsNullOrWhiteSpace($ModelIdRequested) -or $ModelIdRequested -ieq 'auto') { throw 'Choose a model with -ModelId, for example -ModelId qwen3.5-9b.' }
            $model = Get-ModelById -Id $ModelIdRequested
            $hardware = Get-HardwareProfile
            Switch-InstalledModel -Model $model -Hardware $hardware
            $result['status'] = 'activated'
            $result['detail'] = "$($model.Name) is now the active model."
        } elseif ($LibraryAction -eq 'remove') {
            if ([string]::IsNullOrWhiteSpace($ModelIdRequested) -or $ModelIdRequested -ieq 'auto') { throw 'Choose a model with -ModelId.' }
            $model = Get-ModelById -Id $ModelIdRequested
            # Desktop-initiated removes are explicit: the window already asked. -Force is
            # set here (not by the caller) and skips only this interactive prompt; the
            # active-model and shared-projector refusals in the helper still apply.
            $previousForce = $Force
            try { $script:Force = $true; $removed = Remove-DownloadedModel -Model $model } finally { $script:Force = $previousForce }
            if ($removed) {
                $result['status'] = 'removed'
                $result['detail'] = "$($model.Name) was deleted from disk."
            } else {
                $result['status'] = 'cancelled'
                $result['detail'] = 'Nothing was deleted.'
            }
        } elseif ($LibraryAction -eq 'download') {
            # Validate everything now, then hand off: the actual download runs in a
            # console window the caller opens, so this process can answer immediately.
            if ([string]::IsNullOrWhiteSpace($ModelIdRequested) -or $ModelIdRequested -ieq 'auto') { throw 'Choose a model with -ModelId.' }
            $model = Get-ModelById -Id $ModelIdRequested
            $blocker = Get-ModelRuntimeBlocker -Model $model -Runtime (Get-InstalledRuntime)
            if ($blocker) { throw $blocker }
            $hardware = Get-HardwareProfile
            Assert-ModelDiskSpace -RequiredGiB ([double]$model.ApproxGiB)
            $downloaded = @(Get-InstalledModels | Where-Object { $_.Id -ieq $model.Id }).Count -gt 0
            if ($downloaded) { throw "$($model.Name) is already downloaded." }
            $result['status'] = 'validated'
            $result['detail'] = "$($model.Name) passed preflight. The download runs in its own window; this document answers now."
        } else {
            throw "Unknown library action '$LibraryAction'. Valid: download, activate, remove."
        }
    } catch {
        $result['status'] = 'failed'
        $result['detail'] = [string]$_.Exception.Message
    }
    $result['library'] = Get-LibraryDocument
    return [pscustomobject]$result
}

# ---------------------------------------------------------------------
# Tune: measured llama-bench runs, opt-in presets, and local receipts
# ---------------------------------------------------------------------
# All measurements are local evidence. No number is invented: a failed or skipped
# row carries its reason, and a preset is only data until the user selects it.

function Get-TuneValue {
    param($Object, [string] $Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $names = @()
    if ($null -ne $Object.PSObject.Properties) { foreach ($property in $Object.PSObject.Properties) { $names += [string]$property.Name } }
    if ($names -contains $Name) { return $Object.$Name }
    return $Default
}

function Get-TuneJobRoot { return (Join-Path $InstallRoot 'benchmarks') }
function Get-TuneJobDirectory {
    param([string] $JobId)
    if ([string]::IsNullOrWhiteSpace($JobId)) { return $null }
    if ($JobId -notmatch '^tune-[0-9]{8}-[0-9]{6}$') { throw "Invalid Tune job id '$JobId'." }
    return (Join-Path (Get-TuneJobRoot) $JobId)
}
function Get-TuneJobFile { param([string] $JobId, [string] $Name); return (Join-Path (Get-TuneJobDirectory -JobId $JobId) $Name) }
function Read-TuneJson {
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json) } catch { return $null }
}
function Write-TuneJson {
    param([string] $Path, $Document)
    $dir = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $json = ConvertTo-Json -InputObject $Document -Depth 14
    [IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}
function Read-TuneCheckpoint {
    param([string] $JobId)
    $path = Join-Path (Get-TuneJobDirectory -JobId $JobId) 'checkpoint.json'
    $doc = Read-TuneJson -Path $path
    if ($null -eq $doc) { return $null }
    return $doc
}

function Write-TuneCheckpoint {
    param([string] $JobId, $Checkpoint)
    if ($null -eq $Checkpoint) { return }
    $Checkpoint | Add-Member -NotePropertyName updated_at -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
    Write-TuneJson -Path (Join-Path (Get-TuneJobDirectory -JobId $JobId) 'checkpoint.json') -Document $Checkpoint
}

function Get-TuneCompletedCount {
    param($Checkpoint)
    if ($null -eq $Checkpoint) { return 0 }
    # A skipped_fit row is a recorded decision, not a completed benchmark; counting it
    # made a 24-run plan report 26/24 when the 27B rows were skipped.
    $count = @($Checkpoint.stage1 | Where-Object { [string]$_.status -ne 'skipped_fit' }).Count + @($Checkpoint.stage2).Count + @(Get-TuneValue -Object $Checkpoint -Name 'moe' -Default @()).Count
    if ($null -ne $Checkpoint.reference_before) { $count++ }
    if ($null -ne $Checkpoint.reference_before_stage2) { $count++ }
    return [int]$count
}

function Get-TuneLatestJobId {
    $root = Get-TuneJobRoot
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return '' }
    $dir = @(Get-ChildItem -LiteralPath $root -Directory -Filter 'tune-*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1)
    if ($dir.Count -eq 0) { return '' }
    return [string]$dir[0].Name
}
function Get-TuneComparisonCaveat {
    param($Runtimes = $null)
    $list = if ($null -ne $Runtimes) { @($Runtimes) } else { @(Get-TuneRuntimeCandidates) }
    $latest = @($list | Where-Object { [string]$_.backend -eq 'ROCmLatest' } | Select-Object -First 1)
    $vulkan = @($list | Where-Object { [string]$_.backend -eq 'Vulkan' } | Select-Object -First 1)
    $amd = @($list | Where-Object { [string]$_.backend -eq 'ROCm' } | Select-Object -First 1)
    if ($latest.Count -gt 0) {
        $vTag = if ($vulkan.Count -gt 0) { [string]$vulkan[0].tag } else { 'unknown' }
        $sameBuild = ([string]$latest[0].tag -eq $vTag)
        $buildText = if ($sameBuild) { "the same upstream build ($($latest[0].tag))" } else { "upstream $($latest[0].tag); Vulkan is $vTag" }
        $amdText = if ($amd.Count -gt 0) { " The AMD ROCm 7.2.1 package is older (upstream $($amd[0].tag), March)." } else { '' }
        return "ROCm is the ggml-org ROCm 10 build $($latest[0].tag), $buildText.${amdText} Results apply only to these builds on this machine; this is not a general backend ranking."
    }
    return 'ROCm is AMD ROCm 7.2.1 / upstream b8407 (2026-03-18); Vulkan is upstream b12110 (2026-11-04). A backend difference also mixes llama.cpp versions. Results apply only to these builds on this machine, not as a general backend ranking.'
}

function Get-TuneRuntimeCandidates {
    # One newest build per backend channel. The older b12109 is deliberately excluded
    # because it is a rollback copy, not a comparison runtime. A side-by-side
    # ggml-org ROCm 10 build has its own backend label (ROCmLatest).
    $installs = @(Get-RuntimeInstallations | Where-Object { [string]$_.relative_path -ne 'current' -and [bool]$_.exe_present })
    $groups = @{}
    foreach ($item in $installs) {
        $key = [string]$item.backend
        if (-not $groups.ContainsKey($key)) { $groups[$key] = @() }
        $groups[$key] += $item
    }
    $result = @()
    foreach ($backend in @('Vulkan', 'ROCm', 'ROCmLatest')) {
        if (-not $groups.ContainsKey($backend)) { continue }
        $candidates = @($groups[$backend] | Sort-Object -Property @{ Expression = { $stamp = [string](Get-TuneValue -Object $_.installation -Name 'installed_at' -Default ''); try { [datetime]$stamp } catch { [datetime]::MinValue } } } -Descending)
        $item = $candidates[0]
        $path = [string]$item.path
        $device = ''
        $pinnable = $false
        $devices = @()
        try {
            # Ask the benchmark executable itself, not only the server, so the value passed
            # to -dev is one llama-bench accepts. Get-LlamaDeviceList returns its array
            # through the unary-comma idiom; wrapping it in @() would make the array itself
            # one 'device', which silently looks like an iGPU-only machine.
            $devices = Get-LlamaDeviceList -Directory $path -Executable 'llama-bench.exe'
            $selection = Get-GpuDeviceSelection -Devices $devices
            $device = [string]$selection.device
            $pinnable = ([string]$selection.status -eq 'pinned')
        } catch { }
        $bench = Join-Path $path 'llama-bench.exe'
        $label = if ($backend -eq 'Vulkan') { "Vulkan $($item.tag)" } elseif ($backend -eq 'ROCmLatest') { "ggml-org ROCm 10 / $($item.tag)" } else { "AMD ROCm 7.2.1 / $($item.tag)" }
        $result += [pscustomobject]@{
            backend = $backend
            tag = [string]$item.tag
            path = $path
            label = $label
            device = $device
            device_arg = $(if ([string]::IsNullOrWhiteSpace($device)) { '' } else { "-dev $device" })
            devices_source = 'llama-bench --list-devices'
            pinnable = $pinnable
            devices = @($devices)
            bench_exe = $bench
            bench_present = (Test-Path -LiteralPath $bench -PathType Leaf)
            flash_arg = if ($backend -eq 'Vulkan') { 'on' } else { '1' }
            upstream = if ($backend -eq 'ROCm') { [string](Get-TuneValue -Object $item.installation -Name 'sha256' -Default '') } else { [string]$item.tag }
        }
    }
    return @($result)
}

function Get-TuneBenchSupport {
    param([string] $ExePath)
    if (-not (Test-Path -LiteralPath $ExePath -PathType Leaf)) { return [pscustomobject]@{ available = $false; missing = @('llama-bench.exe'); text = '' } }
    $text = ''
    $previous = $ErrorActionPreference
    try {
        # Native help writes its banner to stderr. With ErrorActionPreference=Stop that
        # becomes a terminating NativeCommandError and would look like every flag is
        # missing, so keep the probe non-terminating while it reads both streams.
        $ErrorActionPreference = 'Continue'
        $text = (@(& $ExePath --help 2>&1 | ForEach-Object { [string]$_ }) -join "`n")
    } catch { $text = '' } finally { $ErrorActionPreference = $previous }
    $missing = @()
    foreach ($flag in @('-dev', '-ngl', '-fa', '-ctk', '-ctv', '-b', '-ub', '-p', '-n', '-r', '-o')) {
        if (-not $text.Contains($flag)) { $missing += $flag }
    }
    # -ncmoe is optional: only the MoE sweep needs it, so an older build without it must not block Tune.
    return [pscustomobject]@{ available = ($text.Length -gt 0 -and $missing.Count -eq 0); missing = @($missing); text = $text; moe_offload = $text.Contains('-ncmoe') }
}

function Get-TuneMoeSweepPoints {
    # Expert layers kept on the CPU, as fractions of the model's layer count (all, then fewer
    # and fewer). Measured on this PC: generation peaks part-way down and falls off a cliff
    # once the card pages, so the sweep has to look at several points, not guess one.
    param([int] $BlockCount)
    if ($BlockCount -le 0) { return @() }
    $points = @(foreach ($fraction in @(1.0, 0.8, 0.65, 0.55, 0.45, 0.35, 0.25)) { [int][Math]::Round($BlockCount * $fraction) })
    return @($points | Select-Object -Unique)
}

function Get-TuneMoeCandidates {
    # Installed catalogue models flagged Moe that this PC can sweep: a Vulkan llama-bench
    # that knows -ncmoe, a runtime that can load the model, and a weight file that fits in
    # VRAM plus system RAM. These models never go through Stage 1/2 (their weights exceed
    # VRAM, so that fit check would only skip them).
    param($Hardware, $Runtimes)
    $runtime = $null
    foreach ($candidate in @($Runtimes | Where-Object { [string]$_.backend -eq 'Vulkan' -and [bool]$_.bench_present })) {
        if ((Get-TuneBenchSupport -ExePath ([string]$candidate.bench_exe)).moe_offload) { $runtime = $candidate; break }
    }
    if ($null -eq $runtime) { return @() }
    $result = @()
    foreach ($model in @(Get-InstalledModels | Where-Object { ($_.PSObject.Properties.Name -contains 'Moe') -and [bool]$_.Moe })) {
        if (Get-ModelRuntimeBlocker -Model $model -Runtime $runtime) { continue }
        try {
            $path = Join-Path (Join-Path $InstallRoot 'models') ([string]$model.File)
            $meta = Read-GgufMetadata -Path $path
            $arch = if ($meta.ContainsKey('general.architecture')) { [string]$meta['general.architecture'] } else { '' }
            $blocks = [int](Get-GgufNumber -Metadata $meta -Key "$arch.block_count" -Default 0)
            $weights = [double](Get-Item -LiteralPath $path).Length / 1GB
            if ($weights -gt ([double]$Hardware.MaxAmdVramGiB + [double]$Hardware.RamGiB * 0.6)) { continue }
            $points = @(Get-TuneMoeSweepPoints -BlockCount $blocks)
            if ($points.Count -eq 0) { continue }
            $result += [pscustomobject]@{ id = [string]$model.Id; name = [string]$model.Name; file = [string]$model.File; installed = $true; block_count = $blocks; points = $points; runtime_tag = [string]$runtime.tag; runtime = $runtime }
        } catch { }
    }
    return @($result)
}

function Get-TuneMoeBest {
    # Fastest generation among sweep points that ran cleanly; $null when none did. Prompt
    # speed is reported next to it, never traded away silently.
    param($Entries)
    $good = @($Entries | Where-Object { [string]$_.status -eq 'ok' -and -not [bool]$_.unreliable -and $null -ne (Get-TuneRowMetric -Rows @($_.rows) -Kind 'decode') })
    if ($good.Count -eq 0) { return $null }
    return @($good | Sort-Object -Property @{ Expression = { [double](Get-TuneRowMetric -Rows @($_.rows) -Kind 'decode').mean } } -Descending)[0]
}

function Get-TuneFit {
    param($Model, $Hardware)
    # A llama-bench row allocates for the tested prompt plus the generated tokens, not
    # for the server's multi-slot context. 8192 + 128 = 8320 at one slot is the basis;
    # the projector is not loaded by llama-bench, so it is excluded as well.
    try {
        $estimate = Get-VramEstimate -Model $Model -Hardware $Hardware -Context 8320 -UsedGiB 0 -Slots 1 -BenchmarkOnly
        return [pscustomobject]@{ verdict = [string]$estimate.verdict; needed_gib = [double]$estimate.needed_gib; total_gib = [double]$estimate.total_gib; confidence = [string]$estimate.confidence; context_tokens = [int]$estimate.context_tokens; slots = [int]$estimate.slots; weights_gib = [double]$estimate.weights_gib; kv_gib = [double]$estimate.kv_gib; compute_gib = [double]$estimate.compute_gib; headroom_gib = [double]$estimate.headroom_gib; benchmark_only = [bool]$estimate.benchmark_only; skip = ([string]$estimate.verdict -eq 'will_not_fit') }
    } catch {
        return [pscustomobject]@{ verdict = 'unknown'; needed_gib = 0; total_gib = 0; confidence = 'none'; context_tokens = 8320; slots = 1; weights_gib = 0; kv_gib = 0; compute_gib = 0; headroom_gib = 0; benchmark_only = $true; skip = $false; error = [string]$_.Exception.Message }
    }
}

function Get-TuneModelCandidates {
    param($Hardware)
    $installed = @(Get-InstalledModels | ForEach-Object { [string]$_.Id })
    $result = @()
    foreach ($id in @('qwen3-4b', 'qwen3.5-9b', 'qwen3.8-27b')) {
        try {
            $model = Get-ModelById -Id $id
            $fit = Get-TuneFit -Model $model -Hardware $Hardware
            $result += [pscustomobject]@{ id = [string]$model.Id; name = [string]$model.Name; file = [string]$model.File; installed = ($installed -contains [string]$model.Id); fit = $fit }
        } catch { }
    }
    return @($result)
}

function Get-TunePreconditions {
    $hardware = Get-HardwareProfile
    $server = Get-ServerState
    $blockers = @()
    if (@($server.process_ids).Count -gt 0) {
        $blockers += [pscustomobject]@{ code = 'server_running'; detail = 'A llama-server process is running. Tune will not stop it silently.'; remediation = 'Stop it explicitly with -Action Runtime -RuntimeAction stop, then run Tune again.' }
    }
    $gpu = Get-GpuPinningReport
    if ([string]$gpu.status -ne 'pinned') {
        $blockers += [pscustomobject]@{ code = 'gpu_not_pinned'; detail = [string]$gpu.reason; remediation = 'Connect a discrete Radeon and run Diagnose; a benchmark on the iGPU is not allowed.' }
    }
    $runtimes = @(Get-TuneRuntimeCandidates)
    if ($runtimes.Count -eq 0) {
        $blockers += [pscustomobject]@{ code = 'runtime_missing'; detail = 'No installed llama.cpp runtime with llama-server.exe was found.'; remediation = 'Install a runtime first.' }
    }
    foreach ($runtime in $runtimes) {
        if (-not $runtime.bench_present) {
            $blockers += [pscustomobject]@{ code = 'bench_missing'; detail = "llama-bench.exe is missing from $($runtime.path)."; remediation = 'Reinstall that runtime or choose another build.' }
            continue
        }
        if (-not $runtime.pinnable) {
            $blockers += [pscustomobject]@{ code = 'runtime_not_pinned'; detail = "$($runtime.label) did not identify a discrete device."; remediation = 'Check the runtime device list before benchmarking.' }
        }
        $support = Get-TuneBenchSupport -ExePath $runtime.bench_exe
        if (-not $support.available) {
            $blockers += [pscustomobject]@{ code = 'bench_flags'; detail = "$($runtime.label) is missing llama-bench options: $($support.missing -join ', ')."; remediation = 'Use a build whose llama-bench exposes the required options.' }
        }
    }
    $gameThreshold = [double](Get-GamePauseGiB)
    $game = [pscustomobject]@{ threshold_gib = $gameThreshold; used_gib = $null; active = $false; state = 'off' }
    if ($gameThreshold -gt 0) {
        $usage = Get-GpuMemoryUsage -TotalGiB ([double]$hardware.MaxAmdVramGiB)
        if ($null -ne $usage) {
            $game.used_gib = [double]$usage.UsedGiB
            $game.active = ([double]$usage.UsedGiB -ge $gameThreshold)
            $game.state = if ($game.active) { 'flagged' } else { 'clear' }
            if ($game.active) {
                $blockers += [pscustomobject]@{ code = 'game_active'; detail = "Another program holds $($usage.UsedGiB) GiB of graphics memory (game-pause threshold $gameThreshold GiB)."; remediation = 'Close the game or fullscreen app, then run Tune again.' }
            }
        } else { $game.state = 'unknown' }
    }
    $models = @(Get-TuneModelCandidates -Hardware $hardware)
    $moe = @(Get-TuneMoeCandidates -Hardware $hardware -Runtimes @($runtimes))
    return [pscustomobject]@{ hardware = $hardware; server = $server; gpu = $gpu; game = $game; runtimes = @($runtimes); models = @($models); moe_models = @($moe); blockers = @($blockers) }
}

function Get-TuneBatchCombinations {
    param([int[]] $BatchSizes = @(512, 1024, 2048), [int[]] $UbatchSizes = @(128, 256, 512))
    $rows = @()
    foreach ($batch in $BatchSizes) {
        foreach ($ubatch in $UbatchSizes) {
            if ($ubatch -le $batch) { $rows += [pscustomobject]@{ batch_size = [int]$batch; ubatch_size = [int]$ubatch } }
        }
    }
    return @($rows)
}

function Get-TuneAlternatingOrder {
    param($Runtimes, [int] $Index)
    $list = @($Runtimes)
    if ($list.Count -le 1) { return @($list) }
    $start = [Math]::Abs($Index) % $list.Count
    $out = @()
    for ($i = 0; $i -lt $list.Count; $i++) { $out += $list[($start + $i) % $list.Count] }
    return @($out)
}

function Get-TunePlanDocument {
    $pre = Get-TunePreconditions
    $stage1 = @()
    $stage2 = @()
    $modelIndex = 0
    foreach ($model in @($pre.models)) {
        $order = @(Get-TuneAlternatingOrder -Runtimes @($pre.runtimes) -Index $modelIndex)
        foreach ($runtime in $order) {
            $status = 'planned'
            $reason = ''
            if (-not $model.installed) { $status = 'model_missing'; $reason = 'The model file is not installed.' }
            elseif ($model.fit.skip) { $status = 'skipped_fit'; $reason = "Fit estimate says $($model.fit.verdict) at the benchmark context (8320 tokens, one slot: $($model.fit.needed_gib) GiB needed)." }
            $stage1 += [pscustomobject]@{ model_id = $model.id; model = $model.name; runtime = $runtime.label; runtime_tag = $runtime.tag; backend = $runtime.backend; device = $runtime.device; device_arg = [string]$runtime.device_arg; status = $status; reason = $reason; fit = $model.fit }
        }
        if ($model.installed -and -not $model.fit.skip) {
            foreach ($combo in @(Get-TuneBatchCombinations)) {
                $stage2 += [pscustomobject]@{ model_id = $model.id; model = $model.name; runtime = ''; batch_size = $combo.batch_size; ubatch_size = $combo.ubatch_size; status = 'planned' }
            }
        }
        $modelIndex++
    }
    $status = if (@($pre.blockers).Count -eq 0) { 'ready' } else { 'blocked' }
    return [pscustomobject]@{
        schema_version = 1
        action = 'tune'
        tune_action = 'plan'
        generated_at = (Get-Date).ToUniversalTime().ToString('o')
        status = $status
        comparison_caveat = Get-TuneComparisonCaveat -Runtimes @($pre.runtimes)
        preconditions = $pre
        blockers = @($pre.blockers)
        runtimes = @($pre.runtimes)
        models = @($pre.models)
        stage1 = @($stage1)
        stage2 = @($stage2)
        moe_models = @($pre.moe_models)
        planned_runs = (@($stage1 | Where-Object { $_.status -eq 'planned' }).Count + @($stage2).Count + 2 + [int](@($pre.moe_models | ForEach-Object { @($_.points).Count } | Measure-Object -Sum).Sum))
        reference = [pscustomobject]@{ model_id = 'qwen3-4b'; prompts = @(2048); gen = 128; repetitions = 3 }
        note = 'A preset is opt-in data. Selecting none leaves the generated command line unchanged.'
    }
}

function Get-TuneStatusDocument {
    param([string] $JobId = '')
    if ([string]::IsNullOrWhiteSpace($JobId)) { $JobId = Get-TuneLatestJobId }
    $dir = Get-TuneJobDirectory -JobId $JobId
    if ($null -eq $dir -or -not (Test-Path -LiteralPath $dir -PathType Container)) {
        return [pscustomobject]@{ schema_version = 1; action = 'tune'; tune_action = 'status'; status = 'not_found'; job_id = $JobId }
    }
    $job = Read-TuneJson -Path (Join-Path $dir 'job.json')
    $progress = Read-TuneJson -Path (Join-Path $dir 'progress.json')
    if ($null -eq $job) { return [pscustomobject]@{ schema_version = 1; action = 'tune'; tune_action = 'status'; status = 'invalid_job'; job_id = $JobId } }
    $state = [string](Get-TuneValue -Object $progress -Name 'state' -Default (Get-TuneValue -Object $job -Name 'state' -Default 'unknown'))
    $workerPid = [int](Get-TuneValue -Object $job -Name 'worker_pid' -Default 0)
    if ($state -eq 'running' -and $workerPid -gt 0 -and $null -eq (Get-Process -Id $workerPid -ErrorAction SilentlyContinue)) { $state = 'interrupted' }
    $total = [int](Get-TuneValue -Object $job -Name 'total_runs' -Default 0)
    $completed = [int](Get-TuneValue -Object $progress -Name 'completed_runs' -Default 0)
    $percent = if ($total -gt 0) { [Math]::Round(($completed / $total) * 100, 1) } else { 0 }
    $started = [string](Get-TuneValue -Object $job -Name 'started_at' -Default '')
    $elapsed = 0
    if ($started) { try { $elapsed = [Math]::Round(((Get-Date).ToUniversalTime() - ([datetime]$started).ToUniversalTime()).TotalSeconds, 1) } catch { } }
    return [pscustomobject]@{
        schema_version = 1; action = 'tune'; tune_action = 'status'; status = $state; job_id = $JobId
        worker_pid = $workerPid; started_at = $started; elapsed_seconds = $elapsed
        stage = [string](Get-TuneValue -Object $progress -Name 'stage' -Default '')
        current_model = [string](Get-TuneValue -Object $progress -Name 'current_model' -Default '')
        current_runtime = [string](Get-TuneValue -Object $progress -Name 'current_runtime' -Default '')
        completed_runs = $completed; total_runs = $total; percent = $percent
        current_bench_pid = [int](Get-TuneValue -Object $progress -Name 'current_bench_pid' -Default 0)
        cancel_requested = (Test-Path -LiteralPath (Join-Path $dir 'cancel.json') -PathType Leaf)
        warnings = @(Get-TuneValue -Object $progress -Name 'warnings' -Default @())
        last_error = [string](Get-TuneValue -Object $progress -Name 'last_error' -Default '')
        results_available = (Test-Path -LiteralPath (Join-Path $dir 'results.json') -PathType Leaf)
    }
}

function Get-TuneResultsDocument {
    param([string] $JobId = '')
    if ([string]::IsNullOrWhiteSpace($JobId)) { $JobId = Get-TuneLatestJobId }
    $dir = Get-TuneJobDirectory -JobId $JobId
    if ($null -eq $dir -or -not (Test-Path -LiteralPath $dir -PathType Container)) { return [pscustomobject]@{ schema_version = 1; action = 'tune'; tune_action = 'results'; status = 'not_found'; job_id = $JobId } }
    $results = Read-TuneJson -Path (Join-Path $dir 'results.json')
    if ($null -eq $results) {
        $status = Get-TuneStatusDocument -JobId $JobId
        return [pscustomobject]@{ schema_version = 1; action = 'tune'; tune_action = 'results'; status = 'not_ready'; job_id = $JobId; available = $false; run_status = $status }
    }
    return [pscustomobject]@{ schema_version = 1; action = 'tune'; tune_action = 'results'; status = 'completed'; job_id = $JobId; available = $true; results = $results }
}

function Write-TuneProgress {
    param([string] $JobId, [hashtable] $Fields)
    $path = Get-TuneJobFile -JobId $JobId -Name 'progress.json'
    $doc = Read-TuneJson -Path $path
    if ($null -eq $doc) { $doc = [ordered]@{} }
    $copy = [ordered]@{}
    foreach ($property in $doc.PSObject.Properties) { $copy[$property.Name] = $property.Value }
    foreach ($key in $Fields.Keys) { $copy[$key] = $Fields[$key] }
    $copy['updated_at'] = (Get-Date).ToUniversalTime().ToString('o')
    Write-TuneJson -Path $path -Document ([pscustomobject]$copy)
}

function Stop-TuneProcessTree {
    param([int] $ProcessId)
    if ($ProcessId -le 0) { return }
    try {
        $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $ProcessId" -ErrorAction SilentlyContinue)
        foreach ($child in $children) { Stop-TuneProcessTree -ProcessId ([int]$child.ProcessId) }
    } catch { }
    if ($null -ne (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) { Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue }
}

function Stop-TuneJob {
    param([string] $JobId = '')
    if ([string]::IsNullOrWhiteSpace($JobId)) { $JobId = Get-TuneLatestJobId }
    $dir = Get-TuneJobDirectory -JobId $JobId
    if ($null -eq $dir -or -not (Test-Path -LiteralPath $dir -PathType Container)) { return [pscustomobject]@{ schema_version = 1; action = 'tune'; tune_action = 'cancel'; status = 'not_found'; job_id = $JobId } }
    $job = Read-TuneJson -Path (Join-Path $dir 'job.json')
    $progress = Read-TuneJson -Path (Join-Path $dir 'progress.json')
    $state = [string](Get-TuneValue -Object $progress -Name 'state' -Default (Get-TuneValue -Object $job -Name 'state' -Default 'unknown'))
    if (@('completed', 'cancelled', 'failed', 'interrupted') -contains $state) { return [pscustomobject]@{ schema_version = 1; action = 'tune'; tune_action = 'cancel'; status = 'already_finished'; job_id = $JobId; state = $state } }
    Write-TuneJson -Path (Join-Path $dir 'cancel.json') -Document ([pscustomobject]@{ requested_at = (Get-Date).ToUniversalTime().ToString('o') })
    $benchPid = [int](Get-TuneValue -Object $progress -Name 'current_bench_pid' -Default 0)
    if ($benchPid -gt 0) { Stop-TuneProcessTree -ProcessId $benchPid }
    $workerPid = [int](Get-TuneValue -Object $job -Name 'worker_pid' -Default 0)
    if ($workerPid -gt 0) { Stop-TuneProcessTree -ProcessId $workerPid }
    Write-TuneProgress -JobId $JobId -Fields @{ state = 'cancelled'; stage = 'cancelled'; current_bench_pid = 0 }
    $job | Add-Member -NotePropertyName state -NotePropertyValue 'cancelled' -Force
    Write-TuneJson -Path (Join-Path $dir 'job.json') -Document $job
    return [pscustomobject]@{ schema_version = 1; action = 'tune'; tune_action = 'cancel'; status = 'cancelled'; job_id = $JobId; stopped_worker = ($workerPid -gt 0); stopped_bench = ($benchPid -gt 0) }
}

function Start-TuneWorkerProcess {
    param([string] $JobId)
    $dir = Get-TuneJobDirectory -JobId $JobId
    $dquote = [string][char]34
    $quotedScript = $dquote + $PSCommandPath + $dquote
    $quotedRoot = $dquote + $InstallRoot + $dquote
    $argString = "-NoProfile -ExecutionPolicy Bypass -File $quotedScript -Action Tune -TuneAction Worker -TuneJobId $JobId -InstallRoot $quotedRoot"
    $worker = Start-Process -FilePath 'powershell.exe' -ArgumentList $argString -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $dir 'worker.log') -RedirectStandardError (Join-Path $dir 'worker.err.log')
    return [int]$worker.Id
}

function Start-TuneJob {
    $plan = Get-TunePlanDocument
    if ($TuneSmoke) {
        # A deliberately tiny, single-runtime run for install/smoke checks. It is not a
        # comparison and never writes presets: one 4B prompt at 512 tokens, 64 generated.
        $smokeRuntime = @($plan.runtimes | Where-Object { [string]$_.backend -eq 'Vulkan' } | Select-Object -First 1)
        $smokeModel = @($plan.models | Where-Object { [string]$_.id -eq 'qwen3-4b' } | Select-Object -First 1)
        if ($smokeRuntime.Count -eq 0 -or $smokeModel.Count -eq 0 -or -not $smokeModel[0].installed) {
            $plan.blockers = @([pscustomobject]@{ code = 'smoke_unavailable'; detail = 'The smoke test needs an installed Vulkan runtime and the 4B model.'; remediation = 'Install Vulkan b12110 and the 4B model first.' })
            $plan.status = 'blocked'
            $plan.planned_runs = 0
        } else {
            $plan.runtimes = @($smokeRuntime[0])
            $plan.models = @($smokeModel[0])
            $plan.stage1 = @([pscustomobject]@{ model_id = 'qwen3-4b'; model = $smokeModel[0].name; runtime = $smokeRuntime[0].label; runtime_tag = $smokeRuntime[0].tag; backend = $smokeRuntime[0].backend; device = $smokeRuntime[0].device; device_arg = [string]$smokeRuntime[0].device_arg; status = 'planned'; reason = ''; fit = $smokeModel[0].fit })
            $plan.stage2 = @()
            $plan.moe_models = @()
            $plan.planned_runs = 1
            $plan | Add-Member -NotePropertyName smoke -NotePropertyValue $true -Force
            $plan.reference = [pscustomobject]@{ model_id = 'qwen3-4b'; prompts = @(512); gen = 64; repetitions = 1 }
            $plan.comparison_caveat = Get-TuneComparisonCaveat -Runtimes @($plan.runtimes)
        }
    }
    if (@($plan.blockers).Count -gt 0) { return [pscustomobject]@{ schema_version = 1; action = 'tune'; tune_action = 'start'; status = 'blocked'; job_id = ''; detail = 'Tune refused: preconditions are not met. Nothing was started.'; plan = $plan; blockers = @($plan.blockers) } }
    $jobId = 'tune-' + (Get-Date).ToString('yyyyMMdd-HHmmss')
    $dir = Get-TuneJobDirectory -JobId $jobId
    if (Test-Path -LiteralPath $dir) { return [pscustomobject]@{ schema_version = 1; action = 'tune'; tune_action = 'start'; status = 'failed'; detail = 'A Tune job with this timestamp already exists.' } }
    New-Item -ItemType Directory -Path (Join-Path $dir 'raw') -Force | Out-Null
    $total = [int]$plan.planned_runs
    $job = [ordered]@{ schema_version = 1; job_id = $jobId; state = 'running'; started_at = (Get-Date).ToUniversalTime().ToString('o'); worker_pid = 0; total_runs = $total; plan = $plan }
    Write-TuneJson -Path (Join-Path $dir 'job.json') -Document ([pscustomobject]$job)
    Write-TuneProgress -JobId $jobId -Fields @{ state = 'starting'; stage = 'starting'; completed_runs = 0; current_bench_pid = 0; warnings = @(); last_error = '' }
    try {
        $workerPid = Start-TuneWorkerProcess -JobId $jobId
        $job.worker_pid = [int]$workerPid
        Write-TuneJson -Path (Join-Path $dir 'job.json') -Document ([pscustomobject]$job)
        Write-TuneProgress -JobId $jobId -Fields @{ state = 'running'; stage = 'starting'; worker_pid = [int]$workerPid }
        return [pscustomobject]@{ schema_version = 1; action = 'tune'; tune_action = 'start'; status = 'started'; job_id = $jobId; worker_pid = [int]$workerPid; plan = $plan }
    } catch {
        $job.state = 'failed'
        Write-TuneJson -Path (Join-Path $dir 'job.json') -Document ([pscustomobject]$job)
        return [pscustomobject]@{ schema_version = 1; action = 'tune'; tune_action = 'start'; status = 'failed'; job_id = $jobId; detail = [string]$_.Exception.Message }
    }
}

function Resume-TuneJob {
    param([string] $JobId = '')
    if ([string]::IsNullOrWhiteSpace($JobId)) { $JobId = Get-TuneLatestJobId }
    $dir = Get-TuneJobDirectory -JobId $JobId
    if ($null -eq $dir -or -not (Test-Path -LiteralPath $dir -PathType Container)) { return [pscustomobject]@{ schema_version = 1; action = 'tune'; tune_action = 'resume'; status = 'not_found'; job_id = $JobId } }
    $job = Read-TuneJson -Path (Join-Path $dir 'job.json')
    $progress = Read-TuneJson -Path (Join-Path $dir 'progress.json')
    if ($null -eq $job) { return [pscustomobject]@{ schema_version = 1; action = 'tune'; tune_action = 'resume'; status = 'invalid_job'; job_id = $JobId } }
    $state = [string](Get-TuneValue -Object $progress -Name 'state' -Default (Get-TuneValue -Object $job -Name 'state' -Default 'unknown'))
    if (@('completed', 'cancelled') -contains $state) { return [pscustomobject]@{ schema_version = 1; action = 'tune'; tune_action = 'resume'; status = 'not_resumable'; job_id = $JobId; state = $state } }
    $workerPid = [int](Get-TuneValue -Object $job -Name 'worker_pid' -Default 0)
    if ($workerPid -gt 0 -and $null -ne (Get-Process -Id $workerPid -ErrorAction SilentlyContinue)) { return [pscustomobject]@{ schema_version = 1; action = 'tune'; tune_action = 'resume'; status = 'already_running'; job_id = $JobId; worker_pid = $workerPid } }
    $checkpoint = Read-TuneCheckpoint -JobId $JobId
    if ($null -eq $checkpoint) { return [pscustomobject]@{ schema_version = 1; action = 'tune'; tune_action = 'resume'; status = 'no_checkpoint'; job_id = $JobId } }
    $pre = Get-TunePreconditions
    if (@($pre.blockers).Count -gt 0) { return [pscustomobject]@{ schema_version = 1; action = 'tune'; tune_action = 'resume'; status = 'blocked'; job_id = $JobId; blockers = @($pre.blockers) } }
    $cancelPath = Join-Path $dir 'cancel.json'
    if (Test-Path -LiteralPath $cancelPath -PathType Leaf) { Remove-Item -LiteralPath $cancelPath -Force }
    $job | Add-Member -NotePropertyName state -NotePropertyValue 'running' -Force
    $job | Add-Member -NotePropertyName worker_pid -NotePropertyValue 0 -Force
    Write-TuneJson -Path (Join-Path $dir 'job.json') -Document $job
    try {
        $newPid = Start-TuneWorkerProcess -JobId $JobId
        $job.worker_pid = [int]$newPid
        Write-TuneJson -Path (Join-Path $dir 'job.json') -Document $job
        Write-TuneProgress -JobId $JobId -Fields @{ state = 'running'; stage = 'resumed'; worker_pid = [int]$newPid; completed_runs = (Get-TuneCompletedCount -Checkpoint $checkpoint) }
        return [pscustomobject]@{ schema_version = 1; action = 'tune'; tune_action = 'resume'; status = 'resumed'; job_id = $JobId; worker_pid = [int]$newPid; completed_runs = (Get-TuneCompletedCount -Checkpoint $checkpoint) }
    } catch {
        return [pscustomobject]@{ schema_version = 1; action = 'tune'; tune_action = 'resume'; status = 'failed'; job_id = $JobId; detail = [string]$_.Exception.Message }
    }
}

function Quote-TuneArg {
    param([string] $Value)
    if ($null -eq $Value) { return '""' }
    if ($Value -match '[\s"]') { return ('"' + ($Value -replace '"', '\"') + '"') }
    return $Value
}

function ConvertFrom-TuneBenchJson {
    param([string] $Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { throw 'llama-bench returned no JSON.' }
    $start = $Text.IndexOf('[')
    $end = $Text.LastIndexOf(']')
    if ($start -lt 0 -or $end -le $start) { throw 'llama-bench output did not contain a JSON array.' }
    $parsed = $Text.Substring($start, $end - $start + 1) | ConvertFrom-Json
    $rows = @()
    foreach ($item in @($parsed)) {
        $nPrompt = [int](Get-TuneValue -Object $item -Name 'n_prompt' -Default 0)
        $nGen = [int](Get-TuneValue -Object $item -Name 'n_gen' -Default 0)
        $kind = 'unknown'; $n = 0
        if ($nPrompt -gt 0 -and $nGen -eq 0) { $kind = 'prompt'; $n = $nPrompt }
        elseif ($nGen -gt 0 -and $nPrompt -eq 0) { $kind = 'decode'; $n = $nGen }
        $mean = [double](Get-TuneValue -Object $item -Name 'avg_ts' -Default 0)
        $stddev = [double](Get-TuneValue -Object $item -Name 'stddev_ts' -Default 0)
        $noisy = ($mean -gt 0 -and $stddev -gt ($mean * 0.10))
        $rows += [pscustomobject]@{
            kind = $kind; n = [int]$n; mean = [Math]::Round($mean, 4); stddev = [Math]::Round($stddev, 4); noisy = $noisy
            build_commit = [string](Get-TuneValue -Object $item -Name 'build_commit' -Default '')
            build_number = [int](Get-TuneValue -Object $item -Name 'build_number' -Default 0)
            backends = [string](Get-TuneValue -Object $item -Name 'backends' -Default '')
            devices = [string](Get-TuneValue -Object $item -Name 'devices' -Default '')
            n_batch = [int](Get-TuneValue -Object $item -Name 'n_batch' -Default 0)
            n_ubatch = [int](Get-TuneValue -Object $item -Name 'n_ubatch' -Default 0)
            n_gpu_layers = [int](Get-TuneValue -Object $item -Name 'n_gpu_layers' -Default 0)
            flash_attn = [bool](Get-TuneValue -Object $item -Name 'flash_attn' -Default $false)
        }
    }
    return @($rows)
}

function Invoke-TuneBenchProcess {
    param([string] $FilePath, [string] $Arguments, [string] $WorkingDirectory, [string] $StdoutPath, [string] $StderrPath, [string] $JobId = '')
    $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -WorkingDirectory $WorkingDirectory -WindowStyle Hidden -PassThru -RedirectStandardOutput $StdoutPath -RedirectStandardError $StderrPath
    # Write the PID before waiting so Cancel can stop the actual benchmark process,
    # not just the worker that started it.
    if (-not [string]::IsNullOrWhiteSpace($JobId)) { Write-TuneProgress -JobId $JobId -Fields @{ current_bench_pid = [int]$process.Id } }
    $process.WaitForExit()
    if (-not [string]::IsNullOrWhiteSpace($JobId)) { Write-TuneProgress -JobId $JobId -Fields @{ current_bench_pid = 0 } }
    $out = if (Test-Path -LiteralPath $StdoutPath) { Get-Content -LiteralPath $StdoutPath -Raw } else { '' }
    $err = if (Test-Path -LiteralPath $StderrPath) { Get-Content -LiteralPath $StderrPath -Raw } else { '' }
    return [pscustomobject]@{ exit_code = [int]$process.ExitCode; stdout = [string]$out; stderr = [string]$err; process_id = [int]$process.Id }
}

function Invoke-TuneBench {
    param([string] $JobId, [string] $Stage, $Model, $Runtime, [int[]] $Prompts, [int] $Gen, [int] $Reps, [int] $Batch = 0, [int] $Ubatch = 0, [int] $CpuMoe = -1)
    $modelPath = Join-Path (Join-Path $InstallRoot 'models') ([string]$Model.file)
    if (-not (Test-Path -LiteralPath $modelPath -PathType Leaf)) { return [pscustomobject]@{ status = 'model_missing'; model_id = [string]$Model.id; runtime_tag = [string]$Runtime.tag; backend = [string]$Runtime.backend; device = [string]$Runtime.device; device_verified = $false; observed_devices = @(); rows = @(); error = "Model file is missing: $modelPath" } }
    $benchArgs = @('-m', $modelPath, '-dev', [string]$Runtime.device, '-ngl', '99', '-fa', [string]$Runtime.flash_arg, '-ctk', 'q8_0', '-ctv', 'q8_0', '-p', (@($Prompts) -join ','), '-n', [string]$Gen, '-r', [string]$Reps, '-o', 'json')
    if ($Batch -gt 0) { $benchArgs += @('-b', [string]$Batch) }
    if ($Ubatch -gt 0) { $benchArgs += @('-ub', [string]$Ubatch) }
    if ($CpuMoe -ge 0) { $benchArgs += @('-ncmoe', [string]$CpuMoe) }
    $argString = (@($benchArgs | ForEach-Object { Quote-TuneArg -Value ([string]$_) }) -join ' ')
    $command = $Runtime.bench_exe + ' ' + $argString
    $safe = ("$Stage-$($Model.id)-$($Runtime.backend)-$Batch-$Ubatch-$CpuMoe" -replace '[^A-Za-z0-9._-]', '_')
    $attempts = @()
    $rows = @()
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $outPath = Get-TuneJobFile -JobId $JobId -Name ("raw/$safe-attempt$attempt.json")
        $errPath = Get-TuneJobFile -JobId $JobId -Name ("raw/$safe-attempt$attempt.err.log")
        Write-TuneProgress -JobId $JobId -Fields @{ stage = $Stage; current_model = [string]$Model.id; current_runtime = [string]$Runtime.label; current_bench_pid = 0 }
        $run = Invoke-TuneBenchProcess -FilePath ([string]$Runtime.bench_exe) -Arguments $argString -WorkingDirectory ([string]$Runtime.path) -StdoutPath $outPath -StderrPath $errPath -JobId $JobId
        $attempts += [pscustomobject]@{ attempt = $attempt; exit_code = $run.exit_code; raw_file = $outPath; error_file = $errPath; command = $command }
        if ($run.exit_code -ne 0) {
            Write-TuneProgress -JobId $JobId -Fields @{ current_bench_pid = 0; last_error = ("$Stage $($Model.id) $($Runtime.tag) exit $($run.exit_code): " + (($run.stderr -split "`n" | Select-Object -First 3) -join ' ')) }
            return [pscustomobject]@{ status = 'failed'; model_id = [string]$Model.id; runtime_tag = [string]$Runtime.tag; backend = [string]$Runtime.backend; device = [string]$Runtime.device; device_verified = $false; observed_devices = @(); rows = @(); attempts = @($attempts); command = $command; error = (($run.stderr -split "`n" | Select-Object -First 5) -join ' ') }
        }
        try { $rows = @(ConvertFrom-TuneBenchJson -Text $run.stdout) } catch {
            return [pscustomobject]@{ status = 'parse_failed'; model_id = [string]$Model.id; runtime_tag = [string]$Runtime.tag; backend = [string]$Runtime.backend; device = [string]$Runtime.device; device_verified = $false; observed_devices = @(); rows = @(); attempts = @($attempts); command = $command; error = [string]$_.Exception.Message }
        }
        # Verify the GPU from llama-bench's own JSON, not only from the -dev argument.
        $expectedDevice = [string]$Runtime.device
        $observedDevices = @($rows | ForEach-Object { [string]$_.devices } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
        $rowsWithExpectedDevice = @($rows | Where-Object { [string]$_.devices -eq $expectedDevice }).Count
        if ([string]::IsNullOrWhiteSpace($expectedDevice) -or $observedDevices.Count -ne 1 -or $observedDevices[0] -ne $expectedDevice -or $rowsWithExpectedDevice -ne $rows.Count) {
            $observed = if ($observedDevices.Count -gt 0) { $observedDevices -join ', ' } else { '(none)' }
            Write-TuneProgress -JobId $JobId -Fields @{ current_bench_pid = 0; last_error = "$Stage $($Model.id) $($Runtime.tag) reported device '$observed', expected '$expectedDevice'." }
            return [pscustomobject]@{ status = 'device_mismatch'; model_id = [string]$Model.id; runtime_tag = [string]$Runtime.tag; backend = [string]$Runtime.backend; device = $expectedDevice; device_verified = $false; observed_devices = @($observedDevices); rows = @(); attempts = @($attempts); command = $command; error = "llama-bench reported '$observed', expected '$expectedDevice'; the row is not accepted." }
        }
        $noisy = @($rows | Where-Object { $_.noisy }).Count -gt 0
        if (-not $noisy) { break }
    }
    $stillNoisy = @($rows | Where-Object { $_.noisy }).Count -gt 0
    foreach ($row in $rows) { $row | Add-Member -NotePropertyName unreliable -NotePropertyValue $stillNoisy -Force; $row | Add-Member -NotePropertyName n_batch -NotePropertyValue $(if ($Batch -gt 0) { $Batch } else { $row.n_batch }) -Force; $row | Add-Member -NotePropertyName n_ubatch -NotePropertyValue $(if ($Ubatch -gt 0) { $Ubatch } else { $row.n_ubatch }) -Force }
    return [pscustomobject]@{ status = 'ok'; model_id = [string]$Model.id; runtime_tag = [string]$Runtime.tag; backend = [string]$Runtime.backend; device = [string]$Runtime.device; device_verified = $true; observed_devices = @($observedDevices); rows = @($rows); attempts = @($attempts); command = $command; rerun = (@($attempts).Count -gt 1); unreliable = $stillNoisy }
}

function Get-TuneRowMetric {
    param($Rows, [string] $Kind, [int] $N = 0)
    $match = @($Rows | Where-Object { $_.kind -eq $Kind -and ($N -le 0 -or $_.n -eq $N) } | Select-Object -First 1)
    if ($match.Count -eq 0) { return $null }
    return $match[0]
}

function Get-TuneStageWinner {
    param($Stage1, [string] $ModelId)
    $rows = @($Stage1 | Where-Object { $_.model_id -eq $ModelId -and $_.status -eq 'ok' })
    $candidates = @()
    foreach ($row in $rows) {
        $pp1 = Get-TuneRowMetric -Rows $row.rows -Kind 'prompt' -N 2048
        $pp2 = Get-TuneRowMetric -Rows $row.rows -Kind 'prompt' -N 8192
        $tg = Get-TuneRowMetric -Rows $row.rows -Kind 'decode' -N 128
        if ($null -eq $pp1 -or $null -eq $pp2 -or $null -eq $tg) { continue }
        $score = [Math]::Pow([double]$pp1.mean * [double]$pp2.mean * [double]$tg.mean, 1.0 / 3.0)
        $candidates += [pscustomobject]@{ runtime_tag = $row.runtime_tag; backend = $row.backend; runtime = $row; score = $score; pp2048 = $pp1.mean; pp8192 = $pp2.mean; tg128 = $tg.mean }
    }
    $sorted = @($candidates | Sort-Object score -Descending)
    if ($sorted.Count -eq 0) { return $null }
    return $sorted[0]
}

function Get-TuneMaxContext {
    param($Model, $Hardware, [int] $Maximum = 262144)
    $cap = 131072
    try {
        $modelPath = Join-Path (Join-Path $InstallRoot 'models') ([string]$Model.file)
        $meta = Read-GgufMetadata -Path $modelPath
        $arch = if ($meta.ContainsKey('general.architecture')) { [string]$meta['general.architecture'] } else { '' }
        $trained = [int](Get-GgufNumber -Metadata $meta -Key "$arch.context_length" -Default 0)
        if ($trained -gt 0) { $cap = $trained }
    } catch { }
    $cap = [Math]::Min($cap, $Maximum)
    $best = 0
    for ($context = 8192; $context -le $cap; $context *= 2) {
        try {
            $estimate = Get-VramEstimate -Model $Model -Hardware $Hardware -Context $context -UsedGiB 0
            if ([string]$estimate.verdict -eq 'fits') { $best = $context }
        } catch { }
    }
    if ($best -le 0) { $best = 8192 }
    return [int]$best
}

function Get-TuneEligibleRows {
    param($Rows, $Baseline)
    $base1 = Get-TuneRowMetric -Rows $Baseline.rows -Kind 'prompt' -N 2048
    $base2 = Get-TuneRowMetric -Rows $Baseline.rows -Kind 'prompt' -N 8192
    if ($null -eq $base1 -or $null -eq $base2) { return @() }
    return @($Rows | Where-Object {
        $p1 = Get-TuneRowMetric -Rows $_.rows -Kind 'prompt' -N 2048
        $p2 = Get-TuneRowMetric -Rows $_.rows -Kind 'prompt' -N 8192
        ($null -ne $p1 -and $null -ne $p2 -and -not [bool]$_.unreliable -and [double]$p1.mean -gt [double]$base1.mean -and [double]$p2.mean -gt [double]$base2.mean)
    })
}

function New-TunePresetSet {
    param($Model, $Stage2, $Hardware, [string] $JobId)
    $results = @($Stage2 | Where-Object { $_.model_id -eq $Model.id -and $_.status -eq 'ok' -and @($_.rows).Count -gt 0 })
    if ($results.Count -eq 0) { return $null }
    # The comparison is against the actual default 2048/512 row. If that row did not run,
    # there is no honest baseline and no recommendation may be produced.
    $baseline = @($results | Where-Object { [int]$_.rows[0].n_batch -eq 2048 -and [int]$_.rows[0].n_ubatch -eq 512 } | Select-Object -First 1)
    if ($baseline.Count -eq 0) { return $null }
    # The recommendation rule is explicit: a setting must beat the default batch/ubatch
    # on BOTH prompt tests. A short-test win alone is never enough.
    $eligible = @(Get-TuneEligibleRows -Rows $results -Baseline $baseline[0])
    if ($eligible.Count -eq 0) { return $null }
    $pool = @($eligible)
    $base1 = Get-TuneRowMetric -Rows $baseline[0].rows -Kind 'prompt' -N 2048
    $base2 = Get-TuneRowMetric -Rows $baseline[0].rows -Kind 'prompt' -N 8192
    $baseTg = Get-TuneRowMetric -Rows $baseline[0].rows -Kind 'decode' -N 128
    $withScore = @()
    foreach ($row in $pool) {
        $p1 = Get-TuneRowMetric -Rows $row.rows -Kind 'prompt' -N 2048
        $p2 = Get-TuneRowMetric -Rows $row.rows -Kind 'prompt' -N 8192
        $tg = Get-TuneRowMetric -Rows $row.rows -Kind 'decode' -N 128
        $score = 0.0
        if ($null -ne $p1 -and $null -ne $p2 -and $null -ne $tg -and $null -ne $base1 -and $null -ne $base2 -and $null -ne $baseTg) {
            $score = (([double]$p1.mean / [double]$base1.mean) + ([double]$p2.mean / [double]$base2.mean) + ([double]$tg.mean / [double]$baseTg.mean)) / 3.0
        }
        $withScore += [pscustomobject]@{ result = $row; pp2048 = $p1; pp8192 = $p2; tg128 = $tg; score = $score }
    }
    $fast = @($withScore | Where-Object { $null -ne $_.tg128 } | Sort-Object @{Expression={[double]$_.tg128.mean}} -Descending | Select-Object -First 1)
    $balanced = @($withScore | Where-Object { [double]$_.score -gt 0 } | Sort-Object score -Descending | Select-Object -First 1)
    $long = @($withScore | Where-Object { $null -ne $_.pp8192 } | Sort-Object @{Expression={[double]$_.pp8192.mean}} -Descending | Select-Object -First 1)
    if ($fast.Count -eq 0 -or $balanced.Count -eq 0 -or $long.Count -eq 0) { return $null }
    $fast = $fast[0]; $balanced = $balanced[0]; $long = $long[0]
    $shortContext = Get-TuneMaxContext -Model $Model -Hardware $Hardware -Maximum 32768
    $longContext = Get-TuneMaxContext -Model $Model -Hardware $Hardware -Maximum 262144
    $presets = [ordered]@{}
    foreach ($spec in @(@{ name = 'Fast'; pick = $fast; context = $shortContext; rule = 'highest decode mean among rows that passed both prompt tests' }, @{ name = 'Balanced'; pick = $balanced; context = $shortContext; rule = 'highest mean of normalized 2048 prompt, 8192 prompt, and decode' }, @{ name = 'Long context'; pick = $long; context = $longContext; rule = 'highest 8192 prompt mean with the largest context that the fit estimate says fits' })) {
        $pick = $spec.pick
        $rows = $pick.result.rows
        $presets[$spec.name] = [pscustomobject]@{
            name = $spec.name
            batch_size = [int]$rows[0].n_batch
            ubatch_size = [int]$rows[0].n_ubatch
            context_size = [int]$spec.context
            selected = $false
            receipt = [pscustomobject]@{ job_id = $JobId; model_id = [string]$Model.id; runtime = [string]$pick.result.runtime_tag; backend = [string]$pick.result.backend; command = [string]$pick.result.command; pp2048 = $pick.pp2048; pp8192 = $pick.pp8192; tg128 = $pick.tg128; normalized_score = [Math]::Round([double]$pick.score, 4); eligible_both_prompts = ($eligible.Count -gt 0); selection_rule = $spec.rule; variance_flagged = [bool]$pick.result.unreliable }
        }
    }
    return [pscustomobject]$presets
}

function Save-TunePresets {
    param([string] $ModelId, $Presets)
    if ($null -eq $Presets) { return }
    $settings = Get-AppSettings
    $all = @{}
    if ($settings.ContainsKey('tune_presets') -and $null -ne $settings['tune_presets']) {
        foreach ($property in $settings['tune_presets'].PSObject.Properties) { $all[$property.Name] = $property.Value }
    }
    $all[$ModelId] = $Presets
    Set-AppSetting -Name 'tune_presets' -Value ([pscustomobject]$all)
}

function Get-TunePresetForModel {
    param([string] $ModelId)
    if ([string]::IsNullOrWhiteSpace($ModelId)) { return $null }
    $settings = Get-AppSettings
    if (-not $settings.ContainsKey('tune_presets') -or -not $settings.ContainsKey('tune_preset_selection')) { return $null }
    $selection = Get-TuneValue -Object $settings['tune_preset_selection'] -Name $ModelId -Default ''
    if ([string]::IsNullOrWhiteSpace([string]$selection)) { return $null }
    $models = Get-TuneValue -Object $settings['tune_presets'] -Name $ModelId -Default $null
    $preset = Get-TuneValue -Object $models -Name ([string]$selection) -Default $null
    if ($null -eq $preset) { return $null }
    return [pscustomobject]@{ name = [string]$selection; batch_size = [int](Get-TuneValue -Object $preset -Name 'batch_size' -Default 0); ubatch_size = [int](Get-TuneValue -Object $preset -Name 'ubatch_size' -Default 0); context_size = [int](Get-TuneValue -Object $preset -Name 'context_size' -Default 0) }
}

function Set-TunePresetSelection {
    param([string] $ModelId, [string] $Preset)
    if ([string]::IsNullOrWhiteSpace($ModelId)) { throw 'Choose a model id.' }
    $settings = Get-AppSettings
    $map = @{}
    if ($settings.ContainsKey('tune_preset_selection') -and $null -ne $settings['tune_preset_selection']) {
        foreach ($property in $settings['tune_preset_selection'].PSObject.Properties) { $map[$property.Name] = [string]$property.Value }
    }
    if ([string]::IsNullOrWhiteSpace($Preset) -or $Preset -eq 'none') { $map.Remove($ModelId) }
    else {
        $models = Get-TuneValue -Object $settings['tune_presets'] -Name $ModelId -Default $null
        if ($null -eq $models -or $null -eq (Get-TuneValue -Object $models -Name $Preset -Default $null)) { throw "No Tune preset '$Preset' is stored for model '$ModelId'." }
        $map[$ModelId] = $Preset
    }
    Set-AppSetting -Name 'tune_preset_selection' -Value ([pscustomobject]$map)
}

function Write-TuneSummary {
    param([string] $Path, $Results)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# llama-bench Tune receipt')
    $lines.Add('')
    $lines.Add("Generated: $($Results.generated_at)")
    $lines.Add("Comparison caveat: $($Results.comparison_caveat)")
    $lines.Add('')
    $lines.Add('## Stage 1')
    $lines.Add('| Model | Runtime | Requested device | Observed device | Prompt 2048 tok/s | Prompt 8192 tok/s | Decode 128 tok/s | Status |')
    $lines.Add('|---|---|---|---|---:|---:|---:|---|')
    foreach ($row in @($Results.stage1)) {
        $p1 = Get-TuneRowMetric -Rows @($row.rows) -Kind 'prompt' -N 2048
        $p2 = Get-TuneRowMetric -Rows @($row.rows) -Kind 'prompt' -N 8192
        $tg = Get-TuneRowMetric -Rows @($row.rows) -Kind 'decode' -N 128
        $observed = if (@($row.observed_devices).Count -gt 0) { @($row.observed_devices) -join ', ' } else { '-' }
        $lines.Add("| $($row.model_id) | $($row.runtime_tag) | $($row.device) | $observed | $(if ($null -ne $p1) { $p1.mean } else { '-' }) | $(if ($null -ne $p2) { $p2.mean } else { '-' }) | $(if ($null -ne $tg) { $tg.mean } else { '-' }) | $($row.status) |")
    }
    $lines.Add('')
    $lines.Add('## Stage 2')
    $lines.Add('| Model | Runtime | Batch | Ubatch | Prompt 2048 tok/s | Prompt 8192 tok/s | Decode 128 tok/s | Status |')
    $lines.Add('|---|---|---:|---:|---:|---:|---:|---|')
    foreach ($row in @($Results.stage2)) {
        $p1 = Get-TuneRowMetric -Rows @($row.rows) -Kind 'prompt' -N 2048
        $p2 = Get-TuneRowMetric -Rows @($row.rows) -Kind 'prompt' -N 8192
        $tg = Get-TuneRowMetric -Rows @($row.rows) -Kind 'decode' -N 128
        $batch = if (@($row.rows).Count -gt 0) { $row.rows[0].n_batch } else { '-' }
        $ubatch = if (@($row.rows).Count -gt 0) { $row.rows[0].n_ubatch } else { '-' }
        $lines.Add("| $($row.model_id) | $($row.runtime_tag) | $batch | $ubatch | $(if ($null -ne $p1) { $p1.mean } else { '-' }) | $(if ($null -ne $p2) { $p2.mean } else { '-' }) | $(if ($null -ne $tg) { $tg.mean } else { '-' }) | $($row.status) |")
    }
    $lines.Add('')
    if (@(Get-TuneValue -Object $Results -Name 'moe_sweep' -Default @()).Count -gt 0) {
        $lines.Add('## MoE expert offload (Vulkan)')
        $lines.Add((Get-TuneValue -Object $Results -Name 'moe_note' -Default ''))
        $lines.Add('| Model | Expert layers on CPU | Prompt 2048 tok/s | Decode 128 tok/s | Status |')
        $lines.Add('|---|---:|---:|---:|---|')
        foreach ($sweep in @($Results.moe_sweep)) {
            foreach ($point in @($sweep.points)) {
                $p1 = Get-TuneRowMetric -Rows @($point.rows) -Kind 'prompt' -N 2048
                $tg = Get-TuneRowMetric -Rows @($point.rows) -Kind 'decode' -N 128
                $mark = if ($null -ne $sweep.best_cpu_moe -and [int]$point.cpu_moe -eq [int]$sweep.best_cpu_moe) { ' (fastest generation)' } else { '' }
                $lines.Add("| $($sweep.model_id) | $($point.cpu_moe) | $(if ($null -ne $p1) { $p1.mean } else { '-' }) | $(if ($null -ne $tg) { $tg.mean } else { '-' }) | $($point.status)$mark |")
            }
        }
        $lines.Add('')
    }
    $lines.Add('## Presets')
    $presetModelIds = @($Results.presets.PSObject.Properties | ForEach-Object { [string]$_.Name })
    if ($presetModelIds.Count -eq 0) { $lines.Add('- No preset was recommended by this run.') }
    foreach ($modelId in $presetModelIds) {
        $set = $Results.presets.$modelId
        $lines.Add("### $modelId")
        foreach ($name in @($set.PSObject.Properties.Name)) {
            $preset = $set.$name
            $lines.Add("- ${name}: batch $($preset.batch_size), ubatch $($preset.ubatch_size), context $($preset.context_size); $($preset.receipt.selection_rule).")
        }
        $lines.Add('')
    }
    [IO.File]::WriteAllText($Path, ($lines -join "`n"), (New-Object System.Text.UTF8Encoding($false)))
}

function Invoke-TuneWorker {
    param([string] $JobId)
    $dir = Get-TuneJobDirectory -JobId $JobId
    $job = Read-TuneJson -Path (Join-Path $dir 'job.json')
    if ($null -eq $job) { return 1 }
    $plan = $job.plan
    $started = Get-Date
    $cancel = { Test-Path -LiteralPath (Join-Path $dir 'cancel.json') -PathType Leaf }
    try {
        $checkpoint = Read-TuneCheckpoint -JobId $JobId
        if ($null -eq $checkpoint) {
            $checkpoint = [pscustomobject]@{
                schema_version = 1; job_id = $JobId; plan_generated_at = [string]$plan.generated_at
                reference_before = $null; reference_before_stage2 = $null; stage1 = @(); stage2 = @()
            }
            Write-TuneCheckpoint -JobId $JobId -Checkpoint $checkpoint
        } elseif ([string]$checkpoint.plan_generated_at -ne [string]$plan.generated_at) {
            throw 'The saved checkpoint belongs to a different plan. Start a new Tune job instead of resuming this one.'
        }
        $stage1 = @($checkpoint.stage1)
        $stage2 = @($checkpoint.stage2)
        $referenceBefore = $checkpoint.reference_before
        $referenceMid = $checkpoint.reference_before_stage2
        $total = [int]$job.total_runs
        Write-TuneProgress -JobId $JobId -Fields @{ state = 'running'; stage = 'reference-before'; completed_runs = (Get-TuneCompletedCount -Checkpoint $checkpoint); total_runs = $total; warnings = @(); last_error = '' }
        $firstRuntime = @($plan.runtimes)[0]
        $smoke = [bool](Get-TuneValue -Object $plan -Name 'smoke' -Default $false)
        $referenceModel = @(Get-TuneModelCandidates -Hardware (Get-HardwareProfile) | Where-Object { $_.id -eq 'qwen3-4b' } | Select-Object -First 1)
        if (-not $smoke -and $referenceModel.Count -eq 0) { throw 'The 4B reference model is not in the catalogue, so the reference check cannot run.' }
        if ($referenceModel.Count -gt 0) { $referenceModel = $referenceModel[0] }
        if (-not $smoke -and ($null -eq $referenceBefore -or [string]$referenceBefore.status -ne 'ok')) {
            $referenceBefore = Invoke-TuneBench -JobId $JobId -Stage 'reference-before' -Model $referenceModel -Runtime $firstRuntime -Prompts @(2048) -Gen 128 -Reps 3
            $checkpoint.reference_before = $referenceBefore
            Write-TuneCheckpoint -JobId $JobId -Checkpoint $checkpoint
        }
        if (& $cancel) { Write-TuneProgress -JobId $JobId -Fields @{ state = 'cancelled'; stage = 'cancelled'; current_bench_pid = 0 }; return 0 }
        $stagePrompts = if ($smoke) { @(512) } else { @(2048, 8192) }
        $stageGen = if ($smoke) { 64 } else { 128 }
        $stageReps = if ($smoke) { 1 } else { 3 }
        $modelIndex = 0
        foreach ($model in @($plan.models)) {
            $order = @(Get-TuneAlternatingOrder -Runtimes @($plan.runtimes) -Index $modelIndex)
            foreach ($runtime in $order) {
                if (& $cancel) { Write-TuneProgress -JobId $JobId -Fields @{ state = 'cancelled'; stage = 'cancelled'; current_bench_pid = 0 }; return 0 }
                $existing = @($stage1 | Where-Object { [string]$_.model_id -eq [string]$model.id -and [string]$_.runtime_tag -eq [string]$runtime.tag } | Select-Object -First 1)
                $terminal = ($existing.Count -gt 0 -and (@('ok', 'skipped_fit', 'model_missing') -contains [string]$existing[0].status))
                if ($terminal) {
                    $row = $existing[0]
                } else {
                    if ($existing.Count -gt 0) { $stage1 = @($stage1 | Where-Object { -not ([string]$_.model_id -eq [string]$model.id -and [string]$_.runtime_tag -eq [string]$runtime.tag) }) }
                    if (-not $model.installed) { $row = [pscustomobject]@{ status = 'model_missing'; model_id = $model.id; model = $model.name; runtime_tag = $runtime.tag; backend = $runtime.backend; device = $runtime.device; device_verified = $false; observed_devices = @(); rows = @(); error = 'Model file is not installed.' } }
                    elseif ($model.fit.skip) { $row = [pscustomobject]@{ status = 'skipped_fit'; model_id = $model.id; model = $model.name; runtime_tag = $runtime.tag; backend = $runtime.backend; device = $runtime.device; device_verified = $false; observed_devices = @(); rows = @(); error = "Fit estimate: $($model.fit.verdict), $($model.fit.needed_gib) GiB needed." } }
                    else { $row = Invoke-TuneBench -JobId $JobId -Stage 'stage1' -Model $model -Runtime $runtime -Prompts $stagePrompts -Gen $stageGen -Reps $stageReps }
                    $stage1 += $row
                    $checkpoint.stage1 = @($stage1)
                    Write-TuneCheckpoint -JobId $JobId -Checkpoint $checkpoint
                }
                Write-TuneProgress -JobId $JobId -Fields @{ stage = 'stage1'; completed_runs = (Get-TuneCompletedCount -Checkpoint $checkpoint); total_runs = $total; current_model = [string]$model.id; current_runtime = [string]$runtime.label; current_bench_pid = 0; last_result = [string]$row.status }
            }
            $modelIndex++
        }
        if (& $cancel) { Write-TuneProgress -JobId $JobId -Fields @{ state = 'cancelled'; stage = 'cancelled'; current_bench_pid = 0 }; return 0 }
        # The second reference must use the same build and device as the first, otherwise a
        # backend difference would masquerade as clock drift.
        if (-not $smoke -and ($null -eq $referenceMid -or [string]$referenceMid.status -ne 'ok')) {
            $referenceMid = Invoke-TuneBench -JobId $JobId -Stage 'reference-before-stage2' -Model $referenceModel -Runtime $firstRuntime -Prompts @(2048) -Gen 128 -Reps 3
            $checkpoint.reference_before_stage2 = $referenceMid
            Write-TuneCheckpoint -JobId $JobId -Checkpoint $checkpoint
        }
        $driftPercent = $null
        $driftWarning = ''
        if ($smoke) {
            # The smoke run has no second stage, so there is no drift comparison to make.
        } elseif ($null -eq $referenceBefore -or [string]$referenceBefore.status -ne 'ok' -or $null -eq $referenceMid -or [string]$referenceMid.status -ne 'ok') {
            $driftWarning = 'A reference benchmark did not complete; the run stopped before Stage 2 so a drift check cannot be faked.'
        } else {
            $b1 = Get-TuneRowMetric -Rows $referenceBefore.rows -Kind 'prompt' -N 2048
            $m1 = Get-TuneRowMetric -Rows $referenceMid.rows -Kind 'prompt' -N 2048
            if ($null -ne $b1 -and $null -ne $m1 -and [double]$b1.mean -gt 0) {
                $driftPercent = [Math]::Round([Math]::Abs(([double]$m1.mean - [double]$b1.mean) / [double]$b1.mean) * 100, 2)
                if ($driftPercent -gt 10) { $driftWarning = "Reference prompt speed drifted $($driftPercent) percent between stages; clocks or thermals may be distorting the run. Stopped before Stage 2." }
            } else {
                $driftWarning = 'The reference benchmark did not produce a 2048-token prompt result; the run stopped before Stage 2.'
            }
        }
        if ($driftWarning) {
            Write-TuneProgress -JobId $JobId -Fields @{ state = 'paused_for_user'; stage = 'awaiting-user'; warnings = @($driftWarning); reference_drift_percent = $driftPercent; current_bench_pid = 0 }
            $job | Add-Member -NotePropertyName state -NotePropertyValue 'paused_for_user' -Force
            Write-TuneJson -Path (Join-Path $dir 'job.json') -Document $job
            return 0
        }
        $presetMap = [ordered]@{}
        $stage2Models = if ($smoke) { @() } else { @($plan.models | Where-Object { $_.installed -and -not $_.fit.skip }) }
        foreach ($model in @($stage2Models)) {
            $modelWinner = Get-TuneStageWinner -Stage1 $stage1 -ModelId ([string]$model.id)
            if ($null -eq $modelWinner) { continue }
            $runtime = @($plan.runtimes | Where-Object { $_.tag -eq $modelWinner.runtime_tag } | Select-Object -First 1)
            if ($runtime.Count -eq 0) { continue }
            foreach ($combo in @(Get-TuneBatchCombinations)) {
                if (& $cancel) { Write-TuneProgress -JobId $JobId -Fields @{ state = 'cancelled'; stage = 'cancelled'; current_bench_pid = 0 }; return 0 }
                $existing = @($stage2 | Where-Object { [string]$_.model_id -eq [string]$model.id -and [int]$_.batch_size -eq [int]$combo.batch_size -and [int]$_.ubatch_size -eq [int]$combo.ubatch_size } | Select-Object -First 1)
                if ($existing.Count -gt 0 -and [string]$existing[0].status -eq 'ok') {
                    $row = $existing[0]
                } else {
                    if ($existing.Count -gt 0) { $stage2 = @($stage2 | Where-Object { -not ([string]$_.model_id -eq [string]$model.id -and [int]$_.batch_size -eq [int]$combo.batch_size -and [int]$_.ubatch_size -eq [int]$combo.ubatch_size) }) }
                    $row = Invoke-TuneBench -JobId $JobId -Stage 'stage2' -Model $model -Runtime $runtime[0] -Prompts @(2048, 8192) -Gen 128 -Reps 2 -Batch $combo.batch_size -Ubatch $combo.ubatch_size
                    $row | Add-Member -NotePropertyName runtime -NotePropertyValue $runtime[0].label -Force
                    $row | Add-Member -NotePropertyName batch_size -NotePropertyValue ([int]$combo.batch_size) -Force
                    $row | Add-Member -NotePropertyName ubatch_size -NotePropertyValue ([int]$combo.ubatch_size) -Force
                    $stage2 += $row
                    $checkpoint.stage2 = @($stage2)
                    Write-TuneCheckpoint -JobId $JobId -Checkpoint $checkpoint
                }
                Write-TuneProgress -JobId $JobId -Fields @{ stage = 'stage2'; completed_runs = (Get-TuneCompletedCount -Checkpoint $checkpoint); total_runs = $total; current_model = [string]$model.id; current_runtime = [string]$runtime[0].label; current_bench_pid = 0; last_result = [string]$row.status }
            }
            $presets = New-TunePresetSet -Model $model -Stage2 $stage2 -Hardware (Get-HardwareProfile) -JobId $JobId
            if ($null -ne $presets) { $presetMap[[string]$model.id] = $presets; Save-TunePresets -ModelId ([string]$model.id) -Presets $presets }
        }
        # MoE sweep: one Vulkan llama-bench per -ncmoe point, same prompt/decode sizes as the
        # reference. Resumes per point; a point that already ran ok is not repeated.
        $moeEntries = @(Get-TuneValue -Object $checkpoint -Name 'moe' -Default @())
        foreach ($moeModel in @(Get-TuneValue -Object $plan -Name 'moe_models' -Default @())) {
            $moeRuntime = $moeModel.runtime
            foreach ($point in @($moeModel.points)) {
                if (& $cancel) { Write-TuneProgress -JobId $JobId -Fields @{ state = 'cancelled'; stage = 'cancelled'; current_bench_pid = 0 }; return 0 }
                $existing = @($moeEntries | Where-Object { [string]$_.model_id -eq [string]$moeModel.id -and [int]$_.cpu_moe -eq [int]$point } | Select-Object -First 1)
                if ($existing.Count -gt 0 -and [string]$existing[0].status -eq 'ok') { continue }
                $moeEntries = @($moeEntries | Where-Object { -not ([string]$_.model_id -eq [string]$moeModel.id -and [int]$_.cpu_moe -eq [int]$point) })
                $row = Invoke-TuneBench -JobId $JobId -Stage 'moe' -Model $moeModel -Runtime $moeRuntime -Prompts @(2048) -Gen 128 -Reps 3 -CpuMoe ([int]$point)
                $row | Add-Member -NotePropertyName cpu_moe -NotePropertyValue ([int]$point) -Force
                $moeEntries += $row
                $checkpoint | Add-Member -NotePropertyName moe -NotePropertyValue @($moeEntries) -Force
                Write-TuneCheckpoint -JobId $JobId -Checkpoint $checkpoint
                Write-TuneProgress -JobId $JobId -Fields @{ stage = 'moe'; completed_runs = (Get-TuneCompletedCount -Checkpoint $checkpoint); total_runs = $total; current_model = [string]$moeModel.id; current_runtime = [string]$moeRuntime.label; current_bench_pid = 0; last_result = [string]$row.status }
            }
        }
        $moeSweep = @(foreach ($moeModel in @(Get-TuneValue -Object $plan -Name 'moe_models' -Default @())) {
            $mine = @($moeEntries | Where-Object { [string]$_.model_id -eq [string]$moeModel.id })
            $best = Get-TuneMoeBest -Entries $mine
            [pscustomobject]@{ model_id = [string]$moeModel.id; runtime_tag = [string]$moeModel.runtime_tag; backend = 'Vulkan'; block_count = [int]$moeModel.block_count; points = @($mine); best_cpu_moe = $(if ($null -ne $best) { [int]$best.cpu_moe } else { $null }) }
        })
        $hardware = Get-HardwareProfile
        $results = [ordered]@{
            schema_version = 1; kind = 'llama-bench-tune'; job_id = $JobId; generated_at = (Get-Date).ToUniversalTime().ToString('o')
            smoke = $smoke
            comparison_caveat = Get-TuneComparisonCaveat -Runtimes @($plan.runtimes)
            machine = [pscustomobject]@{ cpu = [string]$hardware.CpuName; ram_gib = [double]$hardware.RamGiB; gpu = [string]$hardware.RocmGpu; max_vram_gib = [double]$hardware.MaxAmdVramGiB; driver = Get-GpuDriverInfo; os = [string][Environment]::OSVersion.VersionString }
            runtimes = @($plan.runtimes)
            reference_before = $referenceBefore
            reference_before_stage2 = $referenceMid
            reference_drift_percent = $driftPercent
            stage1 = @($stage1)
            stage1_order = @($stage1 | ForEach-Object { "$($_.model_id)/$($_.runtime_tag)" })
            stage2 = @($stage2)
            stage2_order = @($stage2 | ForEach-Object { "$($_.model_id)/$($_.runtime_tag)/$($_.batch_size)/$($_.ubatch_size)" })
            presets = [pscustomobject]$presetMap
            moe_sweep = @($moeSweep)
            moe_note = 'Sweep ran at one slot and an 8k-token benchmark context, with the desktop in normal use. The server runs more context, which leaves less VRAM, so its best value is probably a little higher.'
            wall_time_seconds = [Math]::Round(((Get-Date) - $started).TotalSeconds, 1)
        }
        Write-TuneJson -Path (Join-Path $dir 'results.json') -Document ([pscustomobject]$results)
        Write-TuneSummary -Path (Join-Path $dir 'summary.md') -Results ([pscustomobject]$results)
        $job | Add-Member -NotePropertyName state -NotePropertyValue 'completed' -Force
        Write-TuneJson -Path (Join-Path $dir 'job.json') -Document $job
        Write-TuneProgress -JobId $JobId -Fields @{ state = 'completed'; stage = 'completed'; completed_runs = (Get-TuneCompletedCount -Checkpoint $checkpoint); total_runs = $total; current_bench_pid = 0 }
        return 0
    } catch {
        Write-TuneProgress -JobId $JobId -Fields @{ state = 'failed'; stage = 'failed'; current_bench_pid = 0; last_error = [string]$_.Exception.Message }
        try { $job | Add-Member -NotePropertyName state -NotePropertyValue 'failed' -Force; Write-TuneJson -Path (Join-Path $dir 'job.json') -Document $job } catch { }
        return 1
    }
}

function Write-JsonStdout {
    # One typed document on stdout, for -Action State/Recommend/Diagnose.
    param($Document)
    Write-Utf8StdoutLine -Line (ConvertTo-Json -InputObject $Document -Depth 8)
}

# ---------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------

try {
    if ($Uninstall) { $Action = 'Uninstall' }
    if ($DryRun) { $Action = 'Advisor' }

    if ($Action -eq 'Status') {
        Write-Output (Get-CommandCenterStatus)
        exit 0
    }

    if ($Action -eq 'State') {
        # Read-only JSON snapshot for scripts and the window (ADR-003). It runs before
        # run logging so asking for state can never write a log.
        Write-JsonStdout -Document (Get-ApplicationState)
        exit 0
    }

    if ($Action -eq 'Snapshot') {
        # Persist one state document for diagnostics/rollback history, then print its path.
        $snapshotPath = Save-StateSnapshot -Reason 'manual'
        if ($null -eq $snapshotPath) {
            Write-Utf8StdoutLine -Line 'Snapshot failed: the state document could not be written.'
            exit 1
        }
        Write-Utf8StdoutLine -Line $snapshotPath
        exit 0
    }

    if ($Action -eq 'Recommend') {
        # The recommendation engine's document (ADR-005): read-only, before run logging.
        Write-JsonStdout -Document (Get-RecommendationDocument)
        exit 0
    }

    if ($Action -eq 'Diagnose') {
        # One typed diagnostics document (ADR-005): machine-readable, no GUI, read-only.
        Write-JsonStdout -Document (Get-DiagnosticReport)
        exit 0
    }

    if ($Action -eq 'Tune') {
        # Tune is a typed backend surface. Worker is internal and writes its own receipts;
        # every user-facing sub-action prints exactly one JSON document.
        if ($TuneAction -eq 'Worker') { exit (Invoke-TuneWorker -JobId $TuneJobId) }
        $tuneDocument = switch ([string]$TuneAction) {
            'Start' { Start-TuneJob }
            'Resume' { Resume-TuneJob -JobId $TuneJobId }
            'Status' { Get-TuneStatusDocument -JobId $TuneJobId }
            'Cancel' { Stop-TuneJob -JobId $TuneJobId }
            'Results' { Get-TuneResultsDocument -JobId $TuneJobId }
            default { Get-TunePlanDocument }
        }
        Write-JsonStdout -Document $tuneDocument
        exit 0
    }

    if ($Action -eq 'Settings') {
        # The settings surface for the desktop window (ADR-003): read-only document on its
        # own, and one read-validate-write result when a patch is supplied. Every write
        # goes through the existing helpers, so it never bypasses their guards. Runs before
        # run logging; a patch never writes a run log either.
        $script:JsonDocumentsOnly = $true
        if ($SettingsPatch) {
            Write-JsonStdout -Document (Set-SettingsFromDocument -SettingsPatchText $SettingsPatch)
        } else {
            Write-JsonStdout -Document (Get-SettingsDocument)
        }
        exit 0
    }

    if ($Action -eq 'GameWatch') {
        # Background helper started by the launcher when game pause is on: no run log, no menu.
        exit (Invoke-GameWatch)
    }

    if ($Action -eq 'Library') {
        # The model library for the desktop window (ADR-003): a read-only document on
        # its own, and one typed result per download/activate/remove. Downloads only
        # validate here; the long transfer runs in the console window the caller opens.
        $script:JsonDocumentsOnly = $true
        if ($LibraryAction) {
            Write-JsonStdout -Document (Invoke-LibraryAction -LibraryAction $LibraryAction -ModelIdRequested $ModelId)
        } else {
            Write-JsonStdout -Document (Get-LibraryDocument)
        }
        exit 0
    }

    if ($Action -eq 'Runtime') {
        # The runtime adapter entry points (ADR-005) over the command line, so the desktop
        # window never re-implements process control: health is read-only, start launches
        # the proven path, and stop without -Force only reports that a confirmation is
        # required (nothing is killed). One typed JSON document on stdout.
        $runtimeResult = switch ([string]$RuntimeAction) {
            'start' { Start-Runtime -AdapterId $RuntimeAdapter }
            'stop' { Stop-Runtime -AdapterId $RuntimeAdapter -Force:$Force }
            'update' { Update-Runtime -AdapterId $RuntimeAdapter -Backend $Backend -Force:$Force }
            'rollback' { Invoke-RuntimeRollback -Backend $Backend }
            'updates' { Get-RuntimeUpdateReport }
            default { Get-RuntimeHealth -AdapterId $RuntimeAdapter }
        }
        Write-JsonStdout -Document $runtimeResult
        exit 0
    }

    if ($Action -eq 'ListInstalled') {
        Get-InstalledModelList | ForEach-Object { Write-Output $_ }
        exit 0
    }

    if ($Action -eq 'SelfTest') {
        $passed = Test-LocalServer
        if ($passed) { exit 0 } else { exit 1 }
    }

    if ($Action -eq 'ViewLog') {
        Show-LatestRunLog
        exit 0
    }

    if ($Action -eq 'CheckUpdate') {
        $updateCheck = Test-CommandCenterUpdate
        if (-not $updateCheck.Checked) { Write-WarnLine "Could not check for updates: $($updateCheck.Error)"; exit 1 }
        if ($updateCheck.UpdateAvailable) {
            Write-Host "Update available: $($updateCheck.Latest) (you have v$($updateCheck.Current)) — $($updateCheck.Url)"
        } else {
            Write-Host "Up to date: v$($updateCheck.Current)."
        }
        exit 0
    }

    if ($Action -eq 'Gui') {
        # The window is the default front door. If it cannot open (no WPF, a locked-down PC),
        # fall back to the text menu instead of leaving the user with nothing.
        try {
            Show-CommandCenterWindow
        } catch {
            Write-GuiErrorLog -Message "The window could not run, so the text menu opened instead: $($_.Exception.Message) $($_.InvocationInfo.PositionMessage)"
            $menu = Join-Path (Split-Path -Parent $PSCommandPath) 'Start-LlamaCpp.cmd'
            if (Test-Path -LiteralPath $menu -PathType Leaf) {
                Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', "set LLAMACPP_TEXT_MENU=1&& `"$menu`"")
            }
        }
        exit 0
    }

    # Record what the install looked like before a state-changing action runs, so
    # diagnostics, rollback forensics and future benchmarks have history. A failed
    # snapshot must never block the action itself.
    if (@('Activate', 'Install', 'Update', 'Uninstall', 'RemoveModel', 'Easy') -contains $Action) {
        [void](Save-StateSnapshot -Reason "before-$Action")
    }

    Start-RunLogging

    if ($Action -eq 'Dashboard') {
        Show-Dashboard
        Complete-RunLogging -Status 'completed'
        exit 0
    }

    if ($Action -eq 'Uninstall') {
        Remove-Installation
        Complete-RunLogging -Status 'completed'
        exit 0
    }

    $hardware = Get-HardwareProfile
    Write-RunLogEvent -Event 'hardware_detected' -Message 'Hardware profile detected.' -Data @{
        cpu = [string]$hardware.CpuName
        cores = $hardware.CpuCores
        threads = $hardware.CpuThreads
        ram_gib = $hardware.RamGiB
        max_amd_vram_gib = $hardware.MaxAmdVramGiB
        execution_mode = [string]$hardware.ExecutionMode
        profile = [string]$hardware.Profile
        has_amd_gpu = [bool]$hardware.HasAmdGpu
        has_integrated_gpu = [bool]$hardware.HasAmdIntegratedGpu
        vulkan_loader = [bool]$hardware.VulkanLoader
        recommended_model = [string](Get-RecommendedModel -Hardware $hardware).Id
    }
    if ($DryRun) {
        Show-HardwareAdvisor -Hardware $hardware
        Complete-RunLogging -Status 'completed'
        exit 0
    }

    switch ($Action) {
        'Advisor' { Show-HardwareAdvisor -Hardware $hardware }
        'Diagnostics' { Show-Diagnostics -Hardware $hardware }
        'VSCodeChat' {
            # Exit code 2 tells the batch menu the user cancelled and nothing changed.
            if (-not (Install-VsCodeChatEndpoint)) { Complete-RunLogging -Status 'cancelled'; exit 2 }
        }
        'ContinueConfig' {
            if (-not (Install-ContinueConfig)) { Complete-RunLogging -Status 'cancelled'; exit 2 }
        }
        'LlamaVscodeConfig' {
            if (-not (Install-LlamaVscodeSettings)) { Complete-RunLogging -Status 'cancelled'; exit 2 }
        }
        'Update' { [void](Ensure-LlamaCppInstalled -Hardware $hardware -RequestedBackend $Backend) }
        'Launch' { Start-ActiveServer -Hardware $hardware }
        'Monitor' { Show-LiveMonitor }
        'Benchmark' { [void](Invoke-ModelBenchmark) }
        'Easy' {
            if (-not (Invoke-EasyStart -Hardware $hardware)) { Complete-RunLogging -Status 'cancelled'; exit 2 }
        }
        'Preflight' {
            # Exit code 3 tells the batch menu that other apps are crowding graphics memory.
            if (Show-VramPreflight -Hardware $hardware) { Complete-RunLogging -Status 'completed'; exit 3 }
        }
        'IdleSleep' {
            # -IdleMinutes 0 turns idle unload off.
            if (-not (Set-IdleSleep -Minutes $IdleMinutes)) { Complete-RunLogging -Status 'cancelled'; exit 2 }
        }
        'Shortcuts' {
            $made = @(New-DesktopShortcuts)
            if ($made.Count -eq 0) { Write-WarnLine 'No shortcuts were added. Set up a model first so the launchers exist.'; Complete-RunLogging -Status 'cancelled'; exit 2 }
            Write-Success "Desktop shortcuts added: $($made -join ', ')"
        }
        'RemoveShortcuts' {
            $count = Remove-DesktopShortcuts
            Write-Success "Removed $count desktop shortcut(s) that this project created."
        }
        'RemoveModel' {
            $toRemove = if ($ModelId -ieq 'auto') { Select-ModelToRemove } else { Get-ModelById -Id $ModelId }
            if ($null -eq $toRemove -or -not (Remove-DownloadedModel -Model $toRemove)) { Complete-RunLogging -Status 'cancelled'; exit 2 }
        }
        'Activate' {
            if ($ModelId -ieq 'auto') { throw 'Choose a model with -ModelId, for example -ModelId qwen3.5-9b.' }
            Switch-InstalledModel -Model (Get-ModelById -Id $ModelId) -Hardware $hardware
        }
        'Install' {
            $tag = Ensure-LlamaCppInstalled -Hardware $hardware -RequestedBackend $Backend
            if ($null -eq $tag) {
                Complete-RunLogging -Status 'cancelled'
                exit 2
            }
            if (-not $SkipModel) {
                $model = if ($ModelId -ieq 'auto') { Get-RecommendedModel -Hardware $hardware } else { Get-ModelById -Id $ModelId }
                if (Confirm-ModelDownload -Model $model -Hardware $hardware) {
                    Install-Model -Model $model -Hardware $hardware
                } else {
                    Write-WarnLine 'Model download cancelled.'
                }
            }
            Write-Success "llama.cpp $tag is ready."
        }
        'Models' {
            $model = if ($ModelId -ieq 'auto') { Select-ModelInteractively -Hardware $hardware } else { Get-ModelById -Id $ModelId }
            if ($null -ne $model) {
                if (-not (Test-Path -LiteralPath (Get-RuntimeExecutablePath))) {
                    if ($null -eq (Ensure-LlamaCppInstalled -Hardware $hardware -RequestedBackend $Backend)) {
                        Complete-RunLogging -Status 'cancelled'
                        exit 2
                    }
                }
                if (Confirm-ModelDownload -Model $model -Hardware $hardware) {
                    Install-Model -Model $model -Hardware $hardware
                }
            }
        }
    }
    Complete-RunLogging -Status 'completed'
    exit 0
} catch {
    Write-RunLogEvent -Event 'error' -Message $_.Exception.Message
    Write-Host "`n  COMMAND FAILED: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.Exception.Message -match '(?i)driver|vulkan') {
        Write-Host '  Install the current AMD Adrenalin driver from https://www.amd.com/en/support and reboot.' -ForegroundColor Yellow
    }
    Complete-RunLogging -Status 'failed' -Message $_.Exception.Message
    exit 1
}
