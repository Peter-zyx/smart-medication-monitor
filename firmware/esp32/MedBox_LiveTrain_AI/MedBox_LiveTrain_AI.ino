/*
  MedBox ESP32-S3 Firmware
  =======================

  LIVE mode (default)
  -------------------
  - BLE OPEN / physical button starts an event.
  - ESP32 records the load-cell trajectory.
  - ESP32 emits EVENT_START / DATA / EVENT_END over USB Serial.
  - NO manual LABEL is required.
  - realtime_inference.py performs the hierarchical classification.

  TRAIN mode
  ----------
  - Same sensing pipeline.
  - After EVENT_END the firmware emits the old deterministic pill-count
    baseline prediction and waits for LABEL|...
  - This preserves compatibility with medbox_logger.py.

  Hardware
  --------
  ESP32-S3
  On-board LED: GPIO 1, active LOW
  Button:       GPIO 4 -> GND, INPUT_PULLUP
  HX711 DT:     GPIO 5
  HX711 SCK:    GPIO 6

  BLE UART-like service
  ---------------------
  Device: MedBox-S3

  Service:
    6E400001-B5A3-F393-E0A9-E50E24DCCA9E

  RX (phone -> ESP32):
    6E400002-B5A3-F393-E0A9-E50E24DCCA9E

  TX (ESP32 -> phone):
    6E400003-B5A3-F393-E0A9-E50E24DCCA9E

  Commands
  --------
  OPEN
  MODE|LIVE
  MODE|TRAIN
  STATUS
  WEIGHT
  ZERO
  LEARN|DrugName|count|dose
  LABEL|NONE
  LABEL|ONE
  LABEL|TWO
  LABEL|RETURN
  LABEL|DISTURBANCE

  USB command from realtime_inference.py
  --------------------------------------
  AI_RESULT|event_id|prediction|final_delta
  AI_RESULT|event_id|prediction|final_delta|rf_confidence

  ESP32 forwards this result to the phone over BLE as:
  AI|event_id|prediction|final_delta
  AI|event_id|prediction|final_delta|rf_confidence

  Notes
  -----
  - In LIVE mode LABEL is ignored with ERR|LIVE_NO_LABEL.
  - DATA lines are USB Serial only; they are not sent over BLE.
  - The scale calibration factor belongs to the load-cell mechanics,
    not to a particular medication.
*/

#include <Arduino.h>
#include <HX711.h>
#include <Preferences.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

// ============================================================
// HARDWARE
// ============================================================

static const int LED_PIN = 1;
static const int BUTTON_PIN = 4;
static const int HX711_DT_PIN = 5;
static const int HX711_SCK_PIN = 6;

// Active-low onboard LED
static const int LED_ON = LOW;
static const int LED_OFF = HIGH;

// Current load-cell calibration factor.
// Keep this equal to the factor that produced your existing ~8 g readings.
static const float SCALE_CALIBRATION = 653.0f;

// ============================================================
// TIMING
// ============================================================

static const uint32_t CLOSED_SAMPLE_INTERVAL_MS = 100;  // ~10 Hz
static const uint32_t OPEN_SAMPLE_INTERVAL_MS = 100;    // ~10 Hz
static const uint32_t OPEN_DURATION_MS = 5000;
static const uint32_t SETTLE_DURATION_MS = 1500;

static const uint32_t BUTTON_DEBOUNCE_MS = 50;

// BLE notification pacing
static const uint32_t BLE_NOTIFY_INTERVAL_MS = 80;

// ============================================================
// ROLLING BASELINE
// ============================================================

static const int BASELINE_BUFFER_SIZE = 30;        // ~3 s at 10 Hz
static const int BASELINE_EXCLUDE_LATEST = 3;      // ignore last ~300 ms
static const int BASELINE_MIN_USABLE = 10;

// ============================================================
// BLE
// ============================================================

static const char* BLE_DEVICE_NAME = "MedBox-S3";

static const char* SERVICE_UUID =
  "6E400001-B5A3-F393-E0A9-E50E24DCCA9E";

static const char* RX_UUID =
  "6E400002-B5A3-F393-E0A9-E50E24DCCA9E";

static const char* TX_UUID =
  "6E400003-B5A3-F393-E0A9-E50E24DCCA9E";

BLEServer* bleServer = nullptr;
BLECharacteristic* rxCharacteristic = nullptr;
BLECharacteristic* txCharacteristic = nullptr;

volatile bool bleConnected = false;

// Small BLE TX queue.
// DATA samples intentionally stay on USB Serial only.
static const int BLE_QUEUE_SIZE = 20;
String bleQueue[BLE_QUEUE_SIZE];
int bleQueueHead = 0;
int bleQueueTail = 0;
int bleQueueCount = 0;
uint32_t lastBleNotifyMs = 0;

// ============================================================
// SCALE / NVS
// ============================================================

HX711 scale;
Preferences prefs;

String medName = "TestDrug";
float pillWeight = 0.848f;
int expectedDose = 1;

long savedScaleOffset = 0;
bool scaleZeroed = false;

// ============================================================
// MODE / EVENT STATE
// ============================================================

enum RunMode {
  MODE_LIVE,
  MODE_TRAIN
};

RunMode runMode = MODE_LIVE;

enum EventState {
  STATE_CLOSED,
  STATE_OPEN,
  STATE_SETTLING,
  STATE_WAIT_LABEL
};

EventState eventState = STATE_CLOSED;

uint32_t eventId = 0;
uint32_t eventStartMs = 0;
uint32_t settleStartMs = 0;
uint32_t lastClosedSampleMs = 0;
uint32_t lastOpenSampleMs = 0;

float eventBeforeG = NAN;
float eventAfterG = NAN;
float eventRemovedG = NAN;

String lastTriggerSource = "";

// ============================================================
// BASELINE BUFFER
// ============================================================

float baselineBuffer[BASELINE_BUFFER_SIZE];
int baselineWriteIndex = 0;
int baselineCount = 0;

// ============================================================
// BUTTON
// ============================================================

bool lastButtonReading = HIGH;
bool stableButtonState = HIGH;
uint32_t lastButtonChangeMs = 0;

// ============================================================
// USB SERIAL INPUT FROM PYTHON
// ============================================================

String usbCommandBuffer = "";

// ============================================================
// FORWARD DECLARATIONS
// ============================================================

void handleCommand(const String& command);
void openLid(const String& source);
void finishEvent();
void clearBaselineBuffer();
void sampleClosedBaseline();
bool freezeBaseline(float& meanOut, float& stdOut, int& nOut);
float readWeight(int samples = 5);
void queueBle(const String& msg);
void processBleQueue();
void processUsbCommands();
void handleAiResultCommand(const String& command);
void setRunMode(RunMode mode, bool saveToNvs = true);
String runModeName();

// ============================================================
// BLE CALLBACKS
// ============================================================

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* pServer) override {
    bleConnected = true;
    Serial.println("BLE_CONNECTED");
  }

  void onDisconnect(BLEServer* pServer) override {
    bleConnected = false;
    Serial.println("BLE_DISCONNECTED");

    delay(50);
    BLEDevice::startAdvertising();
  }
};

class RxCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* characteristic) override {
    String value = characteristic->getValue().c_str();
    value.trim();

    if (value.length() == 0) {
      return;
    }

    Serial.print("BLE_RX: ");
    Serial.println(value);

    handleCommand(value);
  }
};

// ============================================================
// BLE HELPERS
// ============================================================

void queueBle(const String& msg) {
  if (bleQueueCount >= BLE_QUEUE_SIZE) {
    // Drop oldest message rather than blocking sensing.
    bleQueueHead = (bleQueueHead + 1) % BLE_QUEUE_SIZE;
    bleQueueCount--;
  }

  bleQueue[bleQueueTail] = msg;
  bleQueueTail = (bleQueueTail + 1) % BLE_QUEUE_SIZE;
  bleQueueCount++;
}

void processBleQueue() {
  if (!bleConnected) {
    return;
  }

  if (bleQueueCount <= 0) {
    return;
  }

  uint32_t now = millis();

  if (now - lastBleNotifyMs < BLE_NOTIFY_INTERVAL_MS) {
    return;
  }

  String msg = bleQueue[bleQueueHead];
  bleQueueHead = (bleQueueHead + 1) % BLE_QUEUE_SIZE;
  bleQueueCount--;

  txCharacteristic->setValue(msg.c_str());
  txCharacteristic->notify();

  Serial.print("BLE_TX: ");
  Serial.println(msg);

  lastBleNotifyMs = now;
}

// ============================================================
// SCALE
// ============================================================

float readWeight(int samples) {
  if (!scale.is_ready()) {
    return NAN;
  }

  return scale.get_units(samples);
}

void clearBaselineBuffer() {
  baselineWriteIndex = 0;
  baselineCount = 0;

  for (int i = 0; i < BASELINE_BUFFER_SIZE; i++) {
    baselineBuffer[i] = NAN;
  }
}

void pushBaseline(float value) {
  if (isnan(value)) {
    return;
  }

  baselineBuffer[baselineWriteIndex] = value;
  baselineWriteIndex =
    (baselineWriteIndex + 1) % BASELINE_BUFFER_SIZE;

  if (baselineCount < BASELINE_BUFFER_SIZE) {
    baselineCount++;
  }
}

void sampleClosedBaseline() {
  uint32_t now = millis();

  if (now - lastClosedSampleMs < CLOSED_SAMPLE_INTERVAL_MS) {
    return;
  }

  lastClosedSampleMs = now;

  float w = readWeight(1);

  if (!isnan(w)) {
    pushBaseline(w);
  }
}

bool freezeBaseline(
  float& meanOut,
  float& stdOut,
  int& nOut
) {
  int usable = baselineCount - BASELINE_EXCLUDE_LATEST;

  if (usable < BASELINE_MIN_USABLE) {
    return false;
  }

  float sum = 0.0f;
  float sumSq = 0.0f;
  int n = 0;

  // Oldest element in the circular buffer
  int oldestIndex =
    (baselineWriteIndex - baselineCount + BASELINE_BUFFER_SIZE)
    % BASELINE_BUFFER_SIZE;

  for (int i = 0; i < usable; i++) {
    int idx = (oldestIndex + i) % BASELINE_BUFFER_SIZE;
    float v = baselineBuffer[idx];

    if (isnan(v)) {
      continue;
    }

    sum += v;
    sumSq += v * v;
    n++;
  }

  if (n < BASELINE_MIN_USABLE) {
    return false;
  }

  float mean = sum / n;
  float variance = (sumSq / n) - (mean * mean);

  if (variance < 0.0f) {
    variance = 0.0f;
  }

  meanOut = mean;
  stdOut = sqrtf(variance);
  nOut = n;

  return true;
}

// ============================================================
// MODE
// ============================================================

String runModeName() {
  return runMode == MODE_LIVE ? "LIVE" : "TRAIN";
}

void setRunMode(RunMode mode, bool saveToNvs) {
  runMode = mode;

  // Switching mode cancels label-wait state so the unit does not stay locked.
  if (eventState == STATE_WAIT_LABEL) {
    eventState = STATE_CLOSED;
    clearBaselineBuffer();
  }

  if (saveToNvs) {
    prefs.putString("mode", runModeName());
  }

  String line = "MODE|" + runModeName();

  Serial.println(line);
  queueBle(line);
}

// ============================================================
// EVENT
// ============================================================

void openLid(const String& source) {
  if (eventState == STATE_WAIT_LABEL) {
    queueBle("ERR|LABEL_FIRST");
    Serial.println("ERR|LABEL_FIRST");
    return;
  }

  if (eventState != STATE_CLOSED) {
    queueBle("ERR|LID_BUSY");
    Serial.println("ERR|LID_BUSY");
    return;
  }

  if (!scaleZeroed) {
    queueBle("ERR|ZERO_FIRST");
    Serial.println("ERR|ZERO_FIRST");
    return;
  }

  float baselineMean = NAN;
  float baselineStd = NAN;
  int baselineN = 0;

  if (!freezeBaseline(
        baselineMean,
        baselineStd,
        baselineN
      )) {
    queueBle("ERR|BASELINE_WAIT");
    Serial.println("ERR|BASELINE_WAIT");
    return;
  }

  eventId++;
  eventBeforeG = baselineMean;
  eventAfterG = NAN;
  eventRemovedG = NAN;

  lastTriggerSource = source;

  Serial.print("TRIGGER|");
  Serial.print(source);
  Serial.print("|");
  Serial.println(eventId);

  Serial.print("EVENT_START|");
  Serial.print(eventId);
  Serial.print("|");
  Serial.println(eventBeforeG, 3);

  Serial.print("BASELINE_STD|");
  Serial.print(eventId);
  Serial.print("|");
  Serial.print(baselineStd, 3);
  Serial.print("|");
  Serial.println(baselineN);

  queueBle("O|" + String(eventId));

  digitalWrite(LED_PIN, LED_ON);

  eventState = STATE_OPEN;
  eventStartMs = millis();
  lastOpenSampleMs = 0;
}

void finishEvent() {
  float after = readWeight(20);

  if (isnan(after)) {
    Serial.println("ERR|WEIGHT");
    queueBle("ERR|WEIGHT");

    eventState = STATE_CLOSED;
    clearBaselineBuffer();
    return;
  }

  eventAfterG = after;
  eventRemovedG = eventBeforeG - eventAfterG;

  Serial.print("EVENT_END|");
  Serial.print(eventId);
  Serial.print("|");
  Serial.print(eventBeforeG, 3);
  Serial.print("|");
  Serial.print(eventAfterG, 3);
  Serial.print("|");
  Serial.println(eventRemovedG, 3);

  // A short BLE event summary only.
  // The hierarchical AI result comes from realtime_inference.py.
  queueBle(
    "E|" +
    String(eventId) +
    "|" +
    String(eventRemovedG, 3)
  );

  // Clear the rolling baseline so the next event must rebuild a
  // fresh stable baseline around the new physical state.
  clearBaselineBuffer();

  if (runMode == MODE_LIVE) {
    // IMPORTANT:
    // no LABEL needed in live mode.
    eventState = STATE_CLOSED;

    Serial.print("LIVE_READY|");
    Serial.println(eventId);

    queueBle(
      "READY|" +
      String(eventId)
    );

    return;
  }

  // ==========================================================
  // TRAIN MODE ONLY
  // Preserve the old deterministic count / label workflow.
  // ==========================================================

  int predictedCount = 0;

  if (pillWeight > 0.0f) {
    predictedCount = (int)roundf(
      eventRemovedG / pillWeight
    );

    if (predictedCount < 0) {
      predictedCount = 0;
    }
  }

  String predictionStatus;

  if (predictedCount == expectedDose) {
    predictionStatus = "OK";
  } else if (predictedCount < expectedDose) {
    predictionStatus = "UNDER";
  } else {
    predictionStatus = "OVER";
  }

  Serial.print("PREDICTION|");
  Serial.print(eventId);
  Serial.print("|");
  Serial.print(eventRemovedG, 3);
  Serial.print("|");
  Serial.print(predictedCount);
  Serial.print("|");
  Serial.print(expectedDose);
  Serial.print("|");
  Serial.println(predictionStatus);

  queueBle(
    "R|" +
    String(eventId) +
    "|" +
    String(eventRemovedG, 3) +
    "|" +
    String(predictedCount) +
    "|" +
    String(expectedDose) +
    "|" +
    predictionStatus
  );

  Serial.print("WAITING_FOR_LABEL|");
  Serial.println(eventId);

  eventState = STATE_WAIT_LABEL;
}

// ============================================================
// COMMANDS
// ============================================================

bool isValidLabel(const String& label) {
  return (
    label == "NONE" ||
    label == "ONE" ||
    label == "TWO" ||
    label == "RETURN" ||
    label == "DISTURBANCE"
  );
}

void handleLabelCommand(const String& rawLabel) {
  if (runMode == MODE_LIVE) {
    Serial.println("ERR|LIVE_NO_LABEL");
    queueBle("ERR|LIVE_NO_LABEL");
    return;
  }

  if (eventState != STATE_WAIT_LABEL) {
    Serial.println("ERR|NO_EVENT");
    queueBle("ERR|NO_EVENT");
    return;
  }

  String label = rawLabel;
  label.trim();
  label.toUpperCase();

  if (!isValidLabel(label)) {
    Serial.println("ERR|BAD_LABEL");
    queueBle("ERR|BAD_LABEL");
    return;
  }

  Serial.print("LABEL|");
  Serial.print(eventId);
  Serial.print("|");
  Serial.println(label);

  queueBle(
    "L|" +
    String(eventId) +
    "|" +
    label
  );

  // Now allow the next training event.
  eventState = STATE_CLOSED;
  clearBaselineBuffer();
}

void handleLearnCommand(const String& command) {
  // Format:
  // LEARN|DrugName|count|dose

  int p1 = command.indexOf('|');
  int p2 = command.indexOf('|', p1 + 1);
  int p3 = command.indexOf('|', p2 + 1);

  if (p1 < 0 || p2 < 0 || p3 < 0) {
    Serial.println("ERR|LEARN_FORMAT");
    queueBle("ERR|LEARN_FORMAT");
    return;
  }

  String newName = command.substring(p1 + 1, p2);
  int count = command.substring(p2 + 1, p3).toInt();
  int dose = command.substring(p3 + 1).toInt();

  newName.trim();

  if (
    newName.length() == 0 ||
    count <= 0 ||
    dose <= 0
  ) {
    Serial.println("ERR|LEARN_FORMAT");
    queueBle("ERR|LEARN_FORMAT");
    return;
  }

  if (!scaleZeroed) {
    Serial.println("ERR|ZERO_FIRST");
    queueBle("ERR|ZERO_FIRST");
    return;
  }

  if (eventState != STATE_CLOSED) {
    Serial.println("ERR|LID_BUSY");
    queueBle("ERR|LID_BUSY");
    return;
  }

  Serial.println("BUSY|LEARN");
  queueBle("BUSY|LEARN");

  float totalWeight = readWeight(30);

  if (isnan(totalWeight)) {
    Serial.println("ERR|WEIGHT");
    queueBle("ERR|WEIGHT");
    return;
  }

  float learnedPillWeight = totalWeight / (float)count;

  if (
    learnedPillWeight <= 0.0f ||
    learnedPillWeight > 100.0f
  ) {
    Serial.println("ERR|LEARN_WEIGHT");
    queueBle("ERR|LEARN_WEIGHT");
    return;
  }

  medName = newName;
  pillWeight = learnedPillWeight;
  expectedDose = dose;

  prefs.putString("medName", medName);
  prefs.putFloat("pillWeight", pillWeight);
  prefs.putInt("dose", expectedDose);

  clearBaselineBuffer();

  Serial.print("OK|LEARN|");
  Serial.print(medName);
  Serial.print("|");
  Serial.print(pillWeight, 3);
  Serial.print("|");
  Serial.println(expectedDose);

  queueBle(
    "OK|LEARN|" +
    medName +
    "|" +
    String(pillWeight, 3) +
    "|" +
    String(expectedDose)
  );
}


void handleAiResultCommand(const String& command) {
  // Accepted formats:
  // AI_RESULT|event_id|prediction|final_delta
  // AI_RESULT|event_id|prediction|final_delta|rf_confidence

  int p1 = command.indexOf('|');
  int p2 = command.indexOf('|', p1 + 1);
  int p3 = command.indexOf('|', p2 + 1);
  int p4 = command.indexOf('|', p3 + 1);

  if (p1 < 0 || p2 < 0 || p3 < 0) {
    Serial.println("ERR|AI_RESULT_FORMAT");
    return;
  }

  String idText = command.substring(p1 + 1, p2);
  String prediction = command.substring(p2 + 1, p3);
  String deltaText;

  if (p4 >= 0) {
    deltaText = command.substring(p3 + 1, p4);
  } else {
    deltaText = command.substring(p3 + 1);
  }

  idText.trim();
  prediction.trim();
  prediction.toUpperCase();
  deltaText.trim();

  long aiEventId = idText.toInt();

  if (aiEventId <= 0) {
    Serial.println("ERR|AI_RESULT_ID");
    return;
  }

  bool validPrediction =
    prediction == "ONE" ||
    prediction == "TWO" ||
    prediction == "NONE" ||
    prediction == "RETURN" ||
    prediction == "DISTURBANCE" ||
    prediction == "UNCERTAIN";

  if (!validPrediction) {
    Serial.println("ERR|AI_RESULT_CLASS");
    return;
  }

  String bleMessage =
    "AI|" +
    String(aiEventId) +
    "|" +
    prediction +
    "|" +
    deltaText;

  if (p4 >= 0) {
    String confidenceText = command.substring(p4 + 1);
    confidenceText.trim();

    if (confidenceText.length() > 0) {
      bleMessage += "|" + confidenceText;
    }
  }

  // Forward only a compact result to the phone.
  queueBle(bleMessage);

  // USB acknowledgement for the Python program/log.
  Serial.print("AI_FORWARD|");
  Serial.print(aiEventId);
  Serial.print("|");
  Serial.println(prediction);
}

void handleCommand(const String& rawCommand) {
  String command = rawCommand;
  command.trim();

  String upper = command;
  upper.toUpperCase();

  if (upper.startsWith("AI_RESULT|")) {
    handleAiResultCommand(command);
    return;
  }

  if (upper == "OPEN") {
    openLid("BLE");
    return;
  }

  if (upper == "MODE|LIVE") {
    setRunMode(MODE_LIVE);
    return;
  }

  if (upper == "MODE|TRAIN") {
    setRunMode(MODE_TRAIN);
    return;
  }

  if (upper == "STATUS") {
    String status =
      "S|" +
      medName +
      "|" +
      String(pillWeight, 3) +
      "|" +
      String(expectedDose) +
      "|" +
      runModeName();

    Serial.println(status);
    queueBle(status);
    return;
  }

  if (upper == "WEIGHT") {
    float w = readWeight(10);

    if (isnan(w)) {
      Serial.println("ERR|WEIGHT");
      queueBle("ERR|WEIGHT");
      return;
    }

    String msg =
      "W|" +
      String(w, 3);

    Serial.println(msg);
    queueBle(msg);
    return;
  }

  if (upper == "ZERO") {
    if (eventState != STATE_CLOSED) {
      Serial.println("ERR|LID_BUSY");
      queueBle("ERR|LID_BUSY");
      return;
    }

    Serial.println("BUSY|ZERO");
    queueBle("BUSY|ZERO");

    scale.tare(50);

    savedScaleOffset = scale.get_offset();
    scaleZeroed = true;

    prefs.putLong("scaleOffset", savedScaleOffset);
    prefs.putBool("scaleZeroed", true);

    clearBaselineBuffer();

    Serial.println("OK|ZERO");
    queueBle("OK|ZERO");
    return;
  }

  if (upper.startsWith("LEARN|")) {
    handleLearnCommand(command);
    return;
  }

  if (upper.startsWith("LABEL|")) {
    String label = command.substring(
      command.indexOf('|') + 1
    );

    handleLabelCommand(label);
    return;
  }

  Serial.println("ERR|UNKNOWN");
  queueBle("ERR|UNKNOWN");
}

// ============================================================
// BUTTON
// ============================================================

void processButton() {
  bool reading = digitalRead(BUTTON_PIN);
  uint32_t now = millis();

  if (reading != lastButtonReading) {
    lastButtonChangeMs = now;
    lastButtonReading = reading;
  }

  if (
    now - lastButtonChangeMs >=
    BUTTON_DEBOUNCE_MS
  ) {
    if (reading != stableButtonState) {
      stableButtonState = reading;

      if (stableButtonState == LOW) {
        openLid("BUTTON");
      }
    }
  }
}

// ============================================================
// EVENT STATE MACHINE
// ============================================================

void processEventState() {
  uint32_t now = millis();

  if (eventState == STATE_CLOSED) {
    sampleClosedBaseline();
    return;
  }

  if (eventState == STATE_OPEN) {
    if (
      lastOpenSampleMs == 0 ||
      now - lastOpenSampleMs >=
      OPEN_SAMPLE_INTERVAL_MS
    ) {
      lastOpenSampleMs = now;

      float w = readWeight(1);

      if (!isnan(w)) {
        uint32_t relativeMs =
          now - eventStartMs;

        Serial.print("DATA|");
        Serial.print(eventId);
        Serial.print("|");
        Serial.print(relativeMs);
        Serial.print("|");
        Serial.println(w, 3);
      }
    }

    if (
      now - eventStartMs >=
      OPEN_DURATION_MS
    ) {
      digitalWrite(
        LED_PIN,
        LED_OFF
      );

      Serial.print("LID_CLOSED|");
      Serial.println(eventId);

      queueBle(
        "C|" +
        String(eventId)
      );

      eventState = STATE_SETTLING;
      settleStartMs = now;
    }

    return;
  }

  if (eventState == STATE_SETTLING) {
    if (
      now - settleStartMs >=
      SETTLE_DURATION_MS
    ) {
      finishEvent();
    }

    return;
  }

  // STATE_WAIT_LABEL:
  // nothing happens until LABEL|... arrives in TRAIN mode.
}


// ============================================================
// USB SERIAL COMMANDS FROM PYTHON
// ============================================================

void processUsbCommands() {
  while (Serial.available() > 0) {
    char c = (char)Serial.read();

    if (c == '\r') {
      continue;
    }

    if (c == '\n') {
      usbCommandBuffer.trim();

      if (usbCommandBuffer.length() > 0) {
        Serial.print("USB_RX: ");
        Serial.println(usbCommandBuffer);

        handleCommand(usbCommandBuffer);
      }

      usbCommandBuffer = "";
      continue;
    }

    // Defensive limit in case malformed input arrives.
    if (usbCommandBuffer.length() < 180) {
      usbCommandBuffer += c;
    } else {
      usbCommandBuffer = "";
      Serial.println("ERR|USB_COMMAND_TOO_LONG");
    }
  }
}

// ============================================================
// SETUP
// ============================================================

void setup() {
  pinMode(
    LED_PIN,
    OUTPUT
  );

  digitalWrite(
    LED_PIN,
    LED_OFF
  );

  pinMode(
    BUTTON_PIN,
    INPUT_PULLUP
  );

  Serial.begin(115200);

  delay(1000);

  Serial.println();
  Serial.println(
    "========================================"
  );
  Serial.println(
    "MEDBOX ESP32-S3"
  );
  Serial.println(
    "========================================"
  );

  // ----------------------------------------------------------
  // Preferences
  // ----------------------------------------------------------

  prefs.begin(
    "medmon",
    false
  );

  medName = prefs.getString(
    "medName",
    "TestDrug"
  );

  pillWeight = prefs.getFloat(
    "pillWeight",
    0.848f
  );

  expectedDose = prefs.getInt(
    "dose",
    1
  );

  savedScaleOffset = prefs.getLong(
    "scaleOffset",
    0
  );

  scaleZeroed = prefs.getBool(
    "scaleZeroed",
    false
  );

  // Default to LIVE for this version.
  // If a previous mode exists in NVS we restore it, otherwise LIVE.
  String storedMode = prefs.getString(
    "mode",
    "LIVE"
  );

  storedMode.toUpperCase();

  if (storedMode == "TRAIN") {
    runMode = MODE_TRAIN;
  } else {
    runMode = MODE_LIVE;
  }

  // ----------------------------------------------------------
  // HX711
  // ----------------------------------------------------------

  scale.begin(
    HX711_DT_PIN,
    HX711_SCK_PIN
  );

  scale.set_scale(
    SCALE_CALIBRATION
  );

  if (scaleZeroed) {
    scale.set_offset(
      savedScaleOffset
    );

    Serial.print(
      "RESTORED_OFFSET|"
    );
    Serial.println(
      savedScaleOffset
    );
  } else {
    Serial.println(
      "NO_SAVED_ZERO"
    );
  }

  clearBaselineBuffer();

  // ----------------------------------------------------------
  // BLE
  // ----------------------------------------------------------

  BLEDevice::init(
    BLE_DEVICE_NAME
  );

  bleServer =
    BLEDevice::createServer();

  bleServer->setCallbacks(
    new ServerCallbacks()
  );

  BLEService* service =
    bleServer->createService(
      SERVICE_UUID
    );

  txCharacteristic =
    service->createCharacteristic(
      TX_UUID,
      BLECharacteristic::PROPERTY_NOTIFY
    );

  txCharacteristic->addDescriptor(
    new BLE2902()
  );

  rxCharacteristic =
    service->createCharacteristic(
      RX_UUID,
      BLECharacteristic::PROPERTY_WRITE |
      BLECharacteristic::PROPERTY_WRITE_NR
    );

  rxCharacteristic->setCallbacks(
    new RxCallbacks()
  );

  service->start();

  BLEAdvertising* advertising =
    BLEDevice::getAdvertising();

  advertising->addServiceUUID(
    SERVICE_UUID
  );

  advertising->setScanResponse(
    true
  );

  BLEDevice::startAdvertising();

  // ----------------------------------------------------------
  // Startup status
  // ----------------------------------------------------------

  Serial.print(
    "MODE|"
  );
  Serial.println(
    runModeName()
  );

  Serial.print(
    "STATUS|"
  );
  Serial.print(
    medName
  );
  Serial.print(
    "|pillWeight="
  );
  Serial.print(
    pillWeight,
    3
  );
  Serial.print(
    "|dose="
  );
  Serial.print(
    expectedDose
  );
  Serial.print(
    "|zeroed="
  );
  Serial.println(
    scaleZeroed ? "YES" : "NO"
  );

  Serial.println(
    "BLE_READY|MedBox-S3"
  );

  Serial.println(
    "========================================"
  );
}

// ============================================================
// LOOP
// ============================================================

void loop() {
  processUsbCommands();
  processButton();
  processEventState();
  processBleQueue();

  delay(1);
}
