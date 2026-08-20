# Machine-Learning Pipeline

## Design

The classifier is intentionally hierarchical because final static weight is reliable for quantity-like outcomes, while temporal features are needed to distinguish near-zero outcomes.

```text
EVENT_END and samples
        ↓
ratio = final_delta / pill_weight
        ↓
┌───────────────────────────────────────┐
│ |ratio| < 0.30       → Dynamic RF     │
│ 0.50 ≤ ratio < 1.50 → ONE            │
│ 1.50 ≤ ratio < 2.50 → TWO            │
│ otherwise            → UNCERTAIN      │
└───────────────────────────────────────┘
        ↓
Dynamic RF: NONE / RETURN / DISTURBANCE
```

The intervals `(0.30, 0.50)` and values outside the supported bands are deliberately uncertain. The model must not be modified merely to eliminate these gaps.

## Dynamic features

The dynamic Random Forest does not use final static delta as its primary distinguishing feature. Its configured features cover:

- signal range, standard deviation, rise, drop, and absolute deviation;
- time to extrema and event duration;
- maximum/mean/standard-deviation step sizes and change counts;
- fraction, longest run, and episodes below baseline;
- start/end statistics;
- absolute and signed area;
- sample count.

The exact ordered list is stored in `model/hierarchical_model_config.json`. Feature order must remain aligned with the frozen joblib model.

## Training and runtime artifacts

- Training/evaluation entry point: `experiments/hierarchical_model.py`
- Frozen dynamic classifier: `model/hierarchical_dynamic_rf.joblib`
- Runtime configuration: `model/hierarchical_model_config.json`
- Active real-time runner: `inference/realtime_inference_ble.py`
- ESP32 exporter: `inference/weight/export_esp32_weight_model.py`
- ESP32 runtime: `firmware/esp32/MedBox_LiveTrain_AI/weight_inference.h`
- Generated forest: `firmware/esp32/MedBox_LiveTrain_AI/weight_model_generated.h`

The model was trained on the 60 near-zero events from both real rounds: `NONE`, `RETURN`, and `DISTURBANCE`. ONE and TWO remain deterministic Stage-1 decisions.

The persisted estimator records scikit-learn 1.8.0. `inference/requirements.txt` pins that version because joblib estimators are not guaranteed to be compatible across scikit-learn releases.

## ESP32 deployment

The frozen 500-tree dynamic forest contains 3,174 nodes and is exported without
retraining. The ESP32 buffers at most 64 event samples, recreates the same ordered
24 features, applies the unchanged Stage-1 uncertainty gaps, and averages the same
per-leaf class probabilities. Export metadata and hashes are stored in
`inference/weight/esp32_export_report.json`.

The host C++ verifier exercises the exact header-only runtime used by Arduino.
Round 1, Round 2, and synthetic Round 3 provide 150 regression events; all labels
must match the frozen Python pipeline before deployment. This is implementation
parity and pipeline verification, not new independent model validation.

## RETURN semantics

RETURN should represent a sustained lower-weight state followed by restoration near baseline. A short pressure spike alone is not the intended behavior. Round 2 deliberately introduced greater behavioral variation, exposing limitations when a dynamic RF trained only on Round 1 encountered light disturbances.

## Reproducibility and changes

Run the training script only when intentionally regenerating the complete Round 2 evaluation bundle. It overwrites files in `results/round2/`. Preserve the existing bundle or commit it before retraining.

Any change to feature extraction, thresholds, model, or feature order requires regression tests and a new documented model version. Do not tune after viewing a blind-test label set and continue calling it blind validation.
