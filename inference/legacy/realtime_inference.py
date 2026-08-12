#!/usr/bin/env python3

import csv
import json
import time
from datetime import datetime
from pathlib import Path

import joblib
import numpy as np
import pandas as pd
import serial
from serial.tools import list_ports


# ============================================================
# PROJECT PATHS
# ============================================================

PROJECT_DIR = Path(__file__).resolve().parent

MODEL_DIR = PROJECT_DIR / "round2 result"
MODEL_FILE = MODEL_DIR / "hierarchical_dynamic_rf.joblib"
CONFIG_FILE = MODEL_DIR / "hierarchical_model_config.json"

OUTPUT_ROOT = PROJECT_DIR / "realtime result"


# ============================================================
# SERIAL CONFIG
# ============================================================

PORT = None
# If automatic detection fails, set it manually, for example:
# PORT = "/dev/cu.usbmodem11201"

BAUD_RATE = 115200
SERIAL_TIMEOUT = 1.0


# ============================================================
# FEATURE SETTINGS
# Must match the settings used during model training.
# ============================================================

CHANGE_THRESHOLD_SMALL = 0.5
CHANGE_THRESHOLD_MEDIUM = 2.0
CHANGE_THRESHOLD_LARGE = 5.0

BELOW_BASELINE_THRESHOLD = 0.4
END_WINDOW = 10


# ============================================================
# USER-FACING STATUS
# ============================================================

DISPLAY_TEXT = {
    "ONE": {
        "title": "DOSE TAKEN CORRECTLY",
        "symbol": "✓",
        "message": "One pill was removed.",
    },
    "TWO": {
        "title": "POSSIBLE OVERDOSE",
        "symbol": "⚠",
        "message": "Two pills appear to have been removed.",
    },
    "NONE": {
        "title": "NO MEDICATION REMOVED",
        "symbol": "○",
        "message": "No meaningful medication removal was detected.",
    },
    "RETURN": {
        "title": "MEDICATION RETURNED",
        "symbol": "⚠",
        "message": "Medication appears to have been removed and then returned.",
    },
    "DISTURBANCE": {
        "title": "INTERACTION / DISTURBANCE DETECTED",
        "symbol": "⚠",
        "message": "Interaction was detected, but no stable medication removal was confirmed.",
    },
    "UNCERTAIN": {
        "title": "UNABLE TO CONFIRM",
        "symbol": "?",
        "message": "The final weight change falls outside the configured decision ranges.",
    },
}


# ============================================================
# HELPERS
# ============================================================

def find_serial_port():
    if PORT:
        return PORT

    ports = list(list_ports.comports())

    preferred_keywords = (
        "usbmodem",
        "esp32",
        "jtag",
        "serial",
    )

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

    for port in ports:
        if str(port.device).startswith("/dev/cu."):
            return port.device

    available = "\n".join(
        f"  {p.device}  {p.description}"
        for p in ports
    )

    raise RuntimeError(
        "Could not auto-detect the ESP32 serial port.\n"
        "Available ports:\n"
        f"{available if available else '  (none)'}\n\n"
        "Set PORT manually near the top of realtime_inference.py."
    )


def longest_true_run(mask):
    longest = 0
    current = 0

    for value in mask:
        if value:
            current += 1
            longest = max(longest, current)
        else:
            current = 0

    return longest


def count_change_episodes(mask):
    mask = np.asarray(mask, dtype=bool)

    if len(mask) == 0:
        return 0

    count = int(mask[0])

    if len(mask) > 1:
        count += int(
            np.sum(
                (~mask[:-1]) &
                mask[1:]
            )
        )

    return count


def trapezoid(y, x):
    if hasattr(np, "trapezoid"):
        return np.trapezoid(y, x)

    return np.trapz(y, x)


# ============================================================
# FEATURE EXTRACTION
# ============================================================

def extract_dynamic_features(before_g, samples):
    """
    samples:
        list of dicts:
        {
            "time_ms": int,
            "weight_g": float
        }
    """

    if not samples:
        raise ValueError("No event samples were received.")

    samples = sorted(
        samples,
        key=lambda x: x["time_ms"]
    )

    t = np.array(
        [s["time_ms"] for s in samples],
        dtype=float
    )

    w = np.array(
        [s["weight_g"] for s in samples],
        dtype=float
    )

    rel = w - before_g
    diff = np.diff(w)

    idx_max = int(np.argmax(w))
    idx_min = int(np.argmin(w))

    below_mask = (
        w <=
        (before_g - BELOW_BASELINE_THRESHOLD)
    )

    n_start = min(
        END_WINDOW,
        len(w)
    )

    n_end = min(
        END_WINDOW,
        len(w)
    )

    start_w = w[:n_start]
    end_w = w[-n_end:]

    if len(diff) > 0:
        max_step_up = float(
            np.max(diff)
        )

        max_step_down = float(
            np.min(diff)
        )

        mean_abs_step = float(
            np.mean(
                np.abs(diff)
            )
        )

        std_step = float(
            np.std(diff)
        )

        n_change_small = int(
            np.sum(
                np.abs(diff) >=
                CHANGE_THRESHOLD_SMALL
            )
        )

        n_change_medium = int(
            np.sum(
                np.abs(diff) >=
                CHANGE_THRESHOLD_MEDIUM
            )
        )

        n_change_large = int(
            np.sum(
                np.abs(diff) >=
                CHANGE_THRESHOLD_LARGE
            )
        )

    else:
        max_step_up = 0.0
        max_step_down = 0.0
        mean_abs_step = 0.0
        std_step = 0.0

        n_change_small = 0
        n_change_medium = 0
        n_change_large = 0

    if len(w) > 1:
        abs_area = float(
            trapezoid(
                np.abs(rel),
                t
            )
        )

        signed_area = float(
            trapezoid(
                rel,
                t
            )
        )

        duration_ms = float(
            t[-1] - t[0]
        )

    else:
        abs_area = 0.0
        signed_area = 0.0
        duration_ms = 0.0

    features = {
        "weight_range_g": float(
            np.max(w) -
            np.min(w)
        ),

        "std_weight_g": float(
            np.std(w)
        ),

        "max_rise_from_baseline_g": float(
            np.max(rel)
        ),

        "max_drop_from_baseline_g": float(
            -np.min(rel)
        ),

        "max_abs_deviation_g": float(
            np.max(
                np.abs(rel)
            )
        ),

        "time_to_max_ms": float(
            t[idx_max]
        ),

        "time_to_min_ms": float(
            t[idx_min]
        ),

        "duration_ms": duration_ms,

        "max_step_up_g": max_step_up,
        "max_step_down_g": max_step_down,
        "mean_abs_step_g": mean_abs_step,
        "std_step_g": std_step,

        "n_change_ge_0_5g": n_change_small,
        "n_change_ge_2g": n_change_medium,
        "n_change_ge_5g": n_change_large,

        "fraction_below_baseline_minus_0_4g": float(
            np.mean(below_mask)
        ),

        "longest_below_points": int(
            longest_true_run(
                below_mask
            )
        ),

        "below_episode_count": int(
            count_change_episodes(
                below_mask
            )
        ),

        "start_mean_delta_g": float(
            before_g -
            np.mean(start_w)
        ),

        "start_std_g": float(
            np.std(start_w)
        ),

        "end_std_g": float(
            np.std(end_w)
        ),

        "abs_area_g_ms": abs_area,
        "signed_area_g_ms": signed_area,

        "n_samples": int(
            len(w)
        ),
    }

    return features


# ============================================================
# HIERARCHICAL MODEL
# ============================================================

class HierarchicalMedicationModel:

    def __init__(self):
        if not MODEL_FILE.exists():
            raise FileNotFoundError(
                f"Model not found:\n{MODEL_FILE}\n\n"
                "Make sure hierarchical_dynamic_rf.joblib is inside "
                "'round2 result'."
            )

        if not CONFIG_FILE.exists():
            raise FileNotFoundError(
                f"Config not found:\n{CONFIG_FILE}\n\n"
                "Make sure hierarchical_model_config.json is inside "
                "'round2 result'."
            )

        self.dynamic_rf = joblib.load(
            MODEL_FILE
        )

        with open(
            CONFIG_FILE,
            "r",
            encoding="utf-8"
        ) as f:
            self.config = json.load(f)

        self.pill_weight_g = float(
            self.config[
                "pill_weight_g"
            ]
        )

        stage1 = self.config[
            "stage1"
        ]

        self.zero_ratio_max = float(
            stage1[
                "zero_abs_ratio_max"
            ]
        )

        self.one_ratio_min = float(
            stage1[
                "one_ratio_min"
            ]
        )

        self.one_ratio_max = float(
            stage1[
                "one_ratio_max"
            ]
        )

        self.two_ratio_min = float(
            stage1[
                "two_ratio_min"
            ]
        )

        self.two_ratio_max = float(
            stage1[
                "two_ratio_max"
            ]
        )

        self.dynamic_features = (
            self.config[
                "dynamic_features"
            ]
        )

    def predict(
        self,
        before_g,
        after_g,
        samples,
    ):
        final_delta_g = (
            before_g -
            after_g
        )

        ratio = (
            final_delta_g /
            self.pill_weight_g
        )

        # ------------------------------------------
        # Stage 1:
        # use static final weight for pill quantity.
        # ------------------------------------------

        if abs(ratio) < self.zero_ratio_max:
            stage = "DYNAMIC_RF"

            features = (
                extract_dynamic_features(
                    before_g,
                    samples,
                )
            )

            x = pd.DataFrame(
                [
                    {
                        name:
                        features[name]
                        for name
                        in self.dynamic_features
                    }
                ]
            )

            prediction = (
                self.dynamic_rf
                .predict(x)[0]
            )

            if hasattr(
                self.dynamic_rf,
                "predict_proba"
            ):
                probabilities = (
                    self.dynamic_rf
                    .predict_proba(x)[0]
                )

                classes = (
                    self.dynamic_rf
                    .classes_
                )

                rf_confidence = float(
                    probabilities[
                        list(classes).index(
                            prediction
                        )
                    ]
                )

            else:
                rf_confidence = None

            return {
                "prediction":
                    prediction,
                "stage":
                    stage,
                "final_delta_g":
                    final_delta_g,
                "pill_ratio":
                    ratio,
                "estimated_count":
                    0,
                "rf_confidence":
                    rf_confidence,
                "features":
                    features,
            }

        # ------------------------------------------
        # ONE
        # ------------------------------------------

        if (
            self.one_ratio_min <=
            ratio <
            self.one_ratio_max
        ):
            return {
                "prediction":
                    "ONE",
                "stage":
                    "STATIC_WEIGHT",
                "final_delta_g":
                    final_delta_g,
                "pill_ratio":
                    ratio,
                "estimated_count":
                    1,
                "rf_confidence":
                    None,
                "features":
                    None,
            }

        # ------------------------------------------
        # TWO
        # ------------------------------------------

        if (
            self.two_ratio_min <=
            ratio <
            self.two_ratio_max
        ):
            return {
                "prediction":
                    "TWO",
                "stage":
                    "STATIC_WEIGHT",
                "final_delta_g":
                    final_delta_g,
                "pill_ratio":
                    ratio,
                "estimated_count":
                    2,
                "rf_confidence":
                    None,
                "features":
                    None,
            }

        # ------------------------------------------
        # Anything between / outside expected bands
        # is deliberately not forced into a class.
        # ------------------------------------------

        return {
            "prediction":
                "UNCERTAIN",
            "stage":
                "UNCERTAIN",
            "final_delta_g":
                final_delta_g,
            "pill_ratio":
                ratio,
            "estimated_count":
                None,
            "rf_confidence":
                None,
            "features":
                None,
        }


# ============================================================
# OUTPUT
# ============================================================

def create_session():
    timestamp = datetime.now().strftime(
        "%Y%m%d_%H%M%S"
    )

    session_dir = (
        OUTPUT_ROOT /
        f"session_{timestamp}"
    )

    session_dir.mkdir(
        parents=True,
        exist_ok=False,
    )

    return session_dir


def print_prediction(
    event_id,
    result,
    before_g,
    after_g,
):
    prediction = (
        result[
            "prediction"
        ]
    )

    info = DISPLAY_TEXT[
        prediction
    ]

    print()
    print("=" * 68)
    print(
        f"MEDICATION EVENT #{event_id}"
    )
    print("=" * 68)
    print(
        f"Before weight:       "
        f"{before_g:.3f} g"
    )
    print(
        f"After weight:        "
        f"{after_g:.3f} g"
    )
    print(
        f"Final weight change: "
        f"{result['final_delta_g']:.3f} g"
    )
    print(
        f"Pill ratio:          "
        f"{result['pill_ratio']:.2f}"
    )
    print(
        f"Decision stage:      "
        f"{result['stage']}"
    )

    if (
        result[
            "estimated_count"
        ]
        is not None
    ):
        print(
            f"Estimated quantity:  "
            f"{result['estimated_count']} pill(s)"
        )

    if (
        result[
            "rf_confidence"
        ]
        is not None
    ):
        print(
            f"RF confidence:       "
            f"{result['rf_confidence'] * 100:.1f}%"
        )

    print()
    print(
        f"{info['symbol']} "
        f"{info['title']}"
    )
    print(
        info[
            "message"
        ]
    )
    print("=" * 68)
    print()


# ============================================================
# REAL-TIME LOOP
# ============================================================

def main():
    model = (
        HierarchicalMedicationModel()
    )

    session_dir = (
        create_session()
    )

    raw_path = (
        session_dir /
        "raw_serial.txt"
    )

    samples_path = (
        session_dir /
        "samples.csv"
    )

    predictions_path = (
        session_dir /
        "realtime_predictions.csv"
    )

    port = find_serial_port()

    print("=" * 68)
    print("MEDBOX REAL-TIME INFERENCE")
    print("=" * 68)
    print(
        f"Port:        {port}"
    )
    print(
        f"Baud:        {BAUD_RATE}"
    )
    print(
        f"Pill weight: "
        f"{model.pill_weight_g:.3f} g"
    )
    print(
        f"Model:       "
        f"{MODEL_FILE}"
    )
    print(
        f"Output:      "
        f"{session_dir.resolve()}"
    )
    print()
    print(
        "Do NOT run medbox_logger.py or Arduino Serial Monitor "
        "at the same time."
    )
    print(
        "Press Ctrl+C to stop."
    )
    print("=" * 68)
    print()

    ser = serial.Serial(
        port=port,
        baudrate=BAUD_RATE,
        timeout=SERIAL_TIMEOUT,
    )

    time.sleep(1.0)

    active_events = {}

    with (
        open(
            raw_path,
            "a",
            encoding="utf-8",
            buffering=1,
        ) as raw_file,

        open(
            samples_path,
            "w",
            newline="",
            encoding="utf-8",
        ) as samples_file,

        open(
            predictions_path,
            "w",
            newline="",
            encoding="utf-8",
        ) as predictions_file,
    ):

        samples_writer = csv.DictWriter(
            samples_file,
            fieldnames=[
                "event_id",
                "time_ms",
                "weight_g",
            ],
        )

        samples_writer.writeheader()

        prediction_writer = csv.DictWriter(
            predictions_file,
            fieldnames=[
                "timestamp",
                "event_id",
                "before_g",
                "after_g",
                "final_delta_g",
                "pill_ratio",
                "stage",
                "estimated_count",
                "prediction",
                "rf_confidence",
                "n_samples",
            ],
        )

        prediction_writer.writeheader()

        try:
            while True:
                raw_bytes = (
                    ser.readline()
                )

                if not raw_bytes:
                    continue

                line = (
                    raw_bytes
                    .decode(
                        "utf-8",
                        errors="replace",
                    )
                    .strip()
                )

                if not line:
                    continue

                raw_file.write(
                    line + "\n"
                )

                print(line)

                parts = (
                    line.split("|")
                )

                record_type = (
                    parts[0]
                )

                # ----------------------------------
                # EVENT_START|id|before
                # ----------------------------------

                if (
                    record_type ==
                    "EVENT_START"
                    and len(parts) >= 3
                ):
                    try:
                        event_id = int(
                            parts[1]
                        )

                        before_g = float(
                            parts[2]
                        )

                    except ValueError:
                        continue

                    active_events[
                        event_id
                    ] = {
                        "before_g":
                            before_g,
                        "samples":
                            [],
                    }

                # ----------------------------------
                # DATA|id|time_ms|weight
                # ----------------------------------

                elif (
                    record_type ==
                    "DATA"
                    and len(parts) >= 4
                ):
                    try:
                        event_id = int(
                            parts[1]
                        )

                        time_ms = int(
                            parts[2]
                        )

                        weight_g = float(
                            parts[3]
                        )

                    except ValueError:
                        continue

                    if (
                        event_id
                        not in
                        active_events
                    ):
                        continue

                    active_events[
                        event_id
                    ][
                        "samples"
                    ].append(
                        {
                            "time_ms":
                                time_ms,
                            "weight_g":
                                weight_g,
                        }
                    )

                    samples_writer.writerow(
                        {
                            "event_id":
                                event_id,
                            "time_ms":
                                time_ms,
                            "weight_g":
                                weight_g,
                        }
                    )

                    samples_file.flush()

                # ----------------------------------
                # EVENT_END|id|before|after|removed
                # ----------------------------------

                elif (
                    record_type ==
                    "EVENT_END"
                    and len(parts) >= 5
                ):
                    try:
                        event_id = int(
                            parts[1]
                        )

                        before_g = float(
                            parts[2]
                        )

                        after_g = float(
                            parts[3]
                        )

                    except ValueError:
                        continue

                    event = (
                        active_events
                        .get(event_id)
                    )

                    if event is None:
                        print(
                            f"[WARN] Event {event_id} ended "
                            "but no EVENT_START was captured."
                        )
                        continue

                    try:
                        result = (
                            model.predict(
                                before_g=
                                    before_g,
                                after_g=
                                    after_g,
                                samples=
                                    event[
                                        "samples"
                                    ],
                            )
                        )

                    except Exception as exc:
                        print()
                        print(
                            f"[ERROR] Could not classify "
                            f"Event {event_id}: {exc}"
                        )
                        print()

                        del active_events[
                            event_id
                        ]

                        continue

                    print_prediction(
                        event_id=
                            event_id,
                        result=
                            result,
                        before_g=
                            before_g,
                        after_g=
                            after_g,
                    )

                    prediction_writer.writerow(
                        {
                            "timestamp":
                                datetime.now()
                                .isoformat(
                                    timespec="seconds"
                                ),

                            "event_id":
                                event_id,

                            "before_g":
                                round(
                                    before_g,
                                    3
                                ),

                            "after_g":
                                round(
                                    after_g,
                                    3
                                ),

                            "final_delta_g":
                                round(
                                    result[
                                        "final_delta_g"
                                    ],
                                    3
                                ),

                            "pill_ratio":
                                round(
                                    result[
                                        "pill_ratio"
                                    ],
                                    3
                                ),

                            "stage":
                                result[
                                    "stage"
                                ],

                            "estimated_count":
                                result[
                                    "estimated_count"
                                ],

                            "prediction":
                                result[
                                    "prediction"
                                ],

                            "rf_confidence":
                                (
                                    round(
                                        result[
                                            "rf_confidence"
                                        ],
                                        4
                                    )
                                    if result[
                                        "rf_confidence"
                                    ]
                                    is not None
                                    else ""
                                ),

                            "n_samples":
                                len(
                                    event[
                                        "samples"
                                    ]
                                ),
                        }
                    )

                    predictions_file.flush()

                    del active_events[
                        event_id
                    ]

        except KeyboardInterrupt:
            print()
            print(
                "Stopping real-time inference..."
            )

        finally:
            ser.close()

            print()
            print("=" * 68)
            print("REAL-TIME INFERENCE STOPPED")
            print("=" * 68)
            print(
                f"Raw serial:  "
                f"{raw_path.resolve()}"
            )
            print(
                f"Samples:     "
                f"{samples_path.resolve()}"
            )
            print(
                f"Predictions: "
                f"{predictions_path.resolve()}"
            )
            print()


if __name__ == "__main__":
    main()
