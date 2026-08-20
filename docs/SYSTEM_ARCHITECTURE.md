# System Architecture

## Scope

The current prototype recognizes load-cell medication-access events and a separate
camera-derived action signal. Weight inference runs on the ESP32-S3; camera landmarks
and action classification run on the iPhone. Neither signal is treated as medical
proof of ingestion.

## Current end-to-end path

```text
iPhone ── BLE OPEN ──→ ESP32-S3
                         │
HX711 + load cell ───────┤ local Stage 1 + dynamic RF ── BLE AI ──┐
                         │                                         │
OV2640 ──────────────────┴─ Wi-Fi MJPEG ─→ iPhone MediaPipe/Core ML┤
                                                                   ▼
                                                     result + local history
```

The normal LIVE flow does not require a Mac/PC. The desktop serial inference runner
remains a regression/diagnostic fallback and must not emit a duplicate App result
after the ESP32 has classified the same event.

### ESP32 on-device weight milestone

At event start the firmware preserves the existing rolling-baseline freeze and also
clears a 64-sample inference buffer. The same samples printed as three-decimal USB
`DATA` lines are retained locally. After settling, the firmware applies the unchanged
Stage-1 ratio gates. Near-zero events recreate the original 24 dynamic features and
run the exported 500-tree Random Forest. BLE continues to emit the existing
`AI|event_id|prediction|final_delta[|confidence]` format, so the App parser and event
fusion path remain compatible. TRAIN mode is unchanged and still waits for labels.

See `docs/ON_DEVICE_WEIGHT_INFERENCE.md` for model hashes, parity scope, memory use,
and the physical acceptance checklist.

### iPhone on-device camera milestone

The app contains a camera-connection and on-device inference path. When enabled,
entering a medication flow requests temporary access to the open
`MedBox-Camera-Test` network with `NEHotspotConfiguration.joinOnce`, waits for the
first MJPEG frame from `http://192.168.4.1/stream`, and only then sends `OPEN` over
BLE. At `O|event_id`, the app samples 24 frames over approximately five seconds,
runs the same MediaPipe Pose and Hand landmark models used for training, recreates
the 2,576-feature temporal vector, and classifies it with a Core ML Extra Trees
ensemble. Frames are not saved. The app removes its temporary Wi-Fi configuration
after classification/weight-result completion or when the flow is dismissed.

This mode defaults to on for new installs. The ESP32 stream supports only one client,
so the legacy Mac camera-inference process and browser previews must be closed while
the iPhone is connected. The legacy UDP/BLE camera path remains a diagnostic fallback.

## iOS medication planning

The iOS app keeps prescriptions, the selected in-app language, a random patient ID,
and event history in local application storage. `UNUserNotificationCenter` schedules
one repeating daily notification plus a rolling two-hour chain of eight 15-minute
follow-ups per enabled prescription. A notification response enters the same BLE
`OPEN` flow as the Home screen; notification acknowledgement is not treated as
proof that medication was swallowed.

The Doctor tab currently uses an on-device `PatientDataProviding` implementation.
Its interface is deliberately replaceable by a future authenticated cloud provider,
but this repository does not yet implement cross-device clinician access. A patient
ID alone must never authorize remote access to medication history.

## Hardware configuration

| Component | Configuration |
| --- | --- |
| Board | ALIENTEK/OpenEdv ATK-DNESP32S3, ESP32-S3R8 |
| Flash / PSRAM | 16 MB / 8 MB OPI PSRAM |
| Arduino target | ESP32S3 Dev Module |
| LED | GPIO 1, active LOW |
| Button | Removed; the App `OPEN` command starts an event |
| HX711 DT / SCK | GPIO 9 / GPIO 10 |
| HX711 supply | 3.3 V and common GND |
| HX711 library | bogde/Bogdan Necula HX711 |
| Calibration | `653.0`, mechanical-system-specific |
| Camera | Matching-header OV2640, VGA MJPEG, board camera pins |
| Camera AP | `MedBox-Camera-Test`, `192.168.4.1` |
| Legacy vision return | UDP `4210`, `VISION|action|confidence` |

The camera AP is intentionally open in this local prototype so iOS can request
temporary `joinOnce` access without a credential embedded in the public source.
It must not be used as a production security design. A deployable device requires
per-device provisioning, authenticated transport, and an explicit pairing flow.

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
- ESP32 model parity is verified against recorded events, but physical load-cell
  acceptance is still required after flashing the new firmware.
- On-device camera inference requires the CocoaPods `MediaPipeTasksVision` dependency
  and must be built from `MedBoxApp.xcworkspace`.
- Camera evaluation currently covers one participant/session and does not establish
  cross-user or cross-environment generalisation.
- Clinician lookup is on-device only; secure cloud synchronization, authentication,
  explicit patient authorization, and audit logging are not implemented.

## Future architecture

A later milestone may add Hall-sensor lid state, an electronic lock, cross-user
camera evaluation, and a formally evaluated multimodal decision gate. The current
App only presents matching expected weight count and camera evidence with cautious wording.
