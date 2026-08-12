import csv
import importlib.util
import json
import unittest
from pathlib import Path

import pandas as pd


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "inference" / "realtime_inference_ble.py"
SPEC = importlib.util.spec_from_file_location("realtime_inference_ble", MODULE_PATH)
inference = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(inference)


class SerialDouble:
    def __init__(self):
        self.buffer = bytearray()
        self.flushed = False

    def write(self, value):
        self.buffer.extend(value)

    def flush(self):
        self.flushed = True


def samples_for(round_name, event_id):
    rows = pd.read_csv(ROOT / "data" / round_name / "samples.csv")
    event_rows = rows[rows["event_id"] == event_id].sort_values("time_ms")
    return [
        {"time_ms": int(row.time_ms), "weight_g": float(row.weight_g)}
        for row in event_rows.itertuples()
    ]


class FeatureHelperTests(unittest.TestCase):
    def test_longest_true_run_and_episode_count(self):
        mask = [False, True, True, False, True, True, True, False]
        self.assertEqual(inference.longest_true_run(mask), 3)
        self.assertEqual(inference.count_change_episodes(mask), 2)

    def test_feature_extraction_has_configured_order_and_values(self):
        with (ROOT / "model" / "hierarchical_model_config.json").open() as file:
            config = json.load(file)

        features = inference.extract_dynamic_features(
            before_g=8.479,
            samples=samples_for("round1", 1),
        )

        self.assertEqual(list(features), config["dynamic_features"])
        self.assertGreater(features["n_samples"], 0)
        self.assertGreaterEqual(features["weight_range_g"], 0)

    def test_empty_samples_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "No event samples"):
            inference.extract_dynamic_features(8.0, [])


class HierarchicalModelTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.model = inference.HierarchicalMedicationModel()

    def prediction_for_ratio(self, ratio):
        before = 10.0
        after = before - ratio * self.model.pill_weight_g
        return self.model.predict(before, after, [{"time_ms": 0, "weight_g": before}])

    def test_static_gate_keeps_deliberate_uncertainty_gaps(self):
        self.assertEqual(self.prediction_for_ratio(0.51)["prediction"], "ONE")
        self.assertEqual(self.prediction_for_ratio(1.49)["prediction"], "ONE")
        self.assertEqual(self.prediction_for_ratio(1.51)["prediction"], "TWO")
        self.assertEqual(self.prediction_for_ratio(2.49)["prediction"], "TWO")
        self.assertEqual(self.prediction_for_ratio(0.40)["prediction"], "UNCERTAIN")
        self.assertEqual(self.prediction_for_ratio(2.50)["prediction"], "UNCERTAIN")
        self.assertEqual(self.prediction_for_ratio(-1.00)["prediction"], "UNCERTAIN")

    def test_frozen_model_reproduces_combined_training_set_predictions(self):
        correct = 0
        total = 0

        for round_name in ("round1", "round2"):
            events = pd.read_csv(ROOT / "data" / round_name / "events.csv")
            sample_rows = pd.read_csv(ROOT / "data" / round_name / "samples.csv")

            for event in events.itertuples():
                rows = sample_rows[sample_rows["event_id"] == event.event_id].sort_values("time_ms")
                samples = [
                    {"time_ms": int(row.time_ms), "weight_g": float(row.weight_g)}
                    for row in rows.itertuples()
                ]
                result = self.model.predict(float(event.before_g), float(event.after_g), samples)
                correct += result["prediction"] == event.label
                total += 1

        self.assertEqual(total, 100)
        self.assertEqual(correct, 100)

    def test_ai_result_wire_format(self):
        serial = SerialDouble()
        inference.send_ai_result_to_esp32(
            serial,
            event_id=15,
            result={
                "prediction": "RETURN",
                "final_delta_g": -0.018,
                "rf_confidence": 0.864,
            },
        )
        self.assertEqual(serial.buffer.decode(), "AI_RESULT|15|RETURN|-0.018|0.864\n")
        self.assertTrue(serial.flushed)


class DataIntegrityTests(unittest.TestCase):
    def test_real_rounds_are_balanced(self):
        expected = {"NONE": 10, "ONE": 10, "TWO": 10, "RETURN": 10, "DISTURBANCE": 10}
        for round_name in ("round1", "round2"):
            events = pd.read_csv(ROOT / "data" / round_name / "events.csv")
            self.assertEqual(len(events), 50)
            self.assertEqual(events["label"].value_counts().to_dict(), expected)

    def test_synthetic_round_is_balanced_and_marked_as_template_derived(self):
        events = pd.read_csv(ROOT / "data" / "synthetic_round3" / "events.csv")
        self.assertEqual(len(events), 50)
        self.assertTrue(events["template_source"].notna().all())


if __name__ == "__main__":
    unittest.main()
