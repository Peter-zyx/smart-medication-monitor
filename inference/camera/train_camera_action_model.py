#!/usr/bin/env python3
"""Train a small landmark-based action classifier for the MedBox camera clips.

The model classifies visible action patterns only. A TAKE prediction must never be
presented as proof that medication was swallowed.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import sys
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Iterable, Sequence

import cv2
import joblib
import matplotlib
import mediapipe as mp
import numpy as np
from sklearn.base import clone
from sklearn.ensemble import ExtraTreesClassifier, RandomForestClassifier
from sklearn.feature_selection import SelectKBest, f_classif
from sklearn.impute import SimpleImputer
from sklearn.metrics import (
    accuracy_score,
    balanced_accuracy_score,
    classification_report,
    confusion_matrix,
    f1_score,
)
from sklearn.model_selection import StratifiedKFold, cross_val_predict
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler
from sklearn.svm import SVC

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402


EXTRACTOR_VERSION = "1.0.0"
RANDOM_SEED = 42
DEFAULT_LABELS = ("TAKE", "DRINK", "TOUCH_FACE", "ADJUST", "PICK_ONLY", "NONE")
POSE_IDS = tuple(range(23))  # face and upper body landmarks only
HAND_KEY_IDS = (0, 4, 8, 12, 16, 20)  # wrist + five fingertips


@dataclass(frozen=True)
class ExtractorConfig:
    sampled_frames: int = 24
    temporal_bins: int = 6
    pose_detection_confidence: float = 0.35
    hand_detection_confidence: float = 0.30


def parse_args() -> argparse.Namespace:
    repository_root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(
        description="Extract MediaPipe landmarks and train the MedBox action baseline."
    )
    parser.add_argument(
        "--dataset",
        type=Path,
        default=repository_root / "camera_data",
        help="camera_data directory",
    )
    parser.add_argument(
        "--models-dir",
        type=Path,
        default=Path(__file__).resolve().parent / "models",
        help="Directory containing the MediaPipe .task files",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(__file__).resolve().parent / "output",
        help="Training artifact directory",
    )
    parser.add_argument("--sampled-frames", type=int, default=24)
    parser.add_argument(
        "--force-extract",
        action="store_true",
        help="Ignore an existing feature cache and process every video again",
    )
    parser.add_argument(
        "--quick-check",
        action="store_true",
        help="Process one clip per label to validate the pipeline without training",
    )
    return parser.parse_args()


def require_file(path: Path, description: str) -> None:
    if not path.is_file() or path.stat().st_size < 100_000:
        raise FileNotFoundError(f"Missing or incomplete {description}: {path}")


def discover_clips(dataset: Path, quick_check: bool) -> list[tuple[Path, str]]:
    clips: list[tuple[Path, str]] = []
    for label in DEFAULT_LABELS:
        label_clips = sorted((dataset / label).glob("*/*.mp4"))
        if not label_clips:
            raise FileNotFoundError(f"No MP4 clips found for label {label}: {dataset / label}")
        if quick_check:
            label_clips = label_clips[:1]
        clips.extend((path, label) for path in label_clips)
    return clips


def sampled_rgb_frames(video_path: Path, count: int) -> list[np.ndarray]:
    cap = cv2.VideoCapture(str(video_path))
    if not cap.isOpened():
        raise RuntimeError(f"Cannot open video: {video_path}")

    total = max(1, int(cap.get(cv2.CAP_PROP_FRAME_COUNT)))
    wanted = np.rint(np.linspace(0, total - 1, count)).astype(int)
    wanted_set = set(int(index) for index in wanted)
    frames_by_index: dict[int, np.ndarray] = {}
    frame_index = 0
    while True:
        ok, bgr = cap.read()
        if not ok:
            break
        if frame_index in wanted_set:
            frames_by_index[frame_index] = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
        frame_index += 1
    cap.release()

    if not frames_by_index:
        raise RuntimeError(f"No readable frames: {video_path}")

    available = np.array(sorted(frames_by_index))
    result: list[np.ndarray] = []
    for target in wanted:
        nearest = int(available[np.argmin(np.abs(available - target))])
        result.append(frames_by_index[nearest])
    return result


def _xy(point: object) -> np.ndarray:
    return np.array([float(point.x), float(point.y)], dtype=np.float32)


def _safe_visibility(point: object) -> float:
    value = getattr(point, "visibility", None)
    return float(value) if value is not None else 0.0


def _distance(a: object, b: object) -> float:
    return float(np.linalg.norm(_xy(a) - _xy(b)))


def frame_features(
    rgb: np.ndarray,
    pose_result: object,
    hand_result: object,
) -> tuple[np.ndarray, list[str]]:
    names: list[str] = []
    values: list[float] = []

    pose = pose_result.pose_landmarks[0] if pose_result.pose_landmarks else None
    if pose is not None:
        shoulder_center = (_xy(pose[11]) + _xy(pose[12])) / 2.0
        body_scale = max(_distance(pose[11], pose[12]), 0.08)
    else:
        shoulder_center = np.array([0.5, 0.5], dtype=np.float32)
        body_scale = 0.25

    for landmark_id in POSE_IDS:
        if pose is None:
            px = py = pz = visibility = 0.0
        else:
            point = pose[landmark_id]
            px = (float(point.x) - float(shoulder_center[0])) / body_scale
            py = (float(point.y) - float(shoulder_center[1])) / body_scale
            pz = float(point.z) / body_scale
            visibility = _safe_visibility(point)
        for suffix, value in zip(("x", "y", "z", "visibility"), (px, py, pz, visibility)):
            names.append(f"pose_{landmark_id}_{suffix}")
            values.append(value)

    # Semantic face-contact distances from both arms.
    derived: dict[str, float] = {"pose_present": float(pose is not None)}
    if pose is not None:
        mouth = (_xy(pose[9]) + _xy(pose[10])) / 2.0
        nose = _xy(pose[0])
        for side, point_ids, ear_id in (
            ("left", (15, 19, 21), 7),
            ("right", (16, 20, 22), 8),
        ):
            ear = _xy(pose[ear_id])
            for point_name, point_id in zip(("wrist", "index", "thumb"), point_ids):
                point = _xy(pose[point_id])
                derived[f"{side}_{point_name}_to_mouth"] = float(
                    np.linalg.norm(point - mouth) / body_scale
                )
                derived[f"{side}_{point_name}_to_nose"] = float(
                    np.linalg.norm(point - nose) / body_scale
                )
                derived[f"{side}_{point_name}_to_ear"] = float(
                    np.linalg.norm(point - ear) / body_scale
                )
    else:
        for side in ("left", "right"):
            for point_name in ("wrist", "index", "thumb"):
                for target in ("mouth", "nose", "ear"):
                    derived[f"{side}_{point_name}_to_{target}"] = 0.0

    for name in sorted(derived):
        names.append(name)
        values.append(derived[name])

    hands = sorted(hand_result.hand_landmarks, key=lambda landmarks: landmarks[0].x)
    for slot in range(2):
        prefix = f"hand_{slot}"
        if slot < len(hands):
            hand = hands[slot]
            wrist = _xy(hand[0])
            palm_scale = max(_distance(hand[0], hand[9]), 0.02)
            hand_values: dict[str, float] = {"present": 1.0, "palm_scale": palm_scale / body_scale}
            for landmark_id in HAND_KEY_IDS:
                point = _xy(hand[landmark_id])
                global_point = (point - shoulder_center) / body_scale
                local_point = (point - wrist) / palm_scale
                hand_values[f"key_{landmark_id}_global_x"] = float(global_point[0])
                hand_values[f"key_{landmark_id}_global_y"] = float(global_point[1])
                hand_values[f"key_{landmark_id}_local_x"] = float(local_point[0])
                hand_values[f"key_{landmark_id}_local_y"] = float(local_point[1])
            thumb = _xy(hand[4])
            for finger_name, tip_id in zip(("index", "middle", "ring", "pinky"), (8, 12, 16, 20)):
                tip = _xy(hand[tip_id])
                hand_values[f"pinch_{finger_name}"] = float(np.linalg.norm(thumb - tip) / palm_scale)
            for finger_name, tip_id in zip(
                ("thumb", "index", "middle", "ring", "pinky"), (4, 8, 12, 16, 20)
            ):
                hand_values[f"open_{finger_name}"] = float(
                    np.linalg.norm(_xy(hand[tip_id]) - wrist) / palm_scale
                )
        else:
            hand_values = {"present": 0.0, "palm_scale": 0.0}
            for landmark_id in HAND_KEY_IDS:
                for coordinate in ("global_x", "global_y", "local_x", "local_y"):
                    hand_values[f"key_{landmark_id}_{coordinate}"] = 0.0
            for finger_name in ("index", "middle", "ring", "pinky"):
                hand_values[f"pinch_{finger_name}"] = 0.0
            for finger_name in ("thumb", "index", "middle", "ring", "pinky"):
                hand_values[f"open_{finger_name}"] = 0.0

        for name in sorted(hand_values):
            names.append(f"{prefix}_{name}")
            values.append(hand_values[name])

    names.append("detected_hand_count")
    values.append(float(min(len(hands), 2)))

    # Two coarse image-quality signals help catch unusable clips without encoding identity.
    gray = cv2.cvtColor(rgb, cv2.COLOR_RGB2GRAY)
    names.extend(("image_brightness_mean", "image_brightness_std"))
    values.extend((float(gray.mean() / 255.0), float(gray.std() / 255.0)))
    return np.asarray(values, dtype=np.float32), names


def temporal_summary(sequence: np.ndarray, frame_names: Sequence[str], bins: int) -> tuple[np.ndarray, list[str]]:
    if sequence.ndim != 2 or sequence.shape[0] < 2:
        raise ValueError(f"Expected a time-by-feature array, got {sequence.shape}")
    delta = np.diff(sequence, axis=0)
    summaries: list[tuple[str, np.ndarray]] = [
        ("mean", np.mean(sequence, axis=0)),
        ("std", np.std(sequence, axis=0)),
        ("min", np.min(sequence, axis=0)),
        ("max", np.max(sequence, axis=0)),
        ("delta_abs_mean", np.mean(np.abs(delta), axis=0)),
        ("delta_abs_max", np.max(np.abs(delta), axis=0)),
        ("first", sequence[0]),
        ("last", sequence[-1]),
    ]
    for bin_index, indices in enumerate(np.array_split(np.arange(sequence.shape[0]), bins)):
        summaries.append((f"timebin_{bin_index}", np.mean(sequence[indices], axis=0)))

    output = np.concatenate([values for _, values in summaries]).astype(np.float32)
    names = [f"{summary_name}__{name}" for summary_name, _ in summaries for name in frame_names]
    return output, names


class LandmarkExtractor:
    def __init__(self, pose_model: Path, hand_model: Path, config: ExtractorConfig) -> None:
        base_options = mp.tasks.BaseOptions
        vision = mp.tasks.vision
        self.config = config
        self.pose = vision.PoseLandmarker.create_from_options(
            vision.PoseLandmarkerOptions(
                base_options=base_options(model_asset_path=str(pose_model)),
                running_mode=vision.RunningMode.IMAGE,
                num_poses=1,
                min_pose_detection_confidence=config.pose_detection_confidence,
                min_pose_presence_confidence=config.pose_detection_confidence,
                min_tracking_confidence=config.pose_detection_confidence,
                output_segmentation_masks=False,
            )
        )
        self.hand = vision.HandLandmarker.create_from_options(
            vision.HandLandmarkerOptions(
                base_options=base_options(model_asset_path=str(hand_model)),
                running_mode=vision.RunningMode.IMAGE,
                num_hands=2,
                min_hand_detection_confidence=config.hand_detection_confidence,
                min_hand_presence_confidence=config.hand_detection_confidence,
                min_tracking_confidence=config.hand_detection_confidence,
            )
        )

    def close(self) -> None:
        self.pose.close()
        self.hand.close()

    def extract(self, video_path: Path) -> tuple[np.ndarray, list[str]]:
        frame_vectors: list[np.ndarray] = []
        frame_names: list[str] | None = None
        for rgb in sampled_rgb_frames(video_path, self.config.sampled_frames):
            image = mp.Image(image_format=mp.ImageFormat.SRGB, data=np.ascontiguousarray(rgb))
            vector, current_names = frame_features(
                rgb,
                self.pose.detect(image),
                self.hand.detect(image),
            )
            if frame_names is None:
                frame_names = current_names
            elif current_names != frame_names:
                raise RuntimeError("Frame feature schema changed during extraction")
            frame_vectors.append(vector)
        assert frame_names is not None
        return temporal_summary(np.stack(frame_vectors), frame_names, self.config.temporal_bins)


def cache_matches(cache_path: Path, config: ExtractorConfig, clips: Sequence[tuple[Path, str]]) -> bool:
    if not cache_path.is_file():
        return False
    try:
        cache = np.load(cache_path, allow_pickle=False)
        expected_paths = np.asarray([str(path.resolve()) for path, _ in clips])
        return (
            str(cache["extractor_version"].item()) == EXTRACTOR_VERSION
            and str(cache["config_json"].item()) == json.dumps(asdict(config), sort_keys=True)
            and np.array_equal(cache["paths"], expected_paths)
        )
    except Exception:
        return False


def extract_dataset(
    clips: Sequence[tuple[Path, str]],
    models_dir: Path,
    output_dir: Path,
    config: ExtractorConfig,
    force: bool,
) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    cache_path = output_dir / "camera_features.npz"
    if not force and cache_matches(cache_path, config, clips):
        cache = np.load(cache_path, allow_pickle=False)
        print(f"Using cached features: {cache_path}", flush=True)
        return cache["X"], cache["y"], cache["paths"], cache["feature_names"]

    pose_model = models_dir / "pose_landmarker_lite.task"
    hand_model = models_dir / "hand_landmarker.task"
    require_file(pose_model, "Pose Landmarker model")
    require_file(hand_model, "Hand Landmarker model")

    extractor = LandmarkExtractor(pose_model, hand_model, config)
    X: list[np.ndarray] = []
    feature_names: list[str] | None = None
    started = time.monotonic()
    try:
        for index, (path, label) in enumerate(clips, start=1):
            vector, current_names = extractor.extract(path)
            if feature_names is None:
                feature_names = current_names
            elif feature_names != current_names:
                raise RuntimeError("Video feature schema mismatch")
            X.append(vector)
            elapsed = time.monotonic() - started
            eta = (elapsed / index) * (len(clips) - index)
            print(
                f"[{index:03d}/{len(clips):03d}] {label:<11} {path.name}  ETA {eta:5.0f}s",
                flush=True,
            )
    finally:
        extractor.close()

    assert feature_names is not None
    X_array = np.stack(X)
    y_array = np.asarray([label for _, label in clips])
    paths_array = np.asarray([str(path.resolve()) for path, _ in clips])
    names_array = np.asarray(feature_names)
    np.savez_compressed(
        cache_path,
        X=X_array,
        y=y_array,
        paths=paths_array,
        feature_names=names_array,
        extractor_version=np.asarray(EXTRACTOR_VERSION),
        config_json=np.asarray(json.dumps(asdict(config), sort_keys=True)),
    )
    print(f"Saved feature cache: {cache_path} ({X_array.shape[0]} x {X_array.shape[1]})", flush=True)
    return X_array, y_array, paths_array, names_array


def candidate_models(feature_count: int) -> dict[str, Pipeline]:
    selected = min(320, feature_count)
    return {
        "rbf_svc": Pipeline(
            [
                ("imputer", SimpleImputer(strategy="median")),
                ("scale", StandardScaler()),
                ("select", SelectKBest(score_func=f_classif, k=selected)),
                (
                    "model",
                    SVC(
                        C=4.0,
                        kernel="rbf",
                        gamma="scale",
                        class_weight="balanced",
                        probability=True,
                        random_state=RANDOM_SEED,
                    ),
                ),
            ]
        ),
        "extra_trees": Pipeline(
            [
                ("imputer", SimpleImputer(strategy="median")),
                (
                    "model",
                    ExtraTreesClassifier(
                        n_estimators=600,
                        max_features="sqrt",
                        min_samples_leaf=1,
                        class_weight="balanced",
                        random_state=RANDOM_SEED,
                        n_jobs=-1,
                    ),
                ),
            ]
        ),
        "random_forest": Pipeline(
            [
                ("imputer", SimpleImputer(strategy="median")),
                (
                    "model",
                    RandomForestClassifier(
                        n_estimators=600,
                        max_features="sqrt",
                        min_samples_leaf=1,
                        class_weight="balanced_subsample",
                        random_state=RANDOM_SEED,
                        n_jobs=-1,
                    ),
                ),
            ]
        ),
    }


def write_csv(path: Path, rows: Iterable[dict[str, object]], fieldnames: Sequence[str]) -> None:
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def save_confusion_figure(matrix: np.ndarray, labels: Sequence[str], path: Path) -> None:
    fig, ax = plt.subplots(figsize=(8.5, 7.0))
    image = ax.imshow(matrix, cmap="Blues")
    fig.colorbar(image, ax=ax, fraction=0.046, pad=0.04)
    ax.set(
        xticks=np.arange(len(labels)),
        yticks=np.arange(len(labels)),
        xticklabels=labels,
        yticklabels=labels,
        xlabel="Predicted label",
        ylabel="True label",
        title="5-fold cross-validation confusion matrix",
    )
    plt.setp(ax.get_xticklabels(), rotation=35, ha="right")
    threshold = matrix.max() / 2.0 if matrix.size else 0
    for row in range(matrix.shape[0]):
        for column in range(matrix.shape[1]):
            ax.text(
                column,
                row,
                str(matrix[row, column]),
                ha="center",
                va="center",
                color="white" if matrix[row, column] > threshold else "black",
            )
    fig.tight_layout()
    fig.savefig(path, dpi=170)
    plt.close(fig)


def train_and_evaluate(
    X: np.ndarray,
    y: np.ndarray,
    paths: np.ndarray,
    feature_names: np.ndarray,
    output_dir: Path,
    config: ExtractorConfig,
) -> None:
    labels = [label for label in DEFAULT_LABELS if label in set(y)]
    counts = {label: int(np.sum(y == label)) for label in labels}
    if min(counts.values()) < 5:
        raise ValueError(f"At least five clips per class are required for 5-fold CV: {counts}")

    cv = StratifiedKFold(n_splits=5, shuffle=True, random_state=RANDOM_SEED)
    comparison_rows: list[dict[str, object]] = []
    predictions: dict[str, np.ndarray] = {}
    for name, model in candidate_models(X.shape[1]).items():
        print(f"Evaluating {name} with 5-fold cross-validation...", flush=True)
        predicted = cross_val_predict(model, X, y, cv=cv, method="predict", n_jobs=1)
        predictions[name] = predicted
        comparison_rows.append(
            {
                "model": name,
                "accuracy": accuracy_score(y, predicted),
                "balanced_accuracy": balanced_accuracy_score(y, predicted),
                "macro_f1": f1_score(y, predicted, average="macro"),
            }
        )

    comparison_rows.sort(key=lambda row: float(row["macro_f1"]), reverse=True)
    best_name = str(comparison_rows[0]["model"])
    best_predictions = predictions[best_name]
    print(
        f"Best model: {best_name} | accuracy={comparison_rows[0]['accuracy']:.3f} "
        f"macro_f1={comparison_rows[0]['macro_f1']:.3f}",
        flush=True,
    )

    write_csv(
        output_dir / "model_comparison.csv",
        comparison_rows,
        ("model", "accuracy", "balanced_accuracy", "macro_f1"),
    )
    write_csv(
        output_dir / "cv_predictions.csv",
        (
            {
                "video": str(path),
                "true_label": truth,
                "predicted_label": prediction,
                "correct": truth == prediction,
            }
            for path, truth, prediction in zip(paths, y, best_predictions)
        ),
        ("video", "true_label", "predicted_label", "correct"),
    )

    report = classification_report(
        y,
        best_predictions,
        labels=labels,
        output_dict=True,
        zero_division=0,
    )
    report_rows = []
    for label, metrics in report.items():
        if isinstance(metrics, dict):
            report_rows.append(
                {
                    "label": label,
                    "precision": metrics.get("precision", 0.0),
                    "recall": metrics.get("recall", 0.0),
                    "f1_score": metrics.get("f1-score", 0.0),
                    "support": metrics.get("support", 0.0),
                }
            )
    write_csv(
        output_dir / "classification_report.csv",
        report_rows,
        ("label", "precision", "recall", "f1_score", "support"),
    )

    matrix = confusion_matrix(y, best_predictions, labels=labels)
    with (output_dir / "confusion_matrix.csv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(["true\\predicted", *labels])
        for label, row in zip(labels, matrix):
            writer.writerow([label, *row.tolist()])
    save_confusion_figure(matrix, labels, output_dir / "confusion_matrix.png")

    final_model = clone(candidate_models(X.shape[1])[best_name])
    final_model.fit(X, y)
    artifact = {
        "pipeline": final_model,
        "labels": labels,
        "feature_names": feature_names.tolist(),
        "extractor_version": EXTRACTOR_VERSION,
        "extractor_config": asdict(config),
        "safety_semantics": (
            "TAKE means an ingestion-like visible action was detected; it does not confirm "
            "that medication was swallowed."
        ),
    }
    joblib.dump(artifact, output_dir / "camera_action_model.joblib", compress=3)

    misclassified = int(np.sum(y != best_predictions))
    summary = {
        "created_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "extractor_version": EXTRACTOR_VERSION,
        "extractor_config": asdict(config),
        "clip_count": int(len(y)),
        "class_counts": counts,
        "feature_count": int(X.shape[1]),
        "evaluation": "Stratified 5-fold cross-validation on one participant/session",
        "best_model": best_name,
        "accuracy": float(accuracy_score(y, best_predictions)),
        "balanced_accuracy": float(balanced_accuracy_score(y, best_predictions)),
        "macro_f1": float(f1_score(y, best_predictions, average="macro")),
        "misclassified_clips": misclassified,
        "limitations": [
            "All current clips come from one participant and one recording session.",
            "Cross-validation estimates same-person/same-setup performance only.",
            "TAKE is an ingestion-like visual action, not medical confirmation.",
        ],
    }
    (output_dir / "training_summary.json").write_text(
        json.dumps(summary, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(summary, indent=2, ensure_ascii=False), flush=True)


def main() -> int:
    args = parse_args()
    if args.sampled_frames < 8:
        raise ValueError("--sampled-frames must be at least 8")
    config = ExtractorConfig(sampled_frames=args.sampled_frames)
    args.output.mkdir(parents=True, exist_ok=True)
    clips = discover_clips(args.dataset.resolve(), args.quick_check)
    print(f"Dataset: {args.dataset.resolve()} | clips={len(clips)}", flush=True)
    X, y, paths, feature_names = extract_dataset(
        clips,
        args.models_dir.resolve(),
        args.output.resolve(),
        config,
        args.force_extract,
    )
    if args.quick_check:
        print(
            f"QUICK_CHECK_OK clips={len(y)} feature_shape={X.shape} finite={bool(np.isfinite(X).all())}",
            flush=True,
        )
        return 0
    train_and_evaluate(X, y, paths, feature_names, args.output.resolve(), config)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("Cancelled.", file=sys.stderr)
        raise SystemExit(130)
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise
