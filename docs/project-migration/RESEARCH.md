# Project Migration Research

## Overview

This audit covers the source snapshot supplied from `medbox-project` on 2026-08-12. The source directory is treated as read-only. Migration copies working artifacts into this repository without changing firmware sensing behavior, trained-model contents, raw datasets, or recorded evaluation outputs.

## Current Repository Audit

### Working chain

The newest demonstrated chain consists of:

- `MedBox_LiveTrain_AI.ino`: ESP32-S3 firmware with LIVE/TRAIN modes and USB `AI_RESULT` forwarding to BLE `AI` notifications.
- `realtime_inference_ble.py`: desktop serial inference plus result return to the ESP32.
- `hierarchical_dynamic_rf.joblib` and `hierarchical_model_config.json`: frozen dynamic classifier and deterministic Stage-1 configuration.
- `session_20260812_104322`: runtime evidence containing `S|TestDrug|0.839|1|LIVE`, `EVENT_END`, `LIVE_READY`, and `USB_RX: AI_RESULT|1|ONE|0.533`.

### Distinct historical and experimental files

- `MedBox_LiveTrain.ino` is the immediately preceding collection/LIVE firmware without USB-to-BLE AI forwarding. It is preserved under `firmware/esp32/legacy/`.
- `realtime_inference.py` is the preceding real-time inference version without result return. It is preserved under `inference/legacy/`.
- `medbox_logger.py` is the labelled serial data-collection utility.
- `hierarchical_model.py` is the reproducible training and evaluation script.

These files overlap but are not identical duplicates.

### Data and results

- Round 1: 50 real events, 10 per class.
- Round 2: 50 real events, 10 per class, with greater behavioral variation.
- Synthetic Round 3: 50 template-derived perturbed events, 10 per class.
- Round 1 to Round 2 holdout: flat RF 74%; hierarchical pipeline 82%.
- Combined 100-event five-fold CV: 100% internal separability, not independent validation.
- Synthetic stress test: 50/50, pipeline verification only.

### Duplicates

The model and configuration originally lived inside the Round 2 result directory. Their copies under `model/` are byte-identical and are now the canonical runtime artifacts. The copies under `results/round2/` remain part of the preserved evaluation bundle.

### Missing before migration

- Markdown project and protocol documentation
- Codex maintenance rules
- Git ignore policy
- Tests for the hierarchical gate and protocol parsing
- Modular iOS/CoreBluetooth application

## Recommended Approach

Use an incremental, behavior-preserving migration. Change only filesystem paths required by the new layout. Establish regression tests around the frozen model before extracting shared feature code. Keep runtime serial output outside version control.

## Risks and Mitigations

- **Feature drift:** compare active feature extraction with the preserved legacy implementation and test the frozen model.
- **Protocol drift:** document exact UUIDs/messages and test typed iOS parsing.
- **Misleading claims:** consistently distinguish medication removal evidence from ingestion and internal/synthetic evaluation from independent validation.
- **Hardware-only behavior:** keep firmware verification and end-to-end BLE acceptance as explicit manual tests.

## Open Questions

None block migration. Apple signing identity and a physical ESP32/Mac setup are required only for device acceptance testing.

