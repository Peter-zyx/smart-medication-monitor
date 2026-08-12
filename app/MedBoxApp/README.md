# MedBoxApp

Open `MedBoxApp.xcodeproj` with Xcode 16 or newer. The deployment target is iOS 17.

## Run modes

- Normal launch uses the production `BLEManager` and never fakes a physical connection.
- Add the launch argument `--mock-ble` to use the separate `MockMedicationDevice`.
- In mock mode, choose the next `ONE`, `TWO`, `NONE`, `RETURN`, `DISTURBANCE`, or `UNCERTAIN` result on the Device tab.

The Bluetooth usage description is in `MedBoxApp/Info.plist`. No location permission is requested.

## Acceptance test with hardware

1. Run the active firmware on the ESP32-S3 and start `inference/realtime_inference_ble.py` on the Mac.
2. Launch the app on an iPhone with Bluetooth enabled.
3. Confirm `MedBox-S3` becomes Connected and the app receives `S|...|LIVE`.
4. Wait approximately three seconds for the rolling baseline.
5. Tap **Take Medication** and verify `OPEN` reaches the ESP32.
6. Confirm the event produces USB `EVENT_END`, Python inference, USB `AI_RESULT`, and BLE `AI`.
7. Confirm the matching result appears and a history record is saved.

