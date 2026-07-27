# Security Policy

## Reporting a vulnerability

If you've found a security issue in Windrose+ (the Lua mod, the web dashboard, the RCON listener, the PAK builder, or the C++ mods), please **do not** open a public GitHub issue.

Email security reports to: **security@humangenome.dev**, or open a private security advisory on GitHub at https://github.com/HumanGenome/WindrosePlus/security/advisories/new — that's the preferred channel.

Include:
- A description of the vulnerability
- Steps to reproduce
- Affected component (Lua mod / dashboard / RCON / PAK builder / C++ mod)
- Windrose+ version and Windrose dedicated-server version
- Whether the issue is currently being exploited

We aim to acknowledge reports within 72 hours and provide a triage update within 7 days.

## Scope

In scope:
- Authentication bypass on the dashboard, the RCON listener, or any authenticated `/api/*` route
- Unauthenticated access to data the public map is not supposed to expose
- Path traversal or arbitrary file read/write through the dashboard's static, catalog, or character-repair routes
- Command injection through RCON input, the mod loader, or the PAK builder
- A generated override PAK that lets a connected client escalate privileges on the host

Out of scope:
- Hardware-host vulnerabilities (those belong to your hosting provider)
- Vulnerabilities in retail Windrose itself (report to the game's developers)
- Vulnerabilities in third-party Lua mods running on Windrose+
- Anti-cheat / cheating concerns — Windrose+ does not provide anti-cheat
- Admin commands doing what admins asked for. `wp.speed`, `wp.tp`, and friends are intentionally powerful; protect the RCON password instead.
- Exposing the dashboard to the public internet without a password. Set a real `rcon.password` in `windrose_plus.json`.
