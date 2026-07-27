# Contributing

Hey — glad you're here. Whether it's a bug report, a new command, or a wild Lua mod idea, contributions are welcome.

## Found a bug?

Open an [issue](https://github.com/HumanGenome/WindrosePlus/issues). Include:

- Your Windrose+ version (`wp.version`) and Windrose dedicated-server version (`DeploymentId` in `R5/ServerDescription.json`)
- What happened and what you expected
- Steps to reproduce
- Relevant logs — `R5/Binaries/Win64/ue4ss/UE4SS.log`, the PAK builder console output, or `windrose_plus_data/logs/<date>.log`

Screenshots help a lot. `wp.doctor` output is the fastest single thing to paste for a config or runtime problem.

If your issue is about your specific managed hosting (control panel, billing, support), please contact your host directly. Windrose+ GitHub issues are for the open-source mod itself.

## Found a security issue?

Don't open a public issue — see [SECURITY.md](.github/SECURITY.md).

## Want to add something?

1. Fork the repo
2. Make your changes on a branch
3. Test on a real Windrose server with UE4SS
4. Open a PR — describe what it does and why

Keep code style consistent with what's already there. Lua uses `local` everywhere, snake_case for variables, PascalCase for module tables.

## C++ mods

If you're working in `cpp-mods/`, you'll need the UE4SS SDK. See `cpp-mods/README.md` for build setup.
