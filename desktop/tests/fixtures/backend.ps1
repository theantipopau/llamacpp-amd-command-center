param(
    [string] $Action = 'State',
    [string] $RuntimeAction = 'health',
    [string] $InstallRoot = '',
    [string] $LibraryAction = '',
    [string] $ModelId = '',
    [string] $SettingsPatch = '',
    [switch] $Force
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSCommandPath
$running = Join-Path $InstallRoot 'stub-running.flag'
$starting = Join-Path $InstallRoot 'stub-starting.flag'
$pidFile = Join-Path $InstallRoot 'stub-launcher.pid'

function Write-Json([object] $Document) {
    [Console]::Out.WriteLine(($Document | ConvertTo-Json -Depth 20 -Compress))
}

switch ($Action) {
    'State' {
        $document = Get-Content -LiteralPath (Join-Path $here 'state.json') -Raw | ConvertFrom-Json
        $document.install_root = [string]$InstallRoot
        Write-Json $document
        exit 0
    }
    'Recommend' {
        $text = [IO.File]::ReadAllText((Join-Path $here 'recommend.json'))
        [Console]::Out.Write($text)
        exit 0
    }
    'Settings' {
        if ($SettingsPatch) {
            Write-Json ([ordered]@{
                schema_version = 1
                generated_at = (Get-Date).ToUniversalTime().ToString('o')
                applied = @()
                rejected = @()
                settings = $null
            })
            exit 0
        }
        Write-Json ([ordered]@{
            schema_version = 1
            generated_at = (Get-Date).ToUniversalTime().ToString('o')
            install_root = $InstallRoot
            gpu_vram_gib = 15.8
            active_model_gib = 6.2
            idle_unload = [ordered]@{ capable = $false; minutes = 0; installed_models = 1 }
            use_case = [ordered]@{ allowed = @('chat'); saved = 'chat' }
            game_pause = [ordered]@{ gib = 0; capable = $true; min = 0; max = 40 }
        })
        exit 0
    }
    'Runtime' {
        switch ($RuntimeAction) {
            'start' {
                Set-Content -LiteralPath $running -Value 'loading' -Encoding ASCII
                Set-Content -LiteralPath $starting -Value 'yes' -Encoding ASCII
                Set-Content -LiteralPath $pidFile -Value $PID -Encoding ASCII
                # Keep health reporting "stopped" briefly so a duplicate Start has to
                # exercise the launcher guard instead of relying on a fast "loading".
                $startedAt = Get-Date
                while ((Get-Date) -lt $startedAt.AddSeconds(12) -and (Test-Path -LiteralPath $running)) {
                    Start-Sleep -Milliseconds 100
                }
                Remove-Item -LiteralPath $starting -Force -ErrorAction SilentlyContinue
                while (Test-Path -LiteralPath $running) {
                    Start-Sleep -Milliseconds 100
                }
                Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
                exit 0
            }
            'stop' {
                Remove-Item -LiteralPath $running -Force -ErrorAction SilentlyContinue
                Write-Json ([ordered]@{
                    schema_version = 1
                    adapter = 'llamacpp'
                    status = 'stopped'
                    detail = 'Stub server stopped.'
                    killed = 1
                    remaining = 0
                })
                exit 0
            }
            default {
                $state = if (Test-Path -LiteralPath $starting) { 'stopped' } elseif (Test-Path -LiteralPath $running) { 'loading' } else { 'stopped' }
                Write-Json ([ordered]@{
                    schema_version = 1
                    adapter = 'llamacpp'
                    state = $state
                    ok = ($state -eq 'running')
                    confidence = 'high'
                    reason = 'stub'
                    process_ids = @()
                    port = 8080
                    base_url = 'http://127.0.0.1:8080'
                    model_state = 'unknown'
                })
                exit 0
            }
        }
    }
    default {
        Write-Json ([ordered]@{ schema_version = 1; ok = $true })
        exit 0
    }
}
