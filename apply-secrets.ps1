# Applies the secrets in .env to the local omniroute gateway without ever
# printing them. Safe to re-run: each step skips itself once done.

# Not 'Stop': PowerShell 5.1 turns any native stderr line (omniroute prints
# harmless warnings there) into a terminating error.
$ErrorActionPreference = 'Continue'
$envFile = Join-Path $PSScriptRoot '.env'
$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
            [Environment]::GetEnvironmentVariable('Path','User') + ';' + "$env:APPDATA\npm"

function Read-DotEnv {
    $vals = @{}
    Get-Content $envFile | ForEach-Object {
        if ($_ -match '^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*)$') { $vals[$matches[1]] = $matches[2].Trim() }
    }
    $vals
}

function Set-DotEnvValue($name, $value) {
    $lines = Get-Content $envFile
    $lines = $lines | ForEach-Object { if ($_ -match "^\s*$name\s*=") { "$name=$value" } else { $_ } }
    Set-Content -Path $envFile -Value $lines -Encoding ascii
}

# Call the .cmd shim, not omniroute.ps1: PowerShell binds --flags passed to a
# .ps1 script as that script's own parameters and silently drops them.
$omni = "$env:APPDATA\npm\omniroute.cmd"
function Invoke-Omni { & $omni @args 2>$null | Where-Object { $_ -notmatch 'Loaded env' } }

if (-not (Get-NetTCPConnection -LocalPort 20128 -State Listen -ErrorAction SilentlyContinue)) {
    throw 'omniroute is not running on port 20128. Start it with: omniroute serve --no-open'
}

$cfg = Read-DotEnv

# 1. Admin password
if ($cfg['OMNIROUTE_ADMIN_PASSWORD']) {
    Invoke-Omni setup --password $cfg['OMNIROUTE_ADMIN_PASSWORD'] --non-interactive | Out-Null
    Write-Output 'password: applied'
} else {
    Write-Output 'password: skipped (OMNIROUTE_ADMIN_PASSWORD empty)'
}

# 2. Upstream providers - keys go in over stdin, never on the command line
$providers = [ordered]@{ groq = 'GROQ_API_KEY'; nvidia = 'NVIDIA_API_KEY'; gemini = 'GEMINI_API_KEY' }
$existing = (Invoke-Omni providers list) -join "`n"
foreach ($p in $providers.Keys) {
    $var = $providers[$p]
    if (-not $cfg[$var]) { Write-Output "${p}: skipped ($var empty)"; continue }
    if ($existing -match "\s$p\s") { Write-Output "${p}: already connected (remove it in omniroute first to replace the key)"; continue }
    $cfg[$var] | & $omni providers add $p --name $p --credential-stdin --yes 2>$null | Out-Null
    Write-Output "${p}: added"
}

# Cloudflare Workers AI also needs the account ID, passed as provider-specific
# data. The backslash-escaped quotes are deliberate: PowerShell 5.1 does not
# escape embedded quotes when calling a native .cmd.
if ($cfg['CLOUDFLARE_API_TOKEN'] -and $cfg['CLOUDFLARE_ACCOUNT_ID']) {
    if ($existing -match '\scloudflare-ai\s') {
        Write-Output 'cloudflare: already connected (remove it in omniroute first to replace the key)'
    } else {
        $psd = '{\"accountId\":\"' + $cfg['CLOUDFLARE_ACCOUNT_ID'] + '\"}'
        $cfg['CLOUDFLARE_API_TOKEN'] | & $omni providers add cloudflare-ai --name cloudflare --credential-stdin --yes --provider-specific-data $psd 2>$null | Out-Null
        Write-Output 'cloudflare: added'
    }
} else {
    Write-Output 'cloudflare: skipped (CLOUDFLARE_API_TOKEN or CLOUDFLARE_ACCOUNT_ID empty)'
}

# 3. omniroute API key for Cline, written back to .env.
#    Always created fresh: only the create response carries the full key.
#    Listing returns masked keys, and revealing one needs a dashboard login.
if (-not $cfg['OMNIROUTE_CLINE_KEY']) {
    # Body via @file: PowerShell 5.1 strips the inner double quotes from JSON
    # passed as an argument to a native .cmd.
    $body = Join-Path $env:TEMP 'omni-key-body.json'
    Set-Content -Path $body -Value '{"name":"cline-vscode"}' -Encoding ascii
    $k = ((Invoke-Omni --output json api api-keys post-api-keys --body "@$body") -join '') | ConvertFrom-Json
    Remove-Item $body -ErrorAction SilentlyContinue
    if ($k.key -and $k.key -notmatch '\*') {
        Set-DotEnvValue 'OMNIROUTE_CLINE_KEY' $k.key
        Write-Output 'cline key: created, written to .env'
    } else {
        Write-Output 'cline key: FAILED - no full key in omniroute response'
    }
} else {
    Write-Output 'cline key: already present'
}
