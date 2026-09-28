<#
.SYNOPSIS
    Rename a Windows Server (2025) and optionally set its primary DNS suffix.

.DESCRIPTION
    * renames the computer (NetBIOS/host name, max. 15 characters)
    * if an FQDN is given on a workgroup server, sets the primary DNS suffix
    * asks whether to restart (the new name is active after the restart)

    FOR TEST / DEMO ENVIRONMENTS ONLY.
    Run as Administrator.

.PARAMETER NewName
    New host name (demo01) or FQDN (demo01.example.com).

.PARAMETER Restart
    Restart automatically after renaming.

.PARAMETER Yes
    Do not ask for confirmation (does not restart unless -Restart is given).

.EXAMPLE
    .\set-hostname.ps1

.EXAMPLE
    .\set-hostname.ps1 -NewName demo01.example.com -Yes -Restart
#>
#Requires -RunAsAdministrator
#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$NewName,
    [switch]$Restart,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'

$TcpipParams = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
function Write-Info([string]$Message) { Write-Host '==> ' -ForegroundColor Blue -NoNewline; Write-Host $Message }
function Write-Ok([string]$Message)   { Write-Host '[ok] ' -ForegroundColor Green -NoNewline; Write-Host $Message }
function Write-Warn([string]$Message) { Write-Host '[warn] ' -ForegroundColor Yellow -NoNewline; Write-Host $Message }
function Stop-WithError([string]$Message) { Write-Host '[error] ' -ForegroundColor Red -NoNewline; Write-Host $Message; exit 1 }

function Read-Value([string]$Prompt, [string]$Default) {
    if ($Default) { $Prompt = "$Prompt [$Default]" }
    $answer = Read-Host $Prompt
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer.Trim()
}

function Confirm-Step([string]$Question, [string]$Default = 'y') {
    if ($Yes) { return $true }
    return ((Read-Value "$Question (y/n)" $Default) -match '^[YyJj]')
}

# NetBIOS compatible: letters, digits, '-', max 15 chars, not only digits
function Test-ShortName([string]$Name) {
    return ($Name -match '^[A-Za-z0-9]([A-Za-z0-9-]{0,13}[A-Za-z0-9])?$' -and $Name -notmatch '^\d+$')
}

function Test-DnsSuffix([string]$Suffix) {
    return ($Suffix.Length -le 238 -and $Suffix -match '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$')
}

# ---------------------------------------------------------------------------
# pre-flight checks
# ---------------------------------------------------------------------------
$os = Get-CimInstance Win32_OperatingSystem
if ($os.Caption -notmatch 'Server 2025') {
    Write-Warn "Written for Windows Server 2025, detected $($os.Caption)."
    if (-not (Confirm-Step 'Continue anyway?')) { exit 1 }
}

$computer  = Get-CimInstance Win32_ComputerSystem
$oldName   = $env:COMPUTERNAME
$oldSuffix = (Get-ItemProperty -Path $TcpipParams -Name 'NV Domain' -ErrorAction SilentlyContinue).'NV Domain'
$oldFqdn   = if ($oldSuffix) { "$oldName.$oldSuffix".ToLower() } else { $oldName.ToLower() }

# ---------------------------------------------------------------------------
# collect input
# ---------------------------------------------------------------------------
if (-not $NewName) {
    Write-Info "Current name: $oldName (FQDN: $oldFqdn)"
    $NewName = Read-Value 'New host name or FQDN'
}
$NewName = $NewName.Trim().TrimEnd('.')
if (-not $NewName) { Stop-WithError 'No name given.' }

$newShort  = $NewName.Split('.')[0]
$newSuffix = if ($NewName.Contains('.')) { $NewName.Substring($newShort.Length + 1).ToLower() } else { '' }

if (-not (Test-ShortName $newShort)) {
    Stop-WithError "Invalid host name: '$newShort' (letters, digits and '-', max. 15 characters, not only digits)"
}
if ($newSuffix -and -not (Test-DnsSuffix $newSuffix)) { Stop-WithError "Invalid DNS suffix: '$newSuffix'" }

if ($newSuffix -and $computer.PartOfDomain) {
    Write-Warn "This server is a member of the domain '$($computer.Domain)' - the DNS suffix is managed by the domain and is left unchanged."
    $newSuffix = ''
}

$renameNeeded = $newShort -ne $oldName
$suffixNeeded = $newSuffix -and $newSuffix -ne $oldSuffix
if (-not $renameNeeded -and -not $suffixNeeded) {
    Write-Ok "Name is already $oldFqdn - nothing to do."
    exit 0
}

Write-Host ''
Write-Info 'Summary'
Write-Host "  Old name       : $oldName (FQDN: $oldFqdn)"
Write-Host "  New name       : $newShort"
Write-Host "  DNS suffix     : $(if ($newSuffix) { $newSuffix } elseif ($oldSuffix) { "unchanged ($oldSuffix)" } else { '(none)' })"
Write-Host "  Domain member  : $(if ($computer.PartOfDomain) { $computer.Domain } else { 'no (workgroup)' })"
Write-Host ''
if (-not (Confirm-Step 'Proceed?')) { exit 1 }

# ---------------------------------------------------------------------------
# 1. rename
# ---------------------------------------------------------------------------
if ($renameNeeded) {
    Write-Info "Renaming computer to $newShort"
    if ($computer.PartOfDomain) {
        $credential = Get-Credential -Message "Domain account allowed to rename computers in $($computer.Domain)"
        Rename-Computer -NewName $newShort -DomainCredential $credential -Force -WarningAction SilentlyContinue
    } else {
        Rename-Computer -NewName $newShort -Force -WarningAction SilentlyContinue
    }
    Write-Ok "Computer renamed to $newShort (active after restart)"
}

# ---------------------------------------------------------------------------
# 2. primary DNS suffix
# ---------------------------------------------------------------------------
if ($suffixNeeded) {
    Write-Info "Setting primary DNS suffix to $newSuffix"
    Set-ItemProperty -Path $TcpipParams -Name 'NV Domain' -Value $newSuffix
    Write-Ok "Primary DNS suffix set (active after restart)"
}

$newFqdn = if ($newSuffix) { "$newShort.$newSuffix" } elseif ($oldSuffix) { "$newShort.$oldSuffix" } else { $newShort }
$newFqdn = $newFqdn.ToLower()

Write-Host ''
Write-Ok 'Done.'
Write-Host "  New FQDN after restart: $newFqdn"

# certificates created by init-iis.ps1 are bound to the old name
$iisCerts = @(Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.FriendlyName -like 'init-iis self-signed*' -and $_.Subject -ne "CN=$newFqdn" })
if ($iisCerts.Count -gt 0) {
    Write-Host ''
    Write-Warn 'IIS is still configured for the old name - run init-iis.ps1 again with the new FQDN'
    Write-Warn 'to get a matching certificate.'
}

Write-Host ''
if ($Restart -or (-not $Yes -and (Confirm-Step 'Restart now to apply the new name?' 'n'))) {
    Write-Info 'Restarting'
    Restart-Computer -Force
} else {
    Write-Warn 'Restart the server to apply the new name (Restart-Computer).'
}
