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
    [ValidateSet('Dashboard', 'Install', 'Advisor', 'Models', 'Launch', 'Update', 'Diagnostics', 'Uninstall')]
    [string] $Action = 'Dashboard',
    [string] $InstallRoot = (Join-Path $env:LOCALAPPDATA 'Programs\llama.cpp'),
    [string] $ModelId = 'auto',
    [ValidateSet('Auto', 'Vulkan', 'ROCm')]
    [string] $Backend = 'Auto',
    [ValidateRange(0, 262144)]
    [int] $ContextSize = 0,
    [ValidateRange(1, 65535)]
    [int] $Port = 8080,
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

$script:GitHubApi = 'https://api.github.com/repos/ggml-org/llama.cpp/releases'
$script:GitHubHeaders = @{
    Accept = 'application/vnd.github+json'
    'User-Agent' = 'Freebuff-llama.cpp-command-center'
    'X-GitHub-Api-Version' = '2022-11-28'
}
$script:HfApi = 'https://huggingface.co/api/models'
$script:HfRepositoryCache = @{}
$script:AmdRocmPackageUrl = 'https://repo.radeon.com/rocm/llama.cpp/windows/rocm-rel-7.2.1/llama-b8407-windows-rocm-7.2.1-gfx110X-gfx115X-gfx120X-x64.zip'
$script:AmdRocmPackageName = 'llama-b8407-windows-rocm-7.2.1-gfx110X-gfx115X-gfx120X-x64.zip'
$script:AmdRocmPackageSize = 565651083L
$script:AmdRocmPage = 'https://rocm.docs.amd.com/projects/radeon-ryzen/en/latest/docs/advanced/advancedrad/windows/llm/llamacpp.html'

# ---------------------------------------------------------------------
# Visual terminal helpers
# ---------------------------------------------------------------------

function Clear-Screen {
    try { Clear-Host } catch { }
}

function Write-Step {
    param([string] $Message)
    Write-Host "`n  ║ " -NoNewline -ForegroundColor DarkCyan
    Write-Host $Message -ForegroundColor Cyan
}

function Write-Info {
    param([string] $Message)
    Write-Host "  ║ " -NoNewline -ForegroundColor DarkGray
    Write-Host $Message -ForegroundColor Gray
}

function Write-Success {
    param([string] $Message)
    Write-Host "  ║ " -NoNewline -ForegroundColor DarkGreen
    Write-Host $Message -ForegroundColor Green
}

function Write-WarnLine {
    param([string] $Message)
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
    Write-Host '  ╔══════════════════════════════════════════════════════════════════════════════╗' -ForegroundColor DarkCyan
    Write-Host '  ║  ' -NoNewline -ForegroundColor DarkCyan
    Write-Host 'LLAMA.CPP' -NoNewline -ForegroundColor White
    Write-Host ' // ' -NoNewline -ForegroundColor DarkGray
    Write-Host 'AMD COMMAND CENTER' -NoNewline -ForegroundColor Magenta
    Write-Host '                                      LOCAL • PRIVATE • GPU+CPU  ║' -ForegroundColor DarkCyan
    Write-Host '  ╚══════════════════════════════════════════════════════════════════════════════╝' -ForegroundColor DarkCyan
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
            Reasoning = $true; Vision = $true
        },
        [pscustomobject]@{
            Id = 'gemma3-12b'; Name = 'Gemma 3 12B Vision'; Alias = 'gemma3:12b'
            Repo = 'ggml-org/gemma-3-12b-it-GGUF'; File = 'gemma-3-12b-it-Q4_K_M.gguf'
            Projector = 'mmproj-model-f16.gguf'; ApproxGiB = 7.60; Rank = 92
            Tag = 'VISION'; Description = 'Strong general assistant and image understanding with a balanced memory footprint.'
            Reasoning = $false; Vision = $true
        },
        [pscustomobject]@{
            Id = 'qwen3-8b'; Name = 'Qwen3 8B'; Alias = 'qwen3:8b'
            Repo = 'ggml-org/Qwen3-8B-GGUF'; File = 'Qwen3-8B-Q8_0.gguf'
            Projector = $null; ApproxGiB = 8.10; Rank = 88
            Tag = 'REASONING'; Description = 'High-quality Q8 reasoning and tool use; excellent quality per byte on modern Ryzen CPUs.'
            Reasoning = $true; Vision = $false
        },
        [pscustomobject]@{
            Id = 'llama3.1-8b'; Name = 'Llama 3.1 8B'; Alias = 'llama3.1:8b'
            Repo = 'ggml-org/Meta-Llama-3.1-8B-Instruct-Q4_0-GGUF'; File = 'meta-llama-3.1-8b-instruct-q4_0.gguf'
            Projector = $null; ApproxGiB = 5.62; Rank = 82
            Tag = 'GENERAL'; Description = 'Proven general-purpose instruct model with broad ecosystem support and modest memory use.'
            Reasoning = $false; Vision = $false
        },
        [pscustomobject]@{
            Id = 'gemma3-4b'; Name = 'Gemma 3 4B Vision'; Alias = 'gemma3:4b'
            Repo = 'ggml-org/gemma-3-4b-it-GGUF'; File = 'gemma-3-4b-it-Q4_K_M.gguf'
            Projector = 'mmproj-model-f16.gguf'; ApproxGiB = 3.11; Rank = 70
            Tag = 'VISION'; Description = 'Compact multimodal model for 8 GB systems; fast on Ryzen integrated graphics.'
            Reasoning = $false; Vision = $true
        },
        [pscustomobject]@{
            Id = 'qwen3-4b'; Name = 'Qwen3 4B'; Alias = 'qwen3:4b'
            Repo = 'ggml-org/Qwen3-4B-GGUF'; File = 'Qwen3-4B-Q4_K_M.gguf'
            Projector = $null; ApproxGiB = 2.33; Rank = 68
            Tag = 'FASTEST'; Description = 'Small, fast reasoning and tool-use model; ideal for 8–16 GB systems and CPU fallback.'
            Reasoning = $true; Vision = $false
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
            $isIntegrated = $_.Name -match '(?i)Radeon.*(Graphics|780M|680M|660M|610M|760M|8060S)' -and $_.Name -notmatch '(?i)\bRX\b|Radeon Pro'
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
            $isIntegrated = $name -match '(?i)Radeon.*(Graphics|780M|680M|660M|610M|760M|8060S)' -and $name -notmatch '(?i)\bRX\b|Radeon Pro'
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
        $status = 'NOT RECOMMENDED'
        $color = 'Red'
        $recommended = $false
        if ($headroom -ge 4) { $status = 'EXCELLENT'; $color = 'Green'; $recommended = $true }
        elseif ($headroom -ge 1) { $status = 'GOOD'; $color = 'Cyan'; $recommended = $true }
        elseif ($headroom -ge -1) { $status = 'TIGHT'; $color = 'Yellow'; $recommended = $true }
        $assessments += [pscustomobject]@{
            Model = $model
            HeadroomGiB = [Math]::Round($headroom, 1)
            Status = $status
            Color = $color
            Recommended = $recommended
        }
    }
    return $assessments
}

function Get-RecommendedModel {
    param($Hardware)
    $assessment = @(Get-ModelAssessment -Hardware $Hardware | Where-Object { $_.Recommended } | Select-Object -First 1)
    if ($assessment.Count -eq 0) { return (Get-ModelCatalog | Sort-Object ApproxGiB | Select-Object -First 1) }
    return $assessment[0].Model
}

function Get-SuggestedContext {
    param($Model, $Hardware)
    if ($Model.ApproxGiB -ge 15 -and $Hardware.RamGiB -ge 48) { return 16384 }
    if ($Model.ApproxGiB -ge 7 -and $Hardware.RamGiB -ge 32) { return 16384 }
    if ($Hardware.RamGiB -ge 16) { return 8192 }
    return 4096
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

    Write-Host "`n  MODEL FIT ANALYSIS" -ForegroundColor White
    foreach ($item in ($assessment | Select-Object -First 6)) {
        $badge = $item.Status.PadRight(17)
        Write-Host ('    {0} ' -f $badge) -NoNewline -ForegroundColor $item.Color
        Write-Host ('{0,-25}' -f $item.Model.Name) -NoNewline -ForegroundColor White
        Write-Host ('{0,6:N1} GiB  headroom {1,5:N1} GiB' -f $item.Model.ApproxGiB, $item.HeadroomGiB) -ForegroundColor DarkGray
    }

    Write-Host "`n  ╭─ RECOMMENDED FOR THIS MACHINE ───────────────────────────────────────────────╮" -ForegroundColor DarkGreen
    Write-Host "  │  ◆ $($recommended.Name)  [$($recommended.Tag)]" -ForegroundColor Green
    Write-Host "  │  $($recommended.Description)" -ForegroundColor Gray
    $context = Get-SuggestedContext -Model $recommended -Hardware $Hardware
    Write-Host "  │  Suggested start: $context context tokens, Q4/Q8 weights, Flash Attention on." -ForegroundColor DarkGray
    Write-Host "  BACKEND: $(if ($Hardware.RocmRecommended) { 'AMD ROCm 7.2.1 (validated Windows package)' } else { 'Vulkan (portable AMD fallback)' })" -ForegroundColor $(if ($Hardware.RocmRecommended) { 'Green' } else { 'Cyan' })
    Write-Host "  REASON: $($Hardware.RocmReason)" -ForegroundColor DarkGray
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
    if ((-not $Hardware.HasAmdGpu) -and -not $Force) {
        throw 'No AMD Radeon Vulkan GPU was detected. Use -Force only if DXGI inventory is incorrect.'
    }
    if ((-not $Hardware.HasAmdCpu) -and -not $Force) {
        Write-WarnLine 'No AMD Ryzen/EPYC CPU was detected. The CPU backend remains available.'
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

    $backendChoice = $RequestedBackend
    if ($backendChoice -eq 'Auto') {
        $backendChoice = if ($Hardware.RocmRecommended) { 'ROCm' } else { 'Vulkan' }
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

function New-Launchers {
    param($ActiveModel, $EffectiveContext)
    $current = Join-Path $InstallRoot 'current'
    $modelPath = [string]$ActiveModel.ModelPath
    $mmprojPath = [string]$ActiveModel.MmprojPath
    $alias = [string]$ActiveModel.Alias
    $mmprojArg = ''
    if (-not [string]::IsNullOrWhiteSpace($mmprojPath)) {
        $mmprojArg = "  --mmproj `"$mmprojPath`" ^"
    }
    $reasoningArg = ''
    if ([bool]$ActiveModel.Reasoning) {
        $reasoningArg = "  --reasoning-format deepseek ^`r`n  --reasoning-budget 2048 ^"
    }

    $start = @"
@echo off
setlocal
title llama.cpp - $($ActiveModel.Name) - AMD backend
pushd "$current"
llama-server.exe ^
  --model "$modelPath" ^
$mmprojArg
  --alias "$alias" ^
  --host 127.0.0.1 ^
  --port $Port ^
  --gpu-layers auto ^
  --fit on ^
  --fit-target 1024 ^
  --ctx-size $EffectiveContext ^
  --flash-attn on ^
  --cache-type-k q8_0 ^
  --cache-type-v q8_0 ^
  --jinja ^
$reasoningArg
  --metrics
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
llama-server.exe --list-devices
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
        vision = [bool]$Model.Vision
        context_size = $EffectiveContext
        port = $Port
        activated_at = (Get-Date).ToUniversalTime().ToString('o')
    }
    New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
    $state | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $InstallRoot 'active-model.json') -Encoding UTF8
    New-Launchers -ActiveModel $state -EffectiveContext $EffectiveContext
}

function Install-Model {
    param($Model, $Hardware)
    $assessment = @(Get-ModelAssessment -Hardware $Hardware | Where-Object { $_.Model.Id -eq $Model.Id }) | Select-Object -First 1
    if ($null -ne $assessment) { Write-Info "Fit: $($assessment.Status), headroom $($assessment.HeadroomGiB) GiB" }
    Assert-ModelDiskSpace -RequiredGiB ([double]$Model.ApproxGiB)
    $modelsRoot = Join-Path $InstallRoot 'models'
    New-Item -ItemType Directory -Path $modelsRoot -Force | Out-Null

    Write-Step "Resolving verified model metadata for $($Model.Name)"
    $descriptor = Get-HfFileDescriptor -Repo $Model.Repo -FileName $Model.File
    Write-Info "Revision $($descriptor.Revision.Substring(0,12)); SHA-256 $($descriptor.Sha256.Substring(0,12))..."
    Get-VerifiedDownload -Url $descriptor.Url -Destination (Join-Path $modelsRoot $Model.File) -ExpectedSize $descriptor.Size -ExpectedSha256 $descriptor.Sha256

    if (-not [string]::IsNullOrWhiteSpace([string]$Model.Projector)) {
        $projector = Get-HfFileDescriptor -Repo $Model.Repo -FileName $Model.Projector
        Get-VerifiedDownload -Url $projector.Url -Destination (Join-Path $modelsRoot $Model.Projector) -ExpectedSize $projector.Size -ExpectedSha256 $projector.Sha256
    }

    $context = $ContextSize
    if ($context -eq 0) { $context = Get-SuggestedContext -Model $Model -Hardware $Hardware }
    Set-ActiveModel -Model $Model -EffectiveContext $context
    Write-Success "$($Model.Name) is installed and active at context $context."
}

function Confirm-ModelDownload {
    param($Model, $Hardware)
    if ($Force) { return $true }
    $assessment = @(Get-ModelAssessment -Hardware $Hardware | Where-Object { $_.Model.Id -eq $Model.Id }) | Select-Object -First 1
    $status = if ($null -eq $assessment) { 'UNKNOWN' } else { $assessment.Status }
    Write-Host "`n  About to download $($Model.Name): ~$([Math]::Round($Model.ApproxGiB,2)) GiB [$status]" -ForegroundColor Yellow
    $answer = Read-ConsoleLine -Prompt '  Type YES to continue'
    return ($answer -ieq 'YES')
}

function Select-ModelInteractively {
    param($Hardware)
    $assessment = @(Get-ModelAssessment -Hardware $Hardware)
    Clear-Screen
    Show-Banner
    Write-Host '  MODEL BROWSER — sizes include the vision projector where applicable' -ForegroundColor White
    for ($i = 0; $i -lt $assessment.Count; $i++) {
        $item = $assessment[$i]
        $installed = Test-Path -LiteralPath (Join-Path (Join-Path $InstallRoot 'models') $item.Model.File)
        $mark = if ($installed) { '✓' } else { ' ' }
        Write-Host ("  [{0}] {1} " -f ($i + 1), $mark) -NoNewline -ForegroundColor White
        Write-Host ('{0,-25}' -f $item.Model.Name) -NoNewline -ForegroundColor $item.Color
        Write-Host ('{0,6:N1} GiB  {1,-18} {2}' -f $item.Model.ApproxGiB, $item.Status, $item.Model.Tag) -ForegroundColor DarkGray
        Write-Host "      $(Limit-Text $item.Model.Description 92)" -ForegroundColor DarkGray
    }
    $answer = Read-ConsoleLine -Prompt "`n  Choose 1-$($assessment.Count), or 0 to return"
    $number = 0
    if (-not [int]::TryParse($answer, [ref]$number) -or $number -lt 1 -or $number -gt $assessment.Count) {
        Write-WarnLine 'No model selected.'
        return $null
    }
    return $assessment[$number - 1].Model
}

function Test-LlamaCppRuntime {
    $server = Join-Path (Join-Path $InstallRoot 'current') 'llama-server.exe'
    if (-not (Test-Path -LiteralPath $server -PathType Leaf)) { return $false }
    Push-Location (Split-Path -Parent $server)
    try {
        & $server --list-devices 2>&1 | Out-String | Write-Host
        return ($LASTEXITCODE -eq 0)
    } finally { Pop-Location }
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
    $server = Join-Path (Join-Path $InstallRoot 'current') 'llama-server.exe'
    if (-not (Test-Path -LiteralPath $server -PathType Leaf)) {
        Write-WarnLine 'llama.cpp is not installed yet. Choose Install/update from the dashboard.'
        return
    }
    Push-Location (Split-Path -Parent $server)
    try {
        Write-Step 'llama.cpp version'
        & $server --version 2>&1 | Write-Host
        Write-Step 'llama.cpp devices'
        & $server --list-devices 2>&1 | Write-Host
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

    $context = if ($ContextSize -gt 0) { $ContextSize } else { [int]$active.context_size }
    $arguments = @(
        '--model', [string]$active.model_path,
        '--alias', [string]$active.alias,
        '--host', '127.0.0.1',
        '--port', [string]$Port,
        '--gpu-layers', 'auto',
        '--fit', 'on',
        '--fit-target', '1024',
        '--ctx-size', [string]$context,
        '--flash-attn', 'on',
        '--cache-type-k', 'q8_0',
        '--cache-type-v', 'q8_0',
        '--jinja',
        '--metrics'
    )
    if (-not [string]::IsNullOrWhiteSpace([string]$active.mmproj_path)) {
        $arguments += @('--mmproj', [string]$active.mmproj_path)
    }
    if ([bool]$active.reasoning) {
        $arguments += @('--reasoning-format', 'deepseek', '--reasoning-budget', '2048')
    }

    Clear-Screen
    Show-Banner
    Write-Host "  STARTING $($active.name)" -ForegroundColor Green
    Write-Info "Context: $context | API/Web UI: http://127.0.0.1:$Port/"
    Write-Info 'Open Open-WebUI.cmd in another terminal or paste the URL after startup.'
    Write-Info 'Press Ctrl+C in this terminal to stop the server.'
    Push-Location (Split-Path -Parent $server)
    try { & $server @arguments } finally { Pop-Location }
}

function Remove-Installation {
    $running = Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue
    if (($null -ne $running) -and -not $Force) { throw 'Stop llama-server.exe before uninstalling.' }
    Remove-UserPathEntry -Directory (Join-Path $InstallRoot 'current')
    if (Test-Path -LiteralPath $InstallRoot) { Remove-Item -LiteralPath $InstallRoot -Recurse -Force }
    Write-Success 'llama.cpp, downloaded models, launchers, and the user PATH entry were removed.'
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
    while ($true) {
        $hardware = Get-HardwareProfile
        $recommended = Get-RecommendedModel -Hardware $hardware
        $backendLabel = if ($Backend -eq 'Auto') { if ($hardware.RocmRecommended) { 'AMD ROCm 7.2.1' } else { 'Vulkan' } } else { $Backend }
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

        Write-Host "`n  ═══════════════════════════════════ COMMAND MENU ═══════════════════════════════════" -ForegroundColor DarkCyan
        Write-Host '   [1]  ✨ First-time setup — install llama.cpp + recommended model (asks first)' -ForegroundColor White
        Write-Host '   [2]  ◈ Model browser — compare, download, and activate a model' -ForegroundColor White
        Write-Host '   [3]  ▶  Launch active model server + Web UI' -ForegroundColor White
        Write-Host '   [4]  ✦ Hardware & model advisor' -ForegroundColor White
        Write-Host '   [5]  ↑  Update llama.cpp — preserves every model' -ForegroundColor White
        Write-Host '   [6]  ⚙  Full diagnostics' -ForegroundColor White
        Write-Host '   [7]  ×  Uninstall command center' -ForegroundColor White
        Write-Host '   [8]  ⚡ Backend selector — ROCm / Vulkan' -ForegroundColor White
        Write-Host '   [0]  Exit' -ForegroundColor DarkGray
        Write-Host '  ═══════════════════════════════════════════════════════════════════════════════════' -ForegroundColor DarkCyan

        $choice = Read-ConsoleLine -Prompt '  Select'
        try {
            switch ($choice) {
                '1' {
                    $tag = Ensure-LlamaCppInstalled -Hardware $hardware -Backend $Backend
                    if (Confirm-ModelDownload -Model $recommended -Hardware $hardware) {
                        Install-Model -Model $recommended -Hardware $hardware
                        Write-Success "Ready: llama.cpp $tag + $($recommended.Name)"
                    } else { Write-WarnLine 'Model download cancelled; llama.cpp remains installed.' }
                    Pause-Screen
                }
                '2' {
                    $selected = Select-ModelInteractively -Hardware $hardware
                    if ($null -ne $selected) {
                        if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $InstallRoot 'current') 'llama-server.exe'))) {
                            [void](Ensure-LlamaCppInstalled -Hardware $hardware -Backend $Backend)
                        }
                        if (Confirm-ModelDownload -Model $selected -Hardware $hardware) {
                            Install-Model -Model $selected -Hardware $hardware
                        } else { Write-WarnLine 'Download cancelled.' }
                    }
                    Pause-Screen
                }
                '3' { Start-ActiveServer -Hardware $hardware; Pause-Screen 'Press Enter after stopping the server' }
                '4' { Show-HardwareAdvisor -Hardware $hardware; Pause-Screen }
                '5' { [void](Ensure-LlamaCppInstalled -Hardware $hardware -Backend $Backend); Pause-Screen }
                '6' { Show-Diagnostics -Hardware $hardware; Pause-Screen }
                '7' {
                    $answer = Read-ConsoleLine -Prompt '  Type DELETE to remove llama.cpp and ALL downloaded models'
                    if ($answer -ceq 'DELETE') { Remove-Installation; Pause-Screen 'Press Enter to exit' ; break }
                    Write-WarnLine 'Uninstall cancelled.'; Pause-Screen
                }
                '8' { Select-BackendInteractively }
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

    if ($Action -eq 'Dashboard') {
        Show-Dashboard
        exit 0
    }

    if ($Action -eq 'Uninstall') {
        Remove-Installation
        exit 0
    }

    $hardware = Get-HardwareProfile
    if ($DryRun) {
        Show-HardwareAdvisor -Hardware $hardware
        exit 0
    }

    switch ($Action) {
        'Advisor' { Show-HardwareAdvisor -Hardware $hardware }
        'Diagnostics' { Show-Diagnostics -Hardware $hardware }
        'Update' { [void](Ensure-LlamaCppInstalled -Hardware $hardware -Backend $Backend) }
        'Launch' { Start-ActiveServer -Hardware $hardware }
        'Install' {
            $tag = Ensure-LlamaCppInstalled -Hardware $hardware -Backend $Backend
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
                    [void](Ensure-LlamaCppInstalled -Hardware $hardware -Backend $Backend)
                }
                if (Confirm-ModelDownload -Model $model -Hardware $hardware) {
                    Install-Model -Model $model -Hardware $hardware
                }
            }
        }
    }
} catch {
    Write-Host "`n  COMMAND FAILED: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.Exception.Message -match '(?i)driver|vulkan') {
        Write-Host '  Install the current AMD Adrenalin driver from https://www.amd.com/en/support and reboot.' -ForegroundColor Yellow
    }
    exit 1
}
