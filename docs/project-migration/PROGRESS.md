# Project Migration Progress

## Status: Implementation Complete; Hardware Acceptance Pending

## Phase Progress

### Phase 1: Repository Migration

**Status:** Completed

- Audited 47 source files and classified active, historical, reproducibility, and runtime artifacts.
- Preserved the desktop source snapshot unchanged.
- Established canonical subsystem directories.
- Kept byte-identical model copies in the preserved result bundle while making `model/` canonical at runtime.

### Phase 2: Documentation and Hygiene

**Status:** Completed

- Added bilingual portfolio README, contributor constraints, architecture, BLE, ML, and experiment documents.
- Added Git hygiene and pinned the model's scikit-learn version.

### Phase 3: Desktop Validation

**Status:** Completed

- Python sources compile.
- Eight hardware-independent tests pass.
- The frozen model reproduces all 100 stored real-event predictions.

### Phase 4: iOS MVP

**Status:** Completed

- Added SwiftUI Home, flow, result, history, and device status views.
- Added production CoreBluetooth and separate configurable mock transports.
- Added typed parsing and both Swift Package and Xcode parser tests.

### Phase 5: Verification and Handoff

**Status:** Completed with environment limitation

- Swift syntax parsing, Xcode project plist parsing, and Info.plist validation pass.
- Full `xcodebuild` and Swift tests require a matching full Xcode installation. The installed Command Line Tools compiler and SDK builds do not match.
- Physical BLE/ESP32/Mac acceptance remains a documented manual check.

## Architectural Decisions

- The latest AI-forwarding firmware is canonical; the previous firmware is historical, not deleted.
- Runtime serial sessions are excluded from Git, while their role as end-to-end evidence is documented.
- The desktop remains the current inference host. No model deployment migration is included.
- Camera recognition, cloud services, authentication, and Android are outside this milestone.

## Session Log

### 2026-08-12

- Cloned the empty public repository and created `codex/feature/project-migration`.
- Audited the supplied local project snapshot.
- Copied validated artifacts and repaired new relative paths.
- Confirmed byte-identical model/config copies and excluded runtime/cache output.
- Implemented and checked the iOS MVP.
