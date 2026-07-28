# Security Policy

Please do not open a public issue containing school credentials, VPN cookies,
session tickets, device identifiers, private SSH keys, VNC passwords, or a
real `.env` file.

For a suspected vulnerability in this bridge, use GitHub's private security
advisory flow. For vulnerabilities in Sangfor/aTrust, Surge, Colima, Docker, or
the upstream container image, report them to the corresponding vendor or
project.

The bridge intentionally publishes all UI and proxy ports on `127.0.0.1` only.
Changes that expose these ports to a LAN should be treated as security-sensitive.
