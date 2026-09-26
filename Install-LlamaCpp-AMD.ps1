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
    Research sources checked 2026-09-24:
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
#>

[CmdletBinding()]
param(
    [ValidateSet('Dashboard', 'Install', 'Advisor', 'Models', 'Launch', 'Update', 'Diagnostics', 'VSCodeChat', 'Uninstall', 'ViewLog', 'Status', 'SelfTest', 'Monitor', 'CheckUpdate', 'ContinueConfig', 'LlamaVscodeConfig', 'ListInstalled', 'Activate')]
    [string] $Action = 'Dashboard',
    [string] $InstallRoot = (Join-Path $env:LOCALAPPDATA 'Programs\llama.cpp'),
    [string] $ModelId = 'auto',
    [ValidateSet('Auto', 'Vulkan', 'ROCm')]
    [string] $Backend = 'Auto',
    [ValidateRange(0, 262144)]
    [int] $ContextSize = 0,
    [ValidateRange(1, 65535)]
    [int] $Port = 8080,
    [ValidateSet('Auto', 'On', 'Off')]
    [string] $Thinking = 'Auto',
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

$script:CommandCenterVersion = '0.1.5'
$script:CommandCenterRepo = 'theantipopau/llamacpp-amd-command-center'
$script:GitHubApi = 'https://api.github.com/repos/ggml-org/llama.cpp/releases'
$script:GitHubHeaders = @{
    Accept = 'application/vnd.github+json'
    'User-Agent' = 'Freebuff-llama.cpp-command-center'
    'X-GitHub-Api-Version' = '2022-11-28'
}
$script:HfApi = 'https://huggingface.co/api/models'
# Two server slots share one KV pool sized for two full conversations. VS Code sends
# a compaction/summary request while an Agent turn is still running; with a pool
# only one conversation deep, both fail with "Context size has been exceeded" (500).
$script:ServerSlots = 2
$script:HfRepositoryCache = @{}
$script:AmdRocmPackageUrl = 'https://repo.radeon.com/rocm/llama.cpp/windows/rocm-rel-7.2.1/llama-b8407-windows-rocm-7.2.1-gfx110X-gfx115X-gfx120X-x64.zip'
$script:AmdRocmPackageName = 'llama-b8407-windows-rocm-7.2.1-gfx110X-gfx115X-gfx120X-x64.zip'
$script:AmdRocmPackageSize = 565651083L
$script:AmdRocmPage = 'https://rocm.docs.amd.com/projects/radeon-ryzen/en/latest/docs/advanced/advancedrad/windows/llm/llamacpp.html'
# Recorded the day this ROCm package/version was last hand-checked against AMD's page
# (see the research date in this script's .NOTES). Freshness is time-based only: no
# scraping of AMD's page, so it never depends on a page layout that can change.
$script:AmdRocmPackageCheckedOn = [DateTime]::new(2026, 9, 24)
$script:AmdRocmPackageFreshnessDays = 120

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
    Write-Host "`n  ║ " -NoNewline -ForegroundColor DarkCyan
    Write-Host $Message -ForegroundColor Cyan
}

function Write-Info {
    param([string] $Message)
    Write-RunLogEvent -Event 'info' -Message $Message
    Write-Host "  ║ " -NoNewline -ForegroundColor DarkGray
    Write-Host $Message -ForegroundColor Gray
}

function Write-Success {
    param([string] $Message)
    Write-RunLogEvent -Event 'success' -Message $Message
    Write-Host "  ║ " -NoNewline -ForegroundColor DarkGreen
    Write-Host $Message -ForegroundColor Green
}

function Write-WarnLine {
    param([string] $Message)
    Write-RunLogEvent -Event 'warning' -Message $Message
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
    @(
        [pscustomobject]@{
            Id = 'qwen3.8-27b'; Name = 'Qwen3.8 27B'; Alias = 'qwen3.8:latest'
            Repo = 'ggml-org/Qwen3.8-27B-GGUF'; File = 'Qwen3.8-27B-Q4_K_M.gguf'
            Projector = 'mmproj-Qwen3.8-27B-Q8_0.gguf'; ApproxGiB = 18.25; Rank = 100
            Tag = 'BEST QUALITY'; Description = 'Flagship reasoning, coding, tools, vision and video. Ollama qwen3.8:latest equivalent.'
            Reasoning = $true; Vision = $true; Tools = $true
        },
        [pscustomobject]@{
            Id = 'qwen3.5-9b'; Name = 'Qwen3.5 9B'; Alias = 'qwen3.5:9b'
            Repo = 'unsloth/Qwen3.5-9B-GGUF'; File = 'Qwen3.5-9B-Q4_K_M.gguf'
            Projector = 'mmproj-F16.gguf'; ApproxGiB = 6.20; Rank = 96; KvGiBPer32k = 0.75
            Tag = 'FAST AGENT'; Description = 'Fast 9B reasoning and coding model with vision and tool support; designed for responsive local VS Code agents.'
            Reasoning = $true; Vision = $true; Tools = $true
        },
        [pscustomobject]@{
            Id = 'ornith-1.5-9b'; Name = 'Ornith 1.5 9B'; Alias = 'ornith:1.5-9b'
            Repo = 'ornith-ai/Ornith-1.5-9B-GGUF'; File = 'Ornith-1.5-9B-Q4_K_M.gguf'
            Projector = 'mmproj-Ornith-1.5-9B-BF16.gguf'; ApproxGiB = 6.20; Rank = 95; KvGiBPer32k = 0.75
            Tag = 'COMMUNITY / EXPERIMENTAL'; NeedsMtpLoader = $true
            Description = 'Community coding/reasoning fine-tune of Qwen3.5 9B (MIT). Publisher-reported improvements over base Qwen3.5 9B are not independently verified here; same VRAM and context profile, so it drops in as an A/B option. Needs the Vulkan backend (AMD''s ROCm 7.2.1 package cannot load it), and Vulkan lost the GPU in long sessions on an RX 9070 XT.'
            Reasoning = $true; Vision = $true; Tools = $true
        },
        [pscustomobject]@{
            Id = 'gemma3-12b'; Name = 'Gemma 3 12B Vision'; Alias = 'gemma3:12b'
            Repo = 'ggml-org/gemma-3-12b-it-GGUF'; File = 'gemma-3-12b-it-Q4_K_M.gguf'
            Projector = 'mmproj-model-f16.gguf'; ApproxGiB = 7.60; Rank = 92
            Tag = 'VISION'; Description = 'Strong general assistant and image understanding with a balanced memory footprint.'
            Reasoning = $false; Vision = $true; Tools = $false
        },
        [pscustomobject]@{
            Id = 'qwen3-8b'; Name = 'Qwen3 8B'; Alias = 'qwen3:8b'
            Repo = 'ggml-org/Qwen3-8B-GGUF'; File = 'Qwen3-8B-Q8_0.gguf'
            Projector = $null; ApproxGiB = 8.10; Rank = 88
            Tag = 'REASONING'; Description = 'High-quality Q8 reasoning and tool use; excellent quality per byte on modern Ryzen CPUs.'
            Reasoning = $true; Vision = $false; Tools = $true
        },
        [pscustomobject]@{
            Id = 'llama3.1-8b'; Name = 'Llama 3.1 8B'; Alias = 'llama3.1:8b'
            Repo = 'ggml-org/Meta-Llama-3.1-8B-Instruct-Q4_0-GGUF'; File = 'meta-llama-3.1-8b-instruct-q4_0.gguf'
            Projector = $null; ApproxGiB = 5.62; Rank = 82
            Tag = 'GENERAL'; Description = 'Proven general-purpose instruct model with broad ecosystem support and modest memory use.'
            Reasoning = $false; Vision = $false; Tools = $true
        },
        [pscustomobject]@{
            Id = 'gemma3-4b'; Name = 'Gemma 3 4B Vision'; Alias = 'gemma3:4b'
            Repo = 'ggml-org/gemma-3-4b-it-GGUF'; File = 'gemma-3-4b-it-Q4_K_M.gguf'
            Projector = 'mmproj-model-f16.gguf'; ApproxGiB = 3.11; Rank = 70
            Tag = 'VISION'; Description = 'Compact multimodal model for 8 GB systems; fast on Ryzen integrated graphics.'
            Reasoning = $false; Vision = $true; Tools = $false
        },
        [pscustomobject]@{
            Id = 'qwen3-4b'; Name = 'Qwen3 4B'; Alias = 'qwen3:4b'
            Repo = 'ggml-org/Qwen3-4B-GGUF'; File = 'Qwen3-4B-Q4_K_M.gguf'
            Projector = $null; ApproxGiB = 2.33; Rank = 68
            Tag = 'FASTEST'; Description = 'Small, fast reasoning and tool-use model; ideal for 8–16 GB systems and CPU fallback.'
            Reasoning = $true; Vision = $false; Tools = $true
        }
    )
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
            if ($vram -le 0) { $vram = [Math]::Round(([double]$_.AdapterRAM / 1GB), 1) }
            [pscustomobject]@{
                Name = $name; IsAmd = $isAmd; IsIntegrated = $isIntegrated
                VramGiB = [Math]::Round($vram, 1)
                SharedGiB = if ($isIntegrated) { [Math]::Round(([double]$system.TotalPhysicalMemory / 1GB), 1) } else { 0 }
                Driver = [string]$_.DriverVersion
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
    $rocmRecommendedGpu = @($amdGpus | Where-Object {
        $_.Name -match '(?i)RX\s*9070(\s*XT)?|RX\s*9060\s*XT|RX\s*7900\s*XTX|Radeon\s*PRO\s*W7900|RX\s*7700'
    }) | Select-Object -First 1
    $rocmRecommended = ($null -ne $rocmRecommendedGpu) -and (-not $rocmRecommendedGpu.IsIntegrated)
    $rocmReason = if ($rocmRecommended) {
        'AMD Windows ROCm 7.2.1 compatibility matrix lists this Radeon dGPU (gfx120X/gfx110X/gfx115X family).'
    } elseif ($amdIntegrated) {
        'Ryzen iGPU/UMA systems use Vulkan by default; AMD Windows ROCm support is hardware-specific.'
    } else {
        'This Radeon is not in the current AMD Windows ROCm matrix; Vulkan is the portable fallback.'
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

    return [pscustomobject]@{
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

function Get-ModelById {
    param([string] $Id)
    $found = @(Get-ModelCatalog | Where-Object { $_.Id -ieq $Id })
    if ($found.Count -eq 0) { throw "Unknown model id '$Id'. Run the model browser to see valid choices." }
    return $found[0]
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

function Get-VerifiedDownload {
    param(
        [string] $Url,
        [string] $Destination,
        [long] $ExpectedSize,
        [string] $ExpectedSha256
    )

    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        $existing = Get-Item -LiteralPath $Destination
        if ($existing.Length -eq $ExpectedSize) {
            if ([string]::IsNullOrWhiteSpace($ExpectedSha256)) {
                Write-Step "Checking existing $([IO.Path]::GetFileName($Destination))"
                Write-Success 'Existing AMD package size matches.'
                return
            }
            Write-Step "Verifying existing $([IO.Path]::GetFileName($Destination))"
            if (Test-FileDigest -Path $Destination -ExpectedSha256 $ExpectedSha256) {
                Write-Success 'Already installed and verified.'
                return
            }
            Write-WarnLine 'Checksum mismatch; the managed copy will be downloaded again.'
            Remove-Item -LiteralPath $Destination -Force
        } else {
            Write-WarnLine 'File size mismatch; the managed copy will be downloaded again.'
            Remove-Item -LiteralPath $Destination -Force
        }
    }

    $partial = "$Destination.part"
    if (Test-Path -LiteralPath $partial) {
        if ((Get-Item -LiteralPath $partial).Length -gt $ExpectedSize) {
            Remove-Item -LiteralPath $partial -Force
        }
    }

    Write-Step "Downloading $([IO.Path]::GetFileName($Destination))  ($([Math]::Round($ExpectedSize / 1GB, 2)) GiB)"
    Write-Info $Url
    $curlArgs = @(
        '--location', '--fail', '--show-error', '--retry', '8', '--retry-all-errors',
        '--retry-delay', '3', '--continue-at', '-', '--output', $partial, $Url
    )
    & curl.exe @curlArgs
    if ($LASTEXITCODE -ne 0) {
        throw "curl failed with exit code $LASTEXITCODE. The .part file was kept; rerun to resume."
    }

    $actualSize = (Get-Item -LiteralPath $partial).Length
    if ($actualSize -ne $ExpectedSize) {
        throw "Size verification failed: expected $ExpectedSize bytes, received $actualSize."
    }
    Write-Step "SHA-256 verification: $([IO.Path]::GetFileName($Destination))"
    if ([string]::IsNullOrWhiteSpace($ExpectedSha256)) {
        Write-WarnLine 'AMD does not publish a SHA-256 sidecar for this package; recording the downloaded hash locally.'
        $localHash = (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash.ToLowerInvariant()
        Move-Item -LiteralPath $partial -Destination $Destination -Force
        Set-Content -LiteralPath "$Destination.sha256" -Value "$localHash  $([IO.Path]::GetFileName($Destination))" -Encoding ASCII
        Write-Success "Downloaded from AMD's official repository. Recorded SHA-256: $localHash"
        return
    }
    if (-not (Test-FileDigest -Path $partial -ExpectedSha256 $ExpectedSha256)) {
        throw "SHA-256 verification failed for $([IO.Path]::GetFileName($Destination))."
    }
    Move-Item -LiteralPath $partial -Destination $Destination -Force
    Write-Success 'Verified successfully.'
}

function Get-HfRepository {
    param([string] $Repo)
    $cacheKey = $Repo.ToLowerInvariant()
    if ($script:HfRepositoryCache.ContainsKey($cacheKey)) { return $script:HfRepositoryCache[$cacheKey] }
    $modelInfo = Invoke-RestMethod -Uri ($script:HfApi + '/' + $Repo) -Headers @{ 'User-Agent' = 'Freebuff-llama.cpp-command-center' }
    $revision = [string]$modelInfo.sha
    $tree = Invoke-RestMethod -Uri ($script:HfApi + '/' + $Repo + '/tree/' + $revision + '?recursive=true&expand=true') -Headers @{ 'User-Agent' = 'Freebuff-llama.cpp-command-center' }
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
    return [pscustomobject]@{
        Release = [pscustomobject]@{
            tag_name = 'rocm-7.2.1-b8407'
            html_url = $script:AmdRocmPage
        }
        Asset = [pscustomobject]@{
            name = $script:AmdRocmPackageName
            browser_download_url = $script:AmdRocmPackageUrl
            size = $script:AmdRocmPackageSize
            digest = ''
            officialUnverified = $true
        }
    }
}

function Get-LatestLlamaCppVulkanAsset {
    Write-Step 'Resolving the latest official llama.cpp Windows Vulkan release'
    $stable = Invoke-RestMethod -Uri ($script:GitHubApi + '/latest') -Headers $script:GitHubHeaders
    $asset = @($stable.assets | Where-Object {
        $_.name -match '^llama-.*-bin-win-vulkan-x64\.zip$' -and $_.name -notmatch '^cudart-'
    }) | Select-Object -First 1

    if ($null -ne $asset) {
        Write-Info "Stable $($stable.tag_name) / $($asset.name)"
        return [pscustomobject]@{ Release = $stable; Asset = $asset }
    }

    $tagAsset = @($stable.assets | Where-Object { $_.name -eq 'nightly-tag.txt' }) | Select-Object -First 1
    if ($null -eq $tagAsset) { throw 'The latest llama.cpp release exposes no Windows Vulkan build or nightly tag.' }
    $tagResponse = Invoke-WebRequest -Uri $tagAsset.browser_download_url -UseBasicParsing
    if ($tagResponse.Content -is [byte[]]) {
        $tag = [Text.Encoding]::UTF8.GetString($tagResponse.Content).Trim()
    } else {
        $tag = ([string]$tagResponse.Content).Trim()
    }
    if ($tag -notmatch '^b[0-9]+$') { throw "Malformed llama.cpp nightly tag: '$tag'." }
    $build = Invoke-RestMethod -Uri ($script:GitHubApi + '/tags/' + $tag) -Headers $script:GitHubHeaders
    $asset = @($build.assets | Where-Object {
        $_.name -match '^llama-.*-bin-win-vulkan-x64\.zip$' -and $_.name -notmatch '^cudart-'
    }) | Select-Object -First 1
    if ($null -eq $asset) { throw "llama.cpp build $tag has no Windows x64 Vulkan ZIP." }
    Write-Info "Selected $tag / $($asset.name)"
    return [pscustomobject]@{ Release = $build; Asset = $asset }
}

function Ensure-LlamaCppInstalled {
    param($Hardware, [ValidateSet('Auto', 'Vulkan', 'ROCm')] [string] $RequestedBackend = 'Auto')
    Assert-HardwareForLlama -Hardware $Hardware
    $running = Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue
    if ($null -ne $running) { throw 'Close every running llama-server.exe process before installing or updating.' }

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
    $stage = Join-Path $InstallRoot '.current-new'
    $current = Join-Path $InstallRoot 'current'
    $backup = Join-Path $InstallRoot ('.backup-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $downloadRoot -Force | Out-Null

    if (-not $Force) {
        $sizeGiB = [Math]::Round(([double]$asset.size / 1GB), 2)
        $sourceHost = ([Uri][string]$asset.browser_download_url).Host
        Write-Host "`n  About to download llama.cpp ($backendChoice build $tag, ~$sizeGiB GiB) from $sourceHost." -ForegroundColor Yellow
        Write-Host "  It is installed to $current. Downloaded models are kept." -ForegroundColor DarkGray
        if ((Read-ConsoleLine -Prompt '  Type YES to continue') -ine 'YES') {
            Write-WarnLine 'llama.cpp download cancelled. Nothing was downloaded.'
            return $null
        }
    }

    Get-VerifiedDownload -Url $asset.browser_download_url -Destination $archive -ExpectedSize ([long]$asset.size) -ExpectedSha256 $digest
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
            sha256 = $digest; installed_at = (Get-Date).ToUniversalTime().ToString('o'); backend = $backendChoice
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stage 'installation.json') -Encoding UTF8

        if (Test-Path -LiteralPath $current) { Move-Item -LiteralPath $current -Destination $backup }
        try {
            Move-Item -LiteralPath $stage -Destination $current
        } catch {
            if ((Test-Path -LiteralPath $backup) -and -not (Test-Path -LiteralPath $current)) {
                Move-Item -LiteralPath $backup -Destination $current
            }
            throw
        }
        if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Recurse -Force }
    } finally {
        if (Test-Path -LiteralPath $extract) { Remove-Item -LiteralPath $extract -Recurse -Force }
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    }

    if (-not $NoPath) { Add-UserPathEntry -Directory $current }
    Write-Success "llama.cpp $tag is installed and the $backendChoice backend is ready."
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

function Select-PrimaryLlamaDevice {
    param($Devices)
    # Only the dedicated Radeon. A Ryzen iGPU also appears under Vulkan with a large
    # shared-memory figure; letting llama.cpp split layers onto it is slow, and its long
    # kernels can trip the Windows 2 s GPU timeout (bugcheck 0x116 on a test PC).
    $all = @($Devices)
    $dedicated = @($all | Where-Object { -not $_.Integrated } | Sort-Object MiB -Descending)
    if ($all.Count -le 1 -or $dedicated.Count -eq 0) { return '' }
    return [string]$dedicated[0].Id
}

function Get-PrimaryLlamaDevice {
    $exe = Join-Path (Join-Path $InstallRoot 'current') 'llama-server.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { return '' }
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
    return Select-PrimaryLlamaDevice -Devices (ConvertFrom-LlamaDeviceList -Lines $lines)
}

function Get-ServerArguments {
    param($ActiveModel, [int] $EffectiveContext, [string] $Device = '')
    # Single source of truth for both the generated launcher and Start-ActiveServer.
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
        '--ctx-size', [string]($EffectiveContext * $script:ServerSlots),
        '--flash-attn', 'on',
        '--cache-type-k', 'q8_0',
        '--cache-type-v', 'q8_0',
        '--jinja'
    )
    if (-not [string]::IsNullOrWhiteSpace($Device)) { $arguments += @('--device', $Device) }
    if (Test-ThinkingEnabled -ActiveModel $ActiveModel) {
        $arguments += @('--reasoning', 'on', '--reasoning-format', 'deepseek', '--reasoning-budget', '2048')
    } elseif ([bool]$ActiveModel.reasoning) {
        # Qwen reasoning models often place the tool call inside the thinking block;
        # the server then returns it as reasoning with no content and no tool_calls,
        # and VS Code reports "Sorry, no response was returned".
        $arguments += @('--reasoning', 'off')
    }
    $arguments += '--metrics'
    return ,(Merge-ServerArguments -Base $arguments -Overrides (Get-UserServerArgOverrides))
}

function Test-ThinkingEnabled {
    param($ActiveModel)
    if ($ActiveModel.PSObject.Properties.Name -contains 'thinking') { return [bool]$ActiveModel.thinking }
    if ($ActiveModel -is [System.Collections.IDictionary] -and $ActiveModel.Contains('thinking')) { return [bool]$ActiveModel['thinking'] }
    # Older active-model.json files predate the setting: keep thinking only for non-tool models.
    $tools = if ($ActiveModel.PSObject.Properties.Name -contains 'tool_calling') { [bool]$ActiveModel.tool_calling } else { $false }
    return ([bool]$ActiveModel.reasoning -and -not $tools)
}

function New-Launchers {
    param($ActiveModel, $EffectiveContext)
    $current = Join-Path $InstallRoot 'current'

    # Pair each flag with its value on one line. Every line except the last ends
    # with a caret; a blank line inside a caret continuation would split the
    # command, so optional arguments must never leave an empty line behind.
    $serverArgs = Get-ServerArguments -ActiveModel $ActiveModel -EffectiveContext $EffectiveContext -Device (Get-PrimaryLlamaDevice)
    $lines = @()
    for ($i = 0; $i -lt $serverArgs.Count; $i++) {
        $line = $serverArgs[$i]
        if (($i + 1) -lt $serverArgs.Count -and -not $serverArgs[$i + 1].StartsWith('--')) {
            $value = $serverArgs[$i + 1]
            if ($value -match '[\s\\]') { $value = "`"$value`"" }
            $line = "$line $value"
            $i++
        }
        $lines += "  $line"
    }
    $argumentBlock = $lines -join " ^`r`n"

    $start = @"
@echo off
setlocal
title llama.cpp - $($ActiveModel.name) - AMD backend
pushd "$current"
"$current\llama-server.exe" ^
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
pushd "$current"
"$current\llama-server.exe" --list-devices
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

    if ($ActiveModel.Id -eq 'qwen3.8-27b') {
        Copy-Item -LiteralPath (Join-Path $InstallRoot 'Start-LlamaCpp.cmd') -Destination (Join-Path $InstallRoot 'Start-Qwen3.8.cmd') -Force
    }

    $uninstallPs = @'
param([switch] $Force)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$current = Join-Path $root 'current'
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not [string]::IsNullOrWhiteSpace($userPath)) {
    $kept = @($userPath -split ';' | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_) -and $_.Trim().TrimEnd('\') -ine $current.Trim().TrimEnd('\')
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
        $mmprojPath = Join-Path $modelsRoot $Model.Projector
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

function Get-InstalledRuntime {
    $path = Join-Path $InstallRoot 'current\installation.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } catch { return $null }
}

function Get-ModelRuntimeBlocker {
    param($Model, $Runtime)
    # Ornith's GGUF carries a trailing MTP (nextn) block. Current llama.cpp skips it;
    # AMD's ROCm 7.2.1 package (b8407) predates that and fails with
    # "missing tensor 'blk.32.ssm_conv1d.weight'" (verified on an RX 9070 XT).
    $needsMtp = ($Model.PSObject.Properties.Name -contains 'NeedsMtpLoader') -and [bool]$Model.NeedsMtpLoader
    if (-not $needsMtp -or $null -eq $Runtime) { return '' }
    if ([string]$Runtime.backend -eq 'ROCm' -and [string]$Runtime.tag -match 'b8407') {
        return "$($Model.Name) needs a newer llama.cpp than AMD's ROCm 7.2.1 package (b8407) provides. Switch to the Vulkan backend ([8], then [5] to update) to use it."
    }
    return ''
}

function Get-InstalledModels {
    # Catalog models whose files are already downloaded. Local only: no network, no hashing.
    $modelsRoot = Join-Path $InstallRoot 'models'
    return @(Get-ModelCatalog | Where-Object {
        (Test-Path -LiteralPath (Join-Path $modelsRoot $_.File) -PathType Leaf) -and
        ([string]::IsNullOrWhiteSpace([string]$_.Projector) -or (Test-Path -LiteralPath (Join-Path $modelsRoot $_.Projector) -PathType Leaf))
    })
}

function Get-InstalledModelList {
    # One line per downloaded model for the batch menu: number|id|name|state.
    # state: active, blocked (cannot run on the installed llama.cpp build) or ready.
    $active = Get-ActiveModel
    $activeId = if ($null -ne $active) { [string]$active.id } else { '' }
    $runtime = Get-InstalledRuntime
    $lines = @()
    $number = 0
    foreach ($model in (Get-InstalledModels)) {
        $number++
        $state = 'ready'
        if (Get-ModelRuntimeBlocker -Model $model -Runtime $runtime) { $state = 'blocked' }
        elseif ($model.Id -eq $activeId) { $state = 'active' }
        $lines += "$number|$($model.Id)|$($model.Name)|$state"
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
    Sync-VsCodeChatEndpoint
}

function Resolve-BackendChoice {
    param([string] $RequestedBackend, $Hardware, $Runtime)
    if ($RequestedBackend -ne 'Auto') { return $RequestedBackend }
    # Auto keeps the backend already installed, so an update never silently swaps a
    # working choice (for example Vulkan picked for Ornith) back to the recommendation.
    if ($null -ne $Runtime -and @('ROCm', 'Vulkan') -contains [string]$Runtime.backend) { return [string]$Runtime.backend }
    if ($Hardware.RocmRecommended) { return 'ROCm' }
    return 'Vulkan'
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
        Get-VerifiedDownload -Url $projector.Url -Destination (Join-Path $modelsRoot $Model.Projector) -ExpectedSize $projector.Size -ExpectedSha256 $projector.Sha256
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
    if ($Force) { return $true }
    $assessment = @(Get-ModelAssessment -Hardware $Hardware | Where-Object { $_.Model.Id -eq $Model.Id }) | Select-Object -First 1
    $status = if ($null -eq $assessment) { 'UNKNOWN' } else { $assessment.Status }
    $modelsRoot = Join-Path $InstallRoot 'models'
    $modelPath = Join-Path $modelsRoot $Model.File
    $projectorPath = if ([string]::IsNullOrWhiteSpace([string]$Model.Projector)) { '' } else { Join-Path $modelsRoot $Model.Projector }
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
    $server = Join-Path (Join-Path $InstallRoot 'current') 'llama-server.exe'
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
    $freshness = Get-RocmPackageFreshness
    if ($freshness.Stale) {
        Write-WarnLine "The pinned ROCm package was last hand-checked $($freshness.AgeDays) days ago ($($freshness.CheckedOn.ToString('yyyy-MM-dd'))). Check $script:AmdRocmPage for a newer validated Windows package."
    }
    $server = Join-Path (Join-Path $InstallRoot 'current') 'llama-server.exe'
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

function Start-ActiveServer {
    param($Hardware)
    $server = Join-Path (Join-Path $InstallRoot 'current') 'llama-server.exe'
    if (-not (Test-Path -LiteralPath $server -PathType Leaf)) { throw 'llama.cpp is not installed. Run the installer first.' }
    $active = Get-ActiveModel
    if ($null -eq $active) { throw 'No model is active. Use the model browser to install and activate one.' }
    if (-not (Test-Path -LiteralPath ([string]$active.model_path) -PathType Leaf)) { throw 'The active model file is missing. Reinstall it from the model browser.' }
    Write-RunLogEvent -Event 'server_start' -Message "Starting active model: $($active.name)" -Data @{
        model_id = [string]$active.id
        alias = [string]$active.alias
        context_size = [int]$active.context_size
        port = $Port
    }

    $context = if ($ContextSize -gt 0) { $ContextSize } else { [int]$active.context_size }
    $arguments = Get-ServerArguments -ActiveModel $active -EffectiveContext $context -Device (Get-PrimaryLlamaDevice)

    Clear-Screen
    Show-Banner
    Write-Host "  STARTING $($active.name)" -ForegroundColor Green
    Write-Info "Context: $context | API/Web UI: http://127.0.0.1:$Port/"
    Write-Info 'Open Open-WebUI.cmd in another terminal or paste the URL after startup.'
    Write-Info 'Press Ctrl+C in this terminal to stop the server.'
    Push-Location (Split-Path -Parent $server)
    try { & $server @arguments } finally { Pop-Location }
}

function Get-CommandCenterStatus {
    # One pipe-separated line for the batch menu: alias|name|context|server|vscode
    # server: running, loading (process up, model not ready) or stopped.
    # vscode: yes (active model configured), stale (other model configured) or no.
    $active = Get-ActiveModel
    # '-' marks an empty field: cmd's for /f collapses consecutive delimiters.
    $alias = '-'; $name = '-'; $context = '-'
    if ($null -ne $active) { $alias = [string]$active.alias; $name = [string]$active.name; $context = [string]$active.context_size }

    $server = 'stopped'
    if ($null -ne (Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue)) {
        $server = 'loading'
        try {
            if ((Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 2).status -eq 'ok') { $server = 'running' }
        } catch { }
    }

    $vscode = 'no'
    $configPath = Join-Path $env:APPDATA 'Code\User\chatLanguageModels.json'
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        try {
            $parsed = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
            $local = @($parsed | Where-Object { $null -ne $_ -and $_.name -eq 'llama.cpp local' } | Select-Object -First 1)
            if ($local.Count -gt 0) {
                $ids = @($local[0].models | ForEach-Object { $_.id })
                $vscode = if ($ids -contains $alias) { 'yes' } else { 'stale' }
            }
        } catch { }
    }
    return "$alias|$name|$context|$server|$vscode"
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
    Remove-UserPathEntry -Directory (Join-Path $InstallRoot 'current')
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
        $installInfo = Join-Path $InstallRoot 'current\installation.json'
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
    Write-Host '  [0] Return' -ForegroundColor DarkGray
    $choice = Read-ConsoleLine -Prompt '  Select backend'
    if ($choice -eq '1') { $script:Backend = 'Auto'; Write-Success 'Backend set to Auto.' }
    elseif ($choice -eq '2') { $script:Backend = 'Vulkan'; Write-Success 'Backend set to Vulkan.' }
    elseif ($choice -eq '3') { $script:Backend = 'ROCm'; Write-WarnLine 'ROCm selected. Installation will stop if the Radeon is not in AMD Windows matrix.' }
}

function Show-Dashboard {
    $updateCheck = Test-CommandCenterUpdate
    while ($true) {
        $hardware = Get-HardwareProfile
        $recommended = Get-RecommendedModel -Hardware $hardware
        $runtime = Get-InstalledRuntime
        $backendLabel = if ($null -ne $runtime) { "$($runtime.backend) $($runtime.tag)" } elseif ($Backend -eq 'Auto') { if ($hardware.RocmRecommended) { 'AMD ROCm 7.2.1' } else { 'Vulkan' } } else { $Backend }
        $assessment = @(Get-ModelAssessment -Hardware $hardware | Where-Object { $_.Model.Id -eq $recommended.Id } | Select-Object -First 1)
        $active = Get-ActiveModel
        $installed = Test-Path -LiteralPath (Join-Path (Join-Path $InstallRoot 'current') 'llama-server.exe')
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
        Write-Host '   [8]  ⚡ Backend selector — ROCm / Vulkan' -ForegroundColor White
        Write-Host '   [9]  📄 View latest run log' -ForegroundColor White
        Write-Host '   [10] 📡 Live monitor — health, speed, and context in real time' -ForegroundColor White
        Write-Host '   [0]  Exit' -ForegroundColor DarkGray
        Write-Host '  ═══════════════════════════════════════════════════════════════════════════════════' -ForegroundColor DarkCyan

        $choice = Read-ConsoleLine -Prompt '  Select'
        Write-RunLogEvent -Event 'menu_choice' -Message "Dashboard selection: $choice"
        try {
            switch ($choice) {
                '1' {
                    if (Test-Path -LiteralPath (Join-Path (Join-Path $InstallRoot 'current') 'llama-server.exe')) {
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
                        if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $InstallRoot 'current') 'llama-server.exe'))) {
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
                if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $InstallRoot 'current') 'llama-server.exe'))) {
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
