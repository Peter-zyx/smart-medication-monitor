#!/usr/bin/env python3
"""Export the landmark action classifier as a Core ML tree ensemble.

This script intentionally consumes the cached, finite feature vectors produced by
``train_camera_action_model.py``. It does not re-run landmark extraction and it
does not change the meaning of TAKE: the label remains a visible TAKE-like action,
not proof that medication was swallowed.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import coremltools as ct
import numpy as np
from coremltools.models import datatypes
from coremltools.models.tree_ensemble import TreeEnsembleClassifier
from sklearn.ensemble import ExtraTreesClassifier
from sklearn.metrics import accuracy_score
from sklearn.model_selection import StratifiedKFold, cross_val_predict
from sklearn.tree import _tree


RANDOM_SEED = 42
EXPECTED_EXTRACTOR_VERSION = "1.0.0"


def parse_args() -> argparse.Namespace:
    repository_root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(
        description="Train and export the MedBox camera action classifier to Core ML."
    )
    parser.add_argument(
        "--features",
        type=Path,
        default=Path(__file__).resolve().parent / "output" / "camera_features.npz",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=(
            repository_root
            / "app/MedBoxApp/MedBoxApp/Resources/CameraActionClassifier.mlmodel"
        ),
    )
    parser.add_argument("--estimators", type=int, default=600)
    parser.add_argument(
        "--report",
        type=Path,
        default=Path(__file__).resolve().parent / "coreml_export_report.json",
    )
    parser.add_argument(
        "--skip-cross-validation",
        action="store_true",
        help="Skip the reproducibility CV check and only fit/export the final model.",
    )
    return parser.parse_args()


def load_features(path: Path) -> tuple[np.ndarray, np.ndarray, list[str], str]:
    if not path.is_file():
        raise FileNotFoundError(f"Feature cache not found: {path}")
    cache = np.load(path, allow_pickle=False)
    required = {"X", "y", "feature_names", "extractor_version", "config_json"}
    missing = required.difference(cache.files)
    if missing:
        raise ValueError(f"Feature cache is missing keys: {sorted(missing)}")

    extractor_version = str(cache["extractor_version"].item())
    if extractor_version != EXPECTED_EXTRACTOR_VERSION:
        raise ValueError(
            f"Expected extractor {EXPECTED_EXTRACTOR_VERSION}, got {extractor_version}"
        )

    X = np.asarray(cache["X"], dtype=np.float32)
    y = np.asarray(cache["y"], dtype=str)
    feature_names = [str(value) for value in cache["feature_names"]]
    config_json = str(cache["config_json"].item())
    if X.ndim != 2 or X.shape[1] != len(feature_names):
        raise ValueError(f"Invalid feature shape/schema: {X.shape} vs {len(feature_names)}")
    if not np.isfinite(X).all():
        raise ValueError("The iOS model requires finite features; cache contains NaN/Inf")
    return X, y, feature_names, config_json


def make_model(estimators: int) -> ExtraTreesClassifier:
    return ExtraTreesClassifier(
        n_estimators=estimators,
        max_features="sqrt",
        min_samples_leaf=1,
        class_weight="balanced",
        random_state=RANDOM_SEED,
        n_jobs=-1,
    )


def add_sklearn_tree(
    builder: TreeEnsembleClassifier,
    tree_id: int,
    tree: object,
    tree_class_labels: np.ndarray,
    ensemble_class_labels: list[str],
    scaling: float,
) -> None:
    class_index = {label: index for index, label in enumerate(ensemble_class_labels)}
    stack = [0]
    while stack:
        node_id = stack.pop()
        left = int(tree.children_left[node_id])
        right = int(tree.children_right[node_id])
        if left != _tree.TREE_LEAF:
            builder.add_branch_node(
                tree_id=tree_id,
                node_id=node_id,
                feature_index=int(tree.feature[node_id]),
                feature_value=float(tree.threshold[node_id]),
                branch_mode="BranchOnValueLessThanEqual",
                true_child_id=left,
                false_child_id=right,
            )
            stack.extend((right, left))
            continue

        raw = np.asarray(tree.value[node_id][0], dtype=np.float64)
        total = float(raw.sum())
        probabilities = raw / total if total > 0 else np.zeros_like(raw)
        values: dict[int, float] = {}
        for label, probability in zip(tree_class_labels, probabilities):
            if probability == 0:
                continue
            # Forest sub-estimators use encoded numeric classes even when the
            # ensemble's public classes are strings.
            if str(label) in class_index:
                output_index = class_index[str(label)]
            else:
                output_index = int(label)
            values[output_index] = float(probability * scaling)
        builder.add_leaf_node(tree_id=tree_id, node_id=node_id, values=values)


def convert_to_coreml(
    model: ExtraTreesClassifier,
    feature_count: int,
    feature_names: list[str],
    config_json: str,
) -> object:
    labels = [str(label) for label in model.classes_]
    builder = TreeEnsembleClassifier(
        features=[("features", datatypes.Array(feature_count))],
        class_labels=labels,
        output_features=("label", "probabilities"),
    )
    builder.set_default_prediction_value([0.0] * len(labels))
    scaling = 1.0 / len(model.estimators_)
    for tree_id, estimator in enumerate(model.estimators_):
        add_sklearn_tree(
            builder,
            tree_id,
            estimator.tree_,
            np.asarray(estimator.classes_),
            labels,
            scaling,
        )

    spec = builder.spec
    spec.description.metadata.shortDescription = (
        "Classifies a 5-second MedBox landmark window. TAKE is a visible action only."
    )
    spec.description.metadata.author = "Smart Medication Monitor"
    spec.description.metadata.versionString = "1.0.0"
    spec.description.metadata.userDefined.update(
        {
            "extractor_version": EXPECTED_EXTRACTOR_VERSION,
            "extractor_config": config_json,
            "feature_count": str(feature_count),
            "feature_schema_json": json.dumps(feature_names, separators=(",", ":")),
            "safety_semantics": (
                "TAKE means an ingestion-like visible action; it does not confirm swallowing."
            ),
        }
    )
    return spec


def verify_coreml(
    output: Path,
    model: ExtraTreesClassifier,
    X: np.ndarray,
) -> dict[str, object]:
    coreml_model = ct.models.MLModel(str(output), compute_units=ct.ComputeUnit.CPU_ONLY)
    sample_count = min(24, len(X))
    indices = np.linspace(0, len(X) - 1, sample_count, dtype=int)
    max_probability_error = 0.0
    label_mismatches = 0
    for index in indices:
        sklearn_probabilities = model.predict_proba(X[index : index + 1])[0]
        result = coreml_model.predict({"features": X[index].astype(np.float64)})
        coreml_probabilities = result["probabilities"]
        ordered = np.asarray(
            [float(coreml_probabilities[str(label)]) for label in model.classes_]
        )
        max_probability_error = max(
            max_probability_error,
            float(np.max(np.abs(sklearn_probabilities - ordered))),
        )
        if str(result["label"]) != str(model.classes_[int(np.argmax(sklearn_probabilities))]):
            label_mismatches += 1

    if label_mismatches or max_probability_error > 1e-5:
        raise RuntimeError(
            "Core ML parity check failed: "
            f"label_mismatches={label_mismatches}, max_error={max_probability_error}"
        )
    return {
        "verified_samples": sample_count,
        "label_mismatches": label_mismatches,
        "max_probability_error": max_probability_error,
    }


def main() -> int:
    args = parse_args()
    X, y, feature_names, config_json = load_features(args.features.resolve())

    cv_accuracy = None
    if not args.skip_cross_validation:
        cv = StratifiedKFold(n_splits=5, shuffle=True, random_state=RANDOM_SEED)
        predicted = cross_val_predict(make_model(args.estimators), X, y, cv=cv, n_jobs=1)
        cv_accuracy = float(accuracy_score(y, predicted))

    model = make_model(args.estimators)
    model.fit(X, y)
    spec = convert_to_coreml(model, X.shape[1], feature_names, config_json)

    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    ct.models.utils.save_spec(spec, str(output))
    parity = verify_coreml(output, model, X)

    report = {
        "output": str(output),
        "clip_count": int(len(y)),
        "feature_count": int(X.shape[1]),
        "classes": [str(label) for label in model.classes_],
        "estimators": int(args.estimators),
        "cv_accuracy": cv_accuracy,
        **parity,
        "safety_semantics": (
            "TAKE is an ingestion-like visible action; it does not confirm swallowing."
        ),
    }
    report_path = args.report.resolve()
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
