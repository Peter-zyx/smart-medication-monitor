#!/usr/bin/env python3

import csv
import time
from datetime import datetime
from pathlib import Path

import serial
from serial.tools import list_ports


# ============================================================
# CONFIG
# ============================================================

PORT = None
# Example manual Mac port:
# PORT = "/dev/cu.usbmodem11201"

BAUD_RATE = 115200
SERIAL_TIMEOUT = 1.0

PROJECT_DIR = Path(__file__).resolve().parents[1]
OUTPUT_ROOT = PROJECT_DIR / "runtime" / "medbox_data"


# ============================================================
# SERIAL PORT
# ============================================================

def find_serial_port():
    """
    Auto-detect an ESP32 / usbmodem serial port on macOS.
    If PORT is set manually above, that value is used instead.
    """
    if PORT:
        return PORT

    ports = list(list_ports.comports())

    preferred_keywords = (
        "usbmodem",
        "esp32",
        "jtag",
        "serial",
    )

    # First pass: likely ESP32/macOS ports.
    for port in ports:
        text = " ".join(
            [
                str(port.device or ""),
                str(port.description or ""),
                str(port.manufacturer or ""),
            ]
        ).lower()

        if any(keyword in text for keyword in preferred_keywords):
            return port.device

    # Second pass: any /dev/cu.* device.
    for port in ports:
        if str(port.device).startswith("/dev/cu."):
            return port.device

    available = "\n".join(
        f"  {p.device}  {p.description}"
        for p in ports
    )

    raise RuntimeError(
        "Could not auto-detect a serial port.\n"
        "Available ports:\n"
        f"{available if available else '  (none)'}\n\n"
        "Set PORT manually near the top of medbox_logger.py."
    )


# ============================================================
# SESSION FILES
# ============================================================

def create_session():
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")

    session_dir = (
        OUTPUT_ROOT /
        f"session_{timestamp}"
    )

    session_dir.mkdir(
        parents=True,
        exist_ok=False,
    )

    raw_path = session_dir / "raw_serial.txt"
    samples_path = session_dir / "samples.csv"
    events_path = session_dir / "events.csv"

    return (
        timestamp,
        session_dir,
        raw_path,
        samples_path,
        events_path,
    )


# ============================================================
# MAIN LOGGER
# ============================================================

def main():
    (
        session_id,
        session_dir,
        raw_path,
        samples_path,
        events_path,
    ) = create_session()

    port = find_serial_port()

    print("=" * 68)
    print("MEDBOX SERIAL LOGGER")
    print("=" * 68)
    print(f"Port:       {port}")
    print(f"Baud:       {BAUD_RATE}")
    print(f"Session:    {session_id}")
    print(f"Output:     {session_dir.resolve()}")
    print()
    print("Close Arduino Serial Monitor before running this logger.")
    print("Press Ctrl+C to stop.")
    print("=" * 68)
    print()

    ser = serial.Serial(
        port=port,
        baudrate=BAUD_RATE,
        timeout=SERIAL_TIMEOUT,
    )

    # Give the serial connection a moment to settle.
    time.sleep(1.0)

    # Event data is buffered until LABEL arrives.
    events = {}

    # Current event ID is only a convenience.
    current_event_id = None

    with (
        open(raw_path, "a", encoding="utf-8", buffering=1) as raw_file,
        open(samples_path, "w", newline="", encoding="utf-8") as samples_file,
        open(events_path, "w", newline="", encoding="utf-8") as events_file,
    ):
        samples_writer = csv.DictWriter(
            samples_file,
            fieldnames=[
                "event_id",
                "time_ms",
                "weight_g",
                "label",
            ],
        )

        events_writer = csv.DictWriter(
            events_file,
            fieldnames=[
                "event_id",
                "before_g",
                "after_g",
                "removed_g",
                "predicted_count",
                "expected_count",
                "prediction",
                "label",
                "n_samples",
            ],
        )

        samples_writer.writeheader()
        events_writer.writeheader()

        try:
            while True:
                raw_bytes = ser.readline()

                if not raw_bytes:
                    continue

                line = raw_bytes.decode(
                    "utf-8",
                    errors="replace",
                ).strip()

                if not line:
                    continue

                # Always save the complete raw stream immediately.
                raw_file.write(line + "\n")
                raw_file.flush()

                print(line)

                parts = line.split("|")
                record_type = parts[0]

                # ------------------------------------------------
                # EVENT_START|event_id|before_g
                # ------------------------------------------------
                if record_type == "EVENT_START" and len(parts) >= 3:
                    try:
                        event_id = int(parts[1])
                        before_g = float(parts[2])
                    except ValueError:
                        continue

                    current_event_id = event_id

                    events[event_id] = {
                        "event_id": event_id,
                        "before_g": before_g,
                        "after_g": None,
                        "removed_g": None,
                        "predicted_count": None,
                        "expected_count": None,
                        "prediction": None,
                        "label": None,
                        "samples": [],
                    }

                # ------------------------------------------------
                # DATA|event_id|time_ms|weight_g
                # ------------------------------------------------
                elif record_type == "DATA" and len(parts) >= 4:
                    try:
                        event_id = int(parts[1])
                        time_ms = int(parts[2])
                        weight_g = float(parts[3])
                    except ValueError:
                        continue

                    if event_id not in events:
                        # Defensive fallback in case EVENT_START was missed.
                        events[event_id] = {
                            "event_id": event_id,
                            "before_g": None,
                            "after_g": None,
                            "removed_g": None,
                            "predicted_count": None,
                            "expected_count": None,
                            "prediction": None,
                            "label": None,
                            "samples": [],
                        }

                    events[event_id]["samples"].append(
                        {
                            "event_id": event_id,
                            "time_ms": time_ms,
                            "weight_g": weight_g,
                        }
                    )

                # ------------------------------------------------
                # EVENT_END|event_id|before_g|after_g|removed_g
                # ------------------------------------------------
                elif record_type == "EVENT_END" and len(parts) >= 5:
                    try:
                        event_id = int(parts[1])
                        before_g = float(parts[2])
                        after_g = float(parts[3])
                        removed_g = float(parts[4])
                    except ValueError:
                        continue

                    if event_id not in events:
                        events[event_id] = {
                            "event_id": event_id,
                            "before_g": before_g,
                            "after_g": after_g,
                            "removed_g": removed_g,
                            "predicted_count": None,
                            "expected_count": None,
                            "prediction": None,
                            "label": None,
                            "samples": [],
                        }

                    events[event_id]["before_g"] = before_g
                    events[event_id]["after_g"] = after_g
                    events[event_id]["removed_g"] = removed_g

                # ------------------------------------------------
                # PREDICTION|event_id|removed_g|predicted|expected|status
                # ------------------------------------------------
                elif record_type == "PREDICTION" and len(parts) >= 6:
                    try:
                        event_id = int(parts[1])
                        removed_g = float(parts[2])
                        predicted_count = int(parts[3])
                        expected_count = int(parts[4])
                        prediction = parts[5]
                    except ValueError:
                        continue

                    if event_id not in events:
                        events[event_id] = {
                            "event_id": event_id,
                            "before_g": None,
                            "after_g": None,
                            "removed_g": removed_g,
                            "predicted_count": predicted_count,
                            "expected_count": expected_count,
                            "prediction": prediction,
                            "label": None,
                            "samples": [],
                        }

                    events[event_id]["removed_g"] = removed_g
                    events[event_id]["predicted_count"] = predicted_count
                    events[event_id]["expected_count"] = expected_count
                    events[event_id]["prediction"] = prediction

                # ------------------------------------------------
                # WAITING_FOR_LABEL|event_id
                # Nothing needs to be written yet.
                # ------------------------------------------------
                elif record_type == "WAITING_FOR_LABEL" and len(parts) >= 2:
                    try:
                        current_event_id = int(parts[1])
                    except ValueError:
                        pass

                # ------------------------------------------------
                # LABEL|event_id|label
                #
                # Once a label arrives, commit both event summary
                # and all samples to CSV.
                # ------------------------------------------------
                elif record_type == "LABEL" and len(parts) >= 3:
                    try:
                        event_id = int(parts[1])
                    except ValueError:
                        continue

                    label = parts[2].strip().upper()

                    if event_id not in events:
                        print(
                            f"[WARN] LABEL received for unknown Event {event_id}"
                        )
                        continue

                    event = events[event_id]
                    event["label"] = label

                    # Write all buffered samples.
                    for sample in event["samples"]:
                        samples_writer.writerow(
                            {
                                "event_id": event_id,
                                "time_ms": sample["time_ms"],
                                "weight_g": sample["weight_g"],
                                "label": label,
                            }
                        )

                    samples_file.flush()

                    # Write event-level summary.
                    events_writer.writerow(
                        {
                            "event_id": event_id,
                            "before_g": event["before_g"],
                            "after_g": event["after_g"],
                            "removed_g": event["removed_g"],
                            "predicted_count": event["predicted_count"],
                            "expected_count": event["expected_count"],
                            "prediction": event["prediction"],
                            "label": label,
                            "n_samples": len(event["samples"]),
                        }
                    )

                    events_file.flush()

                    print(
                        f"[SAVED] Event {event_id} | "
                        f"{label} | "
                        f"{len(event['samples'])} samples"
                    )

                    # Remove committed event from RAM.
                    del events[event_id]

                    if current_event_id == event_id:
                        current_event_id = None

                # ------------------------------------------------
                # Current firmware also emits:
                #
                # TRIGGER|BUTTON|1
                # TRIGGER|BLE|2
                # BASELINE_STD|1|0.065|27
                # BLE_RX: ...
                # BLE_TX: ...
                #
                # They are intentionally preserved in raw_serial.txt.
                # This logger does not need them for the current CSV format.
                # ------------------------------------------------

        except KeyboardInterrupt:
            print()
            print("Stopping logger...")

        finally:
            ser.close()

            print()
            print("=" * 68)
            print("LOGGER STOPPED")
            print("=" * 68)
            print(f"Raw serial: {raw_path.resolve()}")
            print(f"Samples:    {samples_path.resolve()}")
            print(f"Events:     {events_path.resolve()}")
            print()


if __name__ == "__main__":
    main()
