# Smart Medication Monitor / 智能用药监测器

An ESP32-S3, load-cell, machine-learning, and iPhone prototype that records evidence around medication-access events. The current system detects changes in medication weight and classifies interaction patterns; it does **not** medically confirm ingestion and is not a diagnostic device.

本项目是一个由 ESP32-S3、称重传感器、机器学习和 iPhone 应用组成的用药事件原型。当前系统通过重量变化与动态信号识别“药物取出”等事件证据，**不能**医学确认药物已被吞服，也不是医疗诊断设备。

## Current implementation / 当前实现

```text
iPhone app or nRF Connect
        ↓ BLE: OPEN
ESP32-S3 + HX711 + load cell + OV2640
        ↓ on-device hierarchical weight inference
        ↓ BLE notification: AI
iPhone app

OV2640 → ESP32 MJPEG → iPhone MediaPipe + Core ML action inference
        → local visual signal + event history
```

The load-cell pipeline remains intact and the frozen hierarchical weight model now
runs on the ESP32-S3. The iPhone runs the prototype camera action classifier
on-device. Legacy desktop weight and camera bridges remain available for diagnostics,
but the normal medication flow no longer requires a computer. Camera evaluation is
limited to one participant/session. The SwiftUI app is under `app/MedBoxApp`.

称重固件、BLE 链路、100 个真实实验事件和层级分类器均已有测试记录；重量模型现在运行于 ESP32，动作模型运行于 iPhone。SwiftUI 应用位于 `app/MedBoxApp`。

## Motivation / 项目动机

Medication adherence cannot be inferred reliably from a reminder acknowledgement alone. This prototype collects physical evidence that medication was accessed or removed, while deliberately avoiding the unsupported claim that removal proves ingestion.

仅点击服药提醒并不能可靠证明服药行为。本原型采集药物被访问或取出的物理证据，同时明确避免将“取出”表述为“已经吞服”。

## Hardware / 硬件

- ESP32-S3R8 development board, 16 MB flash, 8 MB OPI PSRAM
- HX711 with load cell: DT GPIO 9, SCK GPIO 10
- Active-low onboard LED: GPIO 1
- Matching-header OV2640 camera; GPIO 4 is camera D0
- Current mechanical calibration factor: `653.0`
- Experimental mock-pill mass: approximately `0.848 g`

Calibration belongs to the mechanical load-cell setup, not to a medication. Display precision does not imply weighing accuracy.

校准因子属于称重机械系统，并非某种药物的固定参数；显示小数位数不代表实际测量精度。

## BLE communication / BLE 通信

- Device: `MedBox-S3`
- Service: `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`
- RX, phone → ESP32: `6E400002-B5A3-F393-E0A9-E50E24DCCA9E`
- TX notifications, ESP32 → phone: `6E400003-B5A3-F393-E0A9-E50E24DCCA9E`

The product-demo path uses `MODE|LIVE`. LIVE mode never requires a label. See [BLE protocol](docs/BLE_PROTOCOL.md).

产品演示使用 `MODE|LIVE`，LIVE 模式绝不要求人工标签。详见 [BLE 协议](docs/BLE_PROTOCOL.md)。

## Machine-learning pipeline / 机器学习流程

The classifier is intentionally hierarchical:

1. Static weight ratio identifies `ONE` or `TWO` and preserves uncertainty gaps.
2. Near-zero final changes are routed to a Random Forest for `NONE`, `RETURN`, or `DISTURBANCE`.
3. Values outside configured bands return `UNCERTAIN`; the pipeline does not force a class.

分类器采用有意设计的层级结构：静态重量变化先判断一片/两片，净变化接近零时再由随机森林区分无取出、取出后放回和干扰；落在规则空隙中的事件返回不确定结果。

## Experimental evaluation / 实验评估

| Evaluation | Result | Interpretation |
| --- | ---: | --- |
| Train Round 1 → test Round 2, flat RF | 74% | Cross-session experimental holdout |
| Train Round 1 → test Round 2, hierarchical | 82% | Cross-session experimental holdout |
| Combined 100-event hierarchical 5-fold CV | 100% | Internal separability only |
| Synthetic 50-event frozen-pipeline test | 100% | Pipeline/stress-test verification only |

These small prototype experiments are not clinical validation or independent real-world generalisation evidence. See [experiments](docs/EXPERIMENTS.md).

这些小规模原型实验不是临床验证；组合交叉验证和合成数据测试也不是独立真实世界泛化证据。

## iOS application / iOS 应用

The SwiftUI MVP provides:

- Home and medication-event flow
- Multiple daily prescriptions with local 15-minute follow-up reminders
- CoreBluetooth discovery, connection, characteristic subscription, and commands
- Typed BLE message parsing
- Result presentation using cautious product language
- Typed camera-action messages and a separate visual-signal card
- On-device MediaPipe landmark extraction and Core ML action classification
- Local event history
- A stable local patient ID and on-device clinician-view prototype
- User-selectable English and Simplified Chinese UI
- A separate mock transport for development without hardware

## Current limitations / 当前限制

- ESP32 weight-model parity is verified offline; physical scale behavior still requires hardware acceptance testing.
- `OPEN` represents a simulated timed lid interaction; no physical actuator or Hall sensor is implemented.
- Weight evidence does not prove biological ingestion.
- Camera recognition currently reflects one participant/session and is not evidence of cross-user generalisation.
- Doctor lookup is currently local to one device. A secure authenticated backend is
  required before clinicians can retrieve consenting patients' records remotely.
- No cloud backend, authentication, or Android app exists yet.

## Future work / 后续计划

Future research should add cross-user camera data and formally evaluate the multimodal
decision gate. The current visual signal is prototype evidence, not ingestion proof.

未来研究需要增加跨用户摄像头数据并正式评估多模态决策门。目前视觉结果只是原型证据，不代表已经吞服。

## Repository structure / 仓库结构

```text
firmware/esp32/       active and preserved legacy firmware
inference/            model export, verification, desktop fallback, and collection tools
inference/camera/     camera training, live preview, and ESP32 UDP bridge
model/                canonical frozen runtime model and configuration
data/                 real Rounds 1–2 and synthetic Round 3 data
results/              preserved evaluation artifacts
experiments/          reproducible training/evaluation entry point
app/MedBoxApp/        SwiftUI/CoreBluetooth MVP and tests
docs/                 architecture, protocol, ML, and experiment documentation
tests/                hardware-independent Python regression tests
```

## Getting started / 快速开始

The normal LIVE flow does not require desktop inference. Python 3 remains useful for
model regeneration, offline verification, and the optional serial fallback:

```bash
python3 -m venv .venv
source .venv/bin/activate
python3 -m pip install -r inference/requirements.txt
python3 inference/realtime_inference_ble.py
```

Do not run the Arduino Serial Monitor, data logger, and real-time inference process against the same serial port simultaneously.

Firmware settings and upload instructions are in [system architecture](docs/SYSTEM_ARCHITECTURE.md). Run `pod install` in `app/MedBoxApp`, then open `app/MedBoxApp/MedBoxApp.xcworkspace` with Xcode to run the iPhone app with on-device camera recognition.
Camera training and live forwarding instructions are in [the camera README](inference/camera/README.md).

## Safety and project status / 安全与项目状态

This is an engineering/research prototype. User-facing results mean “medication removed,” “medication returned,” or “status uncertain”—never guaranteed ingestion or a medically verified dose.

这是工程/研究原型。界面结果表示“药物被取出”“药物被放回”或“状态不确定”，不代表保证已吞服或医学验证剂量。
