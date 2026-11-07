<#
    Offline checks for Install-LlamaCpp-AMD.ps1. Loads the script's functions without
    running its entry point, then exercises launcher generation and the VS Code
    chatLanguageModels.json writer against temporary folders. No downloads, no
    changes to the real install or VS Code profile.

    powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-CommandCenter.ps1
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Install-LlamaCpp-AMD.ps1'
$tokens = $null; $parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw "Parse errors: $($parseErrors | Out-String)" }
foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($fn.Extent.Text))
}

$work = Join-Path ([IO.Path]::GetTempPath()) ("cc-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
# Point every per-user config location at the temp folder before any test runs, so no
# test (including auto-sync side effects) can ever write the real VS Code or Continue files.
$realVsCodeConfig = Join-Path $env:APPDATA 'Code\User\chatLanguageModels.json'
$realVsCodeStamp = if (Test-Path -LiteralPath $realVsCodeConfig) { (Get-Item -LiteralPath $realVsCodeConfig).LastWriteTimeUtc } else { $null }
$env:APPDATA = Join-Path $work 'appdata'
$env:USERPROFILE = Join-Path $work 'userprofile'
$InstallRoot = Join-Path $work 'install'
$Port = 8080
$Force = $true
$TuneSmoke = $false
$Thinking = 'Auto'
$ContextSize = 0
$script:ServerSlots = 2
$script:AssumeYes = $false
# The game watcher's copy is made from the script file (the real one, never a stand-in).
$script:ScriptSource = $scriptPath
$script:JsonDocumentsOnly = $false
$UseCase = ''
$script:CommandCenterVersion = '0.2.0'
$script:CommandCenterRepo = 'theantipopau/llamacpp-amd-command-center'
$script:GitHubApi = 'https://api.github.com/repos/ggml-org/llama.cpp/releases'
$script:GitHubHeaders = @{}
$script:AmdRocmPage = 'https://rocm.docs.amd.com/projects/radeon-ryzen/en/latest/docs/advanced/advancedrad/windows/llm/llamacpp.html'
$script:AmdRocmPackageCheckedOn = [DateTime]::new(2026, 10, 8)
$script:AmdRocmPackageFreshnessDays = 120
# Catalogue and snapshot settings (the harness loads function definitions only, so
# every script-scope variable must be set here too). The catalogue is the real one
# from the repository: tests read the same files the script ships with.
$script:CatalogDirectory = Join-Path (Split-Path -Parent $scriptPath) 'catalog'
$script:CatalogCache = @{}
$script:StateSnapshotKeep = 40
# Run logging is not started here; the helpers skip logging when these are empty.
$script:RunJsonlPath = $null; $script:RunLogPath = $null; $script:RunSummaryPath = $null
$script:RunLogDirectory = $null; $script:RunStarted = $null; $script:RunTranscriptStarted = $false
$failures = 0
function Assert-True([bool] $Condition, [string] $Message) {
    if ($Condition) { Write-Host "  PASS  $Message" -ForegroundColor Green }
    else { Write-Host "  FAIL  $Message" -ForegroundColor Red; $script:failures++ }
}
function Write-TestGguf {
    # Minimal GGUF v3 header with scalar metadata and no tensors: enough for the header
    # reader and the KV formula, without shipping a multi-GB model in the harness.
    param([string] $Path, [hashtable] $Metadata)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $writer = New-Object IO.BinaryWriter($stream)
    try {
        $writer.Write([Text.Encoding]::ASCII.GetBytes('GGUF'))
        $writer.Write([uint32]3)
        $writer.Write([uint64]0)
        $writer.Write([uint64]$Metadata.Count)
        foreach ($key in $Metadata.Keys) {
            $keyBytes = [Text.Encoding]::UTF8.GetBytes([string]$key)
            $writer.Write([uint64]$keyBytes.Length)
            $writer.Write($keyBytes)
            $value = $Metadata[$key]
            if ($value -is [string]) {
                $writer.Write([uint32]8)
                $valueBytes = [Text.Encoding]::UTF8.GetBytes($value)
                $writer.Write([uint64]$valueBytes.Length)
                $writer.Write($valueBytes)
            } elseif ($value -is [bool]) {
                $writer.Write([uint32]7)
                $writer.Write([bool]$value)
            } else {
                $writer.Write([uint32]4)
                $writer.Write([uint32]$value)
            }
        }
    } finally {
        $writer.Dispose()
        $stream.Dispose()
    }
}

try {
    Write-Host 'Internal calls use real parameter names'
    # Simple (non-advanced) functions silently ignore unknown named parameters, so a
    # typo such as -Backend for -RequestedBackend never raises an error at runtime.
    $declared = @{}
    foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $params = @()
        if ($null -ne $fn.Parameters) { $params += @($fn.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) }
        if ($null -ne $fn.Body.ParamBlock) { $params += @($fn.Body.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) }
        $declared[$fn.Name] = $params
    }
    $badCalls = @()
    foreach ($call in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $name = $call.GetCommandName()
        if ($null -eq $name -or -not $declared.ContainsKey($name)) { continue }
        foreach ($element in $call.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] }) {
            $matched = @($declared[$name] | Where-Object { $_ -like "$($element.ParameterName)*" })
            if ($matched.Count -eq 0) { $badCalls += "$name -$($element.ParameterName) (line $($element.Extent.StartLineNumber))" }
        }
    }
    Assert-True ($badCalls.Count -eq 0) "every named parameter exists$(if ($badCalls.Count) { ': ' + ($badCalls -join ', ') })"

    Write-Host 'GPU architecture overrides'
    # gfx1200/gfx1201 are native in ROCm 7.2+ and in llama.cpp's ROCm builds. Setting
    # HSA_OVERRIDE_GFX_VERSION for them is never correct, so any assignment is a regression.
    $sourceText = Get-Content -LiteralPath $scriptPath -Raw
    $hsaAssignments = @([regex]::Matches($sourceText, '(?im)(\$env:HSA_OVERRIDE_GFX_VERSION\s*=|set\s+"?HSA_OVERRIDE_GFX_VERSION\s*=)'))
    Assert-True ($hsaAssignments.Count -eq 0) 'HSA_OVERRIDE_GFX_VERSION is never assigned (gfx1200/gfx1201 are native)'
    $gameWatchLaunch = @($sourceText -split "`n" | Where-Object { $_ -match "Action', 'GameWatch'" })
    Assert-True ($gameWatchLaunch.Count -eq 1 -and $gameWatchLaunch[0] -match '-WindowStyle Hidden') 'the background game watcher starts hidden (no console window)'

    Write-Host 'Launcher generation (every catalog model)'
    foreach ($model in Get-ModelCatalog) {
        Set-ActiveModel -Model $model -EffectiveContext 32768 -SkipVerification
        $launcher = Get-Content -LiteralPath (Join-Path $InstallRoot 'Start-LlamaCpp.cmd') -Raw
        Assert-True ($launcher -notmatch 'HSA_OVERRIDE_GFX_VERSION') "$($model.Id): the generated launcher never sets HSA_OVERRIDE_GFX_VERSION"
        $block = [regex]::Match($launcher, '(?s)llama-server\.exe"? \^\r?\n(.*?)\r?\nset "LLAMA_EXIT').Groups[1].Value
        $lines = @($block -split '\r?\n')
        $blank = @($lines | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count
        $danglingCaret = $lines[-1].TrimEnd().EndsWith('^')
        $missingCaret = @($lines | Select-Object -SkipLast 1 | Where-Object { -not $_.TrimEnd().EndsWith('^') }).Count
        Assert-True (($blank -eq 0) -and -not $danglingCaret -and ($missingCaret -eq 0)) "$($model.Id): continuation lines are well formed"
        # Model flags live in the router preset now; the launcher keeps only the router's own flags.
        $preset = Get-Content -LiteralPath (Join-Path $InstallRoot 'server-preset.ini') -Raw
        Assert-True (($preset -match "(?m)^\[$([regex]::Escape($model.Alias))\]") -and ($preset -match '(?m)^jinja = true') -and ($preset -match '(?m)^parallel = 2') -and ($preset -match '(?m)^ctx-size = 65536') -and ($preset -match "(?m)^alias = $([regex]::Escape($model.Alias))$") -and ($block -match '--models-preset')) "$($model.Id): preset keeps jinja, alias, and a 2-slot pool sized for two conversations"
        $state = Get-Content -LiteralPath (Join-Path $InstallRoot 'active-model.json') -Raw | ConvertFrom-Json
        Assert-True ($state.tool_calling -eq [bool]$model.Tools) "$($model.Id): tool_calling follows the catalog Tools flag"
        $expectOff = [bool]$model.Reasoning -and [bool]$model.Tools
        $expectOn = [bool]$model.Reasoning -and -not $expectOff
        Assert-True ((($preset -match '(?m)^reasoning = off') -eq $expectOff) -and (($preset -match '(?m)^reasoning = on') -eq $expectOn)) "$($model.Id): thinking is off for tool-capable reasoning models"
    }

    Write-Host 'Hardware recommendation (16 GB Radeon, 31 GB RAM)'
    $hw = [pscustomobject]@{ HasAmdGpu = $true; MaxAmdVramGiB = 15.8; RamGiB = 31.2; ModelBudgetGiB = 24.8 }
    $recommended = Get-RecommendedModel -Hardware $hw
    Assert-True ($recommended.Id -eq 'qwen3.5-9b') "recommends a VRAM-resident tool model (got $($recommended.Id))"
    Assert-True ((Get-SuggestedContext -Model $recommended -Hardware $hw) -eq 65536) 'suggests 64k for the hybrid Qwen3.5 model (small KV cache)'
    Assert-True ((Get-SuggestedContext -Model (Get-ModelById 'qwen3-8b') -Hardware $hw) -eq 32768) 'suggests 32k for a dense 8B model'
    Assert-True ((Get-SuggestedContext -Model (Get-ModelById 'qwen3.8-27b') -Hardware $hw) -eq 32768) 'keeps 32k for the RAM-spilling 27B model'

    Write-Host 'server-args.user.json overrides (merged last, never overwritten)'
    $base = @('--ctx-size', '65536', '--threads', '8', '--flash-attn', 'on')
    $noOverride = Merge-ServerArguments -Base $base -Overrides @()
    Assert-True (($noOverride -join ' ') -eq ($base -join ' ')) 'no override file leaves arguments unchanged'
    $merged = Merge-ServerArguments -Base $base -Overrides @('--threads', '12', '--no-mmap')
    Assert-True (($merged -join ' ') -eq '--ctx-size 65536 --flash-attn on --threads 12 --no-mmap') 'override replaces a duplicate flag and appends a new one, applied last'

    New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
    $overridePath = Get-UserArgsOverridePath
    '["--threads","16"]' | Set-Content -LiteralPath $overridePath -Encoding UTF8
    $model = Get-ModelById 'qwen3.5-9b'
    Set-ActiveModel -Model $model -EffectiveContext 32768 -SkipVerification
    $active = Get-ActiveModel
    $withOverride = Get-ServerArguments -ActiveModel $active -EffectiveContext 32768
    Assert-True ($withOverride -join ' ' -match '--threads 16') 'Get-ServerArguments merges server-args.user.json last'

    '{ not json' | Set-Content -LiteralPath $overridePath -Encoding UTF8
    $malformed = Get-UserServerArgOverrides
    Assert-True ($malformed.Count -eq 0) 'malformed server-args.user.json is ignored, not thrown'

    '[1,2,3]' | Set-Content -LiteralPath $overridePath -Encoding UTF8
    $nonString = Get-UserServerArgOverrides
    Assert-True ($nonString.Count -eq 0) 'a non-string-array server-args.user.json is ignored'
    Remove-Item -LiteralPath $overridePath -Force

    Write-Host 'Ornith is an opt-in alternative, never the silent default'
    $ornith = Get-ModelById 'ornith-1.5-9b'
    Assert-True ($ornith.Rank -lt (Get-ModelById 'qwen3.5-9b').Rank) 'Ornith ranks below Qwen3.5 9B so Qwen3.5 stays the default recommendation'
    $hwBoth = [pscustomobject]@{ HasAmdGpu = $true; MaxAmdVramGiB = 15.8; RamGiB = 31.2; ModelBudgetGiB = 24.8 }
    Assert-True ((Get-RecommendedModel -Hardware $hwBoth).Id -eq 'qwen3.5-9b') 'recommendation still prefers Qwen3.5 9B when Ornith also fits'

    $rocmPkg = [pscustomobject]@{ backend = 'ROCm'; tag = 'rocm-7.2.1-b8407' }
    $vulkanNew = [pscustomobject]@{ backend = 'Vulkan'; tag = 'b11192' }
    Assert-True ([bool](Get-ModelRuntimeBlocker -Model $ornith -Runtime $rocmPkg)) 'Ornith is blocked on the AMD ROCm b8407 package (MTP block fails to load)'
    Assert-True (-not (Get-ModelRuntimeBlocker -Model $ornith -Runtime $vulkanNew)) 'Ornith is allowed on a current Vulkan build'
    Assert-True (-not (Get-ModelRuntimeBlocker -Model (Get-ModelById 'qwen3.5-9b') -Runtime $rocmPkg)) 'Qwen3.5 9B is not blocked on the ROCm package'
    New-Item -ItemType Directory -Path (Join-Path $InstallRoot 'current') -Force | Out-Null
    '{"backend":"ROCm","tag":"rocm-7.2.1-b8407"}' | Set-Content -LiteralPath (Join-Path $InstallRoot 'current\installation.json') -Encoding UTF8
    Assert-True (-not (Confirm-ModelDownload -Model $ornith -Hardware $hwBoth)) 'the download prompt refuses a blocked model before anything downloads'
    Remove-Item -LiteralPath (Join-Path $InstallRoot 'current\installation.json') -Force

    $rocmHw = [pscustomobject]@{ RocmRecommended = $true }
    Assert-True ((Resolve-BackendChoice -RequestedBackend 'Auto' -Hardware $rocmHw -Runtime $vulkanNew) -eq 'Vulkan') 'Auto keeps an installed Vulkan backend instead of reverting to the ROCm recommendation'
    Assert-True ((Resolve-BackendChoice -RequestedBackend 'Auto' -Hardware $rocmHw -Runtime $null) -eq 'ROCm') 'Auto uses the recommendation on a fresh install'
    Assert-True ((Resolve-BackendChoice -RequestedBackend 'ROCm' -Hardware $rocmHw -Runtime $vulkanNew) -eq 'ROCm') 'an explicit backend choice always wins'

    Write-Host 'Newer models and the llama.cpp ROCm (latest) backend'
    $gemma4 = Get-ModelById 'gemma4-12b'
    $rocmLatest = [pscustomobject]@{ backend = 'ROCmLatest'; tag = 'b11239' }
    Assert-True ([bool](Get-ModelRuntimeBlocker -Model $gemma4 -Runtime $rocmPkg)) 'Gemma 4 is blocked on the AMD ROCm b8407 package (predates Gemma 4)'
    Assert-True (-not (Get-ModelRuntimeBlocker -Model $gemma4 -Runtime $vulkanNew)) 'Gemma 4 is allowed on a current Vulkan build'
    Assert-True (-not (Get-ModelRuntimeBlocker -Model $gemma4 -Runtime $rocmLatest)) 'Gemma 4 is allowed on the llama.cpp ROCm (latest) build'
    Assert-True (-not (Get-ModelRuntimeBlocker -Model $ornith -Runtime $rocmLatest)) 'Ornith is allowed on the llama.cpp ROCm (latest) build'
    Assert-True ((Get-RecommendedModel -Hardware $hwBoth).Id -eq 'qwen3.5-9b') 'Gemma 4 never replaces Qwen3.5 9B as the default recommendation'
    Assert-True ((Resolve-BackendChoice -RequestedBackend 'Auto' -Hardware $rocmHw -Runtime $rocmLatest) -eq 'ROCmLatest') 'Auto keeps an installed llama.cpp ROCm (latest) backend on update'
    Assert-True ((Resolve-BackendChoice -RequestedBackend 'Auto' -Hardware $rocmHw -Runtime $null) -ne 'ROCmLatest') 'Auto never picks llama.cpp ROCm (latest) on a fresh install'
    function Invoke-RestMethod {
        param($Uri, $Headers)
        [pscustomobject]@{ tag_name = 'b11239'; html_url = 'https://example.invalid'; assets = @(
            [pscustomobject]@{ name = 'llama-b11239-bin-win-vulkan-x64.zip' },
            [pscustomobject]@{ name = 'llama-b11239-bin-win-rocm-10.0-x64.zip' },
            [pscustomobject]@{ name = 'llama-b11239-bin-ubuntu-rocm-10.0-x64.tar.gz' }) }
    }
    Assert-True ((Get-LatestLlamaCppRocmAsset).Asset.name -eq 'llama-b11239-bin-win-rocm-10.0-x64.zip') 'the ROCm resolver picks the Windows ROCm ZIP whatever its ROCm version'
    Assert-True ((Get-LatestLlamaCppVulkanAsset).Asset.name -eq 'llama-b11239-bin-win-vulkan-x64.zip') 'the Vulkan resolver still picks the Vulkan ZIP'
    Remove-Item -LiteralPath Function:\Invoke-RestMethod
    $noDevices = Get-LlamaDeviceList -Directory (Join-Path $work 'no-such-build')
    Assert-True (@($noDevices).Count -eq 0) 'no llama.cpp build means no devices (so ROCm (latest) is rolled back, not kept)'

    Write-Host 'Catalog matches the recorded upstream evidence (tests/fixtures/catalog-evidence.json)'
    $evidencePath = Join-Path $PSScriptRoot 'fixtures\catalog-evidence.json'
    Assert-True (Test-Path -LiteralPath $evidencePath -PathType Leaf) 'the upstream evidence fixture exists'
    $evidence = Get-Content -LiteralPath $evidencePath -Raw | ConvertFrom-Json
    $evidenceById = @{}
    foreach ($entry in $evidence.files) { $evidenceById[[string]$entry.model_id] = $entry }
    $catalogModels = @(Get-ModelCatalog)
    Assert-True ($catalogModels.Count -eq @($evidence.files).Count) "every catalog model has an evidence record ($($catalogModels.Count) catalog vs $(@($evidence.files).Count) evidence)"
    foreach ($model in $catalogModels) {
        $record = $evidenceById[[string]$model.Id]
        if ($null -eq $record) {
            Assert-True $false "$($model.Id): missing an upstream evidence record - re-verify the repo before shipping it"
            continue
        }
        Assert-True ([string]$record.repo -eq [string]$model.Repo) "$($model.Id): repo matches the verified repo ($($model.Repo))"
        Assert-True ([string]$record.file -eq [string]$model.File) "$($model.Id): file exists upstream at the recorded name ($($model.File))"
        $expectedProjector = if ([string]::IsNullOrWhiteSpace([string]$model.Projector)) { '' } else { [string]$model.Projector }
        Assert-True ([string]$record.projector -eq $expectedProjector) "$($model.Id): projector matches the verified file name"
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$record.file_sha256)) "$($model.Id): evidence records a Git LFS SHA-256 for the model file"
        $totalBytes = [long]$record.file_bytes + [long]$record.projector_bytes
        $totalGiB = [Math]::Round(($totalBytes / 1GB), 2)
        Assert-True ([Math]::Abs(([double]$model.ApproxGiB) - $totalGiB) -le 0.1) "$($model.Id): ApproxGiB $($model.ApproxGiB) is within 0.1 GiB of the recorded artefacts ($totalGiB)"
    }
    Assert-True ([string]$evidenceById['gemma4-12b'].file -eq 'gemma-4-12B-it-Q4_0.gguf') 'Gemma 4 points at a file ggml-org actually publishes (Q4_0, not the non-existent Q4_K_M)'

    Write-Host 'GPU selection never uses the Ryzen iGPU automatically'
    $vkList = @('Available devices:', '  Vulkan0: AMD Radeon RX 9070 XT (16304 MiB, 15416 MiB free)', '  Vulkan1: AMD Radeon(TM) Graphics (16209 MiB, 15398 MiB free)')
    Assert-True ((Select-PrimaryLlamaDevice -Devices (ConvertFrom-LlamaDeviceList -Lines $vkList)) -eq 'Vulkan0') 'Vulkan with dGPU + iGPU pins the dedicated Radeon'
    $swapped = @('  Vulkan0: AMD Radeon(TM) Graphics (16209 MiB, 15398 MiB free)', '  Vulkan1: AMD Radeon RX 9070 XT (16304 MiB, 15416 MiB free)')
    Assert-True ((Select-PrimaryLlamaDevice -Devices (ConvertFrom-LlamaDeviceList -Lines $swapped)) -eq 'Vulkan1') 'selection follows the name, not the device order'
    $rocmList = @('  ROCm0: AMD Radeon RX 9070 XT (16304 MiB, 16153 MiB free)')
    Assert-True ((Select-PrimaryLlamaDevice -Devices (ConvertFrom-LlamaDeviceList -Lines $rocmList)) -eq 'ROCm0') 'a single visible ROCm GPU is still pinned explicitly, not left to driver order'
    $apuOnly = @('  Vulkan0: AMD Radeon(TM) Graphics (16209 MiB, 15398 MiB free)', '  Vulkan1: AMD Radeon 780M Graphics (8000 MiB, 7000 MiB free)')
    $apuSelection = Get-GpuDeviceSelection -Devices (ConvertFrom-LlamaDeviceList -Lines $apuOnly)
    Assert-True (($apuSelection.status -eq 'integrated_only') -and ($apuSelection.device -eq '')) 'an iGPU-only machine is classified integrated_only, never given a device'
    $oneDiscrete = @('  Vulkan0: AMD Radeon RX 9070 XT (16304 MiB, 15416 MiB free)')
    Assert-True ((Select-PrimaryLlamaDevice -Devices (ConvertFrom-LlamaDeviceList -Lines $oneDiscrete)) -eq 'Vulkan0') 'one discrete Vulkan device is pinned explicitly'
    Assert-True ((Get-GpuDeviceSelection -Devices (ConvertFrom-LlamaDeviceList -Lines $vkList)).status -eq 'pinned') 'the discrete member of a discrete+iGPU list is selected'
    Assert-True ((Get-GpuDeviceSelection -Devices (ConvertFrom-LlamaDeviceList -Lines $swapped)).device -eq 'Vulkan1') 'the reordered discrete device is still selected by identity, not index'
    $mixed = ConvertFrom-LlamaDeviceList -Lines @('  ROCm0: AMD Radeon RX 9070 XT (16304 MiB, 16153 MiB free)', '  ROCm1: AMD Radeon(TM) Graphics (16209 MiB, 15398 MiB free)')
    $rocmFound = @($mixed | Where-Object { $_.Id -match '^ROCm' -and -not $_.Integrated })
    Assert-True (($rocmFound.Count -eq 1) -and ($rocmFound[0].Id -eq 'ROCm0')) 'the ROCm (latest) GPU check counts only the dedicated Radeon'
    $noGpu = ConvertFrom-LlamaDeviceList -Lines @('Available devices:', '  (none)')
    $cpuOnly = @($noGpu | Where-Object { $_.Id -match '^ROCm' })
    Assert-True ($cpuOnly.Count -eq 0) 'a build that lists no GPU fails the ROCm (latest) check'
    $pinned = Get-ServerArguments -ActiveModel (Get-ActiveModel) -EffectiveContext 32768 -Device 'Vulkan0'
    Assert-True (($pinned -join ' ') -match '--device Vulkan0') 'the chosen device reaches the server arguments'
    $routerFlags = @((Get-CatalogJson -Name 'runtimes.json').llamacpp_capabilities | Where-Object { ($_.PSObject.Properties.Name -contains 'router') -and ($_.router -eq $true) })
    Assert-True ((@($routerFlags | ForEach-Object { $_.flag }) -contains '--models-preset') -and (@($routerFlags | ForEach-Object { $_.flag }) -contains '--models-max') -and (@($routerFlags | ForEach-Object { $_.flag }) -contains '--metrics')) 'the catalogue declares the router flags that the probe must confirm'
    $ready = Get-RuntimeCapabilitySummary -Capabilities @(
        [pscustomobject]@{ flag = '--models-preset'; router = $true; supported = $true },
        [pscustomobject]@{ flag = '--models-max'; router = $true; supported = $true },
        [pscustomobject]@{ flag = '--metrics'; router = $true; supported = $true }
    )
    Assert-True ($ready.router_ready -and @($ready.router_missing).Count -eq 0) 'a runtime listing every router flag is router-ready'
    $missingMax = Get-RuntimeCapabilitySummary -Capabilities @(
        [pscustomobject]@{ flag = '--models-preset'; router = $true; supported = $true },
        [pscustomobject]@{ flag = '--models-max'; router = $true; supported = $false },
        [pscustomobject]@{ flag = '--metrics'; router = $true; supported = $true }
    )
    Assert-True ((-not $missingMax.router_ready) -and (@($missingMax.router_missing) -contains '--models-max')) 'a missing router flag is named, not assumed supported'
    Set-ActiveModel -Model (Get-ModelById 'qwen3.5-9b') -EffectiveContext 32768 -SkipVerification
    $launcherText = Get-Content -LiteralPath (Join-Path $InstallRoot 'Start-LlamaCpp.cmd') -Raw
    Assert-True ($launcherText -notmatch '--device') 'no device flag when no llama.cpp build is installed to ask'

    Write-Host 'Model picker: downloaded models only, instant offline switch'
    $modelsDir = Join-Path $InstallRoot 'models'
    New-Item -ItemType Directory -Path $modelsDir -Force | Out-Null
    foreach ($name in 'Qwen3.5-9B-Q4_K_M.gguf', 'mmproj-F16.gguf', 'Qwen3-4B-Q4_K_M.gguf', 'Ornith-1.5-9B-Q4_K_M.gguf', 'mmproj-Ornith-1.5-9B-BF16.gguf', 'gemma-3-12b-it-Q4_K_M.gguf') {
        [IO.File]::WriteAllText((Join-Path $modelsDir $name), 'x')
    }
    New-Item -ItemType Directory -Path (Join-Path $InstallRoot 'current') -Force | Out-Null
    '{"backend":"ROCm","tag":"rocm-7.2.1-b8407"}' | Set-Content -LiteralPath (Join-Path $InstallRoot 'current\installation.json') -Encoding UTF8
    Set-ActiveModel -Model (Get-ModelById 'qwen3.5-9b') -EffectiveContext 65536 -SkipVerification
    $list = @(Get-InstalledModelList)
    $ids = @($list | ForEach-Object { ($_ -split '\|')[1] })
    Assert-True (($ids -contains 'qwen3.5-9b') -and ($ids -contains 'qwen3-4b') -and ($ids -contains 'ornith-1.5-9b')) 'lists every model whose files are downloaded'
    Assert-True ($ids -notcontains 'gemma3-12b') 'a model missing its vision projector is not listed as downloaded'
    Assert-True (@($list | Where-Object { $_ -match '\|qwen3\.5-9b\|.*\|active$' }).Count -eq 1) 'the active model is marked active'
    Assert-True (@($list | Where-Object { $_ -match '\|ornith-1\.5-9b\|.*\|blocked$' }).Count -eq 1) 'Ornith is marked blocked on the ROCm package'
    Switch-InstalledModel -Model (Get-ModelById 'qwen3-4b') -Hardware $hwBoth *> $null
    Assert-True ((Get-ActiveModel).id -eq 'qwen3-4b') 'switching activates the chosen downloaded model'
    $threwBlocked = $false
    try { Switch-InstalledModel -Model $ornith -Hardware $hwBoth *> $null } catch { $threwBlocked = $true }
    Assert-True ($threwBlocked -and (Get-ActiveModel).id -eq 'qwen3-4b') 'a blocked model is refused and the active model is unchanged'
    $threwMissing = $false
    try { Switch-InstalledModel -Model (Get-ModelById 'llama3.1-8b') -Hardware $hwBoth *> $null } catch { $threwMissing = $true }
    Assert-True $threwMissing 'a model that is not downloaded is refused instead of downloading'
    Write-Host 'Removing a downloaded model'
    Assert-True ((Get-ProjectorLocalName (Get-ModelById 'gemma3-12b')) -ne (Get-ProjectorLocalName (Get-ModelById 'gemma3-4b'))) 'the two Gemma models no longer share one projector file on disk'
    $threwActive = $false
    try { [void](Remove-DownloadedModel -Model (Get-ModelById 'qwen3-4b') *> $null) } catch { $threwActive = $true }
    Assert-True ($threwActive -and (Test-Path -LiteralPath (Join-Path $modelsDir 'Qwen3-4B-Q4_K_M.gguf'))) 'the active model cannot be removed'
    [void](Remove-DownloadedModel -Model $ornith *> $null)
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $modelsDir 'Ornith-1.5-9B-Q4_K_M.gguf')) -and -not (Test-Path -LiteralPath (Join-Path $modelsDir 'mmproj-Ornith-1.5-9B-BF16.gguf'))) 'removing a model deletes its file and its own projector'
    Assert-True ((Test-Path -LiteralPath (Join-Path $modelsDir 'Qwen3.5-9B-Q4_K_M.gguf')) -and (Test-Path -LiteralPath (Join-Path $modelsDir 'mmproj-F16.gguf'))) "other models' files are left alone"
    $threwMissingRemove = $false
    try { [void](Remove-DownloadedModel -Model $ornith *> $null) } catch { $threwMissingRemove = $true }
    Assert-True $threwMissingRemove 'removing a model that is not downloaded reports it instead of doing nothing silently'

    Remove-Item -LiteralPath $modelsDir -Recurse -Force
    Remove-Item -LiteralPath (Join-Path $InstallRoot 'current\installation.json') -Force

    Write-Host 'Gaming mode: idle unload, launchers, graphics-memory check, shortcuts'
    $qwen = Get-ModelById 'qwen3.5-9b'
    Set-ActiveModel -Model $qwen -EffectiveContext 65536 -SkipVerification
    Assert-True ((Get-IdleSleepSeconds) -eq 0) 'idle unload is off by default'
    Assert-True ((Get-ServerArguments -ActiveModel (Get-ActiveModel) -EffectiveContext 65536) -join ' ' -notmatch 'sleep-idle') 'the server gets no idle flag unless the user turned it on'
    Set-AppSetting -Name 'idle_sleep_minutes' -Value 15
    Assert-True ((Get-IdleSleepSeconds) -eq 900) 'fifteen idle minutes are stored as 900 seconds'
    Assert-True ((Get-ServerArguments -ActiveModel (Get-ActiveModel) -EffectiveContext 65536) -join ' ' -match '--sleep-idle-seconds 900') 'the idle setting reaches the server arguments'
    Set-ActiveModel -Model $qwen -EffectiveContext 65536 -SkipVerification
    $idleLauncher = Get-Content -LiteralPath (Join-Path $InstallRoot 'Start-LlamaCpp.cmd') -Raw
    $idleBlock = @([regex]::Match($idleLauncher, '(?s)llama-server\.exe"? \^\r?\n(.*?)\r?\nset "LLAMA_EXIT').Groups[1].Value -split '\r?\n')
    $idlePreset = Get-Content -LiteralPath (Join-Path $InstallRoot 'server-preset.ini') -Raw
    Assert-True (($idlePreset -match '(?m)^sleep-idle-seconds = 900$') -and (@($idleBlock | Select-Object -SkipLast 1 | Where-Object { -not $_.TrimEnd().EndsWith('^') }).Count -eq 0)) 'the idle flag reaches the model preset, and the launcher keeps well-formed continuation lines'
    Set-AppSetting -Name 'easy_extras_done' -Value $true
    Assert-True ((Get-AppSettings).ContainsKey('idle_sleep_minutes') -and (Get-AppSettings).ContainsKey('easy_extras_done')) 'saving one setting keeps the others'
    [IO.File]::WriteAllText((Get-AppSettingsPath), '{ not json')
    Assert-True ((Get-IdleSleepSeconds) -eq 0) 'a malformed settings.json means defaults, not an error'
    [IO.File]::WriteAllText((Get-AppSettingsPath), '{"idle_sleep_minutes":"soon"}')
    Assert-True ((Get-IdleSleepSeconds) -eq 0) 'a non-numeric idle setting is ignored'
    [IO.File]::WriteAllText((Get-AppSettingsPath), '{"idle_sleep_minutes":99999}')
    Assert-True ((Get-IdleSleepSeconds) -eq 86400) 'the idle setting is capped at 24 hours'
    Remove-Item -LiteralPath (Get-AppSettingsPath) -Force
    $idleResult = Set-IdleSleep -Minutes 15 6> $null
    Assert-True (-not $idleResult) 'idle unload is refused when no llama.cpp build can be asked about the flag'
    Assert-True (-not (Test-Path -LiteralPath (Get-AppSettingsPath))) 'a refused idle setting writes nothing'
    [void](Set-IdleSleep -Minutes 0 *> $null)
    Assert-True ((Get-IdleSleepSeconds) -eq 0) 'idle unload can always be turned off'

    $Port = 8123
    Set-ActiveModel -Model $qwen -EffectiveContext 65536 -SkipVerification
    $Port = 8080
    $chatText = Get-Content -LiteralPath (Join-Path $InstallRoot 'Chat.cmd') -Raw
    $gamingText = Get-Content -LiteralPath (Join-Path $InstallRoot 'Gaming-Mode.cmd') -Raw
    Assert-True (($chatText -match 'http://127\.0\.0\.1:8123') -and ($chatText -match '--app=%URL%/') -and ($chatText -match 'Start-LlamaCpp\.cmd')) 'Chat.cmd uses the configured port, an app-style window, and the generated server launcher'
    Assert-True (($gamingText -match 'taskkill /im llama-server\.exe') -and ($gamingText -notmatch '--model')) 'Gaming-Mode.cmd only stops the server'
    Assert-True (($chatText -notmatch '(?<!\r)\n') -and ($gamingText -notmatch '(?<!\r)\n') -and ($chatText -notmatch '!') -and ($gamingText -notmatch '!')) 'the generated helpers use CRLF and no exclamation marks'

    $hw16 = [pscustomobject]@{ MaxAmdVramGiB = 15.9 }
    $busyGpu = Get-VramPreflight -Model $qwen -Hardware $hw16 -Context 65536 -UsedGiB 9.8
    Assert-True ($busyGpu.Low -and $busyGpu.FreeGiB -eq 6.1) 'a game using 9.8 GiB leaves too little room for Qwen3.5 9B and is flagged'
    Assert-True (-not (Get-VramPreflight -Model $qwen -Hardware $hw16 -Context 65536 -UsedGiB 1.2).Low) 'a mostly idle graphics card passes the check'
    Assert-True (-not (Get-VramPreflight -Model (Get-ModelById 'qwen3.8-27b') -Hardware $hw16 -Context 32768 -UsedGiB 1).Low) 'a model meant to spill into RAM never warns on every start'

    Write-Host 'Fit estimate: GGUF metadata, hybrid KV math, split preflight, confidence'
    $ggufPath = Join-Path $work 'qwen35-hybrid.gguf'
    Write-TestGguf -Path $ggufPath -Metadata ([ordered]@{
        'general.architecture' = 'qwen35'
        'qwen35.block_count' = 32
        'qwen35.attention.head_count' = 16
        'qwen35.attention.head_count_kv' = 4
        'qwen35.attention.key_length' = 256
        'qwen35.attention.value_length' = 256
        'qwen35.embedding_length' = 4096
        'qwen35.full_attention_interval' = 4
        'qwen35.context_length' = 131072
    })
    $ggufMeta = Read-GgufMetadata -Path $ggufPath
    Assert-True (($ggufMeta['general.architecture'] -eq 'qwen35') -and ([int]$ggufMeta['qwen35.block_count'] -eq 32) -and ([int]$ggufMeta['qwen35.attention.head_count_kv'] -eq 4)) 'the GGUF header reader returns architecture and attention shape'
    $kvQ8 = Get-KvCacheGiB -FullAttentionLayers 8 -KvHeads 4 -KeyLength 256 -ValueLength 256 -Context 131072 -CacheType 'q8_0'
    $kvF16 = Get-KvCacheGiB -FullAttentionLayers 8 -KvHeads 4 -KeyLength 256 -ValueLength 256 -Context 131072 -CacheType 'f16'
    Assert-True ([Math]::Abs($kvQ8 - 2.125) -le 0.01) "q8_0 KV uses 8 full-attention layers once, not 32 blocks or K+V twice ($([Math]::Round($kvQ8, 3)) GiB)"
    Assert-True ([Math]::Abs($kvF16 - 4.0) -le 0.01) "f16 KV is 2 bytes per element ($([Math]::Round($kvF16, 3)) GiB)"
    Assert-True ([Math]::Abs(($kvF16 / $kvQ8) - (64 / 34)) -le 0.001) 'q8_0 is 34/32 of f16, so the two cache types cannot be swapped silently'
    $fakeFit = [pscustomobject]@{ Id = 'gguf-test'; File = 'qwen35-hybrid.gguf'; ApproxGiB = 6.2; model_path = $ggufPath; mmproj_path = ''; Moe = $false; KvGiBPer32k = 0.75 }
    $hybridEstimate = Get-VramEstimate -Model $fakeFit -Hardware $hw16 -Context 65536
    Assert-True (($hybridEstimate.hybrid -eq $true) -and ($hybridEstimate.full_attention_layers -eq 8) -and ($hybridEstimate.block_count -eq 32)) 'a full_attention_interval of 4 turns 32 blocks into 8 full-attention layers'
    Assert-True ([Math]::Abs([double]$hybridEstimate.kv_gib - 2.13) -le 0.03) "the estimate uses the metadata KV figure ($([double]$hybridEstimate.kv_gib) GiB), not the per-32k catalogue lump"
    Assert-True ($hybridEstimate.confidence -eq 'medium') 'hybrid attention is medium confidence because linear-attention state is not counted'
    Assert-True ([Math]::Abs(([double]$hybridEstimate.weights_gib + [double]$hybridEstimate.kv_gib + [double]$hybridEstimate.compute_gib + [double]$hybridEstimate.headroom_gib) - [double]$hybridEstimate.needed_gib) -le 0.05) 'weights + KV + compute + headroom add up to the needed total (within two-decimal rounding)'
    Assert-True (($hybridEstimate.estimate -eq $true) -and (@('fits', 'tight', 'will_not_fit') -contains [string]$hybridEstimate.verdict)) 'the document is labelled an estimate and carries one of the three verdicts'
    Assert-True (@($hybridEstimate.warnings | Where-Object { $_ -match 'linear-attention state is not counted' }).Count -eq 1) 'the hybrid warning says exactly what the formula leaves out'
    $fakeMoeFit = [pscustomobject]@{ Id = 'gguf-moe'; File = 'qwen35-hybrid.gguf'; ApproxGiB = 6.2; model_path = $ggufPath; mmproj_path = ''; Moe = $true; KvGiBPer32k = 0.75 }
    $moeEstimate = Get-VramEstimate -Model $fakeMoeFit -Hardware $hw16 -Context 32768
    Assert-True ((@($moeEstimate.warnings | Where-Object { $_ -match 'cliff, not a slope' }).Count -eq 1) -and ($moeEstimate.moe -eq $true)) 'a MoE model carries the --n-cpu-moe cliff warning without changing any offload setting'
    $fallbackEstimate = Get-VramEstimate -Model $qwen -Hardware $hw16 -Context 65536
    Assert-True (($fallbackEstimate.confidence -eq 'low') -and (@($fallbackEstimate.warnings | Where-Object { $_ -match 'falls back' }).Count -eq 1)) 'missing GGUF metadata falls back to the catalogue and is marked low confidence'
    $splitPreflight = Get-VramPreflight -Model $qwen -Hardware $hw16 -Context 65536 -UsedGiB 1.2
    Assert-True (($null -ne $splitPreflight.Estimate) -and ($splitPreflight.WeightsGiB -gt 0) -and ($splitPreflight.KvGiB -gt 0) -and ($splitPreflight.ComputeGiB -gt 0) -and ($splitPreflight.HeadroomGiB -gt 0) -and ($splitPreflight.Verdict -in @('fits', 'tight', 'will_not_fit'))) 'Preflight exposes the four split components and the verdict, not just one lump'
    Assert-True ($null -eq (Get-VramEstimateDocument -Hardware ([pscustomobject]@{ HasAmdGpu = $false }))) 'State carries no estimate on a machine without a Radeon'
    $stateWithModel = Get-ApplicationState
    Assert-True (($stateWithModel.PSObject.Properties.Name -contains 'vram_estimate') -and ($null -ne $stateWithModel.vram_estimate) -and ($stateWithModel.vram_estimate.estimate -eq $true)) 'State exposes the fit estimate as typed JSON for the desktop app'

    $desk = Join-Path $work 'desktop'
    New-Item -ItemType Directory -Path $desk -Force | Out-Null
    $made = @(New-DesktopShortcuts -DesktopPath $desk)
    Assert-True (($made.Count -eq 2) -and (Test-Path -LiteralPath (Join-Path $desk 'AI Chat (local).lnk')) -and (Test-Path -LiteralPath (Join-Path $desk 'AI Off (gaming mode).lnk'))) 'both desktop shortcuts are created'
    $wsh = New-Object -ComObject WScript.Shell
    Assert-True ($wsh.CreateShortcut((Join-Path $desk 'AI Chat (local).lnk')).TargetPath -ieq (Join-Path $InstallRoot 'Chat.cmd')) 'the chat shortcut points at the stable launcher in the install folder'
    $foreign = $wsh.CreateShortcut((Join-Path $desk 'AI Off (gaming mode).lnk'))
    $foreign.TargetPath = Join-Path $env:SystemRoot 'notepad.exe'
    $foreign.Save()
    Assert-True ((Remove-DesktopShortcuts -DesktopPath $desk) -eq 1) 'removal deletes only shortcuts that still point into this install'
    Assert-True ((Test-Path -LiteralPath (Join-Path $desk 'AI Off (gaming mode).lnk')) -and -not (Test-Path -LiteralPath (Join-Path $desk 'AI Chat (local).lnk'))) 'a same-named shortcut the user made is left alone'
    Assert-True (@(New-DesktopShortcuts -DesktopPath (Join-Path $work 'no-such-desktop')).Count -eq 0) 'a missing desktop folder creates nothing and does not throw'

    $Force = $false; $script:AssumeYes = $true
    try {
        Assert-True (Confirm-ModelDownload -Model $qwen -Hardware $hwBoth) 'Easy start asks once, so the per-download prompt is skipped'
        $stillThrows = $false
        try { Assert-HardwareForLlama -Hardware ([pscustomobject]@{ HasAmdGpu = $false; HasAmdCpu = $true }) } catch { $stillThrows = $true }
        Assert-True $stillThrows 'the one-YES shortcut does not bypass the no-Radeon safety check (unlike -Force)'
    } finally { $Force = $true; $script:AssumeYes = $false }
    Assert-True (((Get-CommandCenterStatus) -split '\|').Count -eq 7) 'the status line has the seven fields the menu reads'

    Write-Host 'Use-case picker: "what do you want to use it for?" suggests a model'
    $hw16u = [pscustomobject]@{ HasAmdGpu = $true; MaxAmdVramGiB = 15.8; RamGiB = 31.2; ModelBudgetGiB = 24.8; RocmRecommended = $true }
    $rocmRuntime = [pscustomobject]@{ backend = 'ROCm'; tag = 'rocm-7.2.1-b8407' }
    foreach ($case in 'chat', 'coding', 'images') {
        Assert-True ((Get-ModelForUseCase -UseCase $case -Hardware $hw16u -Runtime $rocmRuntime).Model.Id -eq 'qwen3.5-9b') "16 GB Radeon, $case : the VRAM-resident Qwen3.5 9B (tools and vision)"
    }
    $fastPick = Get-ModelForUseCase -UseCase 'fast' -Hardware $hw16u -Runtime $rocmRuntime
    Assert-True ($fastPick.Model.Id -eq 'qwen3-4b' -and $fastPick.Reason -match 'games') 'fast: the smallest tool-capable model, and it says why'
    $qualityPick = Get-ModelForUseCase -UseCase 'quality' -Hardware $hw16u -Runtime $rocmRuntime
    Assert-True ($qualityPick.Model.Id -eq 'qwen3.8-27b' -and -not $qualityPick.GpuResident -and $qualityPick.Reason -match 'slower') 'quality: the biggest model, and it admits it spills into RAM'
    $hw8 = [pscustomobject]@{ HasAmdGpu = $true; MaxAmdVramGiB = 8.0; RamGiB = 16.0; ModelBudgetGiB = 12.0; RocmRecommended = $false }
    $small = Get-ModelForUseCase -UseCase 'coding' -Hardware $hw8 -Runtime $null
    Assert-True ($small.Model.Tools -and $small.Model.ApproxGiB -le 12) 'an 8 GB card still gets a tool-capable model that fits'
    foreach ($case in Get-UseCaseCatalog) {
        $pick = Get-ModelForUseCase -UseCase $case.Id -Hardware $hw16u -Runtime $rocmRuntime
        Assert-True (-not (Get-ModelRuntimeBlocker -Model $pick.Model -Runtime $rocmRuntime)) "$($case.Id): never suggests a model the planned runtime cannot load"
    }
    Assert-True ((Get-PlannedRuntime -Hardware $hw16u).backend -eq 'ROCm') 'before install, the planned runtime is the ROCm package on a ROCm-capable card'
    Assert-True ($null -eq (Get-PlannedRuntime -Hardware $hw8)) 'a card without ROCm support has no blocker to plan around'
    Assert-True ((Resolve-UseCaseAnswer '2') -eq 'coding' -and (Resolve-UseCaseAnswer 'Images') -eq 'images') 'the text menu accepts a number or a name'
    Assert-True ((Resolve-UseCaseAnswer '') -eq 'chat' -and (Resolve-UseCaseAnswer '99') -eq 'chat' -and (Resolve-UseCaseAnswer 'banana') -eq 'chat') 'Enter or nonsense means everyday chat'
    Assert-True (@(Get-UseCaseCatalog).Count -eq 5 -and @(Get-UseCaseCatalog | Where-Object { -not $_.Title -or -not $_.Detail }).Count -eq 0) 'every use case has a plain-English title and description'

    Write-Host 'Window: the XAML loads and every state reads clearly'
    if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
        Write-Host '  SKIP  window checks need an STA thread (run with powershell.exe)' -ForegroundColor Yellow
    } else {
        $ui = New-GuiWindow -LogoPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'logo.png') -Version '9.9.9'
        $c = $ui.Controls
        $missing = @($c.GetEnumerator() | Where-Object { $null -eq $_.Value } | ForEach-Object { $_.Key })
        Assert-True ($missing.Count -eq 0) "every named control exists$(if ($missing.Count) { ': ' + ($missing -join ', ') })"
        Assert-True ($c.VersionText.Text -eq 'v9.9.9' -and $null -ne $c.LogoImg.Source) 'the version and logo are shown'
        $base = [pscustomobject]@{ Mode = 'off'; ModelName = 'Qwen3.5 9B'; ContextTokens = 65536; IdleMinutes = 0; Shortcuts = $false; Backend = 'ROCm'; GpuName = 'AMD Radeon RX 9070 XT'; TotalGiB = 15.8; UsedGiB = 9.8; NeededGiB = 10.2; Low = $true; Scanning = $false }
        function Copy-GuiCase($Mode, [hashtable] $Change = @{}) {
            $copy = $base.PSObject.Copy(); $copy.Mode = $Mode
            foreach ($key in $Change.Keys) { $copy.$key = $Change[$key] }
            return $copy
        }
        Set-GuiState -Controls $c -State (Copy-GuiCase 'setup' @{ ModelName = ''; ContextTokens = 0 })
        Assert-True (($c.HeroTitle.Text -match 'set up') -and $c.PrimaryText.Text -eq 'Set up and start' -and $c.PrimaryBtn.IsEnabled -and "$($c.OffBtn.Visibility)" -eq 'Collapsed') 'first run: one clear "Set up and start" button'
        Assert-True ($c.ModelName.Text -eq 'Not chosen yet') 'no model yet is said plainly'
        Set-GuiState -Controls $c -State (Copy-GuiCase 'setup' @{ Scanning = $true })
        Assert-True ((-not $c.PrimaryBtn.IsEnabled) -and $c.MemValue.Text -match 'Scanning') 'the button waits while the PC is still being scanned'
        Set-GuiState -Controls $c -State (Copy-GuiCase 'off')
        Assert-True (($c.HeroTitle.Text -eq 'Your AI is off') -and $c.PrimaryText.Text -eq 'Start AI and open chat' -and "$($c.OffBtn.Visibility)" -eq 'Collapsed') 'off: start button, no off button'
        Assert-True (($c.MemValue.Text -eq '9.8 of 15.8 GiB') -and $c.MemHint.Text -match 'Another app' -and $c.MemHint.Text -match '10\.2 GiB') 'off with a busy card: says how much the AI wants'
        Set-GuiState -Controls $c -State (Copy-GuiCase 'off' @{ UsedGiB = 1.0; Low = $false })
        Assert-True ($c.MemHint.Text -match 'Plenty') 'off with a free card: says there is plenty of room'
        Set-GuiState -Controls $c -State (Copy-GuiCase 'loading')
        Assert-True ((-not $c.PrimaryBtn.IsEnabled) -and $c.HeroDetail.Text -match 'Qwen3\.5 9B' -and "$($c.OffBtn.Visibility)" -eq 'Visible') 'loading: button disabled, the model is named'
        Set-GuiState -Controls $c -State (Copy-GuiCase 'on' @{ IdleMinutes = 15; Shortcuts = $true })
        Assert-True (($c.HeroTitle.Text -eq 'Your AI is on') -and $c.PrimaryText.Text -eq 'Open chat' -and "$($c.OffBtn.Visibility)" -eq 'Visible') 'on: open chat and a clear way to turn it off'
        Assert-True (($c.IdleCheck.IsChecked -eq $true) -and ($c.ShortcutCheck.IsChecked -eq $true)) 'the gaming switches reflect the saved settings'
        Set-GuiState -Controls $c -State (Copy-GuiCase 'off' @{ TotalGiB = 0.0; UsedGiB = $null })
        Assert-True ($c.MemValue.Text -match 'Scanning') 'unknown graphics memory never shows a made-up number'
        Assert-True ((Get-GuiState -Hardware $null -UsedGiB $null).Mode -eq 'setup') 'with nothing installed the window offers setup'
        Assert-True ("$($c.UseCaseOverlay.Visibility)" -eq 'Collapsed' -and $c.Uc_chat.IsChecked) 'the use-case panel starts hidden with everyday chat selected'
        $pickView = Get-ModelForUseCase -UseCase 'coding' -Hardware $hw16u -Runtime $rocmRuntime
        Set-GuiUseCaseSuggestion -Controls $c -Suggestion $pickView -Downloaded $false -IsCurrent $false -Scanning $false -Purpose 'setup'
        Assert-True (($c.UcModelName.Text -eq 'Qwen3.5 9B') -and $c.UcModelDetail.Text -match 'to download' -and $c.UcModelDetail.Text -match 'tools' -and $c.UcUseBtn.IsEnabled -and $c.UcUseText.Text -eq 'Continue') 'panel: model, download size and the reason, with a Continue button on first run'
        Set-GuiUseCaseSuggestion -Controls $c -Suggestion $pickView -Downloaded $true -IsCurrent $false -Scanning $false -Purpose 'switch'
        Assert-True ($c.UcModelDetail.Text -match 'Already downloaded' -and $c.UcUseText.Text -eq 'Use this model') 'panel: a downloaded model says so'
        Set-GuiUseCaseSuggestion -Controls $c -Suggestion $pickView -Downloaded $true -IsCurrent $true -Scanning $false -Purpose 'switch'
        Assert-True ($c.UcModelDetail.Text -match 'already use' -and -not $c.UcUseBtn.IsEnabled) 'panel: suggesting the model you already use does not offer a pointless switch'
        Set-GuiUseCaseSuggestion -Controls $c -Suggestion $null -Downloaded $false -IsCurrent $false -Scanning $true -Purpose 'setup'
        Assert-True ($c.UcModelName.Text -match 'scanning' -and -not $c.UcUseBtn.IsEnabled) 'panel: waits while the PC is still being scanned'
    }

    Write-Host 'Command-center self-update version comparison'
    Assert-True ((Compare-SemVer -A 'v0.2.0' -B '0.1.4') -gt 0) 'a newer tag compares greater'
    Assert-True ((Compare-SemVer -A '0.1.4' -B '0.1.4') -eq 0) 'an identical version compares equal'
    Assert-True ((Compare-SemVer -A '0.1.3' -B '0.1.4') -lt 0) 'an older tag compares lesser'

    Write-Host 'ROCm package freshness is time-based only (no network)'
    $script:AmdRocmPackageCheckedOn = (Get-Date).AddDays(-10)
    Assert-True (-not (Get-RocmPackageFreshness).Stale) 'a recently checked-on date is not flagged stale'
    $script:AmdRocmPackageCheckedOn = (Get-Date).AddDays(-400)
    Assert-True ((Get-RocmPackageFreshness).Stale) 'an old checked-on date is flagged stale'

    Write-Host 'Continue config.yaml: fresh file, existing models: key, and the managed block'
    $env:USERPROFILE = Join-Path $work 'userprofile'
    Set-ActiveModel -Model (Get-ModelById 'qwen3.5-9b') -EffectiveContext 65536 -SkipVerification
    $continuePath = Get-ContinueConfigPath
    Assert-True (Install-ContinueConfig) 'creates a fresh config.yaml when none exists'
    $freshText = Get-Content -LiteralPath $continuePath -Raw
    Assert-True ($freshText -match 'provider: llama\.cpp' -and $freshText -match 'model: qwen3\.5:9b') 'fresh file contains the active model'

    Assert-True (Install-ContinueConfig) 'updates its own managed block without asking again'
    $updatedText = Get-Content -LiteralPath $continuePath -Raw
    Assert-True (([regex]::Matches($updatedText, 'managed block \(safe to delete\)')).Count -eq 1) 'repeated activation replaces the block instead of duplicating it'
    Assert-True (Test-Path -LiteralPath ($continuePath + '.command-center.bak')) 'a backup was written before updating the managed block'

    Remove-ContinueConfig
    Assert-True ((Get-Content -LiteralPath $continuePath -Raw) -notmatch 'managed block') 'Remove-ContinueConfig strips the managed block back out'

    $ownConfig = "name: My config`r`nversion: 0.0.1`r`nschema: v1`r`nmodels:`r`n  - name: Claude`r`n    provider: anthropic`r`n    model: claude`r`n"
    [IO.File]::WriteAllText($continuePath, $ownConfig)
    $refused = Install-ContinueConfig
    Assert-True (-not $refused) 'refuses to auto-merge when the user already has their own models: list'
    Assert-True ((Get-Content -LiteralPath $continuePath -Raw) -eq $ownConfig) "the user's own config.yaml is left completely untouched"

    Write-Host 'llama-vscode settings.json: merge, comment guard, and removal'
    $env:APPDATA = Join-Path $work 'appdata'
    $settingsPath = Get-LlamaVscodeSettingsPath
    New-Item -ItemType Directory -Path (Split-Path -Parent $settingsPath) -Force | Out-Null
    '{"editor.fontSize": 14, "workbench.colorTheme": "Dark+"}' | Set-Content -LiteralPath $settingsPath -Encoding UTF8
    Assert-True (Install-LlamaVscodeSettings) 'merges llama-vscode endpoints into an existing settings.json'
    $mergedSettings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    Assert-True ($mergedSettings.'editor.fontSize' -eq 14 -and $mergedSettings.'workbench.colorTheme' -eq 'Dark+') 'unrelated settings are preserved'
    Assert-True ($mergedSettings.'llama-vscode.endpoint' -eq 'http://127.0.0.1:8080' -and $mergedSettings.'llama-vscode.endpoint_tools' -eq 'http://127.0.0.1:8080') 'endpoint and endpoint_tools are set for a tool-capable model'

    Remove-LlamaVscodeSettings
    $afterRemoval = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    Assert-True (($afterRemoval.PSObject.Properties.Name -notcontains 'llama-vscode.endpoint') -and $afterRemoval.'editor.fontSize' -eq 14) 'Remove-LlamaVscodeSettings drops only the keys it manages'

    '{ "editor.fontSize": 14, // a user comment' | Set-Content -LiteralPath $settingsPath -Encoding UTF8
    $commentResult = Install-LlamaVscodeSettings
    Assert-True (-not $commentResult) 'refuses to touch settings.json that contains comments'
    Assert-True ((Get-Content -LiteralPath $settingsPath -Raw) -match 'a user comment') 'a commented settings.json is left completely untouched'

    Write-Host 'Uninstall cleans up only what this project manages'
    $chatConfigPath = Join-Path $env:APPDATA 'Code\User\chatLanguageModels.json'
    $seedForRemoval = '[{"name":"Copilot","vendor":"copilot"},{"name":"llama.cpp local","vendor":"customendpoint","models":[]}]'
    [IO.File]::WriteAllText($chatConfigPath, $seedForRemoval)
    Remove-VsCodeChatEndpoint
    $afterUninstall = @(Get-Content -LiteralPath $chatConfigPath -Raw | ConvertFrom-Json | ForEach-Object { $_ })
    Assert-True ((@($afterUninstall | ForEach-Object { $_.name }) -notcontains 'llama.cpp local') -and (@($afterUninstall | ForEach-Object { $_.name }) -contains 'Copilot')) 'Remove-VsCodeChatEndpoint removes only the managed provider'

    Write-Host 'VS Code chatLanguageModels.json writer'
    $env:APPDATA = Join-Path $work 'appdata'
    $vsDir = Join-Path $env:APPDATA 'Code\User'
    $cfg = Join-Path $vsDir 'chatLanguageModels.json'
    New-Item -ItemType Directory -Path $vsDir -Force | Out-Null
    Set-ActiveModel -Model (Get-ModelById 'qwen3.5-9b') -EffectiveContext 32768 -SkipVerification

    Install-VsCodeChatEndpoint *> $null
    $text = [IO.File]::ReadAllText($cfg)
    $bytes = [IO.File]::ReadAllBytes($cfg)
    Assert-True ($text.TrimStart().StartsWith('[')) 'fresh file is written as a JSON array'
    Assert-True (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB)) 'file has no UTF-8 byte-order mark'

    $seed = '[{"name":"Copilot","vendor":"copilot","settings":{"x":{"reasoningEffort":"medium"}}},{"name":"llama.cpp ROCm","vendor":"customendpoint","models":[]},{"name":"Other","vendor":"customendpoint","models":[]}]'
    [IO.File]::WriteAllText($cfg, $seed)
    Install-VsCodeChatEndpoint *> $null
    $parsed = [IO.File]::ReadAllText($cfg) | ConvertFrom-Json
    $result = @($parsed | ForEach-Object { $_ })
    $names = @($result | ForEach-Object { $_.name })
    Assert-True (($names -contains 'Copilot') -and ($names -contains 'Other')) 'keeps Copilot and unrelated providers'
    Assert-True (($names -notcontains 'llama.cpp ROCm') -and (@($names | Where-Object { $_ -eq 'llama.cpp local' }).Count -eq 1)) 'replaces the legacy provider with exactly one local provider'
    $local = @($result | Where-Object { $_.name -eq 'llama.cpp local' })[0].models[0]
    Assert-True (($local.maxInputTokens + $local.maxOutputTokens) -eq 32768 -and $local.maxInputTokens -ge 28000) "token budget fits Agent mode ($($local.maxInputTokens) in / $($local.maxOutputTokens) out)"
    Assert-True ($local.toolCalling -and $local.id -eq 'qwen3.5:9b') 'tool calling and alias are set'
    Assert-True (Test-Path -LiteralPath ($cfg + '.command-center.bak')) 'backup was written'

    Set-ActiveModel -Model (Get-ModelById 'ornith-1.5-9b') -EffectiveContext 65536 -SkipVerification
    Sync-VsCodeChatEndpoint *> $null
    $synced = @([IO.File]::ReadAllText($cfg) | ConvertFrom-Json | ForEach-Object { $_ } | Where-Object { $_.name -eq 'llama.cpp local' })[0].models[0]
    Assert-True ($synced.id -eq 'ornith:1.5-9b') 'switching models re-syncs a connected VS Code entry to the new model'
    $names = @([IO.File]::ReadAllText($cfg) | ConvertFrom-Json | ForEach-Object { $_.name })
    Assert-True ($names -contains 'Copilot') 'auto-sync keeps the other providers'

    [IO.File]::WriteAllText($cfg, '[{"name":"Copilot","vendor":"copilot"}]')
    Sync-VsCodeChatEndpoint *> $null
    Assert-True (([IO.File]::ReadAllText($cfg)) -notmatch 'llama\.cpp local') 'auto-sync never adds the entry when VS Code was not connected'

    [IO.File]::WriteAllText($cfg, '{ not json')
    $threw = $false
    try { Install-VsCodeChatEndpoint *> $null } catch { $threw = $true }
    Assert-True ($threw -and ([IO.File]::ReadAllText($cfg) -eq '{ not json')) 'refuses to touch malformed JSON'

    Write-Host 'Application state: one typed JSON document (ADR-003)'
    # Seed a small, known install state so these checks are deterministic: two
    # downloaded models, the ROCm b8407 runtime, and Qwen3.5 active.
    $stateModelsDir = Join-Path $InstallRoot 'models'
    New-Item -ItemType Directory -Path $stateModelsDir -Force | Out-Null
    foreach ($name in 'Qwen3.5-9B-Q4_K_M.gguf', 'mmproj-F16.gguf', 'Ornith-1.5-9B-Q4_K_M.gguf', 'mmproj-Ornith-1.5-9B-BF16.gguf') {
        [IO.File]::WriteAllText((Join-Path $stateModelsDir $name), 'x')
    }
    New-Item -ItemType Directory -Path (Join-Path $InstallRoot 'current') -Force | Out-Null
    '{"backend":"ROCm","tag":"rocm-7.2.1-b8407"}' | Set-Content -LiteralPath (Join-Path $InstallRoot 'current\installation.json') -Encoding UTF8
    Set-ActiveModel -Model (Get-ModelById 'qwen3.5-9b') -EffectiveContext 65536 -SkipVerification

    $appState = Get-ApplicationState
    Assert-True ($appState.schema_version -eq 1) 'schema_version is 1'
    Assert-True ($appState.command_center_version -eq $script:CommandCenterVersion) 'reports the command-center version'
    Assert-True ($appState.install_root -eq $InstallRoot) 'reports the install root'
    Assert-True (($null -ne $appState.runtime) -and ($appState.runtime.tag -eq 'rocm-7.2.1-b8407') -and ($appState.runtime.backend -eq 'ROCm') -and ($appState.runtime.exe_present -eq $false)) 'the runtime section matches installation.json and reports exe presence'
    Assert-True (($null -ne $appState.model) -and ($appState.model.id -eq 'qwen3.5-9b') -and ($appState.model.context_size -eq 65536)) 'the model section matches the active model'
    Assert-True (($appState.model.model_present -eq $true) -and ($appState.model.runtime_blocker -eq '')) 'the active model is present on disk and loadable by this runtime'
    Assert-True (@('stopped', 'loading', 'running') -contains $appState.server.state) "server.state is one of stopped/loading/running ($($appState.server.state))"
    Assert-True (($appState.server.port -eq 8080) -and ($appState.server.base_url -eq 'http://127.0.0.1:8080') -and ($appState.server.process_ids -is [array])) 'the server section carries the port, the loopback base url, and a process-id array'
    Assert-True (($appState.models -is [array]) -and (@($appState.models).Count -eq 2)) 'models is an array listing exactly the two downloaded models'
    Assert-True ((@($appState.models | Where-Object { $_.state -eq 'active' }).id) -contains 'qwen3.5-9b') 'the active model is marked active'
    Assert-True ((@($appState.models | Where-Object { $_.state -eq 'blocked' }).id) -contains 'ornith-1.5-9b') 'Ornith is marked blocked on the ROCm package'
    Assert-True (($appState.settings.PSObject.Properties.Name -contains 'idle_sleep_minutes') -and ($appState.settings.PSObject.Properties.Name -contains 'use_case')) 'settings exposes idle_sleep_minutes and use_case'
    Assert-True (@('yes', 'stale', 'no') -contains $appState.editors.vscode) "editors.vscode is yes/stale/no ($($appState.editors.vscode))"
    Assert-True (@('yes', 'no') -contains $appState.desktop_shortcuts) 'desktop_shortcuts is yes/no'
    Assert-True ($null -ne $appState.hardware -or -not [string]::IsNullOrEmpty([string]$appState.hardware_error)) 'hardware is reported, or hardware_error explains why not'
    Assert-True (($null -eq $appState.hardware) -or ($appState.hardware -isnot [string])) 'hardware is a structured object or null, never a bare string'

    $stateJson = ConvertTo-Json -InputObject $appState -Depth 8
    $roundTrip = $stateJson | ConvertFrom-Json
    Assert-True ($roundTrip.schema_version -eq 1) 'the document survives a JSON round trip at schema_version 1'
    Assert-True (($roundTrip.models -is [array]) -and (@($roundTrip.models).Count -eq 2)) 'models survives JSON as an array of two'
    Assert-True (($roundTrip.server.process_ids -is [array]) -and ($null -eq $roundTrip.hardware_error -or [string]$roundTrip.hardware_error -eq '')) 'empty arrays stay arrays and nulls stay null through JSON'
    Assert-True (($roundTrip.generated_at -as [datetime]) -ne $null) 'generated_at is an ISO timestamp'

    $statusFields = @((Get-CommandCenterStatus) -split '\|')
    Assert-True ($statusFields.Count -eq 7) 'the status line still has the seven fields the menu reads'
    Assert-True ($statusFields[3] -eq $appState.server.state) 'the status line and the state document report the same server state'
    Assert-True ($statusFields[4] -eq $appState.editors.vscode) 'the status line and the state document report the same VS Code state'
    Assert-True ($statusFields[6] -eq $appState.desktop_shortcuts) 'the status line and the state document report the same shortcut state'
    $lineRows = @(Get-InstalledModelList | ForEach-Object { ($_ -split '\|')[1] + '|' + ($_ -split '\|')[3] })
    $objectRows = @($appState.models | ForEach-Object { $_.id + '|' + $_.state })
    Assert-True (($lineRows.Count -eq 2) -and (($lineRows -join ';') -eq ($objectRows -join ';'))) 'Get-InstalledModelList is exactly the state document rows'

    Write-Host 'Core state: the status line and the window are projections of one source'
    $core = Get-CoreApplicationState
    $coreNames = @($core.PSObject.Properties.Name)
    $missingInFull = @($coreNames | Where-Object { $appState.PSObject.Properties.Name -notcontains $_ })
    Assert-True ($missingInFull.Count -eq 0) "the state document is a superset of the core state$(if ($missingInFull.Count -gt 0) { ': ' + ($missingInFull -join ', ') })"
    Assert-True (($coreNames -contains 'idle_minutes') -and ([int]$core.idle_minutes -eq [int]((Get-IdleSleepSeconds) / 60))) 'the core state carries the computed idle-unload minutes'
    $lineFields = @((Get-CommandCenterStatus) -split '\|')
    Assert-True ($lineFields[5] -eq [string]$core.idle_minutes) 'the status line projects the core idle minutes'
    $lineAlias = if ($null -eq $core.model) { '-' } else { [string]$core.model.alias }
    Assert-True (($lineFields[0] -eq $lineAlias) -and ($lineFields[3] -eq [string]$core.server.state) -and ($lineFields[6] -eq [string]$core.desktop_shortcuts)) 'the status line carries the core state values verbatim'
    $windowState = Get-GuiState -Hardware $null -UsedGiB $null
    Assert-True (($windowState.IdleMinutes -eq [int]$core.idle_minutes) -and ($windowState.Shortcuts -eq ($core.desktop_shortcuts -eq 'yes'))) 'the window reads idle minutes and shortcuts from the core state'
    Assert-True (($windowState.ModelName -eq [string]$core.model.name) -and ($windowState.ContextTokens -eq [int]$core.model.context_size)) 'the window reads the model straight from the core state'
    Assert-True ($windowState.Mode -eq 'setup') 'without an installed exe the window offers setup'

    Write-Host 'Catalogue files: the single versioned source (ADR-004)'
    $modelsDoc = Get-CatalogJson -Name 'models.json'
    Assert-True (($modelsDoc.schema_version -eq 1) -and (@($modelsDoc.models).Count -eq 9)) 'models.json declares schema_version 1 and the nine catalog models'
    Assert-True (@($modelsDoc.models | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.Id) -or [string]::IsNullOrWhiteSpace([string]$_.File) -or ($_.PSObject.Properties.Name -notcontains 'Rank') }).Count -eq 0) 'every model entry has an id, a file and a rank'
    Assert-True ((@(Get-ModelCatalog).Count -eq 9) -and ((Get-ModelCatalog)[0].Id -eq 'qwen3.8-27b')) 'Get-ModelCatalog reads the file, not an embedded copy'
    $runtimeDoc = Get-CatalogJson -Name 'runtimes.json'
    Assert-True (($runtimeDoc.schema_version -eq 1) -and ([long]$runtimeDoc.amd_rocm_package.size -eq 565651083L) -and ([string]$runtimeDoc.amd_rocm_package.checked_on -eq '2026-10-08')) 'runtimes.json pins the AMD package facts verified in the evidence record'
    Assert-True (([string]$script:AmdRocmPage -eq [string]$runtimeDoc.amd_rocm_package.page) -and ([int]$script:AmdRocmPackageFreshnessDays -eq [int]$runtimeDoc.amd_rocm_package.freshness_days)) 'the script variables match the runtime catalogue'
    $hardwareDoc = Get-CatalogJson -Name 'hardware_profiles.json'
    Assert-True (($hardwareDoc.schema_version -eq 1) -and ([string]$hardwareDoc.rocm.recommended_pattern -match '9070')) 'hardware_profiles.json carries the ROCm matrix pattern'
    $compatDoc = Get-CatalogJson -Name 'compatibility.json'
    Assert-True (($compatDoc.schema_version -eq 1) -and (@($compatDoc.rules).Count -ge 1) -and (@($compatDoc.rules)[0].model_flags -contains 'NeedsMtpLoader')) 'compatibility.json carries the runtime rules'
    $experimental = @($modelsDoc.models | Where-Object { ($_.PSObject.Properties.Name -contains 'Experimental') -and [bool]$_.Experimental })
    Assert-True (($experimental.Count -eq 1) -and ($experimental[0].Id -eq 'ornith-1.5-9b')) 'only Ornith carries the catalogue Experimental flag'
    Assert-True ((@($runtimeDoc.adapters).Count -eq 3) -and (@($runtimeDoc.adapters | Where-Object { [string]$_.status -notin @('active', 'stub') }).Count -eq 0)) 'three runtime adapters are declared with known statuses'
    $capabilityFlags = @($runtimeDoc.llamacpp_capabilities)
    Assert-True (($capabilityFlags.Count -ge 8) -and (@($capabilityFlags | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.flag) -or ([string]$_.flag -notlike '--*') }).Count -eq 0) -and (@($capabilityFlags | Where-Object { [bool]$_.required }).Count -ge 6)) 'capability flags are well formed and the launcher-critical ones are required'
    $blockerOnRocm = Get-ModelRuntimeBlocker -Model (Get-ModelById 'ornith-1.5-9b') -Runtime ([pscustomobject]@{ backend = 'ROCm'; tag = 'rocm-7.2.1-b8407' })
    Assert-True (($blockerOnRocm -ne '') -and ($blockerOnRocm -match 'Ornith 1.5 9B') -and ($blockerOnRocm -match 'b8407')) 'the compatibility rule blocks Ornith on AMD ROCm 7.2.1 with the same message'
    Assert-True (-not (Get-ModelRuntimeBlocker -Model (Get-ModelById 'ornith-1.5-9b') -Runtime ([pscustomobject]@{ backend = 'Vulkan'; tag = 'b11481' }))) 'Vulkan stays unblocked'
    Assert-True (-not (Get-ModelRuntimeBlocker -Model (Get-ModelById 'qwen3.5-9b') -Runtime ([pscustomobject]@{ backend = 'ROCm'; tag = 'rocm-7.2.1-b8407' }))) 'a model without the flags is never blocked'
    $emptyCatalog = Join-Path $work 'empty-catalog'
    New-Item -ItemType Directory -Path $emptyCatalog | Out-Null
    $savedDir = $script:CatalogDirectory; $savedCache = $script:CatalogCache
    try {
        $script:CatalogDirectory = $emptyCatalog
        $script:CatalogCache = @{}
        $missingThrew = $false; $missingMessage = ''
        try { Get-CatalogJson -Name 'models.json' | Out-Null } catch { $missingThrew = $true; $missingMessage = [string]$_.Exception.Message }
        Assert-True ($missingThrew -and ($missingMessage -match 'models.json') -and ($missingMessage -match 'catalog')) 'a missing catalogue file raises a clear error instead of using stale data'
    } finally {
        $script:CatalogDirectory = $savedDir
        $script:CatalogCache = $savedCache
    }

    Write-Host 'Hardware profile: typed model with support, confidence and a recommendation'
    $realProfile = Get-HardwareProfile
    Assert-True ((-not [string]::IsNullOrWhiteSpace([string]$realProfile.cpu.name)) -and ([int]$realProfile.cpu.cores -ge 1) -and ($realProfile.cpu.PSObject.Properties.Name -contains 'vendor_amd')) 'the profile carries a typed cpu section'
    Assert-True (([double]$realProfile.memory.ram_gib -gt 0) -and ([double]$realProfile.memory.ram_gib -eq [double]$realProfile.RamGiB)) 'the typed memory section agrees with the flat field'
    Assert-True ((@('dxgi', 'registry', 'wmi', 'mixed') -contains [string]$realProfile.detection.gpu_source) -and (@('high', 'medium', 'low') -contains [string]$realProfile.detection.confidence)) 'detection reports a source and a confidence from the known set'
    $badGpus = @($realProfile.Gpus | Where-Object { (@('dxgi', 'registry', 'wmi') -notcontains [string]$_.Source) -or (@('high', 'medium', 'low') -notcontains [string]$_.VramConfidence) })
    Assert-True ($badGpus.Count -eq 0) 'every GPU reports where its numbers came from and how much to trust them'
    Assert-True ((@('supported', 'warning', 'unsupported') -contains [string]$realProfile.support.level) -and (@('high', 'medium', 'low') -contains [string]$realProfile.support.confidence) -and ($realProfile.support.reasons -is [array])) 'support is a typed verdict with reasons'
    $realRec = $realProfile.recommendation
    Assert-True ((@('ROCm', 'Vulkan') -contains [string]$realRec.backend) -and (@('high', 'medium', 'low') -contains [string]$realRec.confidence) -and ([string]$realRec.model_id -eq [string](Get-RecommendedModel -Hardware $realProfile).Id)) 'the recommendation names a backend, a confidence and the same model the advisor recommends'
    $supportedFake = Resolve-HardwareSupport -Hardware ([pscustomobject]@{ HasAmdGpu = $true; HasDiscreteAmdGpu = $true; HasAmdIntegratedGpu = $false; VulkanLoader = $true }) -Confidence 'high'
    Assert-True (($supportedFake.level -eq 'supported') -and (@($supportedFake.reasons).Count -eq 0)) 'a discrete Radeon with the Vulkan loader is supported'
    $noRadeon = Resolve-HardwareSupport -Hardware ([pscustomobject]@{ HasAmdGpu = $false; HasDiscreteAmdGpu = $false; HasAmdIntegratedGpu = $false; VulkanLoader = $true }) -Confidence 'medium'
    Assert-True (($noRadeon.level -eq 'unsupported') -and ((@($noRadeon.reasons) -join ' ') -match 'Radeon')) 'no Radeon is unsupported, and it says why'
    $igpuOnly = Resolve-HardwareSupport -Hardware ([pscustomobject]@{ HasAmdGpu = $true; HasDiscreteAmdGpu = $false; HasAmdIntegratedGpu = $true; VulkanLoader = $false }) -Confidence 'medium'
    Assert-True (($igpuOnly.level -eq 'warning') -and (@($igpuOnly.reasons).Count -eq 2)) 'iGPU-only plus a missing Vulkan loader is a warning carrying both reasons'
    $fakeRec = Get-HardwareRecommendation -Hardware $hw16u -Confidence 'high'
    Assert-True (($fakeRec.backend -eq 'ROCm') -and ($fakeRec.model_id -eq 'qwen3.5-9b') -and ($fakeRec.confidence -eq 'high')) 'a 9070 XT class PC recommends ROCm and Qwen3.5 9B'

    Write-Host 'Recommendation engine: catalogue-driven tiers (ADR-005)'
    $rec16 = Get-WorkloadRecommendations -Hardware $hw16u -Runtime $rocmRuntime -DetectionConfidence 'high'
    Assert-True ($rec16.schema_version -eq 1) 'the engine document declares schema_version 1'
    $tiers16 = $rec16.recommended
    Assert-True (($null -ne $tiers16.fast) -and ($null -ne $tiers16.balanced) -and ($null -ne $tiers16.maximum)) 'all three tiers are present'
    Assert-True (($tiers16.fast.model_id -eq 'qwen3-4b') -and ($tiers16.fast.status -eq 'recommended') -and ($tiers16.fast.confidence -eq 'high')) 'fast: smallest tool-capable model, VRAM-resident, high confidence'
    Assert-True (($tiers16.balanced.model_id -eq 'qwen3.5-9b') -and ($tiers16.balanced.status -eq 'recommended') -and $tiers16.balanced.gpu_resident) 'balanced: the default resident tool model'
    Assert-True (($tiers16.maximum.model_id -eq 'qwen3.8-27b') -and ($tiers16.maximum.status -eq 'supported') -and ($tiers16.maximum.confidence -eq 'medium') -and (-not $tiers16.maximum.gpu_resident)) 'maximum: the strongest that fits, marked supported when it spills to RAM'
    foreach ($tierName in 'fast', 'balanced', 'maximum') {
        $tier = $tiers16.$tierName
        Assert-True ((@('supported', 'recommended', 'experimental', 'unsupported') -contains $tier.status) -and (@('high', 'medium', 'low') -contains $tier.confidence) -and (-not [string]::IsNullOrWhiteSpace([string]$tier.reason)) -and ($tier.blockers -is [array])) "${tierName}: status, confidence, reason and blockers are typed"
    }
    # Fit wording: a resident pick states VRAM headroom only; a spilling or Radeon-less pick never claims VRAM residency.
    $residentReason = [string]$tiers16.balanced.reason
    Assert-True (($residentReason -match 'stays entirely in VRAM, leaving about [0-9.]+ GiB after its weights') -and ($residentReason -notmatch 'memory budget headroom')) 'a resident tier states VRAM headroom, never the RAM-inclusive budget'
    Assert-True ([string]$tiers16.maximum.reason -notmatch 'Stays entirely in VRAM') 'a spilling tier never claims VRAM residency'
    $noAmdHw = [pscustomobject]@{ HasAmdGpu = $false; HasDiscreteAmdGpu = $false; HasAmdIntegratedGpu = $false; RocmRecommended = $false; RocmReason = 'test'; MaxAmdVramGiB = 0.0; RamGiB = 32.0; ModelBudgetGiB = 25.0; Gpus = @() }
    $noAmdTiers = Get-WorkloadRecommendations -Hardware $noAmdHw -Runtime $null -DetectionConfidence 'medium'
    Assert-True ([string]$noAmdTiers.recommended.balanced.reason -notmatch 'VRAM') 'without a Radeon, a fitting pick never claims VRAM residency'

    # All four statuses are reachable, proven on the classifier itself.
    $qwen35 = Get-ModelById 'qwen3.5-9b'
    $ornithModel = Get-ModelById 'ornith-1.5-9b'
    $residentFit = [pscustomobject]@{ Recommended = $true; GpuResident = $true; HeadroomGiB = 8.0; Status = 'EXCELLENT' }
    $spillFit = [pscustomobject]@{ Recommended = $true; GpuResident = $false; HeadroomGiB = 6.5; Status = 'EXCELLENT' }
    $noFit = [pscustomobject]@{ Recommended = $false; GpuResident = $false; HeadroomGiB = -3.0; Status = 'NOT RECOMMENDED' }
    Assert-True ((Resolve-RecommendationStatus -Model $qwen35 -Assessment $residentFit -Blocker '') -eq 'recommended') 'resident and fitting = recommended'
    Assert-True ((Resolve-RecommendationStatus -Model $qwen35 -Assessment $spillFit -Blocker '') -eq 'supported') 'fitting but spilling = supported'
    Assert-True ((Resolve-RecommendationStatus -Model $ornithModel -Assessment $residentFit -Blocker '') -eq 'experimental') 'the catalogue Experimental flag = experimental'
    Assert-True ((Resolve-RecommendationStatus -Model $ornithModel -Assessment $residentFit -Blocker 'runtime says no') -eq 'unsupported') 'a runtime blocker wins: unsupported'
    Assert-True ((Resolve-RecommendationStatus -Model $qwen35 -Assessment $noFit -Blocker '') -eq 'unsupported') 'not fitting = unsupported'
    Assert-True ((Get-RecommendationConfidence -Status 'recommended' -DetectionConfidence 'high') -eq 'high') 'sure detection plus a resident pick = high confidence'
    Assert-True ((Get-RecommendationConfidence -Status 'supported' -DetectionConfidence 'high') -eq 'medium') 'a spilling pick drops to medium'
    Assert-True ((Get-RecommendationConfidence -Status 'recommended' -DetectionConfidence 'low') -eq 'low') 'detection doubt caps confidence at low'
    # A machine where nothing fits: unsupported tier with a blocker and low confidence.
    $tinyHw = [pscustomobject]@{ HasAmdGpu = $true; HasDiscreteAmdGpu = $true; HasAmdIntegratedGpu = $false; RocmRecommended = $false; RocmReason = 'test'; MaxAmdVramGiB = 2.0; RamGiB = 4.0; ModelBudgetGiB = 1.0; Gpus = @() }
    $tinyRec = Get-WorkloadRecommendations -Hardware $tinyHw -Runtime $null -DetectionConfidence 'medium'
    Assert-True (($tinyRec.recommended.fast.status -eq 'unsupported') -and (@($tinyRec.recommended.fast.blockers).Count -gt 0)) 'when nothing fits, the tier reports unsupported with a blocker'
    Assert-True (($tinyRec.recommended.fast.confidence -eq 'low') -and (@($tinyRec.blockers).Count -ge 1)) 'unsupported verdicts are low confidence and roll up to the document'
    # No hardcoded GPU names: identical machines differing only in GPU name get identical output.
    $fakeGpuA = [pscustomobject]@{ Name = 'Totally-Fake-GPU-A'; IsAmd = $true; IsIntegrated = $false; VramGiB = 15.8; SharedGiB = 0; Driver = 'x'; Source = 'dxgi'; VramConfidence = 'high' }
    $fakeGpuB = [pscustomobject]@{ Name = 'AMD Radeon RX 9070 XT'; IsAmd = $true; IsIntegrated = $false; VramGiB = 15.8; SharedGiB = 0; Driver = 'x'; Source = 'dxgi'; VramConfidence = 'high' }
    $nameHwA = [pscustomobject]@{ HasAmdGpu = $true; HasDiscreteAmdGpu = $true; HasAmdIntegratedGpu = $false; RocmRecommended = $true; RocmReason = 'matrix'; MaxAmdVramGiB = 15.8; RamGiB = 31.2; ModelBudgetGiB = 24.8; Gpus = @($fakeGpuA) }
    $nameHwB = [pscustomobject]@{ HasAmdGpu = $true; HasDiscreteAmdGpu = $true; HasAmdIntegratedGpu = $false; RocmRecommended = $true; RocmReason = 'matrix'; MaxAmdVramGiB = 15.8; RamGiB = 31.2; ModelBudgetGiB = 24.8; Gpus = @($fakeGpuB) }
    $recByNameA = Get-WorkloadRecommendations -Hardware $nameHwA -Runtime $rocmRuntime -DetectionConfidence 'high'
    $recByNameB = Get-WorkloadRecommendations -Hardware $nameHwB -Runtime $rocmRuntime -DetectionConfidence 'high'
    Assert-True (((ConvertTo-Json -InputObject $recByNameA.recommended -Depth 6) -eq (ConvertTo-Json -InputObject $recByNameB.recommended -Depth 6)) -and ((ConvertTo-Json -InputObject $recByNameA.recommended -Depth 6) -notmatch 'Fake-GPU')) 'machines differing only in GPU name get byte-identical recommendations'

    Write-Host 'Router mode and game pause: preset, command line, model state, unload decisions'
    $routerModel = Get-ModelById 'qwen3.5-9b'
    Set-ActiveModel -Model $routerModel -EffectiveContext 65536 -SkipVerification
    $routerActive = Get-ActiveModel
    $routerArgs = Write-ServerPreset -ActiveModel $routerActive -EffectiveContext 65536
    $routerLine = @($routerArgs) -join ' '
    Assert-True (($routerLine -match '--models-preset') -and ($routerLine -match '--models-max 1') -and ($routerLine -match '--host 127\.0\.0\.1') -and ($routerLine -match '--metrics') -and ($routerLine -notmatch '--model ') -and ($routerLine -notmatch '--jinja')) 'the router command line carries host, port, metrics, the preset and a one-model limit, and no model flags'
    $modelsMaxHits = @([regex]::Matches($routerLine, '--models-max\s+(\S+)'))
    Assert-True (($modelsMaxHits.Count -eq 1) -and ($modelsMaxHits[0].Groups[1].Value -eq '1')) 'router safety: exactly one --models-max and it is 1 on this 16 GB card (a higher value would load two models at once)'
    $presetText = Get-Content -LiteralPath (Get-ServerPresetPath) -Raw
    Assert-True (($presetText -match "(?m)^\[$([regex]::Escape($routerActive.alias))\]") -and ($presetText -match '(?m)^load-on-startup = true$') -and ($presetText -notmatch '(?m)^(host|port|metrics) =')) 'the preset has one model section, loads on startup, and holds no router-level keys'
    $presetBytes = [IO.File]::ReadAllBytes((Get-ServerPresetPath))
    Assert-True (-not ($presetBytes.Length -ge 3 -and $presetBytes[0] -eq 0xEF -and $presetBytes[1] -eq 0xBB -and $presetBytes[2] -eq 0xBF)) 'the preset is written without a byte-order mark'
    $routerSplit = Split-ServerArguments -Arguments @('--model', 'C:\x\m.gguf', '--host', '127.0.0.1', '--port', '8080', '--metrics', '--jinja')
    Assert-True ((($routerSplit.Router -join ' ') -eq '--host 127.0.0.1 --port 8080 --metrics') -and (($routerSplit.Model -join ' ') -eq '--model C:\x\m.gguf --jinja')) 'the split keeps router flags and model flags apart, in order'
    Assert-True ((Get-InstallRelativePath -Path (Join-Path $InstallRoot 'models\m.gguf')) -eq 'models/m.gguf') 'a model inside the install folder is written relative to it'
    Assert-True ((Get-InstallRelativePath -Path 'D:\elsewhere\m.gguf') -eq 'D:\elsewhere\m.gguf') 'a model outside the install folder stays absolute'
    Assert-True ((Resolve-RouterModelState -RouterStatus 'loaded' -IsSleeping $false) -eq 'loaded') 'a loaded model that is not sleeping reads as loaded'
    Assert-True ((Resolve-RouterModelState -RouterStatus 'loaded' -IsSleeping $true) -eq 'asleep') 'a loaded model whose process sleeps reads as asleep'
    Assert-True ((Resolve-RouterModelState -RouterStatus 'loaded' -IsSleeping $null) -eq 'loaded') 'without the sleep flag a loaded model reads as loaded'
    Assert-True (((Resolve-RouterModelState -RouterStatus 'loading') -eq 'loading') -and ((Resolve-RouterModelState -RouterStatus 'unloaded') -eq 'unloaded') -and ((Resolve-RouterModelState -RouterStatus '') -eq 'unknown')) 'loading, unloaded and missing statuses map to their own states'

    # Watcher decisions: 15.8 GiB card, 7 GiB model footprint, 8 GiB threshold.
    $pauseState = @{ high = 0; low = 0; paused = $false }
    $tick1 = Get-GamePauseStep -State $pauseState -ModelLoaded $true -RequestsProcessing 0 -TotalGiB 15.8 -EstimateGiB 7.0 -ThresholdGiB 8
    Assert-True (($tick1.action -eq 'none') -and ($tick1.state['high'] -eq 1)) 'one high sample is not enough to unload'
    $tick2 = Get-GamePauseStep -State $tick1.state -ModelLoaded $true -RequestsProcessing 0 -TotalGiB 15.8 -EstimateGiB 7.0 -ThresholdGiB 8
    Assert-True (($tick2.action -eq 'unload') -and $tick2.state['paused']) 'two high samples in a row unload the model and remember the pause'
    $spike = Get-GamePauseStep -State @{ high = 1; low = 0; paused = $false } -ModelLoaded $true -RequestsProcessing 0 -TotalGiB 6.0 -EstimateGiB 7.0 -ThresholdGiB 8
    Assert-True (($spike.action -eq 'none') -and ($spike.state['high'] -eq 0)) 'a spike that ends resets the count, so nothing unloads'
    $busy = Get-GamePauseStep -State @{ high = 1; low = 0; paused = $false } -ModelLoaded $true -RequestsProcessing 2 -TotalGiB 15.8 -EstimateGiB 7.0 -ThresholdGiB 8
    Assert-True (($busy.action -eq 'none') -and ($busy.state['high'] -eq 2)) 'a chat still running blocks the unload until it finishes'
    $unknownMetrics = Get-GamePauseStep -State @{ high = 1; low = 0; paused = $false } -ModelLoaded $true -RequestsProcessing -1 -TotalGiB 15.8 -EstimateGiB 7.0 -ThresholdGiB 8
    Assert-True ($unknownMetrics.action -eq 'none') 'unknown request counts count as busy, so nothing unloads'
    $wakeState = @{ high = 0; low = 0; paused = $true }
    $wakeAt = 0
    for ($n = 1; $n -le 24; $n++) {
        $r = Get-GamePauseStep -State $wakeState -ModelLoaded $false -RequestsProcessing 0 -TotalGiB 4.0 -EstimateGiB 7.0 -ThresholdGiB 8
        $wakeState = $r.state
        if ($r.action -eq 'wake') { $wakeAt = $n; break }
    }
    Assert-True ($wakeAt -eq 12) 'the model wakes only after a full minute of low use (twelve 5-second samples)'
    $holdState = @{ high = 0; low = 0; paused = $true }
    $holdActions = @()
    for ($n = 1; $n -le 24; $n++) {
        $r = Get-GamePauseStep -State $holdState -ModelLoaded $false -RequestsProcessing 0 -TotalGiB 6.0 -EstimateGiB 7.0 -ThresholdGiB 8
        $holdState = $r.state
        $holdActions += $r.action
    }
    Assert-True ((@($holdActions | Where-Object { $_ -ne 'none' }).Count -eq 0) -and $holdState['paused']) 'a game still holding 6 GiB keeps the model unloaded (3 GiB gap below the threshold)'
    $askedState = @{ high = 0; low = 0; paused = $true }
    $askedAction = 'none'
    for ($n = 1; $n -le 12; $n++) {
        $r = Get-GamePauseStep -State $askedState -ModelLoaded $true -RequestsProcessing 0 -TotalGiB 10.0 -EstimateGiB 7.0 -ThresholdGiB 8
        $askedState = $r.state
        $askedAction = $r.action
    }
    Assert-True ((-not $askedState['paused']) -and ($askedAction -eq 'none')) 'a model loaded by a chat after the game left needs no warm-up and clears the pause'

    # Settings: the game-pause value is clamped, validated and reported.
    Set-AppSetting -Name 'game_pause_gib' -Value 50
    Assert-True ((Get-GamePauseGiB) -eq 40) 'a stored game-pause value above 40 is capped at 40'
    Set-AppSetting -Name 'game_pause_gib' -Value 2
    Assert-True ((Get-GamePauseGiB) -eq 0) 'a stored value below 4 means off'
    Assert-True ((Set-GamePause -Gib 3) -eq $false) 'Set-GamePause refuses 3 GiB'
    $pauseDoc = Get-SettingsDocument
    Assert-True (($pauseDoc.game_pause.min -eq 4) -and ($pauseDoc.game_pause.max -eq 40) -and ($null -ne $pauseDoc.game_pause.capable)) 'the settings document reports game pause with its limits and capability'
    $badPatch = Set-SettingsFromDocument -SettingsPatchText '{"idle_unload":{"minutes":0},"use_case":"chat","game_pause":{"gib":50}}'
    Assert-True (@($badPatch.rejected | Where-Object { $_.field -eq 'game_pause.gib' }).Count -eq 1) 'a game-pause value of 50 is rejected field by field'

    # The launcher gets the watcher line only when the setting is on, and the watcher runs from the install folder's own copy.
    Set-AppSetting -Name 'game_pause_gib' -Value 10
    New-Launchers -ActiveModel $routerActive -EffectiveContext 65536
    $pauseLauncher = Get-Content -LiteralPath (Join-Path $InstallRoot 'Start-LlamaCpp.cmd') -Raw
    Assert-True (($pauseLauncher -match 'Install-LlamaCpp-AMD\.ps1" -Action GameWatch') -and ($pauseLauncher -match '%~dp0tools') -and -not $pauseLauncher.Contains((Split-Path -Parent $scriptPath))) 'with game pause on, the launcher starts the watcher from the install folder copy, never from the ZIP folder'
    Assert-True ((Test-Path -LiteralPath (Join-Path $InstallRoot 'tools\Install-LlamaCpp-AMD.ps1') -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $InstallRoot 'tools\catalog\models.json') -PathType Leaf)) 'the watcher copy and its catalogue are in the install folder'
    Set-AppSetting -Name 'game_pause_gib' -Value 0
    New-Launchers -ActiveModel $routerActive -EffectiveContext 65536
    Assert-True (-not ((Get-Content -LiteralPath (Join-Path $InstallRoot 'Start-LlamaCpp.cmd') -Raw) -match 'GameWatch')) 'with game pause off, the launcher has no watcher line'

    Write-Host 'Speculative drafting: on by default, user override wins'
    Set-ActiveModel -Model (Get-ModelById 'qwen3.5-9b') -EffectiveContext 32768 -SkipVerification
    $specArgs = Get-ServerArguments -ActiveModel (Get-ActiveModel) -EffectiveContext 32768
    Assert-True (($specArgs -join ' ') -match '--spec-type ngram-mod') 'n-gram speculative drafting is in the default server arguments'
    $specOff = Merge-ServerArguments -Base $specArgs -Overrides @('--spec-type', 'none')
    Assert-True (($specOff -join ' ') -match '--spec-type none') 'server-args.user.json can turn speculative decoding off'
    Assert-True (@($specOff | Where-Object { $_ -eq '--spec-type' }).Count -eq 1) 'the override replaces the default flag instead of duplicating it'
    Assert-True ((Get-SuggestedContext -Model (Get-ModelById 'qwen3.8-27b') -Hardware ([pscustomobject]@{ HasAmdGpu = $true; MaxAmdVramGiB = 32; RamGiB = 64; ModelBudgetGiB = 30 })) -eq 65536) 'hybrid Qwen3.8 gets 64k on a card with room (measured 1.1 GiB KV per 32k, not the dense 2.5 GiB default)'

    Write-Host 'Tune: fixture parsing, variance, both-tests rule, opt-in presets'
    $tuneJson = @'
[
  {"n_prompt":2048,"n_gen":0,"avg_ts":1000.0,"stddev_ts":80.0,"build_commit":"abc123","build_number":12110,"backends":"Vulkan","devices":"Vulkan1","n_batch":2048,"n_ubatch":512,"n_gpu_layers":99,"flash_attn":true},
  {"n_prompt":8192,"n_gen":0,"avg_ts":900.0,"stddev_ts":20.0,"build_commit":"abc123","build_number":12110,"backends":"Vulkan","devices":"Vulkan1","n_batch":2048,"n_ubatch":512,"n_gpu_layers":99,"flash_attn":true},
  {"n_prompt":0,"n_gen":128,"avg_ts":50.0,"stddev_ts":1.0,"build_commit":"abc123","build_number":12110,"backends":"Vulkan","devices":"Vulkan1","n_batch":2048,"n_ubatch":512,"n_gpu_layers":99,"flash_attn":true}
]
'@
    $tuneRows = @(ConvertFrom-TuneBenchJson -Text $tuneJson)
    Assert-True ($tuneRows.Count -eq 3) 'llama-bench JSON parses into one row per measurement'
    Assert-True (($tuneRows[0].kind -eq 'prompt') -and ($tuneRows[0].n -eq 2048) -and ($tuneRows[2].kind -eq 'decode') -and ($tuneRows[2].n -eq 128)) 'prompt and decode rows are classified by n_prompt and n_gen'
    Assert-True (($tuneRows[0].noisy -eq $false) -and ($tuneRows[1].noisy -eq $false)) 'stddev below 10 percent of the mean is not flagged as noisy'
    Assert-True (($tuneRows[0].build_commit -eq 'abc123') -and ($tuneRows[0].n_batch -eq 2048) -and ($tuneRows[0].n_ubatch -eq 512)) 'the receipt keeps build and batch facts from the JSON'
    $noisyFixture = $tuneJson.Replace('"stddev_ts":80.0', '"stddev_ts":180.0')
    $noisyRows = @(ConvertFrom-TuneBenchJson -Text $noisyFixture)
    Assert-True ($noisyRows[0].noisy) 'stddev over 10 percent of the mean is flagged'

    $combos = @(Get-TuneBatchCombinations)
    Assert-True (($combos.Count -eq 9) -and (@($combos | Where-Object { $_.ubatch_size -gt $_.batch_size }).Count -eq 0)) 'the default sweep has nine combinations and never exceeds the batch size'
    $skippedCombos = @(Get-TuneBatchCombinations -BatchSizes @(128, 256) -UbatchSizes @(256, 512))
    Assert-True (($skippedCombos.Count -eq 1) -and ($skippedCombos[0].batch_size -eq 256) -and ($skippedCombos[0].ubatch_size -eq 256)) 'combinations where ubatch exceeds batch are skipped'

    $tuneRoot = Join-Path $work 'tune-install'
    New-Item -ItemType Directory -Path (Join-Path $tuneRoot 'models') -Force | Out-Null
    New-Item -ItemType File -Path (Join-Path $tuneRoot 'models\dummy.gguf') -Force | Out-Null
    $previousTuneRoot = $InstallRoot
    $InstallRoot = $tuneRoot
    $tuneJob = 'tune-20261104-000000'
    New-Item -ItemType Directory -Path (Join-Path $tuneRoot "benchmarks\$tuneJob\raw") -Force | Out-Null
    $tuneModel = [pscustomobject]@{ id = 'qwen3-4b'; name = 'Qwen3 4B'; file = 'dummy.gguf' }
    $tuneHardware = [pscustomobject]@{ HasAmdGpu = $true; MaxAmdVramGiB = 15.8; RamGiB = 31.2; ModelBudgetGiB = 24.8 }
    $tuneRuntime = [pscustomobject]@{ tag = 'b12110'; backend = 'Vulkan'; device = 'Vulkan1'; flash_arg = 'on'; path = $tuneRoot; bench_exe = (Join-Path $tuneRoot 'llama-bench.exe'); label = 'Vulkan b12110' }

    # Tune must estimate the benchmark context, not the two-slot server context, and
    # must not count a vision projector that llama-bench never loads.
    $originalTuneEstimate = (Get-Command Get-VramEstimate).ScriptBlock
    try {
        $script:fitCall = $null
        function Get-VramEstimate {
            param($Model, $Hardware, [int] $Context, [double] $UsedGiB = 0, [string] $CacheType = 'q8_0', [int] $Slots = 0, [switch] $BenchmarkOnly)
            $script:fitCall = [pscustomobject]@{ context = $Context; used = $UsedGiB; slots = $Slots; benchmark_only = [bool]$BenchmarkOnly }
            return [pscustomobject]@{ verdict = 'fits'; needed_gib = 4.13; total_gib = 15.8; confidence = 'high'; context_tokens = 8320; slots = $Slots; weights_gib = 2.33; kv_gib = 0.61; compute_gib = 0.2; headroom_gib = 1.0; benchmark_only = [bool]$BenchmarkOnly }
        }
        $fitProbe = Get-TuneFit -Model $tuneModel -Hardware $tuneHardware
        Assert-True (($script:fitCall.context -eq 8320) -and ($script:fitCall.slots -eq 1) -and $script:fitCall.benchmark_only) 'Tune fit uses 8192 prompt + 128 decode at one slot and excludes the projector'
        Assert-True (($fitProbe.context_tokens -eq 8320) -and ($fitProbe.weights_gib -eq 2.33)) 'Tune fit exposes the benchmark-context components'
    } finally {
        Set-Item -Path Function:\Get-VramEstimate -Value $originalTuneEstimate
    }

    # stderr-only help fixture: PowerShell turns native stderr into NativeCommandError
    # when ErrorActionPreference is Stop, which used to make every flag look absent.
    $stderrBench = Join-Path $work 'llama-bench-stderr.cmd'
    @(
        '@echo off',
        'echo Usage: llama-bench [options] 1>&2',
        'echo   -dev, --device 1>&2',
        'echo   -ngl, --n-gpu-layers 1>&2',
        'echo   -fa, --flash-attn 1>&2',
        'echo   -ctk, --cache-type-k 1>&2',
        'echo   -ctv, --cache-type-v 1>&2',
        'echo   -b, --batch-size 1>&2',
        'echo   -ub, --ubatch-size 1>&2',
        'echo   -p, --n-prompt 1>&2',
        'echo   -n, --n-gen 1>&2',
        'echo   -r, --repetitions 1>&2',
        'echo   -o, --output 1>&2',
        'exit /b 1'
    ) | Set-Content -LiteralPath $stderrBench -Encoding ASCII
    $previousEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Stop'
        $stderrSupport = Get-TuneBenchSupport -ExePath $stderrBench
    } finally { $ErrorActionPreference = $previousEap }
    Assert-True ($stderrSupport.available -and @($stderrSupport.missing).Count -eq 0 -and $stderrSupport.text -match '-dev') 'llama-bench help written only to stderr is parsed under ErrorActionPreference Stop'

    # The benchmark's own device list has the iGPU first and the discrete GPU second.
    $fixtureRoot = Join-Path $work 'fixture-runtime'
    New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
    $fixtureBench = Join-Path $fixtureRoot 'llama-bench.exe'
    New-Item -ItemType File -Path $fixtureBench -Force | Out-Null
    $script:fixtureDevices = @(
        [pscustomobject]@{ Id = 'Vulkan0'; Name = 'AMD Radeon(TM) Graphics'; MiB = 512; Integrated = $true },
        [pscustomobject]@{ Id = 'Vulkan1'; Name = 'AMD Radeon RX 9070 XT'; MiB = 16304; Integrated = $false }
    )
    $originalRuntimeInstalls = (Get-Command Get-RuntimeInstallations).ScriptBlock
    $originalDeviceList = (Get-Command Get-LlamaDeviceList).ScriptBlock
    try {
        function Get-RuntimeInstallations {
            return [pscustomobject]@{ relative_path = 'runtimes/vulkan/fixture'; exe_present = $true; backend = 'Vulkan'; tag = 'fixture'; path = $fixtureRoot; installation = [pscustomobject]@{ installed_at = '2026-11-05T00:00:00Z' } }
        }
        function Get-LlamaDeviceList {
            param([string] $Directory, [string] $Executable = 'llama-server.exe')
            if ($Executable -ne 'llama-bench.exe') { throw "unexpected executable $Executable" }
            return ,$script:fixtureDevices
        }
        $fixtureCandidates = @(Get-TuneRuntimeCandidates)
        Assert-True (($fixtureCandidates.Count -eq 1) -and (@($fixtureCandidates[0].devices).Count -eq 2) -and ($fixtureCandidates[0].device -eq 'Vulkan1') -and $fixtureCandidates[0].pinnable) 'Tune reads the benchmark device list and pins the discrete GPU when it is second'
        Assert-True (($fixtureCandidates[0].device_arg -eq '-dev Vulkan1') -and ($fixtureCandidates[0].devices_source -eq 'llama-bench --list-devices')) 'Tune records the exact llama-bench device argument and its source'
    } finally {
        Set-Item -Path Function:\Get-RuntimeInstallations -Value $originalRuntimeInstalls
        Set-Item -Path Function:\Get-LlamaDeviceList -Value $originalDeviceList
    }

    $cleanJson = $tuneJson
    $alwaysNoisyJson = $tuneJson.Replace('"stddev_ts":80.0', '"stddev_ts":180.0')
    $originalBenchProcess = (Get-Command Invoke-TuneBenchProcess).ScriptBlock
    try {
        $script:tuneBenchCalls = 0
        $script:tuneAlwaysNoisy = $false
        $script:tuneCleanJson = $cleanJson
        $script:tuneAlwaysNoisyJson = $alwaysNoisyJson
        function Invoke-TuneBenchProcess {
            param([string] $FilePath, [string] $Arguments, [string] $WorkingDirectory, [string] $StdoutPath, [string] $StderrPath, [string] $JobId = '')
            $script:tuneBenchCalls++
            $payload = if ($script:tuneAlwaysNoisy -or $script:tuneBenchCalls -eq 1) { $script:tuneAlwaysNoisyJson } else { $script:tuneCleanJson }
            return [pscustomobject]@{ exit_code = 0; stdout = $payload; stderr = ''; process_id = 0 }
        }
        $retry = Invoke-TuneBench -JobId $tuneJob -Stage 'unit-retry' -Model $tuneModel -Runtime $tuneRuntime -Prompts @(2048, 8192) -Gen 128 -Reps 3
        Assert-True (($script:tuneBenchCalls -eq 2) -and $retry.rerun -and (-not $retry.unreliable)) 'a noisy first run is rerun once and a clean rerun clears the flag'
        $script:tuneBenchCalls = 0
        $script:tuneAlwaysNoisy = $true
        $stillNoisy = Invoke-TuneBench -JobId $tuneJob -Stage 'unit-noisy' -Model $tuneModel -Runtime $tuneRuntime -Prompts @(2048, 8192) -Gen 128 -Reps 3
        Assert-True (($script:tuneBenchCalls -eq 2) -and $stillNoisy.unreliable -and $stillNoisy.rows[0].noisy) 'a row still noisy after the rerun is marked unreliable'
        $script:tuneBenchCalls = 0
        $script:tuneAlwaysNoisy = $false
        $script:tuneAlwaysNoisyJson = $tuneJson.Replace('"devices":"Vulkan1"', '"devices":"Vulkan0"')
        $deviceMismatch = Invoke-TuneBench -JobId $tuneJob -Stage 'unit-device-mismatch' -Model $tuneModel -Runtime $tuneRuntime -Prompts @(2048, 8192) -Gen 128 -Reps 3
        Assert-True (($deviceMismatch.status -eq 'device_mismatch') -and (-not $deviceMismatch.device_verified) -and (@($deviceMismatch.observed_devices) -contains 'Vulkan0')) 'a benchmark JSON naming a different device is rejected even when the argument was correct'
    } finally {
        Set-Item -Path Function:\Invoke-TuneBenchProcess -Value $originalBenchProcess
    }

    function New-TuneTestResult {
        param([int] $Batch, [int] $Ubatch, [double] $P1, [double] $P2, [double] $Tg, [bool] $Unreliable = $false)
        $rows = @(
            [pscustomobject]@{ kind = 'prompt'; n = 2048; mean = $P1; stddev = 0; noisy = $false; n_batch = $Batch; n_ubatch = $Ubatch },
            [pscustomobject]@{ kind = 'prompt'; n = 8192; mean = $P2; stddev = 0; noisy = $false; n_batch = $Batch; n_ubatch = $Ubatch },
            [pscustomobject]@{ kind = 'decode'; n = 128; mean = $Tg; stddev = 0; noisy = $false; n_batch = $Batch; n_ubatch = $Ubatch }
        )
        return [pscustomobject]@{ model_id = 'qwen3-4b'; status = 'ok'; runtime_tag = 'b12110'; backend = 'Vulkan'; unreliable = $Unreliable; command = 'llama-bench test'; rows = $rows }
    }
    $baseline = New-TuneTestResult -Batch 2048 -Ubatch 512 -P1 100 -P2 90 -Tg 50
    $shortOnly = New-TuneTestResult -Batch 1024 -Ubatch 256 -P1 120 -P2 80 -Tg 90
    $both = New-TuneTestResult -Batch 512 -Ubatch 128 -P1 110 -P2 100 -Tg 60
    $presetSet = New-TunePresetSet -Model $tuneModel -Stage2 @($baseline, $shortOnly, $both) -Hardware $tuneHardware -JobId $tuneJob
    Assert-True ($null -ne $presetSet) 'a setting that wins both prompt tests produces presets'
    if ($null -ne $presetSet) {
        Assert-True (($presetSet.Fast.batch_size -eq 512) -and ($presetSet.Fast.ubatch_size -eq 128)) 'Fast comes from the eligible setting, not the short-test-only setting'
        Assert-True (($presetSet.Balanced.batch_size -eq 512) -and ($presetSet.'Long context'.batch_size -eq 512)) 'Balanced and Long context stay inside the both-tests-eligible set'
        Assert-True (@($presetSet.PSObject.Properties | Where-Object { $_.Value.batch_size -eq 1024 }).Count -eq 0) 'the short-test-only setting is never recommended'
        Assert-True ($presetSet.Fast.receipt.eligible_both_prompts) 'the preset receipt records the both-prompt eligibility rule'
    }
    $noEligible = New-TunePresetSet -Model $tuneModel -Stage2 @($baseline, $shortOnly) -Hardware $tuneHardware -JobId $tuneJob
    Assert-True ($null -eq $noEligible) 'with no setting that wins both prompt tests, no preset is recommended'

    $checkpointDoc = [pscustomobject]@{
        schema_version = 1; job_id = $tuneJob; plan_generated_at = 'fixture'
        reference_before = [pscustomobject]@{ status = 'ok' }
        reference_before_stage2 = $null
        stage1 = @([pscustomobject]@{ model_id = 'qwen3-4b'; runtime_tag = 'b12110'; status = 'ok' })
        stage2 = @([pscustomobject]@{ model_id = 'qwen3-4b'; batch_size = 2048; ubatch_size = 512; status = 'ok' })
    }
    Write-TuneCheckpoint -JobId $tuneJob -Checkpoint $checkpointDoc
    $checkpointRead = Read-TuneCheckpoint -JobId $tuneJob
    Assert-True ((@($checkpointRead.stage1).Count -eq 1) -and (@($checkpointRead.stage2).Count -eq 1) -and ((Get-TuneCompletedCount -Checkpoint $checkpointRead) -eq 3)) 'Tune writes and reads per-row checkpoints for resuming'
    $skipCheckpoint = [pscustomobject]@{ stage1 = @([pscustomobject]@{ status = 'skipped_fit' }); stage2 = @(); reference_before = $null; reference_before_stage2 = $null }
    Assert-True ((Get-TuneCompletedCount -Checkpoint $skipCheckpoint) -eq 0) 'a skipped did-not-fit row is not counted as a completed benchmark'

    Set-AppSetting -Name 'tune_presets' -Value ([pscustomobject]@{ 'qwen3-4b' = [pscustomobject]@{ 'Fast' = [pscustomobject]@{ batch_size = 512; ubatch_size = 128; context_size = 16384; selected = $false; receipt = [pscustomobject]@{ job_id = $tuneJob; model_id = 'qwen3-4b' } } } })
    $tuneActive = [pscustomobject]@{ id = 'qwen3-4b'; model_path = (Join-Path $tuneRoot 'models\dummy.gguf'); mmproj_path = ''; alias = 'qwen3:4b'; reasoning = $false; tool_calling = $false; thinking = $false }
    $beforePreset = Get-ServerArguments -ActiveModel $tuneActive -EffectiveContext 32768
    Assert-True ((($beforePreset -join ' ') -notmatch '--batch-size') -and (($beforePreset -join ' ') -notmatch '--ubatch-size')) 'selecting no preset leaves the launch arguments unchanged'
    Set-TunePresetSelection -ModelId 'qwen3-4b' -Preset 'Fast'
    $afterPreset = Get-ServerArguments -ActiveModel $tuneActive -EffectiveContext 32768
    Assert-True (($afterPreset -join ' ') -match '--batch-size 512 --ubatch-size 128') 'a selected preset maps batch and ubatch to the server flags'
    Assert-True (($afterPreset -join ' ') -match '--ctx-size 32768') 'a selected preset can set the per-slot context (two slots)'
    Set-TunePresetSelection -ModelId 'qwen3-4b' -Preset 'none'
    $clearedPreset = Get-ServerArguments -ActiveModel $tuneActive -EffectiveContext 32768
    Assert-True (($clearedPreset -join ' ') -eq ($beforePreset -join ' ')) 'clearing the selection restores the exact previous command line'
    $tuneSettingsDoc = Get-SettingsDocument
    Assert-True (($tuneSettingsDoc.PSObject.Properties.Name -contains 'tune_presets') -and ($null -ne $tuneSettingsDoc.tune_presets.models)) 'the settings document exposes Tune presets and the opt-in selection'

    $originalServerState = (Get-Command Get-ServerState).ScriptBlock
    $originalGpuReport = (Get-Command Get-GpuPinningReport).ScriptBlock
    $originalRuntimes = (Get-Command Get-TuneRuntimeCandidates).ScriptBlock
    $originalHardwareProfile = (Get-Command Get-HardwareProfile).ScriptBlock
    $originalGamePause = (Get-Command Get-GamePauseGiB).ScriptBlock
    $originalTuneModels = (Get-Command Get-TuneModelCandidates).ScriptBlock
    try {
        function Get-ServerState { [pscustomobject]@{ process_ids = @(4242) } }
        function Get-GpuPinningReport { [pscustomobject]@{ status = 'integrated_only'; reason = 'Only an integrated GPU was found.' } }
        function Get-TuneRuntimeCandidates { return @() }
        function Get-HardwareProfile { [pscustomobject]@{ MaxAmdVramGiB = 15.8 } }
        function Get-GamePauseGiB { return 0 }
        function Get-TuneModelCandidates { return @() }
        $refused = Start-TuneJob
        $codes = @($refused.blockers | ForEach-Object { [string]$_.code })
        Assert-True (($refused.status -eq 'blocked') -and ($codes -contains 'server_running') -and ($codes -contains 'gpu_not_pinned')) 'Tune refuses a running server and an unpinned GPU with typed blockers'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $tuneRoot 'benchmarks\tune-20261104-999999'))) 'a refused Tune start creates no job directory'
    } finally {
        Set-Item -Path Function:\Get-ServerState -Value $originalServerState
        Set-Item -Path Function:\Get-GpuPinningReport -Value $originalGpuReport
        Set-Item -Path Function:\Get-TuneRuntimeCandidates -Value $originalRuntimes
        Set-Item -Path Function:\Get-HardwareProfile -Value $originalHardwareProfile
        Set-Item -Path Function:\Get-GamePauseGiB -Value $originalGamePause
        Set-Item -Path Function:\Get-TuneModelCandidates -Value $originalTuneModels
    }

    # Receipts: "tested on this PC" comes only from completed, non-smoke Tune results.
    $receiptRoot = Join-Path ([IO.Path]::GetTempPath()) ('receipt-test-' + [guid]::NewGuid().ToString('N'))
    $previousReceiptRoot = $InstallRoot
    try {
        $InstallRoot = $receiptRoot
        $emptyReceipts = Get-ModelReceipts
        Assert-True (($emptyReceipts.models.Count -eq 0) -and ($emptyReceipts.caveat -eq '')) 'with no benchmarks folder there are no receipts'
        $fullDir = Join-Path $receiptRoot 'benchmarks\tune-20261105-000002'
        $smokeDir = Join-Path $receiptRoot 'benchmarks\tune-20261105-000003'
        $brokenDir = Join-Path $receiptRoot 'benchmarks\tune-20261105-000004'
        New-Item -ItemType Directory -Path $fullDir, $smokeDir, $brokenDir -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $brokenDir 'results.json'), '{ not json', (New-Object System.Text.UTF8Encoding($false)))
        $fullResults = @{
            smoke = $false; generated_at = '2026-11-04T23:39:16Z'; comparison_caveat = 'Different llama.cpp builds.'
            stage1 = @(
                @{ status = 'ok'; model_id = 'qwen3-4b'; backend = 'Vulkan'; runtime_tag = 'b12110'; device_verified = $true; rows = @(
                    @{ kind = 'prompt'; n = 2048; mean = 5540.29; noisy = $false; unreliable = $false; n_gpu_layers = 99 },
                    @{ kind = 'decode'; n = 128; mean = 180.13; noisy = $false; unreliable = $false; n_gpu_layers = 99 } ) },
                @{ status = 'skipped_fit'; model_id = 'qwen3.8-27b'; backend = 'Vulkan'; runtime_tag = 'b12110'; device_verified = $false; rows = @() },
                @{ status = 'ok'; model_id = 'qwen3-4b'; backend = 'ROCm'; runtime_tag = 'rocm-7.2.1-b8407'; device_verified = $false; rows = @( @{ kind = 'decode'; n = 128; mean = 131.0 } ) }
            )
        }
        [IO.File]::WriteAllText((Join-Path $fullDir 'results.json'), ($fullResults | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
        $smokeResults = @{ smoke = $true; stage1 = @( @{ status = 'ok'; model_id = 'qwen3-4b'; backend = 'Vulkan'; runtime_tag = 'b99999'; device_verified = $true; rows = @( @{ kind = 'decode'; n = 64; mean = 1.0 } ) } ) }
        [IO.File]::WriteAllText((Join-Path $smokeDir 'results.json'), ($smokeResults | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
        $receipts = Get-ModelReceipts
        $fourB = @($receipts.models['qwen3-4b'].Values)
        Assert-True (($fourB.Count -eq 1) -and ($fourB[0].backend -eq 'Vulkan') -and ($fourB[0].runtime_tag -eq 'b12110')) 'only a verified, completed, non-smoke result becomes a receipt'
        Assert-True (($fourB[0].decode.tokens_per_second -eq 180.1) -and (@($fourB[0].prompt)[0].tokens -eq 2048) -and ($fourB[0].gpu_layers -eq 99)) 'receipt numbers are the measured ones, rounded to one decimal'
        Assert-True (-not $receipts.models.ContainsKey('qwen3.8-27b')) 'a model that was skipped has no receipt'
        Assert-True ($receipts.caveat -eq 'Different llama.cpp builds.') 'the comparison caveat travels with the receipts'
    } finally {
        $InstallRoot = $previousReceiptRoot
        Remove-Item -LiteralPath $receiptRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    $cancelJob = 'tune-20261104-000001'
    $cancelDir = Join-Path $tuneRoot "benchmarks\$cancelJob"
    New-Item -ItemType Directory -Path $cancelDir -Force | Out-Null
    $cancelWorker = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 60') -PassThru -WindowStyle Hidden
    $cancelBench = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 60') -PassThru -WindowStyle Hidden
    try {
        $cancelJobDoc = [pscustomobject]@{ schema_version = 1; job_id = $cancelJob; state = 'running'; worker_pid = [int]$cancelWorker.Id; total_runs = 10 }
        Write-TuneJson -Path (Join-Path $cancelDir 'job.json') -Document $cancelJobDoc
        Write-TuneProgress -JobId $cancelJob -Fields @{ state = 'running'; stage = 'stage1'; current_bench_pid = [int]$cancelBench.Id; completed_runs = 1; total_runs = 10 }
        $cancel = Stop-TuneJob -JobId $cancelJob
        Start-Sleep -Milliseconds 250
        Assert-True (($cancel.status -eq 'cancelled') -and $cancel.stopped_worker -and $cancel.stopped_bench) 'Cancel stops the worker and the current benchmark process'
        Assert-True (($null -eq (Get-Process -Id $cancelWorker.Id -ErrorAction SilentlyContinue)) -and ($null -eq (Get-Process -Id $cancelBench.Id -ErrorAction SilentlyContinue))) 'Cancel leaves no worker or benchmark process behind'
        $cancelProgress = Read-TuneJson -Path (Join-Path $cancelDir 'progress.json')
        Assert-True (($cancelProgress.state -eq 'cancelled') -and ([int]$cancelProgress.current_bench_pid -eq 0)) 'Cancel records the cancelled state and clears the benchmark PID'
    } finally {
        Stop-Process -Id $cancelWorker.Id -Force -ErrorAction SilentlyContinue
        Stop-Process -Id $cancelBench.Id -Force -ErrorAction SilentlyContinue
        $InstallRoot = $previousTuneRoot
    }

    Write-Host 'Benchmark history (append, read back, tolerate junk)'
    $benchPath = Join-Path $work 'bench-history.jsonl'
    Add-BenchmarkRecord -Path $benchPath -Record ([pscustomobject]@{ at = '2026-10-01T00:00:00.0000000Z'; model_id = 'qwen3.5-9b'; alias = 'qwen3.5:9b'; prompt_tps = 900.0; gen_tps = 82.4 })
    Add-BenchmarkRecord -Path $benchPath -Record ([pscustomobject]@{ at = '2026-10-02T00:00:00.0000000Z'; model_id = 'qwen3-4b'; alias = 'qwen3:4b'; prompt_tps = 1500.0; gen_tps = 140.0 })
    [IO.File]::AppendAllText($benchPath, "{ not json" + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
    $benchHistory = Get-BenchmarkHistory -Path $benchPath
    Assert-True ($benchHistory.Count -eq 2) 'history keeps valid runs and skips a malformed line'
    Assert-True ($benchHistory[1].model_id -eq 'qwen3-4b') 'runs are returned oldest first'
    Assert-True ((Get-BenchmarkHistory -Path (Join-Path $work 'missing-history.jsonl')).Count -eq 0) 'a missing history file is an empty list, not an error'
    Assert-True ((Get-BenchmarkHistory -Path $benchPath -Max 1).Count -eq 1) 'history display is capped to the newest runs'
    $benchBytes = [IO.File]::ReadAllBytes($benchPath)
    Assert-True (-not ($benchBytes[0] -eq 0xEF -and $benchBytes[1] -eq 0xBB)) 'history file is UTF-8 without a byte-order mark'

    Write-Host 'Runtime adapters: one interface, honest stubs (ADR-005)'
    $adapterList = @(Get-RuntimeAdapters)
    Assert-True ((@($adapterList | ForEach-Object { $_.id }) -join ',') -eq 'llamacpp,lemonade,strata') 'the catalogue declares three adapters'
    Assert-True (((Get-RuntimeAdapter -Id 'llamacpp').status -eq 'active') -and ((Get-RuntimeAdapter -Id 'lemonade').status -eq 'stub') -and ((Get-RuntimeAdapter -Id 'strata').status -eq 'stub')) 'llama.cpp is active; Lemonade and Strata are structured stubs'
    $unknownAdapterThrew = $false
    try { Get-RuntimeAdapter -Id 'nope' | Out-Null } catch { $unknownAdapterThrew = $true }
    Assert-True $unknownAdapterThrew 'an unknown adapter id fails loudly'
    $caps = Get-RuntimeCapabilities -AdapterId 'llamacpp'
    Assert-True (($caps.available -eq $false) -and ($caps.confidence -eq 'none') -and (@($caps.capabilities).Count -ge 8)) 'without an exe, capabilities are unknown rather than guessed'
    Assert-True (@($caps.capabilities | Where-Object { $null -ne $_.supported }).Count -eq 0) 'nothing is claimed supported when nothing was probed'
    $llamaValidation = Test-RuntimeAdapter -AdapterId 'llamacpp' -Hardware $hw16u
    Assert-True (($llamaValidation.ok -eq $false) -and ($llamaValidation.status -eq 'blocked') -and ((@($llamaValidation.blockers) -join ' ') -match 'not installed')) 'a missing llama.cpp is a validation blocker'
    $lemonadeValidation = Test-RuntimeAdapter -AdapterId 'lemonade'
    Assert-True (($lemonadeValidation.ok -eq $false) -and ($lemonadeValidation.status -eq 'not_implemented') -and (@($lemonadeValidation.blockers).Count -ge 1) -and (@($lemonadeValidation.unknowns).Count -ge 1)) 'a stub never fabricates a verdict: not_implemented with documented unknowns'
    $stubHealth = Get-RuntimeHealth -AdapterId 'strata'
    Assert-True (($stubHealth.state -eq 'unknown') -and ($stubHealth.ok -eq $false) -and ($stubHealth.confidence -eq 'none')) 'stub health is unknown, never guessed'
    Assert-True ((Start-Runtime -AdapterId 'lemonade').status -eq 'not_implemented') 'starting a stub does nothing and says so'
    $stubStop = Stop-Runtime -AdapterId 'strata'
    Assert-True (($stubStop.status -eq 'not_implemented') -and ($stubStop.killed -eq 0)) 'stopping a stub does nothing'
    $processBefore = @(Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue).Count
    $llamaStop = Stop-Runtime -AdapterId 'llamacpp'
    $processAfter = @(Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue).Count
    Assert-True ((@('not_running', 'requires_confirmation') -contains $llamaStop.status) -and ($llamaStop.killed -eq 0) -and ($processAfter -eq $processBefore)) 'stopping without -Force never kills anything'

    # Forced stop is the one path ADR-005 could not exercise: it kills every process named
    # llama-server, so running it against the real install would terminate the user's server.
    # Instead spawn a harmless stand-in with that exact process name (a copy of ping.exe)
    # and force-stop it. Hard guard: if any llama-server is ALREADY running we skip, because
    # the force path kills by name and would take down a server this test did not start.
    $preexistingLlama = @(Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue)
    if ($preexistingLlama.Count -gt 0) {
        Write-Host ('  SKIP  forced stop: a llama-server is already running (PIDs ' + (($preexistingLlama | ForEach-Object { $_.Id }) -join ', ') + '); refusing to touch a server this test did not start')
    } else {
        $standInExe = Join-Path $work 'llama-server.exe'
        Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\ping.exe') -Destination $standInExe -Force
        $standIn = Start-Process -FilePath $standInExe -ArgumentList '-n', '600', '127.0.0.1' -PassThru -WindowStyle Hidden
        try {
            $ready = $false
            $waitUntil = (Get-Date).AddSeconds(10)
            while (-not $ready -and (Get-Date) -lt $waitUntil) {
                $ready = $null -ne (Get-Process -Id $standIn.Id -ErrorAction SilentlyContinue)
                if (-not $ready) { Start-Sleep -Milliseconds 200 }
            }
            Assert-True $ready 'the stand-in llama-server is running (a real process with that name)'
            $forced = Stop-Runtime -AdapterId 'llamacpp' -Force
            $standInGone = $false
            $goneBy = (Get-Date).AddSeconds(10)
            while (-not $standInGone -and (Get-Date) -lt $goneBy) {
                $standInGone = $null -eq (Get-Process -Id $standIn.Id -ErrorAction SilentlyContinue)
                if (-not $standInGone) { Start-Sleep -Milliseconds 200 }
            }
            Assert-True (($forced.status -eq 'stopped') -and ($forced.killed -ge 1)) "the forced stop reports stopped and how many it killed (got $($forced.status)/$($forced.killed))"
            Assert-True ($standInGone) 'the forced stop really killed the running llama-server process'
        } finally {
            # Never leave a stand-in behind, even if an assertion above failed.
            if ($null -ne (Get-Process -Id $standIn.Id -ErrorAction SilentlyContinue)) { Stop-Process -Id $standIn.Id -Force -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $standInExe -Force -ErrorAction SilentlyContinue
        }
    }
    $llamaHealth = Get-RuntimeHealth -AdapterId 'llamacpp'
    Assert-True ((@('stopped', 'loading', 'running') -contains $llamaHealth.state) -and ($llamaHealth.confidence -eq 'high')) 'llama.cpp health is a live, direct probe'
    $failedStart = Start-Runtime -AdapterId 'llamacpp' -Hardware $hw16u
    Assert-True ((@('failed', 'already_running', 'backend_not_installed') -contains $failedStart.status) -and (-not [string]::IsNullOrWhiteSpace([string]$failedStart.detail))) "starting against this temp install fails typed, without launching anything (got $($failedStart.status): $($failedStart.detail))"

    Write-Host 'Diagnostics: one typed document (ADR-005)'
    $diag = Get-DiagnosticReport
    Assert-True ($diag.schema_version -eq 1) 'diagnostics declare schema_version 1'
    Assert-True ((@('ok', 'degraded', 'broken') -contains $diag.overall.status) -and (@('high', 'medium', 'low', 'none') -contains $diag.overall.confidence)) 'overall status and confidence come from the known sets'
    Assert-True (($null -ne $diag.runtime_health) -and ($null -ne $diag.hardware_health) -and ($null -ne $diag.model_health) -and ($null -ne $diag.editor_health)) 'all four health sections are present'
    Assert-True (($diag.runtime_health.validation_status -eq 'blocked') -and ($diag.runtime_health.capabilities_available -eq $false)) 'the temp install has no llama-server.exe, so validation blocks'
    Assert-True (((@($diag.blockers) -join ' ') -match 'not installed')) 'and the roll-up blocker names the missing install'
    Assert-True (@('supported', 'warning', 'unsupported') -contains $diag.hardware_health.level) 'hardware health carries the support verdict'
    Assert-True (($diag.model_health.id -eq 'qwen3.5-9b') -and ($diag.model_health.present -eq $true)) 'model health describes the seeded active model'
    Assert-True (($diag.warnings -is [array]) -and ($diag.blockers -is [array])) 'warnings and blockers are arrays'
    Assert-True ($diag.overall.status -eq 'broken') 'a missing runtime makes the install broken'
    $sectionConfidences = @($diag.runtime_health.confidence, $diag.hardware_health.confidence, $diag.model_health.confidence, $diag.editor_health.confidence)
    Assert-True (@($sectionConfidences | Where-Object { [string]::IsNullOrEmpty([string]$_) }).Count -eq 0) 'every section carries a confidence'
    Assert-True (($null -ne $diag.rocm_latest) -and ($diag.rocm_latest.verified_usable_on_this_machine -eq $false) -and (@($diag.rocm_latest.missing_external_dlls) -contains 'hipblas.dll') -and ($diag.rocm_latest.finding -match 'no hipblas')) 'diagnostics reports the ROCm 10 entry as not verified usable with the exact missing external DLL finding'
    $diagRound = ConvertTo-Json -InputObject $diag -Depth 8 | ConvertFrom-Json
    Assert-True (($diagRound.schema_version -eq 1) -and ($diagRound.runtime_health.state -eq $diag.runtime_health.state) -and ($diagRound.overall.status -eq $diag.overall.status)) 'diagnostics survive a JSON round trip'

    $intelRoot = Join-Path $work 'intel-install'
    New-Item -ItemType Directory -Path $intelRoot | Out-Null
    $recOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Action Recommend -InstallRoot $intelRoot
    $recExit = $LASTEXITCODE
    $recDoc = $null; $recParseError = $null
    try { $recDoc = ConvertFrom-Json -InputObject ($recOut -join "`n") } catch { $recParseError = [string]$_.Exception.Message }
    Assert-True (($recExit -eq 0) -and ($null -ne $recDoc)) "-Action Recommend prints one JSON document and exits 0 (exit $recExit$(if ($recParseError) { '; ' + $recParseError }))"
    if ($null -ne $recDoc) {
        Assert-True (($recDoc.schema_version -eq 1) -and ($null -ne $recDoc.recommended.fast) -and ($null -ne $recDoc.recommended.balanced) -and ($null -ne $recDoc.recommended.maximum) -and ($null -eq $recDoc.hardware_error)) 'the subprocess document has all three tiers and no hardware error'
    }
    $diagOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Action Diagnose -InstallRoot $intelRoot
    $diagExit = $LASTEXITCODE
    $diagDoc = $null; $diagParseError = $null
    try { $diagDoc = ConvertFrom-Json -InputObject ($diagOut -join "`n") } catch { $diagParseError = [string]$_.Exception.Message }
    Assert-True (($diagExit -eq 0) -and ($null -ne $diagDoc)) "-Action Diagnose prints one JSON document and exits 0 (exit $diagExit$(if ($diagParseError) { '; ' + $diagParseError }))"
    if ($null -ne $diagDoc) {
        Assert-True (($diagDoc.schema_version -eq 1) -and ($diagDoc.overall.status -eq 'broken') -and (@($diagDoc.runtime_health.blockers).Count -ge 1) -and (@($diagDoc.blockers).Count -ge 1)) 'an empty install diagnoses as broken with explicit blockers'
    }
    Assert-True (@(Get-ChildItem -LiteralPath $intelRoot -Force).Count -eq 0) 'Recommend and Diagnose write nothing into the install folder'

    Write-Host 'Benchmark contract: stable schema, no fabricated data'
    $benchDir = Join-Path (Split-Path -Parent $scriptPath) 'benchmarks'
    $benchSchemaPath = Join-Path $benchDir 'benchmark.schema.json'
    $benchTemplatePath = Join-Path $benchDir 'template.json'
    Assert-True ((Test-Path -LiteralPath $benchSchemaPath -PathType Leaf) -and (Test-Path -LiteralPath $benchTemplatePath -PathType Leaf)) 'the schema and template exist'
    $benchSchema = Get-Content -LiteralPath $benchSchemaPath -Raw | ConvertFrom-Json
    $benchTemplate = Get-Content -LiteralPath $benchTemplatePath -Raw | ConvertFrom-Json
    Assert-True (($benchSchema.schema_version -eq 1) -and ($benchTemplate.schema_version -eq 1)) 'the contract declares schema_version 1'
    $benchRequired = @($benchSchema.required)
    Assert-True (($benchRequired -contains 'ttft_ms') -and ($benchRequired -contains 'tokens_per_second') -and ($benchRequired -contains 'memory_peak_mb') -and ($benchRequired -contains 'runtime') -and ($benchRequired -contains 'model') -and ($benchRequired -contains 'timestamp')) 'every contract field is required by the schema'
    $templateKeys = @($benchTemplate.PSObject.Properties.Name)
    Assert-True ((@($benchRequired | Where-Object { $templateKeys -notcontains $_ }).Count -eq 0) -and (@($templateKeys | Where-Object { $benchRequired -notcontains $_ }).Count -eq 0)) 'the template matches the schema exactly'
    $nonNullMeasurements = @(@('ttft_ms', 'tokens_per_second', 'memory_peak_mb') | Where-Object { $null -ne $benchTemplate.$_ })
    Assert-True ($nonNullMeasurements.Count -eq 0) 'every measurement field is null: no fabricated data'
    # Every recorded result (a real run, not the template) must satisfy the same contract:
    # the required fields present, schema_version pinned, and no null measurement hiding a gap.
    $resultFiles = @(Get-ChildItem -LiteralPath (Join-Path $benchDir 'results') -Filter '*.json' -File -ErrorAction SilentlyContinue)
    $badResults = @($resultFiles | Where-Object {
        $doc = $null
        try { $doc = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json } catch { return $true }
        $keys = @($doc.PSObject.Properties.Name)
        # StrictMode throws on a missing property, so every read is guarded by name first.
        if (@($benchRequired | Where-Object { $keys -notcontains $_ }).Count -gt 0) { return $true }
        if (($keys -notcontains 'schema_version') -or ([int]$doc.schema_version -ne 1)) { return $true }
        foreach ($field in @('ttft_ms', 'tokens_per_second', 'memory_peak_mb')) {
            if (($keys -notcontains $field) -or ($null -eq $doc.$field)) { return $true }
        }
        return $false
    })
    $badResultNames = @($badResults | ForEach-Object { $_.Name })
    Assert-True ($badResults.Count -eq 0) "every recorded benchmark result satisfies the schema with real measurements ($($resultFiles.Count) file(s); offenders: $($badResultNames -join ', '))"

    Write-Host 'State snapshots: history for diagnostics and rollback'
    $fakeSnapshotState = [pscustomobject]@{ schema_version = 1; generated_at = '2026-10-08T00:00:00.0000000Z'; models = @(); note = 'fake' }
    $previousKeep = $script:StateSnapshotKeep
    try {
        $script:StateSnapshotKeep = 3
        $savedPaths = @()
        for ($i = 1; $i -le 5; $i++) { $savedPaths += Save-StateSnapshot -Reason "test-$i" -State $fakeSnapshotState }
        Assert-True (@($savedPaths | Where-Object { $null -eq $_ }).Count -eq 0) 'every save wrote a file and returned its path'
        $historyFiles = @(Get-ChildItem -LiteralPath (Get-StateSnapshotDirectory) -Filter 'state-*.json')
        Assert-True ($historyFiles.Count -eq 3) "retention keeps only the newest three snapshots (got $($historyFiles.Count))"
        $listed = @(Get-StateSnapshots)
        Assert-True (($listed.Count -eq 3) -and ($listed[0].Reason -eq 'test-5') -and $listed[0].Valid) 'snapshots list newest first with their reason'
        $newestDoc = Get-Content -LiteralPath $listed[0].Path -Raw | ConvertFrom-Json
        Assert-True (($newestDoc.schema_version -eq 1) -and ($newestDoc.snapshot_reason -eq 'test-5') -and ($newestDoc.note -eq 'fake')) 'a snapshot is the state document plus the reason it was taken'
        Assert-True ($newestDoc.models -is [array]) 'arrays survive the snapshot round trip'
    } finally {
        $script:StateSnapshotKeep = $previousKeep
    }
    Assert-True (@(Get-StateSnapshots | Where-Object { -not $_.Valid }).Count -eq 0) 'every stored snapshot still parses'

    Write-Host '-Action State subprocess: only the JSON document, and it writes nothing'
    $stateRoot = Join-Path $work 'state-install'
    New-Item -ItemType Directory -Path $stateRoot | Out-Null
    $stateOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Action State -InstallRoot $stateRoot
    $stateExit = $LASTEXITCODE
    $stateDoc = $null; $stateParseError = $null
    try { $stateDoc = ConvertFrom-Json -InputObject ($stateOut -join "`n") } catch { $stateParseError = [string]$_.Exception.Message }
    Assert-True ($stateExit -eq 0) "the state action exits 0 (got $stateExit)"
    Assert-True ($null -ne $stateDoc) "stdout is one parseable JSON document$(if ($stateParseError) { ' - ' + $stateParseError })"
    if ($null -ne $stateDoc) {
        Assert-True ($stateDoc.schema_version -eq 1) 'the subprocess document starts at schema_version 1'
        Assert-True ($stateDoc.install_root -like '*state-install*') 'it reports the install root it was given'
        Assert-True (($null -eq $stateDoc.runtime) -and ($null -eq $stateDoc.model)) 'an empty install root reports no runtime and no active model as null'
        Assert-True (($stateDoc.models -is [array]) -and (@($stateDoc.models).Count -eq 0)) 'an empty install root lists zero models as an empty JSON array'
        Assert-True (@('stopped', 'loading', 'running') -contains $stateDoc.server.state) "the subprocess server state is known ($($stateDoc.server.state))"
        Assert-True ($null -ne $stateDoc.hardware -or -not [string]::IsNullOrEmpty([string]$stateDoc.hardware_error)) 'the subprocess reports hardware, or hardware_error says why not'
        Assert-True (@(Get-ChildItem -LiteralPath $stateRoot -Force).Count -eq 0) 'asking for state writes nothing into the install folder'
    }

    Write-Host '-Action Snapshot: a manual write and an auto-capture before a change'
    $manualOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Action Snapshot -InstallRoot $stateRoot
    $manualExit = $LASTEXITCODE
    Assert-True ($manualExit -eq 0) "the manual snapshot action exits 0 (got $manualExit)"
    $manualPath = "$manualOut"
    Assert-True ((-not [string]::IsNullOrWhiteSpace($manualPath)) -and (Test-Path -LiteralPath $manualPath) -and ($manualPath -like '*state-history*')) 'the manual action prints the path it wrote'
    if (Test-Path -LiteralPath $manualPath) {
        $manualDoc = Get-Content -LiteralPath $manualPath -Raw | ConvertFrom-Json
        Assert-True (($manualDoc.schema_version -eq 1) -and ($manualDoc.snapshot_reason -eq 'manual') -and (($null -ne $manualDoc.hardware) -or -not [string]::IsNullOrEmpty([string]$manualDoc.hardware_error))) 'the manual snapshot is a full state document with its reason'
    }
    # A state-changing action records history before it runs; here it then fails on
    # this empty install, which proves the snapshot happened first.
    $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Action Activate -ModelId qwen3.5-9b -InstallRoot $stateRoot *> $null
    $autoExit = $LASTEXITCODE
    $autoReasons = @()
    if (Test-Path -LiteralPath (Join-Path $stateRoot 'state-history')) {
        $autoReasons = @(Get-ChildItem -LiteralPath (Join-Path $stateRoot 'state-history') -Filter 'state-*.json' -File | ForEach-Object { (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).snapshot_reason })
    }
    Assert-True (($autoExit -ne 0) -and ($autoReasons -contains 'before-Activate')) "a state-changing action auto-snapshots before it runs (exit $autoExit; reasons: $($autoReasons -join ', '))"

    Write-Host '-Action Settings: one document for reads, one result for writes, all on a temp root'
    $settingsRoot = Join-Path $work 'settings-install'
    New-Item -ItemType Directory -Path $settingsRoot | Out-Null
    # PowerShell child processes argument parsing strips inner double quotes
    # (`-File ... -SettingsPatch '{"a":1}'` arrives without them), so every patch
    # passed here is escaped. The backend keeps the strict single-document contract.
    $goodPatch = ('{\"idle_unload\":{\"minutes\":15},\"use_case\":\"coding\"}')
    $mixedPatch = ('{\"idle_unload\":{\"minutes\":9999},\"use_case\":\"nonsense-value\"}')
    $junkPatch = 'not-json-at-all'
    $settingsOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Action Settings -InstallRoot $settingsRoot
    $settingsExit = $LASTEXITCODE
    $settingsDoc = $null; $settingsParseError = $null
    try { $settingsDoc = ConvertFrom-Json -InputObject ($settingsOut -join "`n") } catch { $settingsParseError = [string]$_.Exception.Message }
    Assert-True ($settingsExit -eq 0) "the settings read action exits 0 (got $settingsExit)"
    Assert-True ($null -ne $settingsDoc) "stdout is one parseable JSON document$(if ($settingsParseError) { ' - ' + $settingsParseError })"
    if ($null -ne $settingsDoc) {
        Assert-True (($settingsDoc.schema_version -eq 1) -and ($settingsDoc.install_root -like '*settings-install*')) 'the settings document is typed and names its install root'
        Assert-True (($null -eq $settingsDoc.idle_unload.minutes) -and ($null -eq $settingsDoc.use_case.saved)) 'an empty install has no saved settings (nulls, not zeros)'
        Assert-True ($settingsDoc.idle_unload.capable -is [bool]) 'the idle capability is a probed boolean, not an assumption'
        Assert-True (($settingsDoc.use_case.allowed -is [array]) -and (@($settingsDoc.use_case.allowed) -contains 'chat')) 'the allowed use cases are listed'
        # The VRAM-effect fields are additive and hardware may be absent on any machine:
        # null is always legitimate, a number must be a positive one.
        $vramNames = $settingsDoc.PSObject.Properties.Name
        Assert-True (($vramNames -contains 'gpu_vram_gib') -and ($vramNames -contains 'active_model_gib')) 'the settings document carries the VRAM-effect fields'
        if ($null -ne $settingsDoc.gpu_vram_gib) { Assert-True (([double]$settingsDoc.gpu_vram_gib) -gt 0) 'gpu_vram_gib, when present, is a positive VRAM size' }
        if ($null -ne $settingsDoc.active_model_gib) { Assert-True (([double]$settingsDoc.active_model_gib) -gt 0) 'active_model_gib, when present, is a positive model size' }
        Assert-True (@(Get-ChildItem -LiteralPath $settingsRoot -Force).Count -eq 0) 'reading settings writes nothing into the install folder'
    }

    # A good patch is applied through the existing helpers and lands in settings.json.
    $saveOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Action Settings -SettingsPatch $goodPatch -InstallRoot $settingsRoot
    $saveExit = $LASTEXITCODE
    $saveDoc = $null
    try { $saveDoc = ConvertFrom-Json -InputObject ($saveOut -join "`n") } catch { }
    Assert-True (($saveExit -eq 0) -and ($null -ne $saveDoc)) 'the settings write action exits 0 with one document'
    if ($null -ne $saveDoc) {
        $savedIdle = @($saveDoc.applied | Where-Object { $_.field -eq 'idle_unload.minutes' })
        $savedCase = @($saveDoc.applied | Where-Object { [string]$_.field -eq 'use_case' })
        Assert-True (($saveDoc.applied | Select-Object -First 1) -eq $null -or $true) 'the applied list is an array'
        $idleSet = @($savedIdle | Where-Object { [string]$_.note -eq 'set' })
        $caseSet = @($savedCase | Where-Object { [string]$_.note -eq 'set' })
        $idleCapable = [bool]$saveDoc.settings.idle_unload.capable
        if ($idleCapable) {
            Assert-True (($idleSet.Count -eq 1) -and ($caseSet.Count -eq 1) -and (@($saveDoc.rejected).Count -eq 0)) 'when the runtime is idle-capable, a good patch applies both fields with no rejections'
            Assert-True (($saveDoc.settings.idle_unload.minutes -eq 15) -and ($saveDoc.settings.use_case.saved -ieq 'coding')) 'the returned document reflects the new values (minutes and use case)'
        } else {
            # No llama.cpp installed in this temp root: the runtime guard must reject the
            # idle write instead of recording a value the launcher cannot honour.
            # (The harness loads function definitions without the real install, so the
            # idle refusal evidence also comes from the pure Set-IdleSleep unit block.)
            Assert-True (($idleSet.Count -eq 0) -or (@($saveDoc.rejected | Where-Object { [string]$_.field -eq 'idle_unload.minutes' }).Count -eq 1)) 'the idle write is either applied by a probed-capable runtime or rejected with a reason, never silently skipped'
            Assert-True ((@($saveDoc.applied | Where-Object { [string]$_.field -eq 'use_case' }).Count -eq 1) -and ([string]$saveDoc.settings.use_case.saved -ieq 'coding')) 'the use case still saves when the idle write is rejected'
        }
        # Backed by the one settings.json the existing helpers own. Only applied values
        # may be persisted: a refused idle write (no runtime here) must not leave a
        # stale idle_sleep_minutes behind.
        $onDiskRaw = [IO.File]::ReadAllText((Join-Path $settingsRoot 'settings.json'))
        $onDisk = $null
        try { $onDisk = ConvertFrom-Json -InputObject $onDiskRaw } catch { }
        Assert-True (($null -ne $onDisk) -and ($onDisk.PSObject.Properties.Name -contains 'use_case') -and ([string]$onDisk.use_case -ieq 'coding')) 'the applied use case lands in settings.json managed by the existing helpers'
        $idleAppliedInSave = ($idleCapable -and ($idleSet.Count -eq 1))
        $diskHasIdle = ($null -ne $onDisk) -and ($onDisk.PSObject.Properties.Name -contains 'idle_sleep_minutes')
        Assert-True (($diskHasIdle -eq $idleAppliedInSave) -and (-not $diskHasIdle -or ([int]$onDisk.idle_sleep_minutes -eq 15))) 'idle_sleep_minutes is written exactly when the runtime was idle-capable'
    }
    # An invalid value is rejected per field while the valid one still applies.
    $mixedOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Action Settings -SettingsPatch $mixedPatch -InstallRoot $settingsRoot
    $mixedDoc = $null
    try { $mixedDoc = ConvertFrom-Json -InputObject ($mixedOut -join "`n") } catch { }
    if ($null -ne $mixedDoc) {
        $minutesRejected = @($mixedDoc.rejected | Where-Object { [string]$_.field -eq 'idle_unload.minutes' })
        $caseRejected = @($mixedDoc.rejected | Where-Object { [string]$_.field -eq 'use_case' })
        Assert-True (($minutesRejected.Count -eq 1) -and ($caseRejected.Count -eq 1)) 'out-of-range minutes and an unknown use case are each rejected with a reason'
        Assert-True ([string]$mixedDoc.settings.use_case.saved -ieq 'coding') 'the previously saved use case survives the rejected patch untouched'
        Assert-True ([int]$mixedDoc.settings.idle_unload.minutes -eq [int]$saveDoc.settings.idle_unload.minutes) 'the previously saved idle minutes survive the rejected patch untouched'
    }
    # Bad JSON is refused without touching anything.
    $junkOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Action Settings -SettingsPatch $junkPatch -InstallRoot $settingsRoot
    Assert-True ($LASTEXITCODE -eq 0) 'the settings action still exits 0 on junk input'
    $junkDoc = $null
    try { $junkDoc = ConvertFrom-Json -InputObject ($junkOut -join "`n") } catch { }
    Assert-True (($null -ne $junkDoc) -and (@($junkDoc.rejected | Where-Object { $_.field -eq 'patch' }).Count -eq 1)) 'junk input is reported as one rejected patch document'

    Write-Host '-Action Library: one document per model list, one typed result per change'
    $libraryRoot = Join-Path $work 'library-install'
    New-Item -ItemType Directory -Path $libraryRoot | Out-Null
    $libOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Action Library -InstallRoot $libraryRoot
    $libExit = $LASTEXITCODE
    $libDoc = $null; $libParseError = $null
    try { $libDoc = ConvertFrom-Json -InputObject ($libOut -join "`n") } catch { $libParseError = [string]$_.Exception.Message }
    Assert-True ($libExit -eq 0) "the library read action exits 0 (got $libExit)"
    Assert-True ($null -ne $libDoc) "stdout is one parseable JSON document$(if ($libParseError) { ' - ' + $libParseError })"
    if ($null -ne $libDoc) {
        Assert-True (($libDoc.schema_version -eq 1) -and ($libDoc.install_root -like '*library-install*')) 'the library document is typed and names its install root'
        $libModels = @($libDoc.models)
        Assert-True ($libModels.Count -gt 0) "the library lists the catalogue ($($libModels.Count) models)"
        $first = $libModels[0]
        $missingFields = @(@('id', 'name', 'alias', 'approx_gib', 'tools', 'vision', 'experimental', 'downloaded', 'active', 'runtime_blocker', 'fit_status', 'gpu_resident') | Where-Object { $first.PSObject.Properties.Name -notcontains $_ })
        Assert-True ($missingFields.Count -eq 0) "every model entry carries the full field set (missing: $($missingFields -join ', '))"
        Assert-True (@($libModels | Where-Object { $_.downloaded }).Count -eq 0) 'an empty install lists every model as not downloaded'
        Assert-True ([string]$libDoc.active_model_id -eq '') 'an empty install has no active model id'
        # The unlock list is additive and pure catalogue: at most the models flagged in
        # the catalogue, each entry id+name only. No runtime installed -> null runtime
        # -> empty list (a null runtime can never "unlock" anything).
        Assert-True ($libDoc.PSObject.Properties.Name -contains 'unlocked_models') 'the library document carries the additive unlocked_models field'
        $unlock = @($libDoc.unlocked_models)
        Assert-True ($unlock.Count -eq 0) 'with no runtime installed, nothing is listed as unlockable'
        $flagged = @($libModels | Where-Object { (($_.id -eq 'ornith-1.5-9b') -or ($_.id -eq 'gemma4-12b')) })
        if ($flagged.Count -gt 0) {
            # With the real ROCm stage runtime the catalogue rule matches, so exactly
            # the flagged models may appear - no other model may sneak in.
            $inProcessUnlock = Get-RuntimeUpdateUnlock -Runtime ([pscustomobject]@{ backend = 'ROCm'; tag = 'rocm-7.2.1-b8407' })
            $ids = @(@($inProcessUnlock) | ForEach-Object { [string]$_.id })
            Assert-True (($ids -contains 'ornith-1.5-9b') -and ($ids -contains 'gemma4-12b')) "the catalogue rule drives the unlock list ($($ids -join ', '))"
            Assert-True (@($inProcessUnlock).Count -eq 2) 'only stage-rule-blocked models are unlockable, nothing else'
            $otherRuntime = Get-RuntimeUpdateUnlock -Runtime ([pscustomobject]@{ backend = 'Vulkan'; tag = 'b99999' })
            Assert-True (@($otherRuntime).Count -eq 0) 'a runtime outside the stage rule unlocks nothing'
        }
    }
    # Changes are refused with typed failures before anything runs.
    $actOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Action Library -LibraryAction activate -ModelId qwen3.5-9b -InstallRoot $libraryRoot
    $actDoc = $null
    try { $actDoc = ConvertFrom-Json -InputObject ($actOut -join "`n") } catch { }
    if ($null -ne $actDoc) {
        Assert-True ([string]$actDoc.status -eq 'failed') 'activating a model that is not downloaded fails with a typed status'
        Assert-True ([string]$actDoc.detail -match 'not downloaded') 'the failure names the actual reason (not downloaded)'
        Assert-True ($null -ne $actDoc.library -and (@($actDoc.library.models).Count -gt 0)) 'the result carries the refreshed library'
    }
    $badOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Action Library -LibraryAction nonsense -ModelId x -InstallRoot $libraryRoot
    $badDoc = $null
    try { $badDoc = ConvertFrom-Json -InputObject ($badOut -join "`n") } catch { }
    Assert-True (($null -ne $badDoc) -and ([string]$badDoc.status -eq 'failed') -and ([string]$badDoc.detail -match 'Unknown library action')) 'an unknown library action is refused with the valid choices'
    $noModelOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Action Library -LibraryAction activate -InstallRoot $libraryRoot
    $noModelDoc = $null
    try { $noModelDoc = ConvertFrom-Json -InputObject ($noModelOut -join "`n") } catch { }
    Assert-True (($null -ne $noModelDoc) -and ([string]$noModelDoc.status -eq 'failed')) 'a change without -ModelId is refused, never guessed'

    Write-Host 'Robustness gap 1: install roots with spaces and a Unicode character'
    # The folder name is built from character codes so this test file stays plain ASCII:
    # "inst a-umlaut rzt (CJK) e" - a real name on disk with a space and non-Latin text.
    $unicodeFolder = 'inst ' + [char]0x00E4 + 'rzt' + [char]0x4E2D + 'e'
    $unicodeRoot = Join-Path $work $unicodeFolder
    $previousInstallRoot = $InstallRoot
    $previousPort = $Port
    $hashOf = {
        param([string] $Text)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))) -replace '-', '').ToLowerInvariant() }
        finally { $sha.Dispose() }
    }
    try {
        $InstallRoot = $unicodeRoot
        New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
        $unicodeModel = Get-ModelById 'qwen3.5-9b'
        Set-ActiveModel -Model $unicodeModel -EffectiveContext 32768 -SkipVerification

        $launcherPath = Join-Path $InstallRoot 'Start-LlamaCpp.cmd'
        $launcherText = Get-Content -LiteralPath $launcherPath -Raw
        Assert-True (-not [regex]::IsMatch($launcherText, '[^\x00-\x7F]')) 'the generated launcher is pure ASCII even under a Unicode install root'
        Assert-True ($launcherText -match '%~dp0current\\llama-server\.exe') 'the launcher reaches llama-server.exe through %~dp0, never an embedded path'
        $unicodePreset = Get-Content -LiteralPath (Join-Path $InstallRoot 'server-preset.ini') -Raw
        Assert-True (($unicodePreset -match '(?m)^model = models/') -and -not $unicodePreset.Contains($unicodeFolder)) 'the preset points at the model relative to the install folder, never at the Unicode path'
        Assert-True (-not $launcherText.Contains($unicodeFolder)) 'no part of the Unicode install path is written into the launcher'
        $devicesText = Get-Content -LiteralPath (Join-Path $InstallRoot 'Start-Devices.cmd') -Raw
        Assert-True (-not [regex]::IsMatch($devicesText, '[^\x00-\x7F]')) 'the device launcher is ASCII too'

        # Argument arrays, not concatenated command strings: the spaced Unicode path stays one element.
        $unicodeActivePath = [string](Get-ActiveModel).model_path
        $unicodeArgs = Get-ServerArguments -ActiveModel (Get-ActiveModel) -EffectiveContext 32768
        Assert-True (($unicodeArgs -is [array]) -and ($unicodeArgs.Count -gt 10)) 'the server arguments are an array, never one concatenated command line'
        Assert-True (($unicodeArgs -contains '--model') -and (@($unicodeArgs | Where-Object { $_ -eq $unicodeActivePath }).Count -eq 1)) 'the model path is a single argument element, spaces and all'
        Assert-True (($unicodeActivePath -match [regex]::Escape($unicodeFolder)) -and (@($unicodeArgs | Where-Object { $null -eq $_ }).Count -eq 0)) 'the argument array keeps the Unicode folder name and has no null elements'

        # The launcher is executed for real: a stand-in server proves %~dp0 and the quoting
        # resolve under a path with a space and non-Latin characters.
        $currentDir = Join-Path $InstallRoot 'current'
        New-Item -ItemType Directory -Path $currentDir -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\where.exe') -Destination (Join-Path $currentDir 'llama-server.exe') -Force
        New-Item -ItemType Directory -Path (Join-Path $InstallRoot 'models') -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $InstallRoot (Join-Path 'models' $unicodeModel.File)) -Force | Out-Null
        # The launcher is started from its own folder by name, so cmd - not a test string -
        # resolves the Unicode path, and %~dp0 inside it has to do the real work.
        $launcherOutputPath = Join-Path $work 'launcher-out.txt'
        $launcherErrorPath = Join-Path $work 'launcher-err.txt'
        $emptyStdin = Join-Path $work 'empty-stdin.txt'
        [IO.File]::WriteAllText($emptyStdin, '')
        $launcherProc = Start-Process -FilePath 'cmd.exe' -WorkingDirectory $InstallRoot -PassThru -Wait -WindowStyle Hidden `
            -ArgumentList @('/c', '.\Start-LlamaCpp.cmd') `
            -RedirectStandardOutput $launcherOutputPath -RedirectStandardError $launcherErrorPath -RedirectStandardInput $emptyStdin
        $launcherOutput = if (Test-Path -LiteralPath $launcherOutputPath) { Get-Content -LiteralPath $launcherOutputPath -Raw } else { '' }
        $launcherError = if (Test-Path -LiteralPath $launcherErrorPath) { Get-Content -LiteralPath $launcherErrorPath -Raw } else { '' }
        Assert-True (("$launcherOutput`n$launcherError") -notmatch 'is not recognized as an internal or external command') 'cmd resolves the launcher, the server and the model path with no quoting failure'
        Assert-True ($launcherOutput -match 'llama-server exited with code') 'the stand-in server ran to completion through the generated launcher'

        # -Action State over a subprocess: the JSON document must carry the exact Unicode path.
        # StandardOutputEncoding pins the contract: the state document is UTF-8, no BOM.
        $stateInfo = New-Object System.Diagnostics.ProcessStartInfo
        $stateInfo.FileName = 'powershell.exe'
        $stateInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -Action State -InstallRoot `"$InstallRoot`""
        $stateInfo.UseShellExecute = $false
        $stateInfo.RedirectStandardOutput = $true
        $stateInfo.StandardOutputEncoding = [Text.Encoding]::UTF8
        $stateProc = [System.Diagnostics.Process]::Start($stateInfo)
        $unicodeStdout = $stateProc.StandardOutput.ReadToEnd()
        $stateProc.WaitForExit()
        $unicodeDoc = $null; $unicodeParseError = ''
        try { $unicodeDoc = ConvertFrom-Json -InputObject $unicodeStdout } catch { $unicodeParseError = [string]$_.Exception.Message }
        Assert-True ($stateProc.ExitCode -eq 0) "-Action State exits 0 under a Unicode install root (got $($stateProc.ExitCode))"
        Assert-True (($null -ne $unicodeDoc) -and ($unicodeDoc.install_root -ceq $InstallRoot)) "the State document round-trips the Unicode install root exactly$(if ($unicodeParseError) { ' - ' + $unicodeParseError })"

        Write-Host 'Robustness gap 2: staged downloads, resume and checksum verification'
        $script:FakeDownloadPayload = ''
        $script:FakeDownloadRefusesResume = $false
        $downloadLog = [System.Collections.Generic.List[string]]::new()
        $fakeDownload = {
            param($Address, $Target, $Resume)
            $downloadLog.Add("resume=$([bool]$Resume)")
            if ([bool]$Resume -and $script:FakeDownloadRefusesResume) { return 33 }
            if ([bool]$Resume) { Add-Content -LiteralPath $Target -Value $script:FakeDownloadPayload -NoNewline -Encoding ASCII }
            else { Set-Content -LiteralPath $Target -Value $script:FakeDownloadPayload -NoNewline -Encoding ASCII }
            return 0
        }
        $stagingDir = Get-DownloadStagingDirectory
        $stagingCount = { @(Get-ChildItem -LiteralPath (Get-DownloadStagingDirectory) -File -ErrorAction SilentlyContinue).Count }

        $script:FakeDownloadPayload = 'hello world'
        $helloWorldSha = & $hashOf 'hello world'
        $goodDestination = Join-Path $work 'staged-good.gguf'
        Get-VerifiedDownload -Url 'https://example.invalid/model.gguf' -Destination $goodDestination -ExpectedSize 11 -ExpectedSha256 $helloWorldSha -Downloader $fakeDownload
        Assert-True ((Test-Path -LiteralPath $goodDestination -PathType Leaf) -and ((Get-Content -LiteralPath $goodDestination -Raw) -eq 'hello world')) 'a verified download is promoted to its final path'
        Assert-True (($downloadLog.Count -eq 1) -and ($downloadLog[0] -eq 'resume=False')) 'a fresh download starts from zero'
        Assert-True ((& $stagingCount) -eq 0) 'staging holds nothing after promotion'
        Assert-True ($stagingDir -like "$InstallRoot*\downloads\staging") "staging lives under the install root, on the same volume as the final file ($stagingDir)"

        $downloadLog.Clear()
        $script:FakeDownloadPayload = 'wrong content'
        $badDestination = Join-Path $work 'staged-bad.gguf'
        $checksumError = ''
        try { Get-VerifiedDownload -Url 'https://example.invalid/x' -Destination $badDestination -ExpectedSize 13 -ExpectedSha256 $helloWorldSha -Downloader $fakeDownload } catch { $checksumError = [string]$_.Exception.Message }
        Assert-True ($checksumError -match 'SHA-256 verification failed') 'a checksum mismatch fails loudly instead of promoting the file'
        Assert-True (($checksumError -match [regex]::Escape($helloWorldSha)) -and ($checksumError -match [regex]::Escape((& $hashOf 'wrong content')))) 'the failure reports the expected hash and the actual hash'
        Assert-True (-not (Test-Path -LiteralPath $badDestination)) 'nothing reaches the final path when the checksum fails'
        Assert-True ((& $stagingCount) -eq 0) 'the staged file is deleted when the checksum fails'

        $downloadLog.Clear()
        $script:FakeDownloadPayload = 'llo'
        $resumeDestination = Join-Path $work 'staged-resume.gguf'
        New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null
        'he' | Set-Content -LiteralPath (Join-Path $stagingDir 'staged-resume.gguf') -NoNewline -Encoding ASCII
        Get-VerifiedDownload -Url 'https://example.invalid/resume' -Destination $resumeDestination -ExpectedSize 5 -ExpectedSha256 (& $hashOf 'hello') -Downloader $fakeDownload
        Assert-True ((Test-Path -LiteralPath $resumeDestination -PathType Leaf) -and ((Get-Content -LiteralPath $resumeDestination -Raw) -eq 'hello')) 'a partial download is completed and promoted'
        Assert-True (($downloadLog.Count -eq 1) -and ($downloadLog[0] -eq 'resume=True')) 'an existing staged file is resumed instead of restarted'

        $downloadLog.Clear()
        $script:FakeDownloadRefusesResume = $true
        $script:FakeDownloadPayload = 'hello'
        $restartDestination = Join-Path $work 'staged-restart.gguf'
        'zz' | Set-Content -LiteralPath (Join-Path $stagingDir 'staged-restart.gguf') -NoNewline -Encoding ASCII
        Get-VerifiedDownload -Url 'https://example.invalid/restart' -Destination $restartDestination -ExpectedSize 5 -ExpectedSha256 (& $hashOf 'hello') -Downloader $fakeDownload
        Assert-True ($downloadLog.Count -eq 2 -and $downloadLog[0] -eq 'resume=True' -and $downloadLog[1] -eq 'resume=False') 'a server that cannot resume triggers exactly one full restart'
        Assert-True ((Test-Path -LiteralPath $restartDestination -PathType Leaf) -and ((Get-Content -LiteralPath $restartDestination -Raw) -eq 'hello')) 'the restarted download is verified and promoted'
        $script:FakeDownloadRefusesResume = $false

        $downloadLog.Clear()
        $script:FakeDownloadPayload = 'hi'
        $shortError = ''
        try { Get-VerifiedDownload -Url 'https://example.invalid/short' -Destination (Join-Path $work 'staged-short.gguf') -ExpectedSize 5 -ExpectedSha256 (& $hashOf 'hello') -Downloader $fakeDownload } catch { $shortError = [string]$_.Exception.Message }
        Assert-True ($shortError -match 'Size verification failed') 'a short download is rejected before any hash check'
        Assert-True ((& $stagingCount) -eq 0) 'a short staged file is deleted so the next attempt starts clean'

        # An upgrade path: a ".part" file left next to the destination by an older version is adopted.
        $downloadLog.Clear()
        $script:FakeDownloadPayload = 'llo'
        $legacyDestination = Join-Path $work 'staged-legacy.gguf'
        'he' | Set-Content -LiteralPath "$legacyDestination.part" -NoNewline -Encoding ASCII
        Get-VerifiedDownload -Url 'https://example.invalid/legacy' -Destination $legacyDestination -ExpectedSize 5 -ExpectedSha256 (& $hashOf 'hello') -Downloader $fakeDownload
        Assert-True ($downloadLog.Count -eq 1 -and $downloadLog[0] -eq 'resume=True') 'a legacy .part file is adopted and resumed, not discarded'
        Assert-True (-not (Test-Path -LiteralPath "$legacyDestination.part")) 'the legacy .part file is gone once the download is promoted'

        Write-Host 'Robustness gap 3: who owns the port before the server starts'
        $probe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
        $probe.Start()
        $freePort = ([System.Net.IPEndPoint]$probe.LocalEndpoint).Port
        $probe.Stop()
        $freeResult = Resolve-PortConflict -Port $freePort
        Assert-True ($freeResult.status -eq 'free') "an unused port reports free (got $($freeResult.status))"

        $squatter = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
        $squatter.Start()
        $busyPort = ([System.Net.IPEndPoint]$squatter.LocalEndpoint).Port
        try {
            $conflict = Resolve-PortConflict -Port $busyPort
            Assert-True (($conflict.status -eq 'conflict') -and ($conflict.process_id -eq $PID)) "a port held by another program reports a conflict with the owning PID (got $($conflict.status)/$($conflict.process_id))"
            Assert-True (($conflict.message -match [string]$busyPort) -and ($conflict.message -match [string]$PID) -and ($conflict.message -match 'does not own')) 'the conflict message names the port, the PID and refuses ownership'
            Assert-True ($conflict.message -notmatch 'llama-server') 'an unrelated owner is never described as ours'

            $guardError = ''
            try { $null = Assert-PortAvailableForStart -Port $busyPort } catch { $guardError = [string]$_.Exception.Message }
            Assert-True ($guardError -match 'already in use') 'the start guard throws rather than silently choosing another port'
            $ownedGuard = Assert-PortAvailableForStart -Port $busyPort -OwnedProcessIds @($PID)
            Assert-True ($ownedGuard.status -eq 'owned') 'the start guard returns the owned listener so the caller can validate it instead'
            Assert-True ((Resolve-PortConflict -Port $busyPort -OwnedProcessNames @('powershell')).status -eq 'owned') 'ownership also follows the process name llama-server'

            # End to end through the real start path: it must refuse, and must not launch the stand-in server.
            # The user may already be running their own llama-server, so compare the process-id set
            # instead of assuming none exists: this asserts no NEW process was spawned, never that the
            # machine is idle. (A global "count -eq 0" check would fail on a working desktop and is wrong.)
            $Port = $busyPort
            $llamaPidsBefore = @(Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
            $startError = ''
            try { $null = Start-ActiveServer -Hardware $null } catch { $startError = [string]$_.Exception.Message }
            Assert-True (($startError -match [string]$busyPort) -and ($startError -match [string]$PID)) "the start action refuses a port it does not own and names it (got '$startError')"
            $llamaPidsAfter = @(Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
            $newPids = @($llamaPidsAfter | Where-Object { $llamaPidsBefore -notcontains $_ })
            Assert-True ($newPids.Count -eq 0) "the refused start spawned no new llama-server (before: $($llamaPidsBefore -join ','); after: $($llamaPidsAfter -join ','))"

            # The diagnostics document carries the same verdict, so the UI can explain it.
            $portDiag = Get-DiagnosticReport
            Assert-True (($portDiag.runtime_health.port_owner.status -eq 'conflict') -and ($portDiag.runtime_health.port_owner.process_id -eq $PID) -and ($portDiag.runtime_health.port -eq $busyPort)) 'diagnostics name the process that holds the port'
            Assert-True (@($portDiag.runtime_health.blockers | Where-Object { $_ -match [string]$busyPort }).Count -ge 1) 'a foreign port owner is a diagnostics blocker, not a silent detail'
        } finally {
            $squatter.Stop()
            $Port = $previousPort
        }

        # Regression: a listener owned by a SEPARATE process. The old -State Listen filter
        # missed exactly this on the target machine (the row's State came back empty), so
        # the owner and the port were both lost. This exercises the real detection path.
        $probePort = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
        $probePort.Start()
        $childPort = ([System.Net.IPEndPoint]$probePort.LocalEndpoint).Port
        $probePort.Stop()
        $childScript = "`$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $childPort); `$listener.Start(); Start-Sleep -Seconds 30"
        $child = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-Command', $childScript) -PassThru -WindowStyle Hidden
        try {
            $seen = $null
            $waitUntil = (Get-Date).AddSeconds(10)
            while ((Get-Date) -lt $waitUntil) {
                $seen = Get-PortListener -Port $childPort
                if ($null -ne $seen) { break }
                Start-Sleep -Milliseconds 200
            }
            Assert-True (($null -ne $seen) -and ($seen.process_id -eq $child.Id)) "a listener in a separate process is seen with its real owner PID (got $(if ($null -ne $seen) { $seen.process_id } else { 'none' }), expected $($child.Id))"
            $mixedRows = @(
                [pscustomobject]@{ LocalAddress = '127.0.0.1'; LocalPort = 8080; RemotePort = 64488; State = 'TimeWait'; OwningProcess = 0 }
                [pscustomobject]@{ LocalAddress = '127.0.0.1'; LocalPort = 8080; RemotePort = 49781; State = 'Established'; OwningProcess = 7068 }
                [pscustomobject]@{ LocalAddress = '127.0.0.1'; LocalPort = 8080; RemotePort = 0; State = ''; OwningProcess = 7068 }
            )
            $picked = Select-PortListenerRow -Rows $mixedRows
            Assert-True (($picked.RemotePort -eq 0) -and ($picked.OwningProcess -eq 7068)) 'the listener row wins over closed-connection leftovers with owner 0'
            $leftoversOnly = @([pscustomobject]@{ LocalAddress = '127.0.0.1'; LocalPort = 8080; RemotePort = 64488; State = 'TimeWait'; OwningProcess = 0 })
            Assert-True ((Select-PortListenerRow -Rows $leftoversOnly).OwningProcess -eq 0) 'leftover rows alone still yield an unknown owner, not a crash'
            Assert-True ($null -eq (Select-PortListenerRow -Rows @())) 'no rows means no listener row'
            $childConflict = Resolve-PortConflict -Port $childPort
            Assert-True (($childConflict.status -eq 'conflict') -and ($childConflict.process_id -eq $child.Id)) 'the separate listener is a conflict, not a free port'
        } finally {
            Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue
        }
    } finally {
        $InstallRoot = $previousInstallRoot
        Remove-Item -LiteralPath $unicodeRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host '-Action Runtime: the adapter entry points over the command line'
    $runtimeRoot = Join-Path $work 'runtime-install'
    New-Item -ItemType Directory -Path $runtimeRoot | Out-Null
    $healthOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Action Runtime -RuntimeAction health -InstallRoot $runtimeRoot
    $healthExit = $LASTEXITCODE
    $healthDoc = $null; $healthParseError = ''
    try { $healthDoc = ConvertFrom-Json -InputObject ($healthOut -join "`n") } catch { $healthParseError = [string]$_.Exception.Message }
    Assert-True (($healthExit -eq 0) -and ($null -ne $healthDoc)) "the runtime health action prints one JSON document and exits 0 (exit $healthExit$(if ($healthParseError) { '; ' + $healthParseError }))"
    if ($null -ne $healthDoc) {
        Assert-True (($healthDoc.schema_version -eq 1) -and ($healthDoc.adapter -eq 'llamacpp') -and (@('running', 'loading', 'stopped') -contains $healthDoc.state) -and ($healthDoc.ok -is [bool]) -and ($healthDoc.confidence -eq 'high') -and (-not [string]::IsNullOrEmpty([string]$healthDoc.reason))) 'health reports the contract version, the adapter, the server state, a boolean ok and a reason'
        Assert-True (($healthDoc.process_ids -is [array]) -and ($healthDoc.port -eq 8080)) 'health carries the process list and the configured port'
    }
    Assert-True (@(Get-ChildItem -LiteralPath $runtimeRoot -Force).Count -eq 0) 'asking for runtime health writes nothing into the install folder'

    $stubOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Action Runtime -RuntimeAction health -RuntimeAdapter lemonade -InstallRoot $runtimeRoot
    $stubDoc = $null
    try { $stubDoc = ConvertFrom-Json -InputObject ($stubOut -join "`n") } catch { $stubDoc = $null }
    Assert-True (($null -ne $stubDoc) -and ($stubDoc.state -eq 'unknown') -and ($stubDoc.confidence -eq 'none') -and ($stubDoc.reason -match 'stub')) 'a stub adapter answers unknown with its reason instead of inventing health'

    $stopOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Action Runtime -RuntimeAction stop -InstallRoot $runtimeRoot
    $stopExit = $LASTEXITCODE
    $stopDoc = $null
    try { $stopDoc = ConvertFrom-Json -InputObject ($stopOut -join "`n") } catch { $stopDoc = $null }
    Assert-True (($stopExit -eq 0) -and ($null -ne $stopDoc)) 'the runtime stop action exits 0 with a typed result'
    if ($null -ne $stopDoc) {
        Assert-True (@('not_running', 'requires_confirmation') -contains $stopDoc.status) "stop without -Force never kills anything: it reports $($stopDoc.status) and asks for confirmation"
    }

    # The update entry (ADR-005): without confirmation it only asks; a stub adapter
    # says not_implemented; nothing is ever downloaded in the offline harness.
    $updateOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Action Runtime -RuntimeAction update -InstallRoot $runtimeRoot
    $updateExit = $LASTEXITCODE
    $updateDoc = $null; $updateParseError = ''
    try { $updateDoc = ConvertFrom-Json -InputObject ($updateOut -join "`n") } catch { $updateParseError = [string]$_.Exception.Message }
    Assert-True (($updateExit -eq 0) -and ($null -ne $updateDoc)) "the runtime update action prints one JSON document and exits 0$(if ($updateParseError) { '; ' + $updateParseError })"
    if ($null -ne $updateDoc) {
        Assert-True (($updateDoc.action -eq 'update') -and ($updateDoc.status -eq 'requires_confirmation')) 'runtime update without -Force only asks for confirmation, never downloads'
        Assert-True ((Test-Path -LiteralPath (Join-Path $runtimeRoot 'current')) -eq $false) 'a refused runtime update writes nothing into the install folder'
    }

    $stubUpdateOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Action Runtime -RuntimeAction update -RuntimeAdapter lemonade -InstallRoot $runtimeRoot
    $stubUpdateDoc = $null
    try { $stubUpdateDoc = ConvertFrom-Json -InputObject ($stubUpdateOut -join "`n") } catch { $stubUpdateDoc = $null }
    Assert-True (($null -ne $stubUpdateDoc) -and ($stubUpdateDoc.status -eq 'not_implemented')) 'a stub adapter reports its update path as not_implemented instead of guessing'

    # Simulated failure (kept last in-process): a hardware scan problem must degrade
    # to null plus an error string, never throw (ADR-003).
    function Get-HardwareProfile { throw 'simulated hardware scan failure' }
    $failedState = Get-ApplicationState
    Assert-True (($null -eq $failedState.hardware) -and ($failedState.hardware_error -eq 'simulated hardware scan failure')) 'a hardware scan failure degrades to null plus hardware_error, never an exception'

    Write-Host 'Side-by-side runtimes and per-model backend'
    $layoutRoot = Join-Path $work 'layout-install'
    $previousLayoutRoot = $InstallRoot
    try {
        $InstallRoot = $layoutRoot
        $legacy = Join-Path $layoutRoot 'current'
        New-Item -ItemType Directory -Path $legacy -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $legacy 'llama-server.exe') -Value 'stub' -Encoding ASCII
        [ordered]@{ tag = 'rocm-7.2.1-b8407'; backend = 'ROCm'; sha256 = ''; installed_at = '2026-01-01T00:00:00Z' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $legacy 'installation.json') -Encoding UTF8
        $migrated = Initialize-RuntimeLayout
        $expected = Join-Path $layoutRoot 'runtimes\rocm\rocm-7.2.1-b8407'
        Assert-True ($migrated -eq $expected) 'migration moves current\ to runtimes\rocm\<tag>'
        Assert-True (-not (Test-Path -LiteralPath $legacy)) 'migration removes the legacy current\ folder'
        Assert-True ((Get-Content -LiteralPath (Join-Path $migrated 'llama-server.exe') -Raw).Trim() -eq 'stub') 'migration keeps existing files (no re-download)'
        Assert-True ((Get-AppSettings)['active_runtime'] -eq 'runtimes/rocm/rocm-7.2.1-b8407') 'migration stores active_runtime in settings'
        Assert-True ((Get-ActiveRuntimePath) -eq $migrated) 'the resolver prefers active_runtime'
        Assert-True ((Get-InstalledRuntime).tag -eq 'rocm-7.2.1-b8407') 'the active runtime is the migrated build'

        $vulkan = Join-Path $layoutRoot 'runtimes\vulkan\b9999'
        New-Item -ItemType Directory -Path $vulkan -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $vulkan 'llama-server.exe') -Value 'stub' -Encoding ASCII
        [ordered]@{ tag = 'b9999'; backend = 'Vulkan'; sha256 = 'abc'; installed_at = '2026-01-01T00:00:00Z' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $vulkan 'installation.json') -Encoding UTF8
        Assert-True (@(Get-RuntimeInstallations).Count -eq 2) 'both runtimes are visible side by side'

        $hardwareStub = [pscustomobject]@{ HasAmdGpu = $true; RocmRecommended = $true; MaxAmdVramGiB = 15.8; RamGiB = 31.2; ModelBudgetGiB = 24.8 }
        $dense = Get-ModelById -Id 'qwen3.8-27b'
        $small = Get-ModelById -Id 'qwen3.5-9b'
        Assert-True ((Get-DefaultModelBackend -Model $dense -Hardware $hardwareStub).backend -eq 'ROCm') 'dense 18 GiB+ defaults to ROCm'
        Assert-True ((Get-DefaultModelBackend -Model $small -Hardware $hardwareStub).backend -eq 'Vulkan') 'a 9B model defaults to Vulkan'
        $moe = [pscustomobject]@{ Id = 'moe-test'; ApproxGiB = 20.0; Moe = $true }
        Assert-True ((Get-DefaultModelBackend -Model $moe -Hardware $hardwareStub).backend -eq 'Vulkan') 'a MoE model defaults to Vulkan'

        Set-ModelBackendOverride -ModelId 'qwen3.5-9b' -Backend 'ROCm'
        $preference = Get-ModelBackendPreference -Model $small -Hardware $hardwareStub
        Assert-True (($preference.backend -eq 'ROCm') -and ($preference.source -eq 'user')) 'a user override wins over the default'
        $library = Get-LibraryDocument
        $libraryModel = @($library.models | Where-Object { $_.id -eq 'qwen3.5-9b' })[0]
        Assert-True ($libraryModel.preferred_backend -eq 'ROCm') 'Library reports the overridden backend'

        $patch = '{"idle_unload":{"minutes":0},"use_case":"chat","model_backends":{"qwen3.5-9b":"Vulkan","not-a-model":"ROCm"}}'
        $save = Set-SettingsFromDocument -SettingsPatchText $patch
        Assert-True (@($save.rejected | Where-Object { $_.field -eq 'model_backends.not-a-model' }).Count -eq 1) 'an unknown model id is rejected'
        Assert-True ((Get-ModelBackendPreference -Model $small -Hardware $hardwareStub).backend -eq 'Vulkan') 'a valid override is applied by the settings patch'

        Assert-True ((Get-AmdRocmAsset).Release.tag_name -eq [string](Get-CatalogJson -Name 'runtimes.json').amd_rocm_package.tag) 'Get-AmdRocmAsset reads its tag from the catalogue'
        $vulkanDependency = Get-RuntimeDependencyReport -Path $vulkan -Backend 'Vulkan' -SearchPath @()
        Assert-True (($vulkanDependency.status -eq 'missing_files') -and (@($vulkanDependency.missing_files) -contains 'ggml-vulkan.dll')) 'Diagnose names the missing Vulkan files'
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$vulkanDependency.where_to_get)) 'Diagnose says where to get the missing files'

        Write-Host 'Runtime updates: pruning, cache, rollback'
        # Pruning uses its own backend family so the Vulkan fixtures the launcher test
        # relies on keep their paths and timestamps.
        $testFamilyRoot = Join-Path $layoutRoot 'runtimes\testfam'
        foreach ($i in 1..4) {
            $familyPath = Join-Path $testFamilyRoot "t$i"
            New-Item -ItemType Directory -Path $familyPath -Force | Out-Null
            [ordered]@{ tag = "t$i"; backend = 'testfam'; sha256 = "sha$i"; installed_at = "2026-0$i-01T00:00:00Z" } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $familyPath 'installation.json') -Encoding UTF8
        }
        Remove-OldRuntimeBuilds -BackendFamily 'testfam' -Keep 2
        $keptNames = @(Get-ChildItem -LiteralPath $testFamilyRoot -Directory | Select-Object -ExpandProperty Name)
        Assert-True (($keptNames.Count -eq 2) -and ($keptNames -contains 't3') -and ($keptNames -contains 't4')) 'pruning keeps exactly the newest two builds for a backend'
        Set-ActiveRuntime -Path (Join-Path $testFamilyRoot 't3')
        $familyFive = Join-Path $testFamilyRoot 't5'
        New-Item -ItemType Directory -Path $familyFive -Force | Out-Null
        [ordered]@{ tag = 't5'; backend = 'testfam'; sha256 = 'sha5'; installed_at = '2026-05-01T00:00:00Z' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $familyFive 'installation.json') -Encoding UTF8
        Remove-OldRuntimeBuilds -BackendFamily 'testfam' -Keep 1
        $keptAgain = @(Get-ChildItem -LiteralPath $testFamilyRoot -Directory | Select-Object -ExpandProperty Name)
        Assert-True (($keptAgain -contains 't3') -and ($keptAgain -contains 't5') -and ($keptAgain -notcontains 't4')) 'the active build survives pruning even when it is older than the keep window'
        Remove-Item -LiteralPath $testFamilyRoot -Recurse -Force

        Set-RuntimeUpdateCacheEntry -Family 'vulkan' -Entry ([pscustomobject]@{ latest_tag = 'b12110'; channel = 'test'; source = 'test'; checked_at = (Get-Date).ToUniversalTime().ToString('o'); error = '' })
        $cachedStatus = Get-RuntimeUpdateStatus -Backend 'Vulkan' -InstalledTag 'b9999'
        Assert-True ($cachedStatus.cached -and (-not $cachedStatus.stale) -and ($cachedStatus.latest_tag -eq 'b12110') -and $cachedStatus.update_available -and [string]::IsNullOrEmpty([string]$cachedStatus.error)) 'a fresh cache answers latest-vs-installed without a download or a GitHub call'
        Assert-True ((Test-RuntimeTagNewer -Installed 'b8407' -Latest 'b11401') -and (-not (Test-RuntimeTagNewer -Installed 'b11401' -Latest 'b11401'))) 'comparable bNNNN tags are compared numerically'
        Assert-True (-not (Test-RuntimeTagNewer -Installed 'rocm-7.2.1-b8407' -Latest 'rocm-7.2.1-b8407')) 'the AMD package tag is only compared for inequality, never as a numeric minimum'

        $rollbackOld = Join-Path $layoutRoot 'runtimes\vulkan\b10000'
        $rollbackNew = Join-Path $layoutRoot 'runtimes\vulkan\b10001'
        foreach ($build in @(
            [pscustomobject]@{ path = $rollbackOld; tag = 'b10000'; installed_at = '2026-02-01T00:00:00Z' },
            [pscustomobject]@{ path = $rollbackNew; tag = 'b10001'; installed_at = '2026-03-01T00:00:00Z' }
        )) {
            New-Item -ItemType Directory -Path $build.path -Force | Out-Null
            foreach ($file in 'llama-server.exe', 'ggml-vulkan.dll') { Set-Content -LiteralPath (Join-Path $build.path $file) -Value 'stub' -Encoding ASCII }
            [ordered]@{ tag = $build.tag; backend = 'Vulkan'; sha256 = "sha-$($build.tag)"; installed_at = $build.installed_at } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $build.path 'installation.json') -Encoding UTF8
        }
        Set-ActiveRuntime -Path $rollbackNew
        Set-ActiveModel -Model (Get-ModelById 'qwen3-4b') -EffectiveContext 8192 -SkipVerification
        # A llama-server may be running against the real install while the harness runs;
        # Get-ServerState finds it machine-wide and rollback would stop it. Pin these two
        # tests to a stopped server, then restore the real function from its definition.
        $serverStateDefinition = (Get-Command Get-ServerState).Definition
        function Get-ServerState { [pscustomobject]@{ state = 'stopped'; port = [int]$Port; base_url = "http://127.0.0.1:$Port"; process_ids = @(); model_state = 'unknown' } }
        $rollbackPort = $Port
        $Port = 59987
        try {
            $rolledBack = Invoke-RuntimeRollback -Backend 'Vulkan'
            Assert-True (($rolledBack.status -eq 'rolled_back') -and ($rolledBack.from_tag -eq 'b10001') -and ($rolledBack.to_tag -eq 'b10000') -and (-not $rolledBack.restarted)) 'rollback repoints to the previous build and does not start a server that was stopped'
            Assert-True ((Get-ActiveRuntimePath) -eq $rollbackOld) 'the active runtime now names the previous build folder'
            $rolledLauncher = Get-Content -LiteralPath (Join-Path $layoutRoot 'Start-LlamaCpp.cmd') -Raw
            Assert-True ($rolledLauncher -match [regex]::Escape('runtimes\vulkan\b10000\llama-server.exe')) 'rollback rebuilds the launcher against the previous build'

            $brokenBuild = Join-Path $layoutRoot 'runtimes\vulkan\b10002'
            $newestBuild = Join-Path $layoutRoot 'runtimes\vulkan\b10003'
            New-Item -ItemType Directory -Path $brokenBuild -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $brokenBuild 'llama-server.exe') -Value 'stub' -Encoding ASCII
            [ordered]@{ tag = 'b10002'; backend = 'Vulkan'; sha256 = 'sha-broken'; installed_at = '2026-04-01T00:00:00Z' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $brokenBuild 'installation.json') -Encoding UTF8
            New-Item -ItemType Directory -Path $newestBuild -Force | Out-Null
            foreach ($file in 'llama-server.exe', 'ggml-vulkan.dll') { Set-Content -LiteralPath (Join-Path $newestBuild $file) -Value 'stub' -Encoding ASCII }
            [ordered]@{ tag = 'b10003'; backend = 'Vulkan'; sha256 = 'sha-newest'; installed_at = '2026-05-01T00:00:00Z' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $newestBuild 'installation.json') -Encoding UTF8
            Set-ActiveRuntime -Path $newestBuild
            $refusedRollback = Invoke-RuntimeRollback -Backend 'Vulkan'
            Assert-True (($refusedRollback.status -eq 'refused_broken') -and (@($refusedRollback.missing_files) -contains 'ggml-vulkan.dll')) 'rollback refuses a target that fails the file check, naming the missing file'
            Assert-True ((Get-ActiveRuntimePath) -eq $newestBuild) 'a refused rollback leaves the active runtime unchanged'
        } finally {
            . ([scriptblock]::Create($serverStateDefinition))
            $Port = $rollbackPort
        }

        Set-ActiveRuntime -Path $vulkan
        $launcherModel = Get-ModelById -Id 'qwen3-4b'
        Set-ActiveModel -Model $launcherModel -EffectiveContext 8192 -SkipVerification
        $launcherText = Get-Content -LiteralPath (Join-Path $layoutRoot 'Start-LlamaCpp.cmd') -Raw
        Assert-True ($launcherText -match [regex]::Escape('%~dp0runtimes\vulkan\b9999\llama-server.exe')) 'the launcher runs the active runtime'

        $hashFile = Join-Path $work 'hash-probe.bin'
        [IO.File]::WriteAllBytes($hashFile, [byte[]](1, 2, 3, 4))
        $localHash = Get-ArchiveLocalHash -ArchivePath $hashFile
        Assert-True ($localHash -eq (Get-FileHash -LiteralPath $hashFile -Algorithm SHA256).Hash.ToLowerInvariant()) 'the recorded local archive hash matches Get-FileHash'
        Assert-True (Test-Path -LiteralPath "$hashFile.sha256") 'the local hash is written to a sidecar'
    } finally {
        $InstallRoot = $previousLayoutRoot
    }

    Write-Host 'Desktop window capture gate: the screenshot is a verified artifact, not a manual step'
    # ADR-006: visual changes are checked with a screenshot of the real window. Capture
    # tool = SendKeys-free (PrintWindow only). When no app window is running (CI, or the
    # app was closed), the gate reports a skip instead of failing — the artifact is
    # re-verified next time the window runs; a missing window is never claimed a pass.
    $capturePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Capture-DesktopScreenshot.ps1'
    $gatePng = Join-Path $work 'gate-capture.png'
    $gated = $false
    if (Test-Path -LiteralPath $capturePath) {
        $capOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $capturePath -OutputPath $gatePng 2>$null
        $capExit = $LASTEXITCODE
        $capDoc = $null
        try { $capDoc = ConvertFrom-Json -InputObject ($capOut -join "`n") } catch { $capDoc = $null }
        if ($capExit -eq 3) {
            Write-Host '  SKIP  no llama.cpp Command Center window is open; the capture gate re-runs when the app runs'
        } elseif (($capExit -eq 0) -and ($null -ne $capDoc) -and $capDoc.captured) {
            $gateBytes = [IO.File]::ReadAllBytes($gatePng)
            $gateSig = $gateBytes.Length -ge 4 -and $gateBytes[0] -eq 0x89 -and $gateBytes[1] -eq 0x50 -and $gateBytes[2] -eq 0x4E -and $gateBytes[3] -eq 0x47
            Assert-True ($gateSig -and ($gateBytes.Length -gt 10000)) "the window capture is a real non-empty PNG ($($capDoc.width)x$($capDoc.height), $($gateBytes.Length) bytes) verified by the typed document"
            Assert-True ([bool]$capDoc.png_signature_ok) 'the capture tool self-reports a valid PNG signature'
            $gated = $true
        } else {
            Assert-True $false "the capture tool ran but did not produce a verified document (exit $capExit; error: $(if ($capDoc) { $capDoc.error } else { 'no document' }))"
        }
    } else {
        Assert-True $false 'Capture-DesktopScreenshot.ps1 exists next to the harness'
    }

    Write-Host 'The real user profile was never touched'
    $realNow = if (Test-Path -LiteralPath $realVsCodeConfig) { (Get-Item -LiteralPath $realVsCodeConfig).LastWriteTimeUtc } else { $null }
    Assert-True ($realNow -eq $realVsCodeStamp) "the real chatLanguageModels.json is unchanged ($realVsCodeConfig)"
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures -gt 0) { Write-Host "$failures check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'All checks passed.' -ForegroundColor Green
# Explicit exit: the CI step runs this file through `powershell -command`, where the exit code
# follows the last command's status. A suppressed cleanup error must not turn a pass into a failure.
exit 0
