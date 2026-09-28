# Windows scripts

PowerShell scripts for a freshly installed **Windows Server 2025**: IIS with HTTPS, SSH and RDP access, renaming the server.

> [!WARNING]
> **For test and demo environments only** — see the [main README](../README.md) and
> [LICENSE](../LICENSE). Use at your own risk.

All commands below are run in **Windows PowerShell as Administrator**
(Start → type `powershell` → right-click → *Run as administrator*).

## 1. Install Git and get the repository

Windows Server does not ship with Git. Copy and paste this one-liner to download the latest
64-bit Git for Windows installer from GitHub and install it silently:

```powershell
$ProgressPreference='SilentlyContinue'; [Net.ServicePointManager]::SecurityProtocol='Tls12'; $a=(Invoke-RestMethod https://api.github.com/repos/git-for-windows/git/releases/latest).assets | Where-Object name -Match '^Git-.*-64-bit\.exe$' | Select-Object -First 1; Invoke-WebRequest $a.browser_download_url -OutFile "$env:TEMP\$($a.name)" -UseBasicParsing; Start-Process "$env:TEMP\$($a.name)" -ArgumentList '/VERYSILENT','/NORESTART','/SUPPRESSMSGBOXES' -Wait; $env:Path+=";$env:ProgramFiles\Git\cmd"; git --version
```

If `winget` is available on your server, this works as well:

```powershell
winget install --id Git.Git -e --source winget --accept-package-agreements --accept-source-agreements
```

Then clone the repository:

```powershell
cd $env:USERPROFILE; git clone https://github.com/danielstroehmann/stroehmi-vm.git; cd stroehmi-vm\windows
```

<details>
<summary>Without Git: download the repository as ZIP</summary>

```powershell
$ProgressPreference='SilentlyContinue'; Invoke-WebRequest https://github.com/danielstroehmann/stroehmi-vm/archive/refs/heads/main.zip -OutFile "$env:TEMP\stroehmi-vm.zip" -UseBasicParsing; Expand-Archive "$env:TEMP\stroehmi-vm.zip" $env:USERPROFILE -Force; cd "$env:USERPROFILE\stroehmi-vm-main\windows"; Get-ChildItem .. -Recurse | Unblock-File
```

</details>

## 2. Allow script execution for all users (including SYSTEM)

By default Windows blocks or restricts PowerShell scripts. This one-liner sets the execution
policy `Bypass` for the whole machine (scope `LocalMachine`), so it applies to every user,
including `SYSTEM` (e.g. scheduled tasks). It covers 64-bit and 32-bit Windows PowerShell and,
if installed, PowerShell 7:

```powershell
Set-ExecutionPolicy Bypass -Scope LocalMachine -Force; & "$env:windir\SysWOW64\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -Command 'Set-ExecutionPolicy Bypass -Scope LocalMachine -Force'; if (Get-Command pwsh -ErrorAction SilentlyContinue) { pwsh -NoProfile -Command 'Set-ExecutionPolicy Bypass -Scope LocalMachine -Force' }; Get-ExecutionPolicy -List
```

In the output, `LocalMachine` should now show `Bypass`. Notes:

- A Group Policy (`MachinePolicy` / `UserPolicy` in the list) always wins over this setting.
- A user-specific policy (`CurrentUser`) wins for that user — it is `Undefined` on a fresh server.
- `Bypass` runs every script without warnings. That is fine for a demo machine, but not
  something to do on production systems. To undo: `Set-ExecutionPolicy RemoteSigned -Scope LocalMachine -Force`.

If you only want to run a single script once without changing the policy:

```powershell
powershell -ExecutionPolicy Bypass -File .\init-iis.ps1
```

## 3. Scripts

Run the scripts in **Windows PowerShell 5.1** (`powershell.exe`, the default on Windows Server) —
the IIS module does not work properly in PowerShell 7. Every script has built-in help:
`Get-Help .\init-iis.ps1 -Full`.

### init-iis.ps1

Turns a fresh Windows Server 2025 into an IIS HTTPS demo host — the Windows counterpart of
[`linux/init-apache.sh`](../linux/init-apache.sh):

1. installs all pending Windows updates (via the built-in Windows Update API)
2. installs IIS with the required features (static content, HTTP redirect, management tools)
3. asks whether **SNI** should be used:

   | | without SNI | with SNI |
   | --- | --- | --- |
   | Websites | one | one or more, one per FQDN |
   | IIS site | *Default Web Site* | one site per FQDN (`C:\inetpub\sites\<fqdn>`) |
   | Binding | `*:443`, IP-based `0.0.0.0:443` | `*:443:<fqdn>` with SNI |
   | Clients without SNI | get the certificate | get no certificate |

4. asks for the FQDN(s) and creates a **self-signed certificate** per FQDN
   (`Cert:\LocalMachine\My`, friendly name `init-iis self-signed (<fqdn>)`)
5. per website: shows the demo pages from `homepage/`, lets you pick one and asks for the
   **page title** (browser tab), the greeting and the hosting text
6. redirects HTTP (port 80) to HTTPS with a 301 — one small redirect site per FQDN plus a
   catch-all site `HTTP-Redirect`
7. checks every website: served certificate, HTTPS content, HTTP redirect, and the behaviour
   for clients without SNI

Each run describes the complete demo setup: sites created by an earlier run are replaced,
other IIS sites are left alone.

```powershell
.\init-iis.ps1
```

Non-interactive:

```powershell
# without SNI
.\init-iis.ps1 -Sni:$false -Fqdn demo.example.com -Page index-racing-v2.html -Yes

# with SNI, two websites
.\init-iis.ps1 -Sni -Fqdn a.example.com, b.example.com -Page index-racing-v2.html, index-rocket-v2.html -Yes
```

Options: `-Sni`, `-Fqdn` (one or more), `-Page` (file name or list number; one for all websites
or one per FQDN), `-Title`, `-Greeting`, `-HostInfo`, `-Yes`, `-SkipUpdates`, `-HomepageDir`.

Windows updates may require a reboot and sometimes a second run to catch follow-up updates —
the script tells you when a reboot is pending.

### init-remote-access.ps1

Makes the server reachable via **SSH** and **Remote Desktop** — also after a reboot:

- **OpenSSH server**: installs it if missing (Windows Server 2025 ships it preinstalled but
  disabled), sets `sshd` to start automatically and to restart after a crash, opens TCP 22 in
  the firewall for all network profiles, optionally makes PowerShell the default SSH shell
  (asked, default: PowerShell). Password login with Windows accounts works out of the box.
- **Remote Desktop**: enables RDP for all members of the local *Administrators* group,
  keeps Network Level Authentication on and opens TCP 3389 for all network profiles
  (skip with `-SkipRdp`)
- checks at the end that `sshd` runs, starts automatically and answers on port 22, and that
  port 3389 is open and the Administrators group may log on via RDP

```powershell
.\init-remote-access.ps1
.\init-remote-access.ps1 -Shell powershell -Yes      # non-interactive
```

Connect with `ssh <user>@<server>` or `mstsc /v:<server>`.

### set-hostname.ps1

Renames the server — the Windows counterpart of [`linux/set-hostname.sh`](../linux/set-hostname.sh):

- accepts a host name (`demo01`, max. 15 characters) or an FQDN (`demo01.example.com`)
- on a workgroup server, the domain part of an FQDN is set as the **primary DNS suffix**
- on a domain member, it asks for domain credentials and leaves the DNS suffix to the domain
- asks whether to restart (the new name is active after the restart)

```powershell
.\set-hostname.ps1                                   # asks for the new name
.\set-hostname.ps1 demo01.example.com -Yes -Restart
```

If IIS was set up with `init-iis.ps1` for the old name, run it again with the new FQDN after
the restart to get a matching certificate.
