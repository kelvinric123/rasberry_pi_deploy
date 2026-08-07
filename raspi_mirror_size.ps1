# raspi_mirror_size.ps1
#
# Prints the size in KB of everything in a folder EXCEPT its .git directory.
#
# Used by update_raspi_deploy.bat as a backstop: the deploy repo holds a
# handful of shell scripts, so a mirror of more than a few hundred KB means
# something got swept in that must not be published to a PUBLIC repository
# (build output, an archive, a virtualenv, a nested .git folder).
#
# Lives in its own file rather than inline in the .bat on purpose: cmd does
# not unescape "^|" inside a double-quoted -Command string, so a piped
# one-liner silently reaches PowerShell malformed and returns nothing.
#
# Usage:  powershell -NoProfile -File raspi_mirror_size.ps1 -Path <folder>

param([Parameter(Mandatory = $true)][string]$Path)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Path)) { Write-Output '0'; exit 0 }

$total = 0
$items = Get-ChildItem -LiteralPath $Path -Recurse -File -Force
foreach ($item in $items) {
    # Skip the repository's own metadata - it is not what gets published.
    if ($item.FullName -like '*\.git\*') { continue }
    $total += $item.Length
}

Write-Output ([string][int][math]::Ceiling($total / 1KB))
