# stroehmi-vm

Public collection of helper scripts for setting up demo/test environments (see README.md).

- This repository is PUBLIC: never add secrets (passwords, tokens, private keys, certificates,
  customer data, internal hostnames/IPs). Scripts must prompt for such values at runtime or read
  them from environment variables.
- Scripts are for test/demo use only; keep the warning in README.md intact.
- Linux scripts target a fresh Ubuntu Server 26.04 and live in `linux/`; Windows scripts in `windows/`.
