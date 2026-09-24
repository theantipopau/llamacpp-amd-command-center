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
# Run logging is not started here; the helpers skip logging when these are empty.
$script:RunJsonlPath = $null; $script:RunLogPath = $null; $script:RunSummaryPath = $null
$script:RunLogDirectory = $null; $script:RunStarted = $null; $script:RunTranscriptStarted = $false
$failures = 0
function Assert-True([bool] $Condition, [string] $Message) {
    if ($Condition) { Write-Host "  PASS  $Message" -ForegroundColor Green }
    else { Write-Host "  FAIL  $Message" -ForegroundColor Red; $script:failures++ }
}

try {
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
        Assert-True ($block -match '--jinja' -and $block -match '--ctx-size 32768' -and $block -match "--alias $([regex]::Escape($model.Alias))") "$($model.Id): launcher keeps jinja, context, and alias"
        $state = Get-Content -LiteralPath (Join-Path $InstallRoot 'active-model.json') -Raw | ConvertFrom-Json
        Assert-True ($state.tool_calling -eq [bool]$model.Tools) "$($model.Id): tool_calling follows the catalog Tools flag"
    }

    Write-Host 'Hardware recommendation (16 GB Radeon, 31 GB RAM)'
    $hw = [pscustomobject]@{ HasAmdGpu = $true; MaxAmdVramGiB = 15.8; RamGiB = 31.2; ModelBudgetGiB = 24.8 }
    $recommended = Get-RecommendedModel -Hardware $hw
    Assert-True ($recommended.Id -eq 'qwen3.5-9b') "recommends a VRAM-resident tool model (got $($recommended.Id))"
    Assert-True ((Get-SuggestedContext -Model $recommended -Hardware $hw) -eq 65536) 'suggests 64k for the hybrid Qwen3.5 model (small KV cache)'
    Assert-True ((Get-SuggestedContext -Model (Get-ModelById 'qwen3-8b') -Hardware $hw) -eq 32768) 'suggests 32k for a dense 8B model'
    Assert-True ((Get-SuggestedContext -Model (Get-ModelById 'qwen3.8-27b') -Hardware $hw) -eq 32768) 'keeps 32k for the RAM-spilling 27B model'

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

    [IO.File]::WriteAllText($cfg, '{ not json')
    $threw = $false
    try { Install-VsCodeChatEndpoint *> $null } catch { $threw = $true }
    Assert-True ($threw -and ([IO.File]::ReadAllText($cfg) -eq '{ not json')) 'refuses to touch malformed JSON'
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures -gt 0) { Write-Host "$failures check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'All checks passed.' -ForegroundColor Green
