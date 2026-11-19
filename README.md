# Pulse

Pulse is a native macOS menu bar tracker for Codex, Claude Code, and Gemini in Antigravity. The menu bar shows the percentage remaining in each provider's tightest active quota window. Open the popover to see a combined daily token chart or choose a provider for its individual history, quotas, and models.

## Download

Download the universal ZIP from [GitHub Releases](https://github.com/MrJuandi/pulse/releases/latest), extract it, and move Pulse to Applications. The app supports Apple silicon and Intel Macs running macOS 15 or later.

Release builds run on GitHub-hosted macOS runners. They are ad-hoc signed and are not notarized by Apple, so Gatekeeper may block the first launch.

## Build from source

Requires macOS 15 or later and Xcode or the Xcode Command Line Tools. The build uses Apple tools and system frameworks. It requires no package manager or external build downloads.

```sh
./scripts/build.sh
open dist/Pulse.app
```

The default build targets your Mac's architecture. Set `PULSE_UNIVERSAL=1` to build a universal binary. To keep Pulse in the menu bar after signing in, move it to Applications and enable **Options → Open at Login**.

## Data sources

- **Codex:** Pulse reads the installed Codex tool's account rate-limit response through its app-server protocol and reads token counts from local session logs.
- **Claude Code:** Pulse reads the installed CLI's `/usage` panel from an isolated working directory and counts usage from local session logs. The probe disables hooks, tools, and MCP servers and sends no model prompt. It requires a signed-in CLI and currently expects its English usage panel.
- **Antigravity:** Pulse reads Gemini quota through the running Antigravity desktop app's loopback service and parses token metadata from local conversation databases. The app must be open for live quota. Its local protocol and database layout can change across versions.

Pulse contains its own Swift readers and does not bundle a third-party tracker. The supported provider apps or CLIs must already be installed and signed in for live quota reads. The quota checks use their existing sessions. Pulse does not copy login credentials into its settings or publish local usage.

The chart includes cached tokens when reported and reflects the local history available on that Mac. A dash means no usable quota reading and an asterisk marks a recent cached reading after a failed or delayed refresh. Quota percentages and token totals measure different things.

## License

Pulse is available under the [MIT License](LICENSE).
