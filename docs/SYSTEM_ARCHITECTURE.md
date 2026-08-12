# System Architecture

## Scope

The current prototype recognizes load-cell medication-access events. Camera-based ingestion-like action recognition and multimodal evidence fusion are future work.

## Current end-to-end path

```text
iPhone / nRF Connect
        │ BLE OPEN
        ▼
ESP32-S3 firmware ───── HX711 + load cell
        │ USB Serial EVENT_START / DATA / EVENT_END
        ▼
Mac/PC Python hierarchical inference
        │ USB Serial AI_RESULT
        ▼
ESP32-S3 firmware
        │ BLE AI notification
        ▼
iPhone result and local history
```

The technical UI and documentation must disclose that the Mac/PC is currently required for inference.

## Hardware configuration

| Component | Configuration |
| --- | --- |
| Board | ALIENTEK/OpenEdv ATK-DNESP32S3, ESP32-S3R8 |
| Flash / PSRAM | 16 MB / 8 MB OPI PSRAM |
| Arduino target | ESP32S3 Dev Module |
| LED | GPIO 1, active LOW |
| Button | GPIO 4 → GND, `INPUT_PULLUP`, pressed LOW |
| HX711 DT / SCK | GPIO 5 / GPIO 6 |
| HX711 supply | 3.3 V and common GND |
| HX711 library | bogde/Bogdan Necula HX711 |
| Calibration | `653.0`, mechanical-system-specific |

Known Arduino settings: 16 MB flash, OPI PSRAM, USB CDC on boot enabled, Hardware CDC and JTAG, UART0/Hardware CDC upload, 460800 baud upload.

## Persistent device configuration

Preferences namespace `medmon` stores `medName`, `pillWeight`, `dose`, `scaleOffset`, `scaleZeroed`, and `mode`. The saved scale offset is restored at boot so medication already on the platform is not automatically tared away.

## Firmware states

### LIVE

```text
rolling baseline → OPEN → EVENT_START → DATA → LID_CLOSED
→ settling → EVENT_END → LIVE_READY → rebuild baseline
```

No human label is requested. After ZERO, LEARN, or an event, the baseline buffer is cleared and normally needs about three seconds to rebuild.

### TRAIN

```text
OPEN → EVENT_START → DATA → EVENT_END → PREDICTION
→ WAITING_FOR_LABEL → LABEL
```

TRAIN exists for labelled experimental collection and must not leak its label requirement into LIVE.

## Baseline and timing

- Sampling: approximately 10 Hz
- Rolling buffer: 30 samples, approximately 3 seconds
- Exclude newest: 3 samples, approximately 300 ms
- Minimum usable samples: 10
- Simulated OPEN period: 5 seconds
- Settling after close: 1.5 seconds

At event start, the firmware excludes the newest baseline samples and freezes the remaining mean as `eventBeforeG`. It also records baseline standard deviation.

## Current limitations

- `OPEN` controls a timed simulated state; there is no actuator or Hall sensor.
- A display precision of three decimals does not establish scale accuracy.
- Weight change supports medication-removal evidence, not biological-ingestion proof.
- Model deployment remains on the desktop.

## Future architecture

A later milestone may add Hall-sensor lid state, an electronic lock, camera-derived ingestion-like evidence, and explicit multimodal fusion. None is implemented in this milestone.

