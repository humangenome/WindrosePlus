# Contributing

Bug reports, new commands and Lua mods are all welcome.

## Found a bug?

Open an [issue](https://github.com/HumanGenome/WindrosePlus/issues). Include:

- Your Windrose+ version (`wp.version`) and Windrose dedicated-server version (`DeploymentId` in `R5/ServerDescription.json`)
- What happened and what you expected
- Steps to reproduce
- Relevant logs: `R5/Binaries/Win64/ue4ss/UE4SS.log`, the PAK builder console output, or `windrose_plus_data/logs/<date>.log`

Screenshots help a lot. `wp.doctor` output is the fastest single thing to paste for a config or runtime problem.

If your issue is about a hosted server you rent (control panel, billing, support), please contact your host directly. Windrose+ GitHub issues are for the open-source mod itself.

## Found a security issue?

Don't open a public issue; see [SECURITY.md](.github/SECURITY.md).

## Want to add something?

1. Fork the repo
2. Make your changes on a branch
3. Test on a real Windrose server with UE4SS
4. Open a PR that says what it does and why

Keep code style consistent with what's already there. Lua uses `local` everywhere, snake_case for variables, PascalCase for module tables.

## Route list and PAK builder version

Other tools read two files in each release, and CI checks both:

- `server/routes.json` lists every route in `server/windrose_plus_server.ps1`. Add, change or remove a route and update it in the same change, and raise `routes_version` when a route is added or removed or its method, login rule, request or response changes. CI fails if the server and the list disagree, or if the routes changed since the last release and `routes_version` did not go up.
- `tools/PAK_BUILDER_VERSION` goes up whenever the generated PAK output changes. CI keeps a fingerprint of the files that decide that output (the PAK builder and its `tools/lib` scripts, the default INI files, the repak and retoc versions in `release.yml`). After changing one of them, raise the version if the output changes, then run `pwsh scripts/Test-ReleaseMetadata.ps1 -RecordPakFingerprint` (add `-PakOutputUnchanged` for a change that leaves the output the same, such as a comment).

`pwsh scripts/Test-ReleaseMetadata.Tests.ps1` runs the checks' own tests.

## C++ mods

If you're working in `cpp-mods/`, you'll need the UE4SS SDK. See `cpp-mods/README.md` for build setup.
