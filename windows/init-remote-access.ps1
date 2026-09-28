<#
.SYNOPSIS
    Enable remote access on Windows Server 2025: OpenSSH server and Remote Desktop (RDP).

.DESCRIPTION
    * installs the OpenSSH server (Windows capability) if it is not present yet
    * starts sshd and sets it to start automatically, also after a reboot
    * restarts sshd automatically if it crashes
    * opens TCP port 22 in the Windows firewall for all network profiles
    * optionally makes PowerShell the default shell for SSH sessions
    * enables Remote Desktop for all members of the local Administrators group
      (Network Level Authentication stays on), opens TCP 3389 in the firewall

    SSH password login is allowed by default (Windows accounts, including Administrator).

    FOR TEST / DEMO ENVIRONMENTS ONLY.
    Run as Administrator.

.PARAMETER Shell
    Default shell for SSH sessions: powershell or cmd (asked if not given).

.PARAMETER SkipRdp
    Do not touch the Remote Desktop configuration.

.PARAMETER Yes
    Do not ask for confirmation (default shell: powershell).

.EXAMPLE
    .\init-remote-access.ps1

.EXAMPLE
    .\init-remote-access.ps1 -Shell powershell -Yes
#>
#Requires -RunAsAdministrator
#Requires -Version 5.1

[CmdletBinding()]
param(
    [ValidateSet('powershell', 'cmd')]
    [string]$Shell,
    [switch]$SkipRdp,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$SshPort          = 22
$FirewallRuleName = 'OpenSSH-Server-In-TCP'
$PowerShellExe    = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$OpenSshRegPath   = 'HKLM:\SOFTWARE\OpenSSH'
$RdpPort          = 3389
$RdpRegPath       = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
# language independent id of the firewall group "Remote Desktop" ("Remotedesktop" on German systems)
$RdpFirewallGroup = '@FirewallAPI.dll,-28752'
$AdminsSid        = 'S-1-5-32-544'

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

function Confirm-Step([string]$Question) {
    if ($Yes) { return $true }
    return ((Read-Value "$Question (y/n)" 'y') -match '^[YyJj]')
}

function Test-LocalPort([int]$Port) {
    $client = New-Object System.Net.Sockets.TcpClient
    try { $client.Connect('127.0.0.1', $Port); return $true }
    catch { return $false }
    finally { $client.Close() }
}

# true if the Administrators group has "Allow log on through Remote Desktop Services"
function Test-AdminsRdpRight {
    $cfg = Join-Path $env:TEMP "secedit-$([guid]::NewGuid()).inf"
    try {
        & secedit.exe /export /areas USER_RIGHTS /cfg $cfg /quiet | Out-Null
        $line = Select-String -Path $cfg -Pattern '^SeRemoteInteractiveLogonRight' | Select-Object -First 1
        return ($line -and $line.Line -match [regex]::Escape("*$AdminsSid"))
    } finally {
        Remove-Item $cfg -Force -ErrorAction SilentlyContinue
    }
}

# connect to the local port and read the SSH banner
function Get-SshBanner([int]$Port) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $client.Connect('127.0.0.1', $Port)
        $client.ReceiveTimeout = 5000
        $reader = New-Object System.IO.StreamReader($client.GetStream())
        return $reader.ReadLine()
    } catch {
        return $null
    } finally {
        $client.Close()
    }
}

# ---------------------------------------------------------------------------
# pre-flight checks
# ---------------------------------------------------------------------------
$os = Get-CimInstance Win32_OperatingSystem
if ($os.Caption -notmatch 'Server 2025') {
    Write-Warn "Written for Windows Server 2025, detected $($os.Caption)."
    if (-not (Confirm-Step 'Continue anyway?')) { exit 1 }
}

# ---------------------------------------------------------------------------
# collect input
# ---------------------------------------------------------------------------
if (-not $Shell) {
    if ($Yes) { $Shell = 'powershell' }
    else {
        $Shell = (Read-Value 'Default shell for SSH sessions (powershell/cmd)' 'powershell').ToLower()
        if ($Shell -notin 'powershell', 'cmd') { Stop-WithError "Invalid shell: '$Shell' (powershell or cmd)" }
    }
}

$sshdService = Get-Service -Name sshd -ErrorAction SilentlyContinue

Write-Host ''
Write-Info 'Summary'
Write-Host "  OpenSSH server : $(if ($sshdService) { 'already installed' } else { 'will be installed' })"
Write-Host '  Startup type   : Automatic (also after reboot), restart on failure'
Write-Host "  Firewall       : allow TCP $SshPort (all profiles)"
Write-Host "  Default shell  : $Shell"
Write-Host '  Password login : allowed (Windows default)'
Write-Host "  Remote Desktop : $(if ($SkipRdp) { 'unchanged' } else { "enabled for Administrators, NLA on, TCP $RdpPort open" })"
Write-Host ''
if (-not (Confirm-Step 'Proceed?')) { exit 1 }

# ---------------------------------------------------------------------------
# 1. install
# ---------------------------------------------------------------------------
if (-not $sshdService) {
    # Windows Server 2025 ships OpenSSH server preinstalled; older builds need the capability
    Write-Info 'Installing the OpenSSH server capability (downloads from Windows Update)'
    $capability = Get-WindowsCapability -Online | Where-Object Name -like 'OpenSSH.Server*' | Select-Object -First 1
    if (-not $capability) { Stop-WithError 'OpenSSH server capability not found on this system.' }
    if ($capability.State -ne 'Installed') {
        Add-WindowsCapability -Online -Name $capability.Name | Out-Null
    }
    $sshdService = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if (-not $sshdService) { Stop-WithError 'sshd service not found after installation.' }
    Write-Ok 'OpenSSH server installed'
} else {
    Write-Ok 'OpenSSH server already installed'
}

# ---------------------------------------------------------------------------
# 2. service: automatic start + restart on failure
# ---------------------------------------------------------------------------
Write-Info 'Setting sshd to start automatically'
Set-Service -Name sshd -StartupType Automatic
# restart after 60 s on the first three failures, reset the counter after one day
& sc.exe failure sshd reset= 86400 actions= restart/60000/restart/60000/restart/60000 | Out-Null
Start-Service -Name sshd
Write-Ok 'sshd running'

# ---------------------------------------------------------------------------
# 3. firewall
# ---------------------------------------------------------------------------
Write-Info "Allowing TCP $SshPort in the Windows firewall"
$rule = Get-NetFirewallRule -Name $FirewallRuleName -ErrorAction SilentlyContinue
if ($rule) {
    Set-NetFirewallRule -Name $FirewallRuleName -Enabled True -Profile Any -Action Allow
} else {
    New-NetFirewallRule -Name $FirewallRuleName -DisplayName 'OpenSSH Server (sshd)' -Enabled True `
        -Direction Inbound -Protocol TCP -LocalPort $SshPort -Action Allow -Profile Any | Out-Null
}
Write-Ok "Firewall rule $FirewallRuleName enabled"

# ---------------------------------------------------------------------------
# 4. default shell
# ---------------------------------------------------------------------------
if (-not (Test-Path $OpenSshRegPath)) { New-Item -Path $OpenSshRegPath -Force | Out-Null }
if ($Shell -eq 'powershell') {
    Write-Info 'Setting PowerShell as default SSH shell'
    New-ItemProperty -Path $OpenSshRegPath -Name DefaultShell -Value $PowerShellExe -PropertyType String -Force | Out-Null
} else {
    Write-Info 'Using cmd.exe as default SSH shell'
    Remove-ItemProperty -Path $OpenSshRegPath -Name DefaultShell -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# 5. remote desktop
# ---------------------------------------------------------------------------
if (-not $SkipRdp) {
    Write-Info 'Enabling Remote Desktop'
    Set-ItemProperty -Path $RdpRegPath -Name fDenyTSConnections -Value 0
    # keep Network Level Authentication on
    Set-ItemProperty -Path "$RdpRegPath\WinStations\RDP-Tcp" -Name UserAuthentication -Value 1
    Set-Service -Name TermService -StartupType Automatic
    Start-Service -Name TermService
    $rdpRules = @(Get-NetFirewallRule -Group $RdpFirewallGroup -ErrorAction SilentlyContinue)
    if ($rdpRules.Count -gt 0) {
        $rdpRules | Set-NetFirewallRule -Enabled True -Profile Any -Action Allow
    } elseif (-not (Get-NetFirewallRule -Name 'RDP-Demo-In-TCP' -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name 'RDP-Demo-In-TCP' -DisplayName 'Remote Desktop (TCP-In, init-remote-access)' -Enabled True `
            -Direction Inbound -Protocol TCP -LocalPort $RdpPort -Action Allow -Profile Any | Out-Null
    }
    Write-Ok 'Remote Desktop enabled'
}

# ---------------------------------------------------------------------------
# 6. verification
# ---------------------------------------------------------------------------
$svc = Get-CimInstance Win32_Service -Filter "Name='sshd'"
if ($svc.State -eq 'Running') { Write-Ok 'sshd is running' } else { Write-Warn "sshd state is '$($svc.State)'" }
if ($svc.StartMode -eq 'Auto') { Write-Ok 'sshd starts automatically' } else { Write-Warn "sshd start mode is '$($svc.StartMode)'" }

$banner = Get-SshBanner $SshPort
if ($banner -like 'SSH-*') { Write-Ok "Port $SshPort answers: $banner" } else { Write-Warn "No SSH banner on port $SshPort" }

if (-not $SkipRdp) {
    if (Test-LocalPort $RdpPort) { Write-Ok "Port $RdpPort (RDP) is listening" } else { Write-Warn "Port $RdpPort (RDP) is not reachable" }
    if (Test-AdminsRdpRight) { Write-Ok 'Administrators may log on via Remote Desktop' }
    else { Write-Warn 'The Administrators group lacks "Allow log on through Remote Desktop Services" - check local/group policy' }
}

$addresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
    Select-Object -ExpandProperty IPAddress)

Write-Host ''
Write-Ok 'Done.'
Write-Host "  Connect with   : ssh $env:USERNAME@$($env:COMPUTERNAME.ToLower())"
foreach ($ip in $addresses) {
    Write-Host "                   ssh $env:USERNAME@$ip"
}
Write-Host "  Config file    : $env:ProgramData\ssh\sshd_config"
if (-not $SkipRdp) {
    Write-Host "  Remote Desktop : mstsc /v:$($env:COMPUTERNAME.ToLower())  (members of the local Administrators group)"
}
Write-Host ''
Write-Host '  Key login for administrators uses C:\ProgramData\ssh\administrators_authorized_keys,'
Write-Host '  for other users %USERPROFILE%\.ssh\authorized_keys.'
