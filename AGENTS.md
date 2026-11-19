# Caffeine Plus - AGENTS.md

## Project Overview
macOS menu bar app that prevents your Mac from sleeping (fork of Caffeine, MIT) and keeps it awake during schedule windows registered by Claude through a local MCP server.

## Tech Stack
- **Language**: Swift
- **UI Framework**: SwiftUI + AppKit (`NSStatusItem`, `NSHostingController`)
- **IDE**: Xcode
- **Platforms**: macOS
- **Localization**: 13 languages (`src/Caffeine/Resources/*.lproj`): de, en, es, fr, it, ja, ko, nl, pt, pt-BR, ru, uk, zh-Hans

## Dependencies
- **DZFoundation** (Swift package)

Sparkle was removed in Caffeine Plus (no auto-update).

## Guides
The original local guides (`~/Agents/...`) are not available; follow the existing code style (`.swiftformat`), Swift/SwiftUI best practices and accessibility (labels, hints, keyboard).

Changes are specified with OpenSpec (`openspec/`).

## Build Commands
```bash
# Build
xcodebuild -project src/Caffeine.xcodeproj -scheme "Caffeine" -destination "platform=macOS" build

# Clean
xcodebuild -project src/Caffeine.xcodeproj -scheme "Caffeine" clean
```

## Testing (MANDATORY)
Pure logic lives in `src/Caffeine/Classes/Core` and is tested with `swift test` (root `Package.swift`). The Xcode app has no test target.
