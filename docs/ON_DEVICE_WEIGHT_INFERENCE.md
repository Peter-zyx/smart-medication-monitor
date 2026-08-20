# On-device ESP32 weight inference milestone

## Objective

Remove the normal Mac/PC dependency without changing the validated HX711 sampling,
rolling baseline, LIVE/TRAIN state behavior, BLE device identity, or uncertainty
gaps. Weight results remain evidence of medication removal or interaction and do not
prove ingestion.

## Deployment design

- LIVE keeps emitting high-frequency `DATA` on USB for diagnostics.
- Up to 64 of the same 10 Hz event samples are also retained in a small ESP32 buffer.
- Values used by local inference are rounded to the same three decimals previously
  consumed from the serial stream.
- Stage 1 uses the saved/learned device `pillWeight` and the original ratio windows.
- Near-zero events use the exported 500-tree forest for `NONE`, `RETURN`, or
  `DISTURBANCE` and include RF confidence.
- `E`, `READY`, and `AI` retain their existing BLE formats and ordering.
- A legacy desktop `AI_RESULT` for an event already classified locally is ignored,
  preventing duplicate App records.
- TRAIN remains label-driven and does not invoke the on-device classifier.

## Regression evidence

`tests/test_esp32_weight_model.py` compiles the same C++ runtime header used by the
Arduino sketch and compares it with the frozen Python model across:

| Dataset | Events | Role |
| --- | ---: | --- |
| Round 1 | 50 | Real prototype regression |
| Round 2 | 50 | Real cross-session regression |
| Synthetic Round 3 | 50 | Template-derived pipeline stress test |

All 150 labels match. The generated model also reports zero label mismatches for
all 90 dynamic-RF-routed cases. These checks establish software parity only; they do
not replace physical load-cell acceptance or establish clinical validity.

## Target build

- Board: ESP32S3 Dev Module
- Core: ESP32 Arduino `3.3.10-cn`
- Flash: 16 MB
- PSRAM: OPI
- Partition: 3 MB app / 9.9 MB FATFS
- USB: Hardware CDC and JTAG, CDC on boot

The milestone build uses 1,373,435 bytes of program flash (43% of the 3 MB app
partition) and 63,056 bytes of global dynamic memory (19%).

## Physical acceptance still required

1. Upload the active sketch and confirm `WEIGHT_AI_READY|trees=500|nodes=3174`.
2. Confirm saved zero and learned pill weight are restored.
3. Run one known example of each physical class where practical.
4. Verify each LIVE event emits `EVENT_END`, `LIVE_READY`, and exactly one
   `ON_DEVICE_AI`; the App receives exactly one matching BLE `AI`.
5. Confirm LIVE never asks for `LABEL`, while TRAIN still does.
6. Confirm the baseline rebuilds after each event and no camera/BLE behavior regresses.
