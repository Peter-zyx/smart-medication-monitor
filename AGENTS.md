# AGENTS.md

Read this file and the relevant document under `docs/` before changing a subsystem.

## Non-negotiable behavior

- Do not rewrite validated firmware sensing or rolling-baseline logic without a documented reason and regression evidence.
- Preserve the BLE device name and UUIDs unless an explicit versioned protocol migration is planned.
- LIVE mode must never require `LABEL`; TRAIN mode may wait for a label.
- Keep raw high-frequency `DATA` on USB Serial, not BLE.
- Preserve the deliberate Stage-1 uncertainty gaps; do not force every event into a class.
- Do not claim medication removal proves ingestion or that the project provides diagnosis.
- Do not describe combined internal cross-validation or synthetic testing as independent validation.
- Keep firmware, inference, app, model, and experiments modular.
- Add or update tests whenever parser, protocol, feature, or decision-gate behavior changes.
- Prefer small, logically separated commits.

## Current protocol assumptions

- BLE device: `MedBox-S3`
- Service: `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`
- RX: `6E400002-B5A3-F393-E0A9-E50E24DCCA9E`
- TX: `6E400003-B5A3-F393-E0A9-E50E24DCCA9E`
- Current application mode: `MODE|LIVE`
- Desktop result: `AI_RESULT|event_id|prediction|final_delta[|confidence]`
- Phone result: `AI|event_id|prediction|final_delta[|confidence]`
- Supported result labels: `ONE`, `TWO`, `NONE`, `RETURN`, `DISTURBANCE`, `UNCERTAIN`

## Project terminology

- Use **medication removed** for weight evidence.
- Use **ingestion-like action detected** only for a future vision signal.
- Use **medication taking likely confirmed by multiple signals** only after multimodal evidence exists.
- Never use **guaranteed ingestion**, **medically verified dose**, or **clinical diagnosis**.
- Treat synthetic Round 3 as a pipeline/stress-test dataset derived from real templates.

## Subsystem notes

- `firmware/esp32/MedBox_LiveTrain_AI/` is the active firmware.
- `firmware/esp32/legacy/` and `inference/legacy/` preserve the immediately preceding working versions; do not silently promote or delete them.
- `model/` is the canonical runtime model location.
- `results/round2/` preserves the original evaluation bundle, including byte-identical model/config copies for traceability.
- `runtime/` contains temporary serial sessions and is intentionally ignored.
- The present inference host is a Mac/PC. Do not move the model to iOS or ESP32 without a separate milestone.

## Verification expectations

- Python changes: compile files and run hardware-independent tests.
- Swift parser changes: run Swift unit tests.
- CoreBluetooth changes: build with Xcode and retain the manual device acceptance checklist.
- Firmware changes: record board configuration and physical test results; compilation alone does not verify scale behavior.

