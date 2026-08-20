# MedBoxApp

Run `pod install`, then open `MedBoxApp.xcworkspace` with Xcode 16 or newer. The
deployment target is iOS 17. The project file can compile without the pod for UI
work, but real on-device action recognition is enabled only in the workspace build.

## Run modes

- Normal launch uses the production `BLEManager` and never fakes a physical connection.
- Add the launch argument `--mock-ble` to use the separate `MockMedicationDevice`.
- In mock mode, choose the next `ONE`, `TWO`, `NONE`, `RETURN`, `DISTURBANCE`, or `UNCERTAIN` result on the Device tab.

The Bluetooth usage description is in `MedBoxApp/Info.plist`. No location permission is requested.

## On-device iPhone camera recognition

- The Device tab contains **Recognize actions on this iPhone**. It defaults to on
  for new installs and can be disabled manually.
- When enabled, the app requests temporary access to `MedBox-Camera-Test`, opens
  `http://192.168.4.1/stream`, waits for a valid JPEG frame, and then continues the
  BLE `OPEN` flow.
- The prototype camera AP is open and contains no repository credential. Production
  hardware must replace it with per-device provisioning and authenticated pairing.
- The Hotspot Configuration entitlement, local-network privacy description, and
  local-network ATS declaration are included in the Xcode project.
- The ESP32 stream currently allows one viewer. Close the Mac camera script and all
  browser previews before testing the iPhone preview.
- At the start of an ESP event, the app extracts MediaPipe Pose and Hand landmarks
  from 24 frames, builds the same 2,576-feature window used during training, and
  runs the bundled Core ML classifier. It does not save frames.
- `TAKE` means a visible ingestion-like action only; it never proves swallowing.

## Prescriptions and reminders

- The Home tab supports multiple locally persisted prescriptions with a medication
  name, dose, unit, and daily reminder time.
- With notification permission, each prescription receives a daily local
  notification. The app also queues eight follow-ups at 15-minute intervals,
  covering the next two hours when there is no response.
- Tapping the notification action or **Respond and open MedBox** counts as a user
  response, cancels the current follow-up chain, and starts the existing BLE flow.
- iOS limits an app to roughly 64 pending local notifications, so this prototype
  uses a rolling follow-up window and refreshes it whenever the app opens or the
  prescription/language configuration changes. It reserves the daily reminder
  for every enabled prescription first, then shares the remaining follow-up slots
  across prescriptions so later entries are not starved by earlier ones.

## Language and clinician prototype

- The Device tab lets the user switch the complete product UI and newly scheduled
  notifications between English and Simplified Chinese.
- Each local installation generates a persistent `MBX-XXXX-XXXX` patient ID.
- The Doctor tab can look up that ID and show local prescriptions and medication
  history grouped by date.
- This build intentionally does **not** expose health data to another device by ID.
  Real clinician access requires authenticated cloud storage, patient consent,
  role-based authorization, audit logging, and a configured backend.

## Acceptance test with hardware

1. Run the combined active firmware on the ESP32-S3.
2. Do not start the desktop inference or legacy Mac camera scripts.
3. Close every browser camera viewer.
4. Launch the app on an iPhone with Bluetooth enabled.
5. Confirm `MedBox-S3` becomes Connected and the app receives `S|...|LIVE`.
6. Wait approximately three seconds for the rolling baseline.
7. Tap **Take Medication** and verify `OPEN` reaches the ESP32.
8. Confirm USB reports `EVENT_END` and `ON_DEVICE_AI`, followed by BLE `AI`, while
   the iPhone produces its local camera action result.
9. Confirm the camera card appears. A matching expected weight count and camera `TAKE` may
   display “Medication taking likely confirmed by multiple signals.”

## Acceptance test for the iPhone camera migration

1. Run `pod install`, open `MedBoxApp.xcworkspace`, select the MedBoxApp target,
   and confirm **Hotspot Configuration** is
   present under Signing & Capabilities for the selected development team.
2. Upload the combined firmware and close the Mac camera process plus every browser
   or phone camera page.
3. Run the app on a physical iPhone; this cannot be validated in Simulator.
4. Open Device, enable **Recognize actions on this iPhone**, and tap
   **Test camera preview**.
5. Approve the Wi-Fi and Local Network prompts. Confirm the status becomes
   **Camera connected**.
6. Disconnect the test preview, return Home, and start a prescription event.
7. Confirm the app connects to the camera and displays a frame before BLE `OPEN`.
8. Confirm recognition advances through 24 frames and displays an action/confidence.
9. When the event result arrives, confirm the preview disconnects and iOS returns
   to an available previously known Wi-Fi network.

## Acceptance test for reminders and clinician UI

1. Add a prescription scheduled a few minutes in the future and allow notifications.
2. Confirm the first notification uses the selected language.
3. Leave it unanswered and confirm the next notification appears 15 minutes later.
4. Tap **Open MedBox** and confirm the BLE interaction flow opens and the remaining
   follow-ups for that prescription are replaced by the next daily schedule.
5. Copy the patient ID from the Doctor tab, enter it in the lookup field, and verify
   prescriptions and date-grouped local history appear.
6. Enter a different ID and verify no patient data is returned.
