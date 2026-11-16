# Third-party notices

Windrose+ is MIT licensed ([LICENSE](LICENSE)). The release zip also carries parts made by others, each under its own licence. Each licence text ships in the zip next to the part it covers.

| Part | In the release zip | Licence | Licence text |
|---|---|---|---|
| [repak](https://github.com/trumank/repak) | `tools/bin/repak.exe` | MIT or Apache-2.0 | `tools/bin/LICENSE-repak-MIT.txt`, `tools/bin/LICENSE-repak-APACHE.txt` |
| [retoc](https://github.com/trumank/retoc) | `tools/bin/retoc.exe` | MIT | `tools/bin/LICENSE-retoc.txt` |
| windrose-heal's Rust dependencies (about 100 crates, RocksDB, Snappy, LZ4, Zstandard and zlib among them) | `tools/windrose-heal/windrose-heal.exe` | MIT, Apache-2.0, BSD, Zlib and others, per crate | `tools/windrose-heal/THIRD-PARTY-LICENSES.txt` |
| [Leaflet](https://leafletjs.com/) 1.9.4 | `server/web/vendor/leaflet/` | BSD-2-Clause | `server/web/vendor/leaflet/LICENSE` |
| Cinzel, Cormorant Garamond and IBM Plex Mono fonts | `server/web/vendor/fonts/` | SIL Open Font License 1.1 | `server/web/vendor/fonts/OFL-*.txt` |
| [rxi/json.lua](https://github.com/rxi/json.lua) | `WindrosePlus/Scripts/modules/json.lua` | MIT | the file's own header |
| [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS): the C++ mods are built against it, and `UE4SS-settings.ini` is its settings file | `cpp-mods/*/*.dll`, `UE4SS-settings.ini` | MIT | `cpp-mods/LICENSE-UE4SS.txt` |

UE4SS itself is not in the zip. `install.ps1` downloads the pinned UE4SS build from the UE4SS releases on GitHub.

`tools/windrose-heal/THIRD-PARTY-LICENSES.txt` is written by the release workflow from the crates that are built into that release (`scripts/third-party-licenses.py`), so it always matches the program in the same zip.
