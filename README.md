# MemPalace TypeWhisper Plugin

A [TypeWhisper](https://github.com/TypeWhisper/typewhisper-mac) `MemoryStoragePlugin` that stores and searches transcription-derived memories in [MemPalace Cloud](https://mempalace.cloud) or a self-hosted MemPalace instance.

## Status

**Pre-release (v0.2.0)** — builds + passes unit tests against a mocked MemPalace MCP API. Has not yet been validated against the live `api.mempalace.cloud` endpoint or shipped as a `.bundle` for TypeWhisper users.

## How it works

TypeWhisper's memory-extraction pipeline produces `MemoryEntry` records after eligible transcriptions. This plugin:

1. Files each memory's `content` into a user-configured wing/room via the MemPalace `mempalace_add_drawer` MCP tool.
2. Keeps a **local sidecar** (`pluginDataDirectory/sidecar.json`) that maps each `MemoryEntry.id` (UUID) to the returned `drawer_id`, and retains TypeWhisper-specific fields (`confidence`, `accessCount`, `lastAccessedAt`, `metadata`, `source`, `type`, `createdAt`) that MemPalace cannot round-trip.
3. Uses `source_file = "tw_<uuid>"` so search results can be mapped back to the originating MemoryEntry — `tw_<uuid>` has no slashes and survives MemPalace's `Path.name` basename strip.

Co-tenancy: MemPalace deduplicates drawers by content-hash. When two memories with identical content collapse to the same `drawer_id`, deleting one keeps the drawer until the last co-tenant is removed.

## Build

Requires Xcode 15+ / Swift 6.0 / macOS 14+.

```bash
git submodule update --init --recursive
swift build
swift test
```

The submodule at `vendor/typewhisper-mac` provides the `TypeWhisperPluginSDK` Swift Package.

## Build the installable bundle

```bash
git submodule update --init --recursive   # one-time
scripts/build-bundle.sh                   # arm64 + x86_64 universal
# or: scripts/build-bundle.sh --arch arm64 # arm64 only (faster on M-series)
```

Output:

- `build/MemPalacePlugin.bundle` — the macOS plugin bundle
- `build/MemPalacePlugin.zip` — zipped bundle for distribution

## Install in TypeWhisper

1. TypeWhisper menubar → **Settings → Integrations**
2. **+ Install from File** (top-right) → select `build/MemPalacePlugin.zip`
3. **Memory → MemPalace** appears → enable, then click the gear icon to configure API key + wing/room.

## Distribution (planned)

- **v1:** GitHub Releases attaches `MemPalacePlugin.zip`. Users download + Install from File.
- **v2:** Submit to TypeWhisper's community plugin registry (`PluginRegistry/community-v1/com.mempalace.memory.json`) once the upstream community-build pipeline is finalized.

## Configuration

Open Settings → Integrations → MemPalace and provide:

- **Deployment:** Cloud or Self-Hosted.
- **Base URL:** defaults to `https://api.mempalace.cloud` for Cloud; user-supplied for Self-Hosted.
- **API Key:** stored in the macOS Keychain via TypeWhisper's `HostServices.storeSecret`.
- **Wing / Room:** target filing location. The Settings UI fetches available wings/rooms from the MemPalace `mempalace_list_wings` and `mempalace_list_rooms` tools and exposes them as pickers.

## Known limitations (v0.2)

- No cross-device sync of TypeWhisper-specific fields (`confidence`, `accessCount`, `lastAccessedAt`). The sidecar is local to each Mac.
- No offline write queue: failed `store()` calls throw and propagate to the host. TypeWhisper logs the error; the memory is **not** retried automatically.
- No lazy-reconcile pass: if a drawer is deleted directly in MemPalace's UI, the sidecar will retain a stale `drawer_id` mapping until the user clears or rebuilds.

These will likely land in v0.3 / v1.0.

## License

MIT. See [LICENSE](LICENSE).
