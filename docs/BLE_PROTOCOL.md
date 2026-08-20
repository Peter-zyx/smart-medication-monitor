# BLE Protocol

## Transport

The firmware exposes a Nordic-UART-like BLE service:

| Role | UUID |
| --- | --- |
| Service | `6E400001-B5A3-F393-E0A9-E50E24DCCA9E` |
| RX, phone → ESP32 | `6E400002-B5A3-F393-E0A9-E50E24DCCA9E` |
| TX notifications, ESP32 → phone | `6E400003-B5A3-F393-E0A9-E50E24DCCA9E` |

Device name: `MedBox-S3`. Commands and notifications are UTF-8, pipe-delimited messages. The iOS app writes commands to RX and subscribes to TX.

## Phone commands

| Command | Purpose |
| --- | --- |
| `OPEN` | Start an event when zeroed, closed, and baseline-ready |
| `STATUS` | Request medication/device mode status |
| `WEIGHT` | Request current weight |
| `ZERO` | Tare and persist scale offset |
| `MODE|LIVE` | Product demonstration mode; no label |
| `MODE|TRAIN` | Labelled experimental collection mode |
| `LEARN|name|count|dose` | Derive unit mass from a known count |
| `LABEL|NONE|ONE|TWO|RETURN|DISTURBANCE` | TRAIN-only label command |

The last row denotes one selected label, for example `LABEL|RETURN`.

## BLE notifications

| Message | Meaning |
| --- | --- |
| `O|event_id` | Timed lid/event interaction opened |
| `C|event_id` | Timed lid/event interaction closed |
| `E|event_id|removed_weight` | Compact physical event summary |
| `READY|event_id` | LIVE event complete; baseline rebuilding begins |
| `AI|event_id|prediction|final_delta` | ESP32 hierarchical result without RF confidence |
| `AI|event_id|prediction|final_delta|confidence` | ESP32 dynamic-RF result with confidence |
| `V|event_id|action|confidence` | Legacy camera action forwarded by the ESP32 from the Mac vision process |
| `W|weight` | Current weight response |
| `S|medName|pillWeight|dose|mode` | Current medication configuration and mode |
| `MODE|LIVE` / `MODE|TRAIN` | Mode acknowledgement |
| `BUSY|ZERO` / `OK|ZERO` | Zero progress/result |
| `BUSY|LEARN` / `OK|LEARN|name|pillWeight|dose` | Learn progress/result |
| `ERR|code` | Rejected command or device error |

TRAIN additionally emits compact result/label messages such as `R|...` and `L|...`; these are not required by the MVP LIVE flow.

## USB serial event stream

High-frequency samples intentionally remain on USB:

```text
TRIGGER|BLE|1
EVENT_START|1|8.432
BASELINE_STD|1|0.012|27
DATA|1|100|8.431
LID_CLOSED|1
EVENT_END|1|8.432|7.590|0.842
LIVE_READY|1
```

`EVENT_END` fields are event ID, before weight, after weight, and removed weight.

## On-device result and desktop fallback

LIVE events are classified directly by the ESP32 after `EVENT_END`. The device
preserves the existing `AI|...` BLE wire format, so the iOS parser does not need a
protocol migration. USB also reports a diagnostic line:

```text
ON_DEVICE_AI|event_id|prediction|final_delta|confidence_or_NA|samples=n
```

The legacy Python runner may still send over USB for diagnostics or an older firmware:

```text
AI_RESULT|event_id|prediction|final_delta
AI_RESULT|event_id|prediction|final_delta|rf_confidence
```

The ESP32 validates the event ID/class and forwards compact `AI|...` over BLE only
when that event has not already produced a local result. A duplicate desktop result
is logged as `AI_RESULT_IGNORED|event_id|LOCAL_ALREADY_SENT`.

## Result labels

- `ONE`: one medication unit appears removed.
- `TWO`: possible multiple-dose removal; verify the dose.
- `NONE`: no medication removed.
- `RETURN`: medication appears removed and placed back.
- `DISTURBANCE`: interaction detected, state not confirmed.
- `UNCERTAIN`: system cannot confidently determine medication state.

These labels describe device evidence and do not prove ingestion.

## Camera vision bridge

The Mac reads the ESP32 MJPEG stream and sends stable camera results back to the
ESP32 over UDP port `4210`:

```text
VISION|TAKE|0.824
```

The ESP32 validates the action/confidence, associates it with an event started in
the preceding 15 seconds (or event `0` when no recent event exists), and emits:

```text
V|event_id|TAKE|0.824
```

Supported camera actions are `TAKE`, `DRINK`, `TOUCH_FACE`, `ADJUST`, `PICK_ONLY`,
`NONE`, and `UNCERTAIN`. `TAKE` means **ingestion-like action detected** and does
not prove that medication was swallowed. Only a matching weight result plus a
`TAKE` camera signal may be described as medication taking likely confirmed by
multiple signals.

## Parser requirements

Unknown well-formed messages should be retained as typed `unknown` values for diagnostics. Malformed numeric fields should produce parser errors rather than silently updating UI state. BLE delegate callbacks publish parsed application events; views do not split protocol strings.
