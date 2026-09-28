<#
.SYNOPSIS
    Set up a fresh Windows Server 2025 as an IIS HTTPS demo host - with or without SNI.

.DESCRIPTION
    * installs all pending Windows updates
    * installs IIS with the required features (static content, HTTP redirect, management tools)
    * without SNI: one website on the "Default Web Site", certificate bound IP-based on
      0.0.0.0:443 (served to every client, no SNI needed)
    * with SNI: one IIS site per FQDN, each with its own certificate and an SNI binding
      *:443:<fqdn>
    * creates a self-signed certificate per FQDN
    * redirects plain HTTP (port 80) to HTTPS
    * deploys one of the demo pages from ..\homepage per website, with custom title and texts

    Each run describes the complete demo setup: sites created by an earlier run of this
    script are replaced. Other IIS sites are not touched.

    FOR TEST / DEMO ENVIRONMENTS ONLY - do not use in production.
    Run in Windows PowerShell 5.1 (powershell.exe) as Administrator.

.PARAMETER Sni
    Use SNI bindings (one site per FQDN). Use -Sni:$false to force the non-SNI setup.
    Asked if not given; implied when more than one FQDN is passed.

.PARAMETER Fqdn
    FQDN(s) of the website(s). Without SNI exactly one FQDN.

.PARAMETER Page
    Demo page(s) from the homepage folder, as file name (index-racing-v2.html) or list number.
    One value for all websites or one value per FQDN (same order).

.PARAMETER Title
    Page title (browser tab) for all websites (default: the page's own title).

.PARAMETER Greeting
    Greeting shown on the page (default: SHOWTIME).

.PARAMETER HostInfo
    Hosting info shown on the page (default: "Hosting: IIS [Windows]").

.PARAMETER Yes
    Do not ask for confirmation; use defaults for everything not given.

.PARAMETER SkipUpdates
    Skip installing Windows updates.

.PARAMETER HomepageDir
    Folder with the demo pages (default: <repo>\homepage).

.EXAMPLE
    .\init-iis.ps1

.EXAMPLE
    .\init-iis.ps1 -Sni:$false -Fqdn demo.example.com -Page index-racing-v2.html -Yes

.EXAMPLE
    .\init-iis.ps1 -Sni -Fqdn a.example.com, b.example.com -Page index-racing-v2.html, index-rocket-v2.html -Yes
#>
#Requires -RunAsAdministrator
#Requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$Sni,
    [string[]]$Fqdn,
    [string[]]$Page,
    [string]$Title,
    [string]$Greeting,
    [string]$HostInfo,
    [switch]$Yes,
    [switch]$SkipUpdates,
    [string]$HomepageDir = (Join-Path $PSScriptRoot '..\homepage')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$DefaultSiteName   = 'Default Web Site'
$CatchAllSiteName  = 'HTTP-Redirect'
$SitesRoot         = Join-Path $env:SystemDrive 'inetpub\sites'
$RedirectRoot      = Join-Path $env:SystemDrive 'inetpub\redirect'
$CertDays          = 365
$CertFriendlyName  = 'init-iis self-signed'
$DefaultGreeting   = 'SHOWTIME'
$DefaultHostInfo   = 'Hosting: IIS [Windows]'
$MaxTextLen        = 30
$MaxTitleLen       = 80
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

function Confirm-Step([string]$Question, [string]$Default = 'y') {
    if ($Yes) { return $true }
    return ((Read-Value "$Question (y/n)" $Default) -match '^[YyJj]')
}

function Test-Fqdn([string]$Name) {
    return ($Name.Length -le 253 -and $Name -match '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$')
}

# restrict page texts to characters that are safe in a JS string and the pixel fonts
function Test-PageText([string]$Text) {
    return ($Text.Length -le $MaxTextLen -and $Text -match '^[\[\]A-Za-z0-9 .,:;!?()/_+#@&%*=-]*$')
}

# the title is HTML-encoded on insert, only control characters are rejected
function Test-Title([string]$Text) {
    return ($Text.Length -ge 1 -and $Text.Length -le $MaxTitleLen -and $Text -notmatch '[\x00-\x1F]')
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

function Show-PageList {
    Write-Host ''
    Write-Info "Available demo pages in ${HomepageDir}:"
    for ($i = 0; $i -lt $pages.Count; $i++) {
        Write-Host ('  {0,2}) {1,-28} {2}' -f ($i + 1), $pages[$i].Name, (Get-PageTitle $pages[$i].FullName))
    }
    Write-Host ''
}

# list number or file name -> FileInfo
function Resolve-Page([string]$Selection) {
    if ($Selection -match '^\d+$') {
        $index = [int]$Selection
        if ($index -lt 1 -or $index -gt $pages.Count) { Stop-WithError "Invalid selection: $Selection" }
        return $pages[$index - 1]
    }
    $path = Join-Path $HomepageDir (Split-Path $Selection -Leaf)
    if (-not (Test-Path $path -PathType Leaf)) { Stop-WithError "Page not found: $path" }
    return Get-Item $path
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

function Get-DemoCertificate([string]$Name) {
    $cert = Get-ChildItem Cert:\LocalMachine\My |
        Where-Object { $_.Subject -eq "CN=$Name" -and $_.FriendlyName -eq "$CertFriendlyName ($Name)" -and $_.NotAfter -gt (Get-Date).AddDays(1) } |
        Sort-Object NotAfter -Descending | Select-Object -First 1
    if ($cert) {
        Write-Warn "Certificate for $Name already exists - reusing $($cert.Thumbprint)"
        return $cert
    }
    Write-Info "Creating self-signed certificate for $Name"
    $cert = New-SelfSignedCertificate -Type SSLServerAuthentication -DnsName $Name `
        -CertStoreLocation 'Cert:\LocalMachine\My' -FriendlyName "$CertFriendlyName ($Name)" `
        -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 `
        -KeyUsage DigitalSignature, KeyEncipherment -NotAfter (Get-Date).AddDays($CertDays)
    Write-Ok "Certificate: Cert:\LocalMachine\My\$($cert.Thumbprint)"
    return $cert
}

function Set-SiteHeader([string]$Site, [string]$Name, [string]$Value) {
    $filter = 'system.webServer/httpProtocol/customHeaders'
    Remove-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Location $Site -Filter $filter `
        -Name '.' -AtElement @{ name = $Name } -ErrorAction SilentlyContinue
    Add-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Location $Site -Filter $filter `
        -Name '.' -Value @{ name = $Name; value = $Value }
}

# site on port 80 that answers with a 301 to https://<Target>/<path>?<query>
function New-RedirectSite([string]$Name, [string]$HostHeader, [string]$Target) {
    New-Website -Name $Name -PhysicalPath $RedirectRoot -IPAddress '*' -Port 80 -HostHeader $HostHeader | Out-Null
    # $S = requested path, $Q = query string
    Set-WebConfiguration -PSPath 'MACHINE/WEBROOT/APPHOST' -Location $Name -Filter 'system.webServer/httpRedirect' -Value @{
        enabled            = $true
        destination        = ('https://{0}$S$Q' -f $Target)
        exactDestination   = $true
        httpResponseStatus = 'Permanent'
    }
}

# sites created by earlier runs live below $SitesRoot or $RedirectRoot
function Remove-DemoSites {
    foreach ($site in @(Get-ChildItem IIS:\Sites)) {
        $path = [Environment]::ExpandEnvironmentVariables($site.physicalPath)
        if ($path -notlike "$SitesRoot\*" -and $path -ne $RedirectRoot) { continue }
        foreach ($binding in @($site.bindings.Collection | Where-Object { $_.protocol -eq 'https' })) {
            $hostName = ($binding.bindingInformation -split ':')[2]
            if ($hostName -and (Test-Path "IIS:\SslBindings\!443!$hostName")) { Remove-Item "IIS:\SslBindings\!443!$hostName" }
        }
        Write-Info "Removing previous demo site '$($site.name)'"
        Remove-Website -Name $site.name
    }
}

function Publish-Page($Site) {
    Write-Info "Deploying $($Site.Page.Name) as $($Site.Target)"
    New-Item -ItemType Directory -Path $Site.WebRoot -Force | Out-Null
    $html = [IO.File]::ReadAllText($Site.Page.FullName, $Utf8NoBom)
    $html = [regex]::Replace($html, '(?m)^(\s*const GREETING\s*=\s*)".*";', { param($m) $m.Groups[1].Value + '"' + $Site.Greeting + '";' })
    $html = [regex]::Replace($html, '(?m)^(\s*const HOST_INFO\s*=\s*)".*";', { param($m) $m.Groups[1].Value + '"' + $Site.HostInfo + '";' })
    if ($Site.Title -ne $Site.OriginalTitle) {
        $encodedTitle = [System.Net.WebUtility]::HtmlEncode($Site.Title)
        $html = ([regex]'<title>.*?</title>').Replace($html, { '<title>' + $encodedTitle + '</title>' }, 1)
    }
    [IO.File]::WriteAllText($Site.Target, $html, $Utf8NoBom)
}

# TLS handshake against the local port 443; $ServerName is sent as SNI unless it is an IP address
function Get-ServedCertificate([string]$ServerName) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $client.Connect('127.0.0.1', 443)
        $acceptAll = [System.Net.Security.RemoteCertificateValidationCallback] { $true }
        $ssl = New-Object System.Net.Security.SslStream($client.GetStream(), $false, $acceptAll)
        $ssl.AuthenticateAsClient($ServerName)
        return New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate)
    } catch {
        return $null
    } finally {
        $client.Close()
    }
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
# accept "a.example.com, b.example.com" as well as -Fqdn a.example.com, b.example.com
$fqdns = @($Fqdn | ForEach-Object { $_ -split '[,;\s]+' } | Where-Object { $_ })

if ($PSBoundParameters.ContainsKey('Sni')) { $useSni = [bool]$Sni }
elseif ($fqdns.Count -gt 1)                { $useSni = $true }
elseif ($Yes)                              { $useSni = $false }
else {
    Write-Host ''
    Write-Host '  Without SNI: one website, its certificate is served to every client (IP-based binding).'
    Write-Host '  With SNI   : one or more websites, each with its own FQDN and certificate.'
    $useSni = Confirm-Step 'Use SNI?' 'n'
}

if ($fqdns.Count -eq 0) {
    if ($useSni) {
        $answer = Read-Value 'FQDNs of the websites (separated by comma or space)' (Get-DefaultFqdn)
    } else {
        $answer = Read-Value 'FQDN of the website (used for IIS and the certificate)' (Get-DefaultFqdn)
    }
    $fqdns = @($answer -split '[,;\s]+' | Where-Object { $_ })
}
$fqdns = @($fqdns | ForEach-Object { $_.Trim().ToLower().TrimEnd('.') } | Select-Object -Unique)
if ($fqdns.Count -eq 0) { Stop-WithError 'No FQDN given.' }
foreach ($name in $fqdns) {
    if (-not (Test-Fqdn $name)) { Stop-WithError "Invalid FQDN: '$name'" }
}
if (-not $useSni -and $fqdns.Count -gt 1) {
    Stop-WithError 'Without SNI only one FQDN is possible - use -Sni for several websites.'
}

$pageArgs = @($Page | Where-Object { $_ })
if ($pageArgs.Count -gt 1 -and $pageArgs.Count -ne $fqdns.Count) {
    Stop-WithError "Pass one page for all websites or one page per FQDN ($($fqdns.Count))."
}
if ($pageArgs.Count -eq 0) { Show-PageList }

$sites = @()
for ($i = 0; $i -lt $fqdns.Count; $i++) {
    $name = $fqdns[$i]
    if (-not $Yes) {
        Write-Host ''
        Write-Info "Website $($i + 1) of $($fqdns.Count): https://$name/"
    }

    if ($pageArgs.Count -eq 1)     { $selection = $pageArgs[0] }
    elseif ($pageArgs.Count -gt 1) { $selection = $pageArgs[$i] }
    else                           { $selection = Read-Value "  Page for $name (1-$($pages.Count))" }
    $pageFile      = Resolve-Page $selection
    $originalTitle = Get-PageTitle $pageFile.FullName

    $siteTitle = $Title
    if (-not $siteTitle) {
        if ($Yes) { $siteTitle = $originalTitle }
        else { $siteTitle = Read-Value '  Page title (browser tab)' $originalTitle }
    }
    $siteGreeting = $Greeting
    if (-not $siteGreeting) {
        if ($Yes) { $siteGreeting = $DefaultGreeting }
        else { $siteGreeting = Read-Value "  Greeting shown on the page (max $MaxTextLen chars)" $DefaultGreeting }
    }
    $siteHostInfo = $HostInfo
    if (-not $siteHostInfo) {
        if ($Yes) { $siteHostInfo = $DefaultHostInfo }
        else { $siteHostInfo = Read-Value "  Hosting info shown on the page (max $MaxTextLen chars)" $DefaultHostInfo }
    }
    if (-not (Test-Title $siteTitle)) { Stop-WithError "Title must be 1-$MaxTitleLen characters without control characters." }
    if (-not (Test-PageText $siteGreeting)) { Stop-WithError "Greeting contains unsupported characters or is longer than $MaxTextLen chars." }
    if (-not (Test-PageText $siteHostInfo)) { Stop-WithError "Hosting info contains unsupported characters or is longer than $MaxTextLen chars." }

    if ($useSni) {
        $siteName = $name
        $webRoot  = Join-Path $SitesRoot $name
    } else {
        $siteName = $DefaultSiteName
        $webRoot  = $null   # resolved from the Default Web Site once IIS is installed
    }
    $sites += [pscustomobject]@{
        Fqdn          = $name
        SiteName      = $siteName
        WebRoot       = $webRoot
        Target        = $null
        Page          = $pageFile
        OriginalTitle = $originalTitle
        Title         = $siteTitle
        Greeting      = $siteGreeting
        HostInfo      = $siteHostInfo
        Cert          = $null
    }
}

Write-Host ''
Write-Info 'Summary'
if ($useSni) {
    Write-Host '  Mode         : SNI - one IIS site per FQDN, binding *:443:<fqdn>'
} else {
    Write-Host "  Mode         : without SNI - '$DefaultSiteName', binding *:443 (0.0.0.0:443)"
}
foreach ($site in $sites) {
    Write-Host ''
    Write-Host "  https://$($site.Fqdn)/"
    Write-Host "    IIS site     : $($site.SiteName)"
    Write-Host "    Page         : $($site.Page.Name)"
    Write-Host "    Title        : $($site.Title)"
    Write-Host "    Greeting     : $($site.Greeting)"
    Write-Host "    Hosting info : $($site.HostInfo)"
}
Write-Host ''
Write-Host "  Certificates : self-signed, one per FQDN, $CertDays days, Cert:\LocalMachine\My"
Write-Host "  HTTP (80)    : 301 redirect to HTTPS"
Write-Host "  Updates      : $(if ($SkipUpdates) { 'skipped' } else { 'yes' })"
Write-Host '  Demo sites from earlier runs of this script are replaced.'
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
if (-not (Test-Path "IIS:\Sites\$DefaultSiteName")) { Stop-WithError "IIS site '$DefaultSiteName' not found." }

# ---------------------------------------------------------------------------
# 3. self-signed certificates
# ---------------------------------------------------------------------------
foreach ($site in $sites) {
    $site.Cert = Get-DemoCertificate $site.Fqdn
}

# ---------------------------------------------------------------------------
# 4. IIS sites and bindings
# ---------------------------------------------------------------------------
Remove-DemoSites

# the Default Web Site gives up port 80 to the redirect sites in both modes
Get-WebBinding -Name $DefaultSiteName -Protocol http  | Remove-WebBinding
Get-WebBinding -Name $DefaultSiteName -Protocol https | Remove-WebBinding
# IP-based http.sys binding = the non-SNI certificate binding
if (Test-Path 'IIS:\SslBindings\0.0.0.0!443') { Remove-Item 'IIS:\SslBindings\0.0.0.0!443' }

if ($useSni) {
    Write-Info "Stopping '$DefaultSiteName' (not used with SNI)"
    Stop-Website -Name $DefaultSiteName
    Set-ItemProperty "IIS:\Sites\$DefaultSiteName" -Name serverAutoStart -Value $false

    foreach ($site in $sites) {
        Write-Info "Creating site '$($site.SiteName)' with SNI binding *:443:$($site.Fqdn)"
        New-Item -ItemType Directory -Path $site.WebRoot -Force | Out-Null
        New-Website -Name $site.SiteName -PhysicalPath $site.WebRoot -IPAddress '*' -Port 443 `
            -HostHeader $site.Fqdn -Ssl -SslFlags 1 | Out-Null
        if (Test-Path "IIS:\SslBindings\!443!$($site.Fqdn)") { Remove-Item "IIS:\SslBindings\!443!$($site.Fqdn)" }
        (Get-WebBinding -Name $site.SiteName -Protocol https -HostHeader $site.Fqdn).AddSslCertificate($site.Cert.Thumbprint, 'My')
        Set-SiteHeader $site.SiteName 'X-Content-Type-Options' 'nosniff'
        Set-SiteHeader $site.SiteName 'Referrer-Policy' 'strict-origin-when-cross-origin'
    }
} else {
    $site = $sites[0]
    Write-Info "Configuring '$DefaultSiteName' for HTTPS on port 443 (no SNI)"
    Set-ItemProperty "IIS:\Sites\$DefaultSiteName" -Name serverAutoStart -Value $true
    New-WebBinding -Name $DefaultSiteName -Protocol https -IPAddress '*' -Port 443 -SslFlags 0
    (Get-WebBinding -Name $DefaultSiteName -Protocol https -Port 443).AddSslCertificate($site.Cert.Thumbprint, 'My')
    Set-SiteHeader $DefaultSiteName 'X-Content-Type-Options' 'nosniff'
    Set-SiteHeader $DefaultSiteName 'Referrer-Policy' 'strict-origin-when-cross-origin'
    $site.WebRoot = [Environment]::ExpandEnvironmentVariables((Get-Item "IIS:\Sites\$DefaultSiteName").physicalPath)
}

# HTTP -> HTTPS: IIS' built-in redirect cannot keep the requested host name,
# so every FQDN gets its own small redirect site plus one catch-all site
New-Item -ItemType Directory -Path $RedirectRoot -Force | Out-Null
foreach ($site in $sites) {
    Write-Info "Creating redirect site '$($site.Fqdn)-http' (http://$($site.Fqdn)/ -> https://$($site.Fqdn)/)"
    New-RedirectSite -Name "$($site.Fqdn)-http" -HostHeader $site.Fqdn -Target $site.Fqdn
}
Write-Info "Creating catch-all redirect site '$CatchAllSiteName' (-> https://$($sites[0].Fqdn)/)"
New-RedirectSite -Name $CatchAllSiteName -HostHeader '' -Target $sites[0].Fqdn

# ---------------------------------------------------------------------------
# 5. homepages
# ---------------------------------------------------------------------------
foreach ($site in $sites) {
    $site.Target = Join-Path $site.WebRoot 'index.html'
    Publish-Page $site
}

# ---------------------------------------------------------------------------
# 6. firewall + start
# ---------------------------------------------------------------------------
Write-Info 'Enabling firewall rules for HTTP and HTTPS'
Enable-NetFirewallRule -Name 'IIS-WebServerRole-HTTP-In-TCP', 'IIS-WebServerRole-HTTPS-In-TCP' -ErrorAction SilentlyContinue

Write-Info 'Starting IIS sites'
Start-Service W3SVC
foreach ($site in $sites) {
    Start-Website -Name $site.SiteName
    Start-Website -Name "$($site.Fqdn)-http"
}
Start-Website -Name $CatchAllSiteName

# ---------------------------------------------------------------------------
# 7. verification
# ---------------------------------------------------------------------------
Write-Host ''
Write-Info 'Checking the websites'
$curl = Join-Path $env:SystemRoot 'System32\curl.exe'
foreach ($site in $sites) {
    $served = Get-ServedCertificate $site.Fqdn
    if ($served -and $served.Thumbprint -eq $site.Cert.Thumbprint) { Write-Ok "$($site.Fqdn): serves its own certificate" }
    else { Write-Warn "$($site.Fqdn): TLS handshake failed or served a different certificate" }

    if (-not (Test-Path $curl)) { continue }
    $tmp = [IO.Path]::GetTempFileName()
    try {
        $code = & $curl -sk --ssl-no-revoke -o $tmp -w '%{http_code}' --resolve "$($site.Fqdn):443:127.0.0.1" "https://$($site.Fqdn)/"
        $sameContent = ([IO.File]::ReadAllText($tmp, $Utf8NoBom) -eq [IO.File]::ReadAllText($site.Target, $Utf8NoBom))
        if ($code -eq '200' -and $sameContent) { Write-Ok "$($site.Fqdn): HTTPS 200, serves $($site.Page.Name)" }
        else { Write-Warn "$($site.Fqdn): HTTPS returned '$code' or unexpected content" }
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
    $redirect = & $curl -s -o NUL -w '%{http_code} %{redirect_url}' --resolve "$($site.Fqdn):80:127.0.0.1" "http://$($site.Fqdn)/"
    if ($redirect -like "301 https://$($site.Fqdn)*") { Write-Ok "$($site.Fqdn): HTTP redirects to HTTPS (301)" }
    else { Write-Warn "$($site.Fqdn): HTTP check returned '$redirect'" }
}
$noSni = Get-ServedCertificate '127.0.0.1'
if ($useSni) {
    if ($noSni) { Write-Warn "Clients without SNI still get a certificate ($($noSni.Subject)) - another IP-based binding exists" }
    else { Write-Ok 'Clients without SNI get no certificate (SNI only)' }
} else {
    if ($noSni -and $noSni.Thumbprint -eq $sites[0].Cert.Thumbprint) { Write-Ok 'Clients without SNI get the certificate (IP-based binding)' }
    else { Write-Warn 'HTTPS without SNI (by IP) did not return the expected certificate' }
}

Write-Host ''
Write-Ok 'Done.'
foreach ($site in $sites) {
    $sha256 = [Security.Cryptography.SHA256]::Create().ComputeHash($site.Cert.RawData)
    Write-Host ''
    Write-Host "  URL                : https://$($site.Fqdn)/"
    Write-Host "  IIS site           : $($site.SiteName) ($(if ($useSni) { "*:443:$($site.Fqdn), SNI" } else { '*:443, no SNI' }))"
    Write-Host "  Certificate        : Cert:\LocalMachine\My\$($site.Cert.Thumbprint)"
    Write-Host "  SHA-256 fingerprint: $([BitConverter]::ToString($sha256).Replace('-', ':'))"
}
Write-Host ''
Write-Host '  The certificates are self-signed - browsers will show a warning.'
Write-Host '  Make sure DNS (or the hosts file on the client) points the FQDNs to this server.'
if ((New-Object -ComObject Microsoft.Update.SystemInfo).RebootRequired) {
    Write-Host ''
    Write-Warn 'A reboot is required to finish installing updates (Restart-Computer).'
}
