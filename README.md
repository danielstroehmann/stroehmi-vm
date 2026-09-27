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
| [windows/](windows/) | Scripts for Windows servers (coming later) |
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

## No secrets in this repository

This repository is public. Never commit passwords, API tokens, private keys, certificates or
customer data. Scripts must ask for such values at runtime or read them from environment
variables. The [.gitignore](.gitignore) blocks common key and certificate files as an extra
safety net.

## License

[MIT](LICENSE) — free to use, copy and modify, provided **"as is", without any warranty or
liability**.
