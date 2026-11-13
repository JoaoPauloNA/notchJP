<div align="center">

<img src="notchi/notchi/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="96" alt="notchJP app icon">

# notchJP

**Music, audio controls, AI agent activity, and everyday tools. One macOS panel.**

[![macOS](https://img.shields.io/badge/macOS-15%2B-black?logo=apple)](#requirements)
[![License](https://img.shields.io/badge/license-GPL--3.0--only-blue)](LICENSE)
[![Build & Test](https://github.com/JoaoPauloNA/notchJP/actions/workflows/test.yml/badge.svg)](https://github.com/JoaoPauloNA/notchJP/actions/workflows/test.yml)

[Features](#features) · [Build from source](#build-from-source) · [Home integrations](#home-integrations) · [Contributing](CONTRIBUTING.md) · [Português](README.pt-BR.md)

</div>

notchJP is a free, open-source macOS companion based on [Notchi by Ruban](https://github.com/sk-ruban/notchi). It extends the original agent companion with Spotify playback, per-app audio mixing, panels on external displays, productivity tools, and optional home device controls.

**Status: early public source release.** The dashboard supports Brazilian Portuguese and English (Appearance → Language). This repository does not provide a notarized installer or a public automatic-update feed. Build instructions are below; a ready-to-install public binary is not available yet.

## Features

| Area | What you can do |
| --- | --- |
| Multiple displays | Use a panel on each display. Side drawers follow the position of external screens; choose layouts and favorite display resolutions. |
| Spotify | Browse playback information, skip tracks, seek, and open album selection. The player takes its accent color from album artwork. |
| Audio mixer | Adjust volume and mute per application, view peak levels, and choose compatible output devices. Volumes, destinations, and the enabled state survive restarts. |
| AI agents | Follow Claude Code and Codex activity with animated companions, session information, and usage views. Approvals remain in the original terminal. |
| Calendar and tools | See events, manage reminders, use focus timers, and share files from the tray. |
| Appearance | Reorder and hide tabs, select the initial tab, and use optional Liquid Glass on supported systems. |
| Home controls | Control compatible LG webOS TVs and TCL Home air conditioners, with device names, favorites, scenes, and timers. |

You can use the music, audio, and productivity panels without an AI provider account. Provider integrations and home controls are optional.

## Requirements

- macOS 15 or later.
- Xcode 26.3 or later, with the macOS SDK and command-line tools selected.
- Apple Silicon is the tested development platform; Intel compatibility has not been validated.
- Spotify for the Spotify controls; supported devices/accounts for home integrations.
- Claude Code or Codex only if you want their agent integrations.

A MacBook notch is the primary layout. External displays use dedicated drawers or top panels.

## Build from source

```sh
git clone https://github.com/JoaoPauloNA/notchJP.git
cd notchJP
./scripts/build-local-app.sh
```

The build is written to `build/public/Build/Products/Release/notchJP.app`. The script builds and verifies a local signature; it does not install the app or contact a private update service. Open `notchi/notchi.xcodeproj` to develop in Xcode.

Local builds use ad-hoc signing by default and are **not Apple-notarized**. For repeated personal builds, set `NOTCH_SIGN_IDENTITY` to an existing signing identity you manage. Signing changes can cause macOS to request permissions again. Do not install this fork alongside another Notchi-derived app that uses the same bundle identifier (`com.ruban.notchi`): they may share preferences and system permissions.

The original Notchi download is a different app; its releases do not contain the notchJP features listed here.

## Public and private editions

This repository contains the **public edition**. It has no automatic update service, VPS address, download token, or private release workflow. Settings identifies it as “Edição Pública” and links to this repository for manual updates. The build script and CI reject bundles containing update-feed credentials or enabled automatic updates.

The maintainer's **private edition** is maintained separately, with its own signed automatic-update channel. Private server configuration and distribution credentials are not part of this repository. There is no switch in the public app that enables that channel.

## First launch

1. Open the app and use **Configurações** to choose visible tabs and appearance.
2. Connect Spotify and grant Automation permission when requested.
3. Enable **Ativar mixer** in **Áudio** to use per-app volume. macOS may request system audio access. The switch is remembered on subsequent launches.
4. Enable only the optional integrations you need. Calendar, Reminders, microphone, Accessibility, and local network permissions depend on the feature used.
5. Configure agent hooks in settings if you use Claude Code or Codex. Review and approve any hook setup in the corresponding tool.

## Home integrations

These are optional, community integrations, not official LG or TCL products. Neither company sponsors or endorses notchJP. Compatibility depends on device model, firmware, region, and account support.

### LG webOS TV

Connect to a compatible TV on the local network and approve pairing on the TV. Controls include volume, mute, power off, inputs, and remote navigation. Wake-on-LAN requires a saved MAC address and a TV/network configuration that supports waking; it is not guaranteed for every model or power state.

### TCL Home air conditioners

Sign in using **your own TCL Home account** and choose the appropriate region. Available controls include power, target temperature, mode, fan, and supported airflow/eco/sleep settings. The implementation communicates with TCL cloud services and requires internet access; login challenges and cloud API changes can affect availability. Not every TCL appliance or account region is supported. Protocol attribution is preserved in [the TCL third-party notices](notchi/notchi/Resources/TCL_THIRD_PARTY_NOTICES.txt).

### Scenes and timers

Save combinations of supported device actions and assign keyboard shortcuts. Timers require the app to remain open and the Mac awake. Missed actions are not replayed after sleep. Mac Shortcuts actions can control the air conditioner, LG TV and saved scenes; name a shortcut to call it through Siri. See [Siri setup](docs/SIRI.md). iPhone/HomePod bridging and HomeKit are not included.

## Privacy and permissions

See [PRIVACY.md](PRIVACY.md) for a feature-by-feature overview. Your credentials, TV pairing data, device selections, and private update credentials are not bundled with this source release.

The audio mixer processes audio in memory without recording it to a file. Dictation is a separate feature and may record/transcribe audio according to its selected backend. Optional cloud integrations communicate with their respective providers; this is not an entirely offline app.

## New in 1.4

Save, apply, rename and delete audio profiles; reconnect audio from Diagnostics; export a status-only JSON report without account/device names or credentials. A first-launch guide explains optional integrations and can be reopened from About. Background service refreshes are separated from pointer tracking, and home timers run only while an action is scheduled.

Public distribution remains source-only on GitHub; there is no installer release planned for this phase.

## Known limitations

- Audio conversion supports Float32 mono/stereo at 8–192 kHz. Multi-stream and other formats report an error. Bluetooth/USB routes and wake recovery need broader hardware validation.
- The public source edition has automatic updates disabled. Update the source and rebuild.
- Home integrations have been tested on a limited set of devices. Reports with model, firmware, region, and sanitized logs are welcome.
- Dashboard language is selectable; some integration errors and Shortcuts action names still use their original language.

## Development

```sh
./scripts/test.sh all
```

GitHub Actions builds and tests on a hosted macOS runner. It has no access to the maintainer's Mac, signing keys, private server, or device credentials.

See [CONTRIBUTING.md](CONTRIBUTING.md) for bug reports and pull requests. Please avoid including API tokens, account emails, TV pairing keys, or private network details in public issues.

## Credits and license

notchJP is a derivative of [Notchi](https://github.com/sk-ruban/notchi) by Ruban and its contributors. The original project supplies the foundation, agent companions, and much of the application infrastructure. This repository begins with a reviewed source snapshot; the original project's development history remains available upstream.

Original design acknowledgments include [Claude Island](https://github.com/farouqaldori/claude-island), [Readout](https://readout.org), and [Aseprite](https://www.aseprite.org). Additional notices are in [third-party licenses](docs/third-party-licenses.md) and the source resources.

Licensed under **GPL-3.0-only**. See [LICENSE](LICENSE). LG, TCL, Spotify, and other product names belong to their respective owners.
