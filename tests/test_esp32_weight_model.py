import csv
import importlib.util
import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import pandas as pd


ROOT = Path(__file__).resolve().parents[1]
RUNTIME_PATH = ROOT / "inference" / "realtime_inference_ble.py"
EXPORTER_PATH = ROOT / "inference" / "weight" / "export_esp32_weight_model.py"
VERIFIER_PATH = ROOT / "inference" / "weight" / "verify_esp32_weight_runtime.cpp"

SPEC = importlib.util.spec_from_file_location("weight_runtime_for_esp32_test", RUNTIME_PATH)
inference = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(inference)


class ESP32WeightModelTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        compiler = shutil.which("clang++") or shutil.which("g++")
        if compiler is None:
            raise unittest.SkipTest("A C++17 compiler is required for ESP32 parity verification")
        cls.temporary_directory = tempfile.TemporaryDirectory(prefix="medbox-weight-")
        cls.verifier = Path(cls.temporary_directory.name) / "verify_weight"
        subprocess.run(
            [compiler, "-std=c++17", "-O2", str(VERIFIER_PATH), "-o", str(cls.verifier)],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        )
        cls.model = inference.HierarchicalMedicationModel()

    @classmethod
    def tearDownClass(cls):
        if hasattr(cls, "temporary_directory"):
            cls.temporary_directory.cleanup()

    def test_generated_model_artifacts_are_current(self):
        subprocess.run(
            [str(ROOT / ".venv" / "bin" / "python"), str(EXPORTER_PATH), "--check"],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        )

    def test_cpp_runtime_matches_frozen_python_pipeline(self):
        checked = 0
        max_confidence_error = 0.0
        for dataset in ("round1", "round2", "synthetic_round3"):
            data_directory = ROOT / "data" / dataset
            completed = subprocess.run(
                [
                    str(self.verifier),
                    str(data_directory / "events.csv"),
                    str(data_directory / "samples.csv"),
                ],
                cwd=ROOT,
                check=True,
                capture_output=True,
                text=True,
            )
            actual = {
                int(row["event_id"]): row
                for row in csv.DictReader(
                    ["event_id,label,confidence,final_delta", *completed.stdout.splitlines()]
                )
            }
            events = pd.read_csv(data_directory / "events.csv")
            samples = pd.read_csv(data_directory / "samples.csv")
            for event in events.itertuples():
                event_samples = samples[samples["event_id"] == event.event_id].sort_values("time_ms")
                expected = self.model.predict(
                    float(event.before_g),
                    float(event.after_g),
                    [
                        {"time_ms": int(row.time_ms), "weight_g": float(row.weight_g)}
                        for row in event_samples.itertuples()
                    ],
                )
                result = actual[int(event.event_id)]
                self.assertEqual(
                    result["label"],
                    expected["prediction"],
                    f"{dataset} event {event.event_id}",
                )
                if expected["rf_confidence"] is not None:
                    error = abs(float(result["confidence"]) - expected["rf_confidence"])
                    max_confidence_error = max(max_confidence_error, error)
                    self.assertLess(error, 1e-6, f"{dataset} event {event.event_id}")
                else:
                    self.assertEqual(result["confidence"], "NA")
                self.assertAlmostEqual(
                    float(result["final_delta"]),
                    float(event.before_g) - float(event.after_g),
                    places=9,
                )
                checked += 1

        self.assertEqual(checked, 150)
        self.assertLess(max_confidence_error, 1e-6)

    def test_export_report_records_full_parity(self):
        report = json.loads(
            (ROOT / "inference" / "weight" / "esp32_export_report.json").read_text()
        )
        self.assertEqual(report["tree_count"], 500)
        self.assertEqual(report["node_count"], 3174)
        self.assertEqual(report["verification"]["label_mismatches"], 0)


if __name__ == "__main__":
    unittest.main()
