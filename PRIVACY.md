# Privacy and data handling

This describes the public source edition, not the privacy practices of third-party services.

- **Audio mixer:** captures application output using macOS audio APIs and processes it in memory. It does not write recordings to disk.
- **Spotify:** uses macOS automation to read playback information and send playback commands. Artwork may be fetched over the network.
- **Calendar and Reminders:** access the macOS stores after permission is granted. Reminders can be created or completed through the app.
- **Dictation:** microphone access is separate from the mixer. Depending on the selected backend, audio/text may be processed locally or sent to the configured transcription service. Review the backend before using it for sensitive speech.
- **AI providers and account integrations:** optional usage, account, and sentiment features communicate with their configured providers. Sentiment analysis may send prompt content to the selected API. Provider terms and privacy policies apply.
- **LG TV:** pairing and control use the local network. Pairing credentials are retained locally for reconnection.
- **TCL Home:** account authentication and device commands use TCL cloud services and associated infrastructure. Session credentials are stored through macOS Keychain support.
- **Local state:** preferences, mixer levels, scenes, and related app state are stored on the Mac. Optional clipboard history stays in memory; avoid enabling it if you do not want clipboard text retained during the session.
- **Updates:** this edition has no configured automatic-update feed and includes no private distribution token.

Source code is available for inspection. Do not upload logs containing credentials, prompt content, account details, device identifiers, or local addresses to public issues. Third-party APIs and device firmware can change independently of this project.
