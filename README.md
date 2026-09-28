# stroehmi-vm

A collection of helper scripts for quickly setting up **demo and test environments**
(for example a web server with TLS) that other things can then be tried out on.

> [!WARNING]
> **For test and demo environments only.**
> These scripts are meant for throwaway VMs, labs and demos. They are **not** hardened,
> not reviewed for production use, and may change system settings without asking
> (updates, packages, web server configuration, certificates).
> Do **not** run them on production systems or on machines holding important data.
> Use at your own risk — see [LICENSE](LICENSE).

## Contents

| Folder | Purpose |
| --- | --- |
| [linux/](linux/) | Bash scripts for Linux servers (Ubuntu) |
| [windows/](windows/) | PowerShell scripts for Windows Server 2025 — see [windows/README.md](windows/README.md) |
| [homepage/](homepage/) | Demo HTML pages that the scripts can deploy as a start page |

## Scripts

### linux/init-apache.sh

Turns a fresh **Ubuntu Server 26.04** into an Apache2 HTTPS demo host:

1. installs all pending updates (`apt-get full-upgrade`)
2. installs Apache2 and enables the required modules (`ssl`, `headers`, `http2`)
3. asks for the server's FQDN and creates a **self-signed certificate** for it
4. configures an HTTPS vhost and redirects port 80 to HTTPS
5. shows the demo pages from `homepage/`, lets you pick one and deploys it as `index.html`
   (the greeting and hosting text on the page can be customised)

```bash
git clone https://github.com/danielstroehmann/stroehmi-vm.git
cd stroehmi-vm
sudo ./linux/init-apache.sh
```

Non-interactive usage, for example from cloud-init:

```bash
sudo ./linux/init-apache.sh --fqdn demo.example.com --page index-racing-v2.html \
     --host-info "Hosting: Apache [Ubuntu]" --yes
```

Run `./linux/init-apache.sh --help` for all options.

Result:

- website: `https://<fqdn>/` (browsers warn because the certificate is self-signed)
- certificate / key: `/etc/ssl/certs/<fqdn>.crt`, `/etc/ssl/private/<fqdn>.key`
- Apache config: `/etc/apache2/sites-available/<fqdn>.conf`

To use a real certificate later, replace the certificate and key files (or change the paths in
the site config) and run `sudo systemctl reload apache2`.

### linux/init-ssh.sh

Installs and configures the OpenSSH server on a fresh **Ubuntu Server 26.04**:

1. installs all pending updates (`apt-get full-upgrade`)
2. installs `openssh-server` and enables it
3. allows **password login for all users, including root**
   (via `/etc/ssh/sshd_config.d/00-demo-password-auth.conf`, which takes precedence over the
   cloud-init default `PasswordAuthentication no`)
4. offers to set a root password, because root is locked on Ubuntu by default

```bash
sudo ./linux/init-ssh.sh
```

Non-interactive usage (the password comes from the environment and is never stored in the repo):

```bash
sudo ROOT_PASSWORD='<choose-one>' ./linux/init-ssh.sh --yes
```

> [!CAUTION]
> Root login with a password is insecure. Only use this on isolated test/demo machines.

### linux/set-hostname.sh

Changes the hostname of an **Ubuntu Server 26.04**:

1. sets the static hostname (short name) via `hostnamectl`
2. maps FQDN and short name to `127.0.1.1` in `/etc/hosts` (a backup is kept)
3. tells cloud-init not to reset the hostname or `/etc/hosts` on the next reboot

```bash
sudo ./linux/set-hostname.sh                        # asks for the new name
sudo ./linux/set-hostname.sh demo01.example.com --yes
```

If Apache was set up with `init-apache.sh` for the old name, run it again with the new FQDN to
get a matching vhost and certificate.

## No secrets in this repository

This repository is public. Never commit passwords, API tokens, private keys, certificates or
customer data. Scripts must ask for such values at runtime or read them from environment
variables. The [.gitignore](.gitignore) blocks common key and certificate files as an extra
safety net.

## License

[MIT](LICENSE) — free to use, copy and modify, provided **"as is", without any warranty or
liability**.
