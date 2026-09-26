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
$InstallRoot = Join-Path $work 'install'
$Port = 8080
$Force = $true
$Thinking = 'Auto'
$script:ServerSlots = 2
$script:CommandCenterVersion = '0.1.5'
$script:CommandCenterRepo = 'theantipopau/llamacpp-amd-command-center'
$script:AmdRocmPage = 'https://rocm.docs.amd.com/projects/radeon-ryzen/en/latest/docs/advanced/advancedrad/windows/llm/llamacpp.html'
$script:AmdRocmPackageCheckedOn = [DateTime]::new(2026, 9, 24)
$script:AmdRocmPackageFreshnessDays = 120
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

    Write-Host 'GPU selection never uses the Ryzen iGPU automatically'
    $vkList = @('Available devices:', '  Vulkan0: AMD Radeon RX 9070 XT (16304 MiB, 15416 MiB free)', '  Vulkan1: AMD Radeon(TM) Graphics (16209 MiB, 15398 MiB free)')
    Assert-True ((Select-PrimaryLlamaDevice -Devices (ConvertFrom-LlamaDeviceList -Lines $vkList)) -eq 'Vulkan0') 'Vulkan with dGPU + iGPU pins the dedicated Radeon'
    $swapped = @('  Vulkan0: AMD Radeon(TM) Graphics (16209 MiB, 15398 MiB free)', '  Vulkan1: AMD Radeon RX 9070 XT (16304 MiB, 15416 MiB free)')
    Assert-True ((Select-PrimaryLlamaDevice -Devices (ConvertFrom-LlamaDeviceList -Lines $swapped)) -eq 'Vulkan1') 'selection follows the name, not the device order'
    $rocmList = @('  ROCm0: AMD Radeon RX 9070 XT (16304 MiB, 16153 MiB free)')
    Assert-True ((Select-PrimaryLlamaDevice -Devices (ConvertFrom-LlamaDeviceList -Lines $rocmList)) -eq '') 'a single visible GPU needs no pin'
    $apuOnly = @('  Vulkan0: AMD Radeon(TM) Graphics (16209 MiB, 15398 MiB free)', '  Vulkan1: AMD Radeon 780M Graphics (8000 MiB, 7000 MiB free)')
    Assert-True ((Select-PrimaryLlamaDevice -Devices (ConvertFrom-LlamaDeviceList -Lines $apuOnly)) -eq '') 'an iGPU-only machine is left to llama.cpp defaults'
    $pinned = Get-ServerArguments -ActiveModel (Get-ActiveModel) -EffectiveContext 32768 -Device 'Vulkan0'
    Assert-True (($pinned -join ' ') -match '--device Vulkan0') 'the chosen device reaches the server arguments'
    Set-ActiveModel -Model (Get-ModelById 'qwen3.5-9b') -EffectiveContext 32768 -SkipVerification
    $launcherText = Get-Content -LiteralPath (Join-Path $InstallRoot 'Start-LlamaCpp.cmd') -Raw
    Assert-True ($launcherText -notmatch '--device') 'no device flag when no llama.cpp build is installed to ask'

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
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures -gt 0) { Write-Host "$failures check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'All checks passed.' -ForegroundColor Green
