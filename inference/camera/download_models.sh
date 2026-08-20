#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
model_dir="$script_dir/models"
mkdir -p "$model_dir"

curl -L --fail --retry 3 \
  "https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_lite/float16/1/pose_landmarker_lite.task" \
  -o "$model_dir/pose_landmarker_lite.task"

curl -L --fail --retry 3 \
  "https://storage.googleapis.com/mediapipe-models/hand_landmarker/hand_landmarker/float16/1/hand_landmarker.task" \
  -o "$model_dir/hand_landmarker.task"

openssl dgst -sha256 \
  "$model_dir/pose_landmarker_lite.task" \
  "$model_dir/hand_landmarker.task"
