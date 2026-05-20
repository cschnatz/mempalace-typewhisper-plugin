# MemPalace TypeWhisper Plugin

A [TypeWhisper](https://github.com/TypeWhisper/typewhisper-mac) `MemoryStoragePlugin` that stores and searches transcription-derived memories in [MemPalace Cloud](https://mempalace.cloud) or a self-hosted MemPalace instance.

## Status

**v0.3.0** — live-tested against `api.mempalace.cloud`. Apple Silicon only (arm64). 11 unit tests passing.

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

## v0.3 features

- **Offline queue:** Failed `store()` calls are written to `pluginDataDirectory/queue.json` and replayed by a background drain loop with exponential backoff. Memories never silently lost on network blip.
- **Lazy reconcile:** Every Nth `listAll()` call samples 8 random sidecar entries and drops mappings whose drawer was deleted directly in MemPalace's UI.
- **Synchronous activate/deactivate flushes:** UI badge primed from disk before activate returns; deactivate blocks (≤2s) so a host quit doesn't lose the last mutations.

## Known limitations (v0.3)

- No cross-device sync of TypeWhisper-specific fields (`confidence`, `accessCount`, `lastAccessedAt`). The sidecar is local to each Mac.
- `accessCount` increments on every search hit, not just on actual memory consumption by TypeWhisper.

## License

MIT. See [LICENSE](LICENSE).
