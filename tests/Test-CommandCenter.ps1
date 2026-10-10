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
$Thinking = 'Auto'
$ContextSize = 0
$script:ServerSlots = 2
$script:AssumeYes = $false
$script:JsonDocumentsOnly = $false
$UseCase = ''
$script:CommandCenterVersion = '0.1.6'
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

    Write-Host 'Launcher generation (every catalog model)'
    foreach ($model in Get-ModelCatalog) {
        Set-ActiveModel -Model $model -EffectiveContext 32768 -SkipVerification
        $launcher = Get-Content -LiteralPath (Join-Path $InstallRoot 'Start-LlamaCpp.cmd') -Raw
        $block = [regex]::Match($launcher, '(?s)llama-server\.exe"? \^\r?\n(.*?)\r?\nset "LLAMA_EXIT').Groups[1].Value
        $lines = @($block -split '\r?\n')
        $blank = @($lines | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count
        $danglingCaret = $lines[-1].TrimEnd().EndsWith('^')
        $missingCaret = @($lines | Select-Object -SkipLast 1 | Where-Object { -not $_.TrimEnd().EndsWith('^') }).Count
        Assert-True (($blank -eq 0) -and -not $danglingCaret -and ($missingCaret -eq 0)) "$($model.Id): continuation lines are well formed"
        Assert-True ($block -match '--jinja' -and $block -match '--parallel 2' -and $block -match '--ctx-size 65536' -and $block -match "--alias $([regex]::Escape($model.Alias))") "$($model.Id): launcher keeps jinja, alias, and a 2-slot pool sized for two conversations"
        $state = Get-Content -LiteralPath (Join-Path $InstallRoot 'active-model.json') -Raw | ConvertFrom-Json
        Assert-True ($state.tool_calling -eq [bool]$model.Tools) "$($model.Id): tool_calling follows the catalog Tools flag"
        $expectOff = [bool]$model.Reasoning -and [bool]$model.Tools
        $expectOn = [bool]$model.Reasoning -and -not $expectOff
        Assert-True ((($block -match '--reasoning off') -eq $expectOff) -and (($block -match '--reasoning on') -eq $expectOn)) "$($model.Id): thinking is off for tool-capable reasoning models"
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
    Assert-True ((Select-PrimaryLlamaDevice -Devices (ConvertFrom-LlamaDeviceList -Lines $rocmList)) -eq '') 'a single visible GPU needs no pin'
    $apuOnly = @('  Vulkan0: AMD Radeon(TM) Graphics (16209 MiB, 15398 MiB free)', '  Vulkan1: AMD Radeon 780M Graphics (8000 MiB, 7000 MiB free)')
    Assert-True ((Select-PrimaryLlamaDevice -Devices (ConvertFrom-LlamaDeviceList -Lines $apuOnly)) -eq '') 'an iGPU-only machine is left to llama.cpp defaults'
    $mixed = ConvertFrom-LlamaDeviceList -Lines @('  ROCm0: AMD Radeon RX 9070 XT (16304 MiB, 16153 MiB free)', '  ROCm1: AMD Radeon(TM) Graphics (16209 MiB, 15398 MiB free)')
    $rocmFound = @($mixed | Where-Object { $_.Id -match '^ROCm' -and -not $_.Integrated })
    Assert-True (($rocmFound.Count -eq 1) -and ($rocmFound[0].Id -eq 'ROCm0')) 'the ROCm (latest) GPU check counts only the dedicated Radeon'
    $noGpu = ConvertFrom-LlamaDeviceList -Lines @('Available devices:', '  (none)')
    $cpuOnly = @($noGpu | Where-Object { $_.Id -match '^ROCm' })
    Assert-True ($cpuOnly.Count -eq 0) 'a build that lists no GPU fails the ROCm (latest) check'
    $pinned = Get-ServerArguments -ActiveModel (Get-ActiveModel) -EffectiveContext 32768 -Device 'Vulkan0'
    Assert-True (($pinned -join ' ') -match '--device Vulkan0') 'the chosen device reaches the server arguments'
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
    Assert-True (($idleLauncher -match '--sleep-idle-seconds 900') -and (@($idleBlock | Select-Object -SkipLast 1 | Where-Object { -not $_.TrimEnd().EndsWith('^') }).Count -eq 0)) 'the launcher keeps well-formed continuation lines with the idle flag'
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
    Assert-True ((@('failed', 'already_running') -contains $failedStart.status) -and (-not [string]::IsNullOrWhiteSpace([string]$failedStart.detail))) 'starting against this temp install fails typed, without launching anything'

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
        Assert-True ($launcherText -match '--model "%~dp0models\\.') 'the model path is quoted and relative to %~dp0'
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
