# MedBox camera action baseline

This folder trains a small action classifier from the videos in the repository's
`camera_data/` directory.
It uses MediaPipe Pose and Hand landmarks plus a classical classifier, so it is
appropriate for the current small dataset. The legacy live runner works on the Mac,
and the same landmark pipeline plus classifier are now exported for iPhone use.

## Run

```bash
cd /path/to/smart-medication-monitor
python3 -m venv .venv-camera-ai
./.venv-camera-ai/bin/python -m pip install -r inference/camera/requirements.txt
bash inference/camera/download_models.sh
./.venv-camera-ai/bin/python inference/camera/train_camera_action_model.py
```

Use `--force-extract` only when the clips or feature extractor changed. Otherwise
the script reuses `inference/camera/output/camera_features.npz`.

The model download script uses the official Google MediaPipe model storage. The
downloaded `.task` files, trained outputs, virtual environment, and raw camera
videos are intentionally excluded from Git.

## Outputs

- `camera_action_model.joblib`: fitted pipeline
- `training_summary.json`: headline metrics and limitations
- `model_comparison.csv`: candidate model comparison
- `classification_report.csv`: per-label precision/recall/F1
- `cv_predictions.csv`: per-video cross-validation predictions
- `confusion_matrix.csv` and `.png`: confusion details

## Export the on-device iPhone classifier

`export_coreml_action_model.py` trains the validated Extra Trees configuration from
the finite feature cache, writes a Core ML tree ensemble with one 2,576-value input,
and verifies labels/probabilities against scikit-learn on macOS. The checked-in
`coreml_export_report.json` records the latest parity result.

```bash
python3 -m venv /tmp/medbox-coreml-venv
/tmp/medbox-coreml-venv/bin/pip install 'numpy<2' 'scikit-learn==1.5.1' \
  'coremltools==8.3.0' joblib
/tmp/medbox-coreml-venv/bin/python \
  inference/camera/export_coreml_action_model.py \
  --features inference/camera/output/camera_features.npz
```

The iOS target also bundles the exact Pose and Hand `.task` assets used to create
the feature cache. Google requires the `MediaPipeTasksVision` CocoaPod on iOS; run
`pod install` in `app/MedBoxApp` and build `MedBoxApp.xcworkspace`.

## Live ESP32 inference

1. Upload and run the combined `MedBox_LiveTrain_AI.ino` firmware on the ESP32.
2. Connect the Mac to the `MedBox-Camera-Test` Wi-Fi network.
3. Close the camera page on every phone/browser because the current stream supports
   one client at a time.
4. Run:

```bash
cd /path/to/smart-medication-monitor
MPLCONFIGDIR=/tmp/medbox-matplotlib \
  ./.venv-camera-ai/bin/python inference/camera/live_camera_action.py
```

The preview takes about five seconds to fill its first rolling window, then updates
the prediction roughly once per second. Press `q` or Escape to stop. The script does
not save frames. Stable results are also sent automatically to `192.168.4.1:4210`
as `VISION|action|confidence`; the combined firmware forwards them to the iPhone
over BLE as `V|event_id|action|confidence`. Use `--no-esp-forward` for local-only
testing.

The current live calibration uses a 40% confidence threshold and one stable vote,
which was checked against the recorded positive and negative actions. These are
prototype settings and should be revalidated if the camera position changes.

To test a saved clip without the ESP32, run:

```bash
MPLCONFIGDIR=/tmp/medbox-matplotlib \
  ./.venv-camera-ai/bin/python inference/camera/live_camera_action.py \
  --video camera_data/TAKE/SESSION/CLIP.mp4 --headless
```

## Interpretation and safety

`TAKE` means that the camera detected an ingestion-like visible action. It does
not prove that medication was swallowed. The current dataset contains one person
and one recording session, so its metrics estimate only same-person/same-camera
performance. Combine camera output with weight evidence in the final system and
describe the result as likely supported by multiple signals, not medically confirmed.
