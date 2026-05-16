# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

CozyPet — a macOS-native desktop pet app: floating sprite + YAML-driven daily workflow + Claude chat + ElevenLabs/local TTS. Menu-bar app (`LSUIElement = YES`), no Dock icon. Personal-use; App Sandbox is intentionally disabled so `NSWorkspace.open(bundleID:)` can launch arbitrary apps.

Requires macOS 14+ and Xcode 16+ (Swift 6 toolchain).

## Build & run

The Xcode project is the source of truth — `Pet_app.xcodeproj` already embeds the local SPM package, Resources, entitlements, and Info.plist.

```sh
open Pet_app/Pet_app.xcodeproj
# Set Signing & Capabilities → Team to your Apple ID, then ⌘R
```

First open will resolve SwiftPM (Yams, SDWebImage / SDWebImageSwiftUI) — 1–2 minutes. If you get "No such module 'PetCore'", do **File → Packages → Reset Package Caches**.

### Running tests

```sh
cd Packages/PetCore && swift test            # all PetCore tests
swift test --filter WorkflowLoaderTests       # single test class
```

Or **⌘U** inside Xcode. Tests use `swift-testing` (not XCTest), so a full Xcode install is required — Command Line Tools alone won't work.

The Pet_app target itself has no automated UI/unit tests; logic is pushed down to `PetCore` and tested there.

## Architecture

Two-layer split is load-bearing — keep new logic in `PetCore` and only AppKit/SwiftUI glue in `Pet_app`.

### `Packages/PetCore/` — pure logic, no AppKit

Local SPM package. Imported by `Pet_app` via project-relative reference (not a remote dep). Five modules:

- **Workflow/** — YAML schema + loader for `workflow.yaml`. `WorkflowStep` carries optional `say` / `open_url` / `open_app` (bundle id) / `open_path`.
- **LLM/** — provider abstraction. `ClaudeProvider` (default, uses prompt caching for persona system prompt), `OpenAIProvider`, plus TTS providers: `ElevenLabsTTS`, `LocalBertVITS2TTS` (HTTP client for the Python sidecar), and `CachingTTSProvider` wrapper that hashes text+voice config to a file in `tts-cache/`.
- **Pet/** — `PetProfile` metadata (multi-pet support via `pets.yaml`).
- **Storage/** — `AppPaths`. Everything user-editable lives under `~/Library/Application Support/Pet/`: `workflow.yaml`, `pets.yaml`, `persona.yaml`, `notes.json`, `tts-cache/`, `tts-server/`.
- **Schedule/** — placeholder for v2 (EventKit / Reminders / Calendar).

### `Pet_app/Pet_app/` — UI + AppKit glue

- **AppDelegate** — owns singletons: `WorkflowStore`, `PetStore`, `VoicePlayer`, lazily-built `PetStateMachine` and `ChatModel`. Hosts the four utility windows (workflow / chat history / settings) via `NSHostingController` wrapped in plain `NSWindow`s — *do not* set `hosting.preferredContentSize` (clamps the window so it can't be resized).
- **PetWindow/** — the floating sprite. `PetWindowController` configures an `NSWindow` with `.borderless` + `.floating` and `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]` so it follows the user across Spaces and full-screen apps. Dragging is raw AppKit `performDrag(with:)` for zero-latency tracking. `PetStateMachine` is `@Observable` and drives both sprite expression and speech bubble; every `state.say(...)` goes through `VoicePlayer` which calls the TTS provider returned by `SettingsView.makeTTSProvider()`.
- **Chat/** — `ChatModel` is shared between the menu-bar "和小宠聊天" history window and the inline input bar under the sprite, so context is continuous regardless of entry point.
- **Workflow/** — `WorkflowPanel` (today's todos + love-notes side panel) and `WorkflowRunner` (chains TTS readout of step `say` lines, aborts mid-chain if a `state.say` is interrupted — detected via the `natural=false` completion callback).
- **Voice/** — `VoicePlayer` (NSSound playback) + `LocalTTSServer` (spawns/monitors the Python sidecar in `~/Library/Application Support/Pet/tts-server/` when backend is `bertVITS2Local`; killed in `applicationWillTerminate`).
- **Settings/** — single `SettingsView` with 4 tabs (Pet / Chat / Voice / General). API keys are in `UserDefaults` (v1 limitation; v2 will migrate to Keychain). Posts `.ttsBackendChanged` so AppDelegate can start/stop the local server.
- **System/** — `AppLauncher` (NSWorkspace launches), `LoginItem` (`SMAppService.mainApp`).

### `tts-server/` — optional Python sidecar

FastAPI wrapper around xzjosh's Bert-VITS2 v2.3 Taffy model. Install via `./setup.sh` (clones the ModelScope studio repo + LFS weights into `~/Library/Application Support/Pet/tts-server/`). The Swift app auto-spawns it on launch only when TTS backend = `bertVITS2Local`. Endpoints: `POST /tts` (returns mp3 bytes), `GET /health`. Default port 47322 (`PET_TTS_PORT`).

**v2.3 vs v1.x is intentional** — v1.x's `text/chinese.py` strips English with `re.sub('[a-zA-Z]+', '', seg)`, which is why mixed-language input drops English. v2.3's cleaner supports ZH/JP/EN.

## Conventions / gotchas

- **PetCore must not import AppKit/SwiftUI.** It's consumed by the SwiftUI app but stays pure so it remains testable with `swift test`.
- **User files override bundle resources.** On launch, loaders prefer `~/Library/Application Support/Pet/{workflow,persona,pets}.yaml` and fall back to `Pet_app/Resources/` bundle copies. When changing schema, update both.
- **GIF cache invalidation:** SDWebImage keys by URL string. Since pet GIFs live in `Bundle.main` and `cp` doesn't change the path, `AppDelegate.invalidatePetGifCache()` purges the cache every launch so new art shows up after a rebuild.
- **Speech bubble interruption is a feature, not a bug.** `state.say(..., completion:)` passes `natural: Bool` — `false` means another `say` preempted it. The workflow readout and any chained TTS uses this to abort cleanly instead of trampling.
- **Window sizing:** every utility window is built by `AppDelegate.makeUtilityWindow` which deliberately omits `preferredContentSize`. Don't add it back.
- **`persona.yaml` is hot-reloaded** by `ClaudeProvider` — no app restart needed when editing the system prompt.
- The `Pet_app/Pet_app/` group is a **synced folder reference** in Xcode. Drop a `.swift` file into the Finder folder and it's picked up automatically; no need to Add Files.

## Other docs

- `README.md` — user-facing pitch + setup
- `SETUP.md` — detailed first-run / signing / debugging walkthrough, plus end-to-end verification checklist and v2 roadmap
- `tts-server/README.md` — local TTS install + API
