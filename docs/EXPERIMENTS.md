# Experiments

## Dataset inventory

| Dataset | Origin | Events | Class balance |
| --- | --- | ---: | --- |
| Round 1 | Real prototype session | 50 | 10 each: NONE, ONE, TWO, RETURN, DISTURBANCE |
| Round 2 | Real prototype session with greater variation | 50 | 10 each |
| Synthetic Round 3 | Perturbed templates derived from Rounds 1–2 | 50 | 10 each |

Each dataset contains an event table, sample table, and raw serial log. No participant clinical data is represented; washers were principally used as mock medication units.

## Results

### Cross-session experimental holdout

Training on Round 1 and testing on Round 2:

- Flat five-class Random Forest: 74%.
- Hierarchical pipeline: 82%.

The hierarchical gate protected ONE/TWO quantity decisions from large pressure disturbances. Nine Round 2 `DISTURBANCE` events remained confused with `NONE` or `RETURN`, demonstrating that the small dynamic training set did not cover all light-disturbance behavior.

This is a useful cross-session prototype test, but it is not clinical validation and should not be generalized to users, medications, devices, or environments not represented here.

### Combined internal cross-validation

Five-fold cross-validation across all 100 real events produced 100% accuracy. Because both sessions participate in the folds and the dataset is small, this is described only as **internal separability/cross-validation**, not independent real-world validation.

### Synthetic stress test

Synthetic Round 3 uses time warping, amplitude scaling, baseline randomization, noise, drift, and endpoint perturbation applied to observed signal templates. The frozen hierarchical pipeline classified 50/50 events.

This verifies pipeline execution and stress-tests behavior around observed patterns. It is expected to be optimistic because its templates derive from the same two rounds used to develop the model. It is not independent generalisation evidence.

## Artifact map

- Raw real data: `data/round1/`, `data/round2/`
- Synthetic data: `data/synthetic_round3/`
- Cross-session and internal-CV artifacts: `results/round2/`
- Synthetic stress-test artifacts: `results/synthetic_round3/`
- Training/evaluation script: `experiments/hierarchical_model.py`

The joblib and JSON files inside `results/round2/` are preserved members of the original result bundle. Byte-identical canonical runtime copies are located in `model/`.

## Runtime demonstration evidence

The supplied temporary session `session_20260812_104322` recorded a LIVE configuration, an `EVENT_END`, `LIVE_READY`, and the USB receipt of `AI_RESULT|1|ONE|0.533`. Runtime sessions are intentionally excluded from Git because they are generated serial logs; this observation is retained in the migration audit.

## Reporting language

Acceptable: medication removed, medication event detected, interaction detected, internal cross-validation, synthetic pipeline verification.

Not acceptable: guaranteed ingestion, medically verified dose, clinical diagnosis, 100% real-world accuracy, independently validated synthetic result.

