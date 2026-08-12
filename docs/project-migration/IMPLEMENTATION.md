# Project Migration Implementation Plan

## Overview

Migrate the validated hardware/ML prototype into a traceable repository, verify the desktop pipeline without hardware, then build the SwiftUI/CoreBluetooth MVP around the established protocol.

## Phase Summary

1. Preserve and organize existing artifacts.
2. Document architecture, protocol, ML, experiments, and contributor constraints.
3. Add hardware-independent regression checks.
4. Add the SwiftUI application and typed BLE parser.
5. Verify software builds and record remaining hardware acceptance tests.

## Phase 1: Repository Migration

### Tasks

- [x] Audit all source artifacts.
- [x] Identify active versus historical files.
- [x] Copy firmware, inference, model, data, and results without deleting the source snapshot.
- [x] Update only paths made invalid by migration.

### Success Criteria

Canonical working artifacts are easy to locate and protected historical versions remain available.

## Phase 2: Documentation and Hygiene

### Tasks

- [ ] Add bilingual README and AGENTS guidance.
- [ ] Document system architecture, BLE protocol, ML pipeline, and experiments.
- [ ] Add requirements and ignore rules.

### Success Criteria

Current versus future functionality and evaluation limitations are unambiguous.

## Phase 3: Desktop Validation

### Tasks

- [ ] Compile/import Python files.
- [ ] Test feature helpers and all Stage-1 decision bands.
- [ ] Load the frozen model and reproduce stored evaluation expectations.

### Success Criteria

Tests run without hardware or an open serial port.

## Phase 4: iOS MVP

### Tasks

- [ ] Create SwiftUI project structure.
- [ ] Add typed models, BLE protocol/parser, CoreBluetooth manager, and mock transport.
- [ ] Implement Home, event flow, result, history, and device status.
- [ ] Add parser unit tests and Bluetooth permission text.

### Success Criteria

The app builds for an iPhone simulator, mock results can exercise every class, and parsing tests pass.

## Phase 5: Verification and Handoff

### Tasks

- [ ] Run Python and Swift tests/builds available in the environment.
- [ ] Document the physical end-to-end checklist and remaining limitations.

### Success Criteria

Automated checks pass and hardware-dependent checks are clearly separated.

