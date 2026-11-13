# Contributing to notchJP

Report bugs and propose features in [Issues](https://github.com/JoaoPauloNA/notchJP/issues). Include steps to reproduce, macOS version, and expected/actual behavior. For LG/TCL reports, include model, firmware, and region, but remove credentials and personal device identifiers.

For code changes, open `notchi/notchi.xcodeproj` with Xcode 26.3 or later. Keep pull requests focused, describe the behavior change, and run `./scripts/test.sh all`. Add regression tests for behavior fixes. The project uses MainActor isolation by default.

Do not commit credentials, pairing keys, local preferences, signed private builds, or update-server secrets. Do not edit user hook configuration directly; use the existing hook installers and their tests.

Contributions are licensed under GPL-3.0-only. Preserve upstream copyright and third-party notices.
