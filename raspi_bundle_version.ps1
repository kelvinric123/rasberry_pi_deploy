# raspi_bundle_version.ps1
#
# Prints the script-bundle version the QMed server will publish for a folder
# of Raspberry Pi scripts, WITHOUT contacting the server.
#
# This is an exact re-implementation of App\Services\RaspberryPiScriptBundle:
# sha256 each of the 7 installed files, sort by name, join "name:sha" with LF,
# sha256 that, keep the first 12 hex characters. Use it to confirm that the
# version shown on /admin/raspberry-pi after pressing Sync is the one you
# actually pushed.
#
# Usage:  powershell -NoProfile -File raspi_bundle_version.ps1 -Path <folder>

param([Parameter(Mandatory = $true)][string]$Path)

$ErrorActionPreference = 'Stop'

# Must match RaspberryPiScriptBundle::FILES exactly.
$files = @(
    'server.py',
    'start_local_server.sh',
    'video_sync.sh',
    'heartbeat.sh',
    'kiosk.sh',
    'net_watchdog.sh',
    'self_update.sh'
)

# PHP's ksort() compares byte-for-byte. Sort-Object is culture-aware and could
# order punctuation differently, so sort ordinally to stay bit-identical.
[array]::Sort($files, [System.StringComparer]::Ordinal)

$parts = @()
foreach ($name in $files) {
    $full = Join-Path $Path $name
    if (-not (Test-Path -LiteralPath $full)) { continue }
    $hash = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLower()
    $parts += ('{0}:{1}' -f $name, $hash)
}

if ($parts.Count -eq 0) { Write-Output 'none'; exit 0 }

# LF join, UTF-8 bytes - same as the PHP implode("\n", ...).
$joined = [string]::Join("`n", $parts)
$bytes = [System.Text.Encoding]::UTF8.GetBytes($joined)
$sha = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
$hex = -join ($sha | ForEach-Object { $_.ToString('x2') })

Write-Output $hex.Substring(0, 12)
