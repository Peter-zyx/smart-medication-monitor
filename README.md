# Smart Medication Monitor / 智能用药监测器

An ESP32-S3, load-cell, machine-learning, and iPhone prototype that records evidence around medication-access events. The current system detects changes in medication weight and classifies interaction patterns; it does **not** medically confirm ingestion and is not a diagnostic device.

本项目是一个由 ESP32-S3、称重传感器、机器学习和 iPhone 应用组成的用药事件原型。当前系统通过重量变化与动态信号识别“药物取出”等事件证据，**不能**医学确认药物已被吞服，也不是医疗诊断设备。

## Current implementation / 当前实现

```text
iPhone app or nRF Connect
        ↓ BLE: OPEN
ESP32-S3 + HX711 + load cell
        ↓ USB Serial: EVENT_START / DATA / EVENT_END
Mac/PC Python hierarchical inference
        ↓ USB Serial: AI_RESULT
ESP32-S3
        ↓ BLE notification: AI
iPhone app
```

The load-cell firmware, BLE link, 100-event real experimental dataset, hierarchical classifier, and desktop real-time return path have been tested. The initial SwiftUI app is under `app/MedBoxApp`.

称重固件、BLE 链路、100 个真实实验事件、层级分类器以及桌面实时结果回传链路均已有测试记录。初始 SwiftUI 应用位于 `app/MedBoxApp`。

## Motivation / 项目动机

Medication adherence cannot be inferred reliably from a reminder acknowledgement alone. This prototype collects physical evidence that medication was accessed or removed, while deliberately avoiding the unsupported claim that removal proves ingestion.

仅点击服药提醒并不能可靠证明服药行为。本原型采集药物被访问或取出的物理证据，同时明确避免将“取出”表述为“已经吞服”。

## Hardware / 硬件

- ESP32-S3R8 development board, 16 MB flash, 8 MB OPI PSRAM
- HX711 with load cell: DT GPIO 5, SCK GPIO 6
- Active-low onboard LED: GPIO 1
- Button: GPIO 4 to GND with `INPUT_PULLUP`
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
- CoreBluetooth discovery, connection, characteristic subscription, and commands
- Typed BLE message parsing
- Result presentation using cautious product language
- Local event history
- A separate mock transport for development without hardware

## Current limitations / 当前限制

- Inference currently runs on a Mac/PC, not on the iPhone or ESP32.
- `OPEN` represents a simulated timed lid interaction; no physical actuator or Hall sensor is implemented.
- Weight evidence does not prove biological ingestion.
- No camera recognition, multimodal fusion, cloud backend, authentication, or Android app exists yet.

## Future work / 后续计划

Planned research may add camera-based ingestion-like action evidence and multimodal fusion. It is not part of the current implementation. Deployment to ESP32, iPhone, or a backend remains an open engineering decision.

未来研究可能加入摄像头“类似吞服动作”证据与多模态融合，但当前尚未实现。模型最终部署到 ESP32、iPhone 或服务端仍是开放决策。

## Repository structure / 仓库结构

```text
firmware/esp32/       active and preserved legacy firmware
inference/            desktop real-time inference and collection tools
model/                canonical frozen runtime model and configuration
data/                 real Rounds 1–2 and synthetic Round 3 data
results/              preserved evaluation artifacts
experiments/          reproducible training/evaluation entry point
app/MedBoxApp/        SwiftUI/CoreBluetooth MVP and tests
docs/                 architecture, protocol, ML, and experiment documentation
tests/                hardware-independent Python regression tests
```

## Getting started / 快速开始

Desktop inference requires Python 3:

```bash
python3 -m venv .venv
source .venv/bin/activate
python3 -m pip install -r inference/requirements.txt
python3 inference/realtime_inference_ble.py
```

Do not run the Arduino Serial Monitor, data logger, and real-time inference process against the same serial port simultaneously.

Firmware settings and upload instructions are in [system architecture](docs/SYSTEM_ARCHITECTURE.md). Open `app/MedBoxApp/MedBoxApp.xcodeproj` with Xcode to run the iPhone app.

## Safety and project status / 安全与项目状态

This is an engineering/research prototype. User-facing results mean “medication removed,” “medication returned,” or “status uncertain”—never guaranteed ingestion or a medically verified dose.

这是工程/研究原型。界面结果表示“药物被取出”“药物被放回”或“状态不确定”，不代表保证已吞服或医学验证剂量。

