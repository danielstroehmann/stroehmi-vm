<#
.SYNOPSIS
    Set up a fresh Windows Server 2025 as an IIS HTTPS demo host.

.DESCRIPTION
    * installs all pending Windows updates
    * installs IIS with the required features (static content, HTTP redirect, management tools)
    * creates a self-signed certificate for the given FQDN
    * binds it on port 443 WITHOUT SNI (IP-based binding 0.0.0.0:443)
    * redirects plain HTTP (port 80) to HTTPS
    * deploys one of the demo pages from ..\homepage as index.html

    FOR TEST / DEMO ENVIRONMENTS ONLY - do not use in production.
    Run in Windows PowerShell 5.1 (powershell.exe) as Administrator.

.PARAMETER Fqdn
    FQDN the server listens on (used for the certificate).

.PARAMETER Page
    Demo page from the homepage folder, as file name (index-racing-v2.html) or list number.

.PARAMETER Greeting
    Greeting shown on the page (default: SHOWTIME).

.PARAMETER HostInfo
    Hosting info shown on the page (default: "Hosting: IIS [Windows]").

.PARAMETER Yes
    Do not ask for confirmation.

.PARAMETER SkipUpdates
    Skip installing Windows updates.

.PARAMETER HomepageDir
    Folder with the demo pages (default: <repo>\homepage).

.EXAMPLE
    .\init-iis.ps1

.EXAMPLE
    .\init-iis.ps1 -Fqdn demo.example.com -Page index-racing-v2.html -Yes
#>
#Requires -RunAsAdministrator
#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$Fqdn,
    [string]$Page,
    [string]$Greeting,
    [string]$HostInfo,
    [switch]$Yes,
    [switch]$SkipUpdates,
    [string]$HomepageDir = (Join-Path $PSScriptRoot '..\homepage')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$SiteName          = 'Default Web Site'
$RedirectSiteName  = 'HTTP-Redirect'
$RedirectRoot      = Join-Path $env:SystemDrive 'inetpub\redirect'
$CertDays          = 365
$CertFriendlyName  = 'init-iis self-signed'
$DefaultGreeting   = 'SHOWTIME'
$DefaultHostInfo   = 'Hosting: IIS [Windows]'
$MaxTextLen        = 30
$Utf8NoBom         = New-Object System.Text.UTF8Encoding($false)

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

function Test-Fqdn([string]$Name) {
    return ($Name.Length -le 253 -and $Name -match '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$')
}

# restrict page texts to characters that are safe in a JS string and the pixel fonts
function Test-PageText([string]$Text) {
    return ($Text.Length -le $MaxTextLen -and $Text -match '^[\[\]A-Za-z0-9 .,:;!?()/_+#@&%*=-]*$')
}

function Get-PageTitle([string]$Path) {
    $m = [regex]::Match([IO.File]::ReadAllText($Path, $Utf8NoBom), '<title>(.*?)</title>')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}

function Get-DefaultFqdn {
    try { return [System.Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName.ToLower() }
    catch { return $env:COMPUTERNAME.ToLower() }
}

function Install-PendingUpdates {
    $session  = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    Write-Info 'Searching for Windows updates (this can take a while)'
    $result = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'")
    if ($result.Updates.Count -eq 0) {
        Write-Ok 'No updates available'
        return
    }
    $updates = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($update in $result.Updates) {
        if (-not $update.EulaAccepted) { $update.AcceptEula() }
        Write-Host "    $($update.Title)"
        [void]$updates.Add($update)
    }
    Write-Info "Downloading $($updates.Count) update(s)"
    $downloader = $session.CreateUpdateDownloader()
    $downloader.Updates = $updates
    [void]$downloader.Download()
    Write-Info 'Installing updates'
    $installer = $session.CreateUpdateInstaller()
    $installer.Updates = $updates
    $install = $installer.Install()
    # ResultCode: 2 = succeeded, 3 = succeeded with errors, 4 = failed
    if ($install.ResultCode -eq 2) { Write-Ok 'Updates installed' }
    else { Write-Warn "Windows Update finished with result code $($install.ResultCode) - check Settings > Windows Update" }
}

function Set-SiteHeader([string]$Site, [string]$Name, [string]$Value) {
    $filter = 'system.webServer/httpProtocol/customHeaders'
    Remove-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Location $Site -Filter $filter `
        -Name '.' -AtElement @{ name = $Name } -ErrorAction SilentlyContinue
    Add-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Location $Site -Filter $filter `
        -Name '.' -Value @{ name = $Name; value = $Value }
}

# ---------------------------------------------------------------------------
# pre-flight checks
# ---------------------------------------------------------------------------
if ($PSVersionTable.PSEdition -ne 'Desktop') {
    Stop-WithError 'Please run this script in Windows PowerShell 5.1 (powershell.exe), not in PowerShell 7 - the IIS module needs it.'
}

$os = Get-CimInstance Win32_OperatingSystem
if ($os.ProductType -eq 1) { Stop-WithError "This script needs Windows Server (detected: $($os.Caption))." }
if ($os.Caption -notmatch 'Server 2025') {
    Write-Warn "Written for Windows Server 2025, detected $($os.Caption)."
    if (-not (Confirm-Step 'Continue anyway?')) { exit 1 }
}

if (-not (Test-Path $HomepageDir -PathType Container)) {
    Stop-WithError "Homepage folder not found: $HomepageDir (clone the whole repository or pass -HomepageDir)."
}
$HomepageDir = (Resolve-Path $HomepageDir).Path
$pages = @(Get-ChildItem -Path $HomepageDir -Filter '*.html' -File | Sort-Object Name)
if ($pages.Count -eq 0) { Stop-WithError "No .html files found in $HomepageDir." }

# ---------------------------------------------------------------------------
# collect input
# ---------------------------------------------------------------------------
if (-not $Fqdn) {
    $Fqdn = Read-Value 'FQDN for this server (used for IIS and the certificate)' (Get-DefaultFqdn)
}
$Fqdn = $Fqdn.Trim().ToLower().TrimEnd('.')
if (-not (Test-Fqdn $Fqdn)) { Stop-WithError "Invalid FQDN: '$Fqdn'" }

if (-not $Page) {
    Write-Host ''
    Write-Info "Available demo pages in ${HomepageDir}:"
    for ($i = 0; $i -lt $pages.Count; $i++) {
        Write-Host ('  {0,2}) {1,-28} {2}' -f ($i + 1), $pages[$i].Name, (Get-PageTitle $pages[$i].FullName))
    }
    Write-Host ''
    $Page = Read-Value "Select the page to use as index.html (1-$($pages.Count))"
}
if ($Page -match '^\d+$') {
    $index = [int]$Page
    if ($index -lt 1 -or $index -gt $pages.Count) { Stop-WithError "Invalid selection: $Page" }
    $Page = $pages[$index - 1].Name
}
$Page = Split-Path $Page -Leaf
$PagePath = Join-Path $HomepageDir $Page
if (-not (Test-Path $PagePath -PathType Leaf)) { Stop-WithError "Page not found: $PagePath" }

if (-not $Greeting) {
    if ($Yes) { $Greeting = $DefaultGreeting }
    else { $Greeting = Read-Value "Greeting shown on the page (max $MaxTextLen chars)" $DefaultGreeting }
}
if (-not $HostInfo) {
    if ($Yes) { $HostInfo = $DefaultHostInfo }
    else { $HostInfo = Read-Value "Hosting info shown on the page (max $MaxTextLen chars)" $DefaultHostInfo }
}
if (-not (Test-PageText $Greeting)) { Stop-WithError "Greeting contains unsupported characters or is longer than $MaxTextLen chars." }
if (-not (Test-PageText $HostInfo)) { Stop-WithError "Hosting info contains unsupported characters or is longer than $MaxTextLen chars." }

Write-Host ''
Write-Info 'Summary'
Write-Host "  FQDN         : $Fqdn"
Write-Host "  Page         : $Page ($(Get-PageTitle $PagePath))"
Write-Host "  Greeting     : $Greeting"
Write-Host "  Hosting info : $HostInfo"
Write-Host "  Certificate  : self-signed, $CertDays days, Cert:\LocalMachine\My"
Write-Host '  HTTPS binding: *:443 without SNI (0.0.0.0:443)'
Write-Host "  Updates      : $(if ($SkipUpdates) { 'skipped' } else { 'yes' })"
Write-Host ''
if (-not (Confirm-Step 'Proceed?')) { exit 1 }

# ---------------------------------------------------------------------------
# 1. windows updates
# ---------------------------------------------------------------------------
if (-not $SkipUpdates) {
    Install-PendingUpdates
}

# ---------------------------------------------------------------------------
# 2. IIS
# ---------------------------------------------------------------------------
Write-Info 'Installing IIS'
$features = 'Web-Server', 'Web-Static-Content', 'Web-Default-Doc', 'Web-Http-Errors', 'Web-Http-Redirect',
            'Web-Http-Logging', 'Web-Filtering', 'Web-Mgmt-Console', 'Web-Scripting-Tools'
$featureResult = Install-WindowsFeature -Name $features
if (-not $featureResult.Success) { Stop-WithError 'Installing the IIS features failed.' }
Import-Module WebAdministration

# ---------------------------------------------------------------------------
# 3. self-signed certificate
# ---------------------------------------------------------------------------
$cert = Get-ChildItem Cert:\LocalMachine\My |
    Where-Object { $_.Subject -eq "CN=$Fqdn" -and $_.FriendlyName -eq "$CertFriendlyName ($Fqdn)" -and $_.NotAfter -gt (Get-Date).AddDays(1) } |
    Sort-Object NotAfter -Descending | Select-Object -First 1
if ($cert) {
    Write-Warn "Certificate for $Fqdn already exists - reusing $($cert.Thumbprint)"
} else {
    Write-Info "Creating self-signed certificate for $Fqdn"
    $cert = New-SelfSignedCertificate -Type SSLServerAuthentication -DnsName $Fqdn `
        -CertStoreLocation 'Cert:\LocalMachine\My' -FriendlyName "$CertFriendlyName ($Fqdn)" `
        -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 `
        -KeyUsage DigitalSignature, KeyEncipherment -NotAfter (Get-Date).AddDays($CertDays)
    Write-Ok "Certificate: Cert:\LocalMachine\My\$($cert.Thumbprint)"
}

# ---------------------------------------------------------------------------
# 4. HTTPS site (non-SNI) + HTTP redirect site
# ---------------------------------------------------------------------------
Write-Info "Configuring '$SiteName' for HTTPS on port 443 (no SNI)"
if (-not (Test-Path "IIS:\Sites\$SiteName")) { Stop-WithError "IIS site '$SiteName' not found." }

if (Test-Path "IIS:\Sites\$RedirectSiteName") { Remove-Website -Name $RedirectSiteName }
Get-WebBinding -Name $SiteName -Protocol http  | Remove-WebBinding
Get-WebBinding -Name $SiteName -Protocol https | Remove-WebBinding
# the IP based http.sys binding 0.0.0.0:443 is what makes this a non-SNI binding
if (Test-Path 'IIS:\SslBindings\0.0.0.0!443') { Remove-Item 'IIS:\SslBindings\0.0.0.0!443' }

New-WebBinding -Name $SiteName -Protocol https -IPAddress '*' -Port 443 -SslFlags 0
(Get-WebBinding -Name $SiteName -Protocol https -Port 443).AddSslCertificate($cert.Thumbprint, 'My')

Set-SiteHeader $SiteName 'X-Content-Type-Options' 'nosniff'
Set-SiteHeader $SiteName 'Referrer-Policy' 'strict-origin-when-cross-origin'

Write-Info "Creating site '$RedirectSiteName' (port 80 -> https://$Fqdn/)"
New-Item -ItemType Directory -Path $RedirectRoot -Force | Out-Null
New-Website -Name $RedirectSiteName -PhysicalPath $RedirectRoot -IPAddress '*' -Port 80 | Out-Null
# $S = requested path, $Q = query string
Set-WebConfiguration -PSPath 'MACHINE/WEBROOT/APPHOST' -Location $RedirectSiteName -Filter 'system.webServer/httpRedirect' -Value @{
    enabled            = $true
    destination        = ('https://{0}$S$Q' -f $Fqdn)
    exactDestination   = $true
    httpResponseStatus = 'Permanent'
}

# ---------------------------------------------------------------------------
# 5. homepage
# ---------------------------------------------------------------------------
$webRoot = [Environment]::ExpandEnvironmentVariables((Get-Item "IIS:\Sites\$SiteName").physicalPath)
$target  = Join-Path $webRoot 'index.html'
Write-Info "Deploying $Page as $target"
$html = [IO.File]::ReadAllText($PagePath, $Utf8NoBom)
$html = [regex]::Replace($html, '(?m)^(\s*const GREETING\s*=\s*)".*";', { param($m) $m.Groups[1].Value + '"' + $Greeting + '";' })
$html = [regex]::Replace($html, '(?m)^(\s*const HOST_INFO\s*=\s*)".*";', { param($m) $m.Groups[1].Value + '"' + $HostInfo + '";' })
[IO.File]::WriteAllText($target, $html, $Utf8NoBom)

# ---------------------------------------------------------------------------
# 6. firewall + start
# ---------------------------------------------------------------------------
Write-Info 'Enabling firewall rules for HTTP and HTTPS'
Enable-NetFirewallRule -Name 'IIS-WebServerRole-HTTP-In-TCP', 'IIS-WebServerRole-HTTPS-In-TCP' -ErrorAction SilentlyContinue

Write-Info 'Starting IIS sites'
Start-Service W3SVC
Start-Website -Name $SiteName
Start-Website -Name $RedirectSiteName

# ---------------------------------------------------------------------------
# 7. verification
# ---------------------------------------------------------------------------
$curl = Join-Path $env:SystemRoot 'System32\curl.exe'
if (Test-Path $curl) {
    $httpsCode = & $curl -sk --ssl-no-revoke -o NUL -w '%{http_code}' --resolve "${Fqdn}:443:127.0.0.1" "https://$Fqdn/"
    $noSniCode = & $curl -sk --ssl-no-revoke -o NUL -w '%{http_code}' 'https://127.0.0.1/'
    $httpCode  = & $curl -s -o NUL -w '%{http_code}' --resolve "${Fqdn}:80:127.0.0.1" "http://$Fqdn/"
    if ($httpsCode -eq '200') { Write-Ok 'HTTPS responds with 200' } else { Write-Warn "HTTPS check returned '$httpsCode'" }
    if ($noSniCode -eq '200') { Write-Ok 'HTTPS without SNI (by IP) responds with 200' } else { Write-Warn "HTTPS check without SNI returned '$noSniCode'" }
    if ($httpCode  -eq '301') { Write-Ok 'HTTP redirects to HTTPS (301)' } else { Write-Warn "HTTP check returned '$httpCode'" }
} else {
    Write-Warn 'curl.exe not found - skipping the HTTP checks'
}

$sha256      = [Security.Cryptography.SHA256]::Create().ComputeHash($cert.RawData)
$fingerprint = [BitConverter]::ToString($sha256).Replace('-', ':')

Write-Host ''
Write-Ok 'Done.'
Write-Host "  URL                : https://$Fqdn/"
Write-Host "  Certificate        : Cert:\LocalMachine\My\$($cert.Thumbprint)"
Write-Host "  SHA-256 fingerprint: $fingerprint"
Write-Host "  HTTPS site         : $SiteName (*:443, no SNI)"
Write-Host "  HTTP redirect site : $RedirectSiteName (*:80)"
Write-Host ''
Write-Host '  The certificate is self-signed - browsers will show a warning.'
Write-Host "  Make sure DNS (or the hosts file on the client) points $Fqdn to this server."
if ((New-Object -ComObject Microsoft.Update.SystemInfo).RebootRequired) {
    Write-Host ''
    Write-Warn 'A reboot is required to finish installing updates (Restart-Computer).'
}
