#!/usr/bin/env python3
"""Run the trained MedBox camera action model on an ESP32 MJPEG stream.

TAKE is an ingestion-like visible action only. It is never proof that medication
was swallowed.
"""

from __future__ import annotations

import argparse
import json
import socket
import sys
import time
from collections import Counter, deque
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence

import cv2
import joblib
import mediapipe as mp
import numpy as np

from train_camera_action_model import (
    ExtractorConfig,
    LandmarkExtractor,
    frame_features,
    temporal_summary,
)
from vision_protocol import encode_vision_message


DEFAULT_STREAM_URL = "http://192.168.4.1/stream"
SAFETY_TEXT = "TAKE-like visual action only - ingestion is not confirmed"
DISPLAY_NAMES = {
    "TAKE": "TAKE-like action",
    "DRINK": "DRINK",
    "TOUCH_FACE": "TOUCH FACE",
    "ADJUST": "ADJUST HAIR/CLOTHING",
    "PICK_ONLY": "PICK ONLY",
    "NONE": "NO TARGET ACTION",
    "UNCERTAIN": "UNCERTAIN",
}


@dataclass(frozen=True)
class Prediction:
    label: str
    confidence: float
    probabilities: dict[str, float]


def parse_args() -> argparse.Namespace:
    camera_ai_dir = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(
        description="Run rolling-window inference on the MedBox ESP32 camera stream."
    )
    source = parser.add_mutually_exclusive_group()
    source.add_argument(
        "--url",
        default=DEFAULT_STREAM_URL,
        help=f"ESP32 MJPEG URL (default: {DEFAULT_STREAM_URL})",
    )
    source.add_argument(
        "--video",
        type=Path,
        help="Classify one saved MP4 instead of opening the live stream",
    )
    parser.add_argument(
        "--model",
        type=Path,
        default=camera_ai_dir / "output" / "camera_action_model.joblib",
    )
    parser.add_argument("--models-dir", type=Path, default=camera_ai_dir / "models")
    parser.add_argument(
        "--window-seconds",
        type=float,
        default=5.0,
        help="Approximate live action window duration",
    )
    parser.add_argument(
        "--predict-every",
        type=float,
        default=1.0,
        help="Seconds between rolling-window predictions",
    )
    parser.add_argument(
        "--threshold",
        type=float,
        default=0.40,
        help="Minimum smoothed confidence for a stable label",
    )
    parser.add_argument(
        "--stability-votes",
        type=int,
        default=1,
        help="Matching predictions required among the latest three",
    )
    parser.add_argument(
        "--esp-host",
        default="192.168.4.1",
        help="ESP32 camera AP address used for vision-result forwarding",
    )
    parser.add_argument(
        "--esp-port",
        type=int,
        default=4210,
        help="ESP32 UDP port used for vision-result forwarding",
    )
    parser.add_argument(
        "--no-esp-forward",
        action="store_true",
        help="Disable Mac-to-ESP32 UDP forwarding and show predictions locally only",
    )
    parser.add_argument(
        "--headless",
        action="store_true",
        help="Print predictions without opening the preview window",
    )
    parser.add_argument(
        "--event-log",
        type=Path,
        help="Optional JSONL label log; frames are never saved",
    )
    parser.add_argument(
        "--max-seconds",
        type=float,
        default=0.0,
        help="Stop a live test after this many seconds; 0 means no limit",
    )
    return parser.parse_args()


def require_artifact(path: Path, description: str, minimum_size: int = 1) -> None:
    if not path.is_file() or path.stat().st_size < minimum_size:
        raise FileNotFoundError(f"Missing or incomplete {description}: {path}")


class CameraActionPredictor:
    def __init__(self, artifact_path: Path, models_dir: Path) -> None:
        require_artifact(artifact_path, "trained action model", 10_000)
        pose_model = models_dir / "pose_landmarker_lite.task"
        hand_model = models_dir / "hand_landmarker.task"
        require_artifact(pose_model, "Pose Landmarker model", 100_000)
        require_artifact(hand_model, "Hand Landmarker model", 100_000)

        artifact = joblib.load(artifact_path)
        required_keys = {
            "pipeline",
            "labels",
            "feature_names",
            "extractor_version",
            "extractor_config",
            "safety_semantics",
        }
        missing = required_keys.difference(artifact)
        if missing:
            raise ValueError(f"Model artifact is missing keys: {sorted(missing)}")

        self.pipeline = artifact["pipeline"]
        self.labels = list(artifact["labels"])
        self.expected_feature_names = list(artifact["feature_names"])
        self.safety_semantics = str(artifact["safety_semantics"])
        self.config = ExtractorConfig(**artifact["extractor_config"])
        self.extractor = LandmarkExtractor(pose_model, hand_model, self.config)

        if not hasattr(self.pipeline, "predict_proba"):
            raise TypeError("The trained pipeline does not expose predict_proba().")

    def close(self) -> None:
        self.extractor.close()

    def extract_frame(self, bgr: np.ndarray) -> tuple[np.ndarray, list[str]]:
        rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
        image = mp.Image(image_format=mp.ImageFormat.SRGB, data=np.ascontiguousarray(rgb))
        return frame_features(
            rgb,
            self.extractor.pose.detect(image),
            self.extractor.hand.detect(image),
        )

    def predict_feature_vector(self, vector: np.ndarray, names: Sequence[str]) -> Prediction:
        if list(names) != self.expected_feature_names:
            raise ValueError(
                "Live feature schema does not match the trained model. "
                "Retrain or use the matching script/model pair."
            )
        probabilities = self.pipeline.predict_proba(vector.reshape(1, -1))[0]
        classes = [str(value) for value in self.pipeline.classes_]
        probability_map = {label: float(value) for label, value in zip(classes, probabilities)}
        best_index = int(np.argmax(probabilities))
        return Prediction(classes[best_index], float(probabilities[best_index]), probability_map)

    def predict_sequence(
        self, sequence: np.ndarray, frame_names: Sequence[str]
    ) -> Prediction:
        vector, names = temporal_summary(sequence, frame_names, self.config.temporal_bins)
        return self.predict_feature_vector(vector, names)

    def predict_video(self, video_path: Path) -> Prediction:
        require_artifact(video_path, "test video", 1_000)
        vector, names = self.extractor.extract(video_path)
        return self.predict_feature_vector(vector, names)


def prediction_payload(
    prediction: Prediction,
    stable_label: str | None = None,
    stable_confidence: float | None = None,
) -> dict[str, object]:
    label = stable_label or prediction.label
    confidence = prediction.confidence if stable_confidence is None else stable_confidence
    payload: dict[str, object] = {
        "timestamp_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "label": label,
        "confidence": round(float(confidence), 4),
        "raw_label": prediction.label,
        "raw_confidence": round(prediction.confidence, 4),
        "probabilities": {
            key: round(value, 4)
            for key, value in sorted(prediction.probabilities.items())
        },
    }
    if label == "TAKE":
        payload["meaning"] = SAFETY_TEXT
    return payload


def stable_prediction(
    history: Sequence[Prediction], threshold: float, required_votes: int
) -> tuple[str, float]:
    if not history:
        return "UNCERTAIN", 0.0
    counts = Counter(item.label for item in history)
    label, votes = counts.most_common(1)[0]
    matching = [item.confidence for item in history if item.label == label]
    confidence = float(np.mean(matching))
    if votes < required_votes or confidence < threshold:
        return "UNCERTAIN", confidence
    return label, confidence


def draw_status(
    frame: np.ndarray,
    stable_label: str,
    stable_confidence: float,
    sample_count: int,
    required_samples: int,
    source_fps: float,
) -> np.ndarray:
    output = frame.copy()
    overlay = output.copy()
    cv2.rectangle(overlay, (0, 0), (output.shape[1], 126), (15, 15, 15), -1)
    cv2.addWeighted(overlay, 0.75, output, 0.25, 0, output)

    if sample_count < required_samples:
        headline = f"Warming up: {sample_count}/{required_samples} samples"
        color = (0, 215, 255)
    else:
        headline = DISPLAY_NAMES.get(stable_label, stable_label)
        color = (70, 220, 70) if stable_label != "UNCERTAIN" else (0, 190, 255)
    cv2.putText(output, headline, (18, 35), cv2.FONT_HERSHEY_SIMPLEX, 0.78, color, 2)
    cv2.putText(
        output,
        f"confidence {stable_confidence:.0%} | stream {source_fps:.1f} FPS",
        (18, 66),
        cv2.FONT_HERSHEY_SIMPLEX,
        0.55,
        (230, 230, 230),
        1,
    )
    cv2.putText(
        output,
        "Rolling 5 s window | q or Esc to quit",
        (18, 93),
        cv2.FONT_HERSHEY_SIMPLEX,
        0.50,
        (205, 205, 205),
        1,
    )
    if stable_label == "TAKE":
        cv2.putText(
            output,
            SAFETY_TEXT,
            (18, 119),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.40,
            (0, 210, 255),
            1,
        )
    return output


def append_event(path: Path | None, payload: dict[str, object]) -> None:
    if path is None:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(payload, ensure_ascii=False) + "\n")


def send_vision_udp(
    udp_socket: socket.socket,
    host: str,
    port: int,
    label: str,
    confidence: float,
) -> bool:
    message = encode_vision_message(label, confidence)
    try:
        sent = udp_socket.sendto(message, (host, port))
    except OSError as exc:
        print(f"VISION_UDP_ERROR|{exc}", file=sys.stderr, flush=True)
        return False
    if sent != len(message):
        print(f"VISION_UDP_ERROR|short_write={sent}/{len(message)}", file=sys.stderr, flush=True)
        return False
    print(f"VISION_UDP_SENT|{host}:{port}|{label}|{confidence:.3f}", flush=True)
    return True


def open_stream(url: str) -> cv2.VideoCapture:
    cap = cv2.VideoCapture()
    if hasattr(cv2, "CAP_PROP_OPEN_TIMEOUT_MSEC"):
        cap.set(cv2.CAP_PROP_OPEN_TIMEOUT_MSEC, 7_000)
    if hasattr(cv2, "CAP_PROP_READ_TIMEOUT_MSEC"):
        cap.set(cv2.CAP_PROP_READ_TIMEOUT_MSEC, 7_000)
    if not cap.open(url):
        cap.release()
        raise ConnectionError(
            f"Cannot open {url}. Connect the Mac to MedBox-Camera-Test, keep the ESP32 "
            "camera sketch running, and close every browser/phone stream first."
        )
    return cap


def run_live(args: argparse.Namespace, predictor: CameraActionPredictor) -> None:
    if not 0.0 < args.threshold <= 1.0:
        raise ValueError("--threshold must be between 0 and 1")
    if args.stability_votes not in (1, 2, 3):
        raise ValueError("--stability-votes must be 1, 2, or 3")
    if args.window_seconds <= 0 or args.predict_every <= 0:
        raise ValueError("Window and prediction intervals must be positive")
    if not 1 <= args.esp_port <= 65535:
        raise ValueError("--esp-port must be between 1 and 65535")

    cap = open_stream(args.url)
    udp_socket = None if args.no_esp_forward else socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    required_samples = predictor.config.sampled_frames
    sample_interval = args.window_seconds / required_samples
    samples: deque[np.ndarray] = deque(maxlen=required_samples)
    history: deque[Prediction] = deque(maxlen=3)
    frame_names: list[str] | None = None
    stable_label = "UNCERTAIN"
    stable_confidence = 0.0
    last_emitted_label: str | None = None
    started = time.monotonic()
    next_sample_at = started
    last_predict_at = started - args.predict_every
    displayed_frames = 0
    fps_started = started

    print(f"Connected: {args.url}", flush=True)
    print(
        f"Warming up a {args.window_seconds:.1f}s window ({required_samples} landmark samples)...",
        flush=True,
    )
    try:
        while True:
            ok, bgr = cap.read()
            if not ok or bgr is None:
                raise ConnectionError(
                    "Camera stream stopped. Reset the ESP32 and make sure no second client "
                    "opened /stream."
                )

            now = time.monotonic()
            displayed_frames += 1
            elapsed_for_fps = max(now - fps_started, 1e-6)
            source_fps = displayed_frames / elapsed_for_fps

            if now >= next_sample_at:
                vector, current_names = predictor.extract_frame(bgr)
                if frame_names is None:
                    frame_names = current_names
                elif current_names != frame_names:
                    raise RuntimeError("Live frame feature schema changed")
                samples.append(vector)
                next_sample_at = now + sample_interval

            if (
                len(samples) == required_samples
                and frame_names is not None
                and now - last_predict_at >= args.predict_every
            ):
                raw = predictor.predict_sequence(np.stack(samples), frame_names)
                history.append(raw)
                stable_label, stable_confidence = stable_prediction(
                    history, args.threshold, args.stability_votes
                )
                payload = prediction_payload(raw, stable_label, stable_confidence)
                print(json.dumps(payload, ensure_ascii=False), flush=True)
                if stable_label != "UNCERTAIN" and stable_label != last_emitted_label:
                    append_event(args.event_log, payload)
                    if udp_socket is not None:
                        send_vision_udp(
                            udp_socket,
                            args.esp_host,
                            args.esp_port,
                            stable_label,
                            stable_confidence,
                        )
                    last_emitted_label = stable_label
                last_predict_at = now

            if not args.headless:
                preview = draw_status(
                    bgr,
                    stable_label,
                    stable_confidence,
                    len(samples),
                    required_samples,
                    source_fps,
                )
                cv2.imshow("MedBox Camera Action - live", preview)
                key = cv2.waitKey(1) & 0xFF
                if key in (ord("q"), 27):
                    break

            if args.max_seconds > 0 and now - started >= args.max_seconds:
                break
    finally:
        cap.release()
        if udp_socket is not None:
            udp_socket.close()
        if not args.headless:
            cv2.destroyAllWindows()


def main() -> int:
    args = parse_args()
    predictor = CameraActionPredictor(args.model.resolve(), args.models_dir.resolve())
    try:
        if args.video is not None:
            result = predictor.predict_video(args.video.resolve())
            print(json.dumps(prediction_payload(result), indent=2, ensure_ascii=False))
        else:
            run_live(args, predictor)
    finally:
        predictor.close()
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("Stopped.", file=sys.stderr)
        raise SystemExit(130)
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
