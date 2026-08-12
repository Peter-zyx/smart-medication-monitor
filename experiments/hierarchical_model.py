from pathlib import Path
import json

import joblib
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

from sklearn.ensemble import RandomForestClassifier
from sklearn.metrics import (
    accuracy_score,
    classification_report,
    confusion_matrix,
    ConfusionMatrixDisplay,
)
from sklearn.model_selection import StratifiedKFold, cross_val_predict


# ============================================================
# PROJECT PATHS
# ============================================================

PROJECT_DIR = Path(__file__).resolve().parents[1]

ROUND1_EVENTS = PROJECT_DIR / "data" / "round1" / "events.csv"
ROUND1_SAMPLES = PROJECT_DIR / "data" / "round1" / "samples.csv"

ROUND2_EVENTS = PROJECT_DIR / "data" / "round2" / "events.csv"
ROUND2_SAMPLES = PROJECT_DIR / "data" / "round2" / "samples.csv"

RESULT_DIR = PROJECT_DIR / "results" / "round2"
RESULT_DIR.mkdir(parents=True, exist_ok=True)


# ============================================================
# MODEL CONFIG
# ============================================================

# Current learned mock-pill weight.
# Change this if LEARN produces a different pill weight later.
PILL_WEIGHT_G = 0.848

# Stage-1 ratio rules.
# ratio = final_delta_g / PILL_WEIGHT_G
ZERO_RATIO_MAX = 0.30

ONE_RATIO_MIN = 0.50
ONE_RATIO_MAX = 1.50

TWO_RATIO_MIN = 1.50
TWO_RATIO_MAX = 2.50

# Feature-extraction settings.
CHANGE_THRESHOLD_SMALL = 0.5
CHANGE_THRESHOLD_MEDIUM = 2.0
CHANGE_THRESHOLD_LARGE = 5.0

BELOW_BASELINE_THRESHOLD = 0.4
END_WINDOW = 10

LABELS = [
    "NONE",
    "ONE",
    "TWO",
    "RETURN",
    "DISTURBANCE",
]

ZERO_DELTA_CLASSES = [
    "NONE",
    "RETURN",
    "DISTURBANCE",
]


# ============================================================
# FEATURES
# ============================================================

# Dynamic RF deliberately does NOT use final_delta_g.
# Stage 1 already uses final weight change to classify ONE/TWO.
DYNAMIC_FEATURES = [
    "weight_range_g",
    "std_weight_g",
    "max_rise_from_baseline_g",
    "max_drop_from_baseline_g",
    "max_abs_deviation_g",
    "time_to_max_ms",
    "time_to_min_ms",
    "duration_ms",
    "max_step_up_g",
    "max_step_down_g",
    "mean_abs_step_g",
    "std_step_g",
    "n_change_ge_0_5g",
    "n_change_ge_2g",
    "n_change_ge_5g",
    "fraction_below_baseline_minus_0_4g",
    "longest_below_points",
    "below_episode_count",
    "start_mean_delta_g",
    "start_std_g",
    "end_std_g",
    "abs_area_g_ms",
    "signed_area_g_ms",
    "n_samples",
]

# Flat RF comparison feature set.
FLAT_FEATURES = [
    "final_delta_g",
    *DYNAMIC_FEATURES,
    "end_mean_delta_g",
]


# ============================================================
# FEATURE EXTRACTION HELPERS
# ============================================================

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
    # Compatible with both newer and older NumPy releases.
    if hasattr(np, "trapezoid"):
        return np.trapezoid(y, x)

    return np.trapz(y, x)


def extract_features(events_file, samples_file, round_name):
    events = pd.read_csv(events_file)
    samples = pd.read_csv(samples_file)

    rows = []

    for _, event_row in events.iterrows():
        event_id = int(event_row["event_id"])

        event_samples = (
            samples[
                samples["event_id"] == event_id
            ]
            .sort_values("time_ms")
            .copy()
        )

        if len(event_samples) == 0:
            raise ValueError(
                f"{round_name} Event {event_id} has no samples."
            )

        before = float(event_row["before_g"])
        after = float(event_row["after_g"])
        removed = float(event_row["removed_g"])

        t = event_samples["time_ms"].to_numpy(dtype=float)
        w = event_samples["weight_g"].to_numpy(dtype=float)

        rel = w - before
        diff = np.diff(w)

        max_w = float(np.max(w))
        min_w = float(np.min(w))

        idx_max = int(np.argmax(w))
        idx_min = int(np.argmin(w))

        below_mask = (
            w <=
            (before - BELOW_BASELINE_THRESHOLD)
        )

        n_end = min(END_WINDOW, len(w))

        start_w = w[:n_end]
        end_w = w[-n_end:]

        if len(diff) > 0:
            max_step_up = float(np.max(diff))
            max_step_down = float(np.min(diff))
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

        else:
            abs_area = 0.0
            signed_area = 0.0

        rows.append({
            "round": round_name,
            "sample_uid": f"{round_name}-E{event_id}",
            "event_id": event_id,
            "label": str(event_row["label"]),

            "before_g": before,
            "after_g": after,
            "final_delta_g": removed,

            "weight_range_g": float(
                max_w - min_w
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

            "duration_ms": float(
                t[-1] - t[0]
            ) if len(t) > 1 else 0.0,

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
                before -
                np.mean(start_w)
            ),

            "start_std_g": float(
                np.std(start_w)
            ),

            "end_mean_delta_g": float(
                before -
                np.mean(end_w)
            ),

            "end_std_g": float(
                np.std(end_w)
            ),

            "abs_area_g_ms": abs_area,
            "signed_area_g_ms": signed_area,

            "n_samples": int(len(w)),
        })

    return pd.DataFrame(rows)


# ============================================================
# MODEL
# ============================================================

def make_rf():
    return RandomForestClassifier(
        n_estimators=500,
        random_state=42,
        class_weight="balanced",
        max_features="sqrt",
        min_samples_leaf=1,
        n_jobs=-1,
    )


def stage1_route(final_delta_g):
    ratio = (
        final_delta_g /
        PILL_WEIGHT_G
    )

    if abs(ratio) < ZERO_RATIO_MAX:
        return (
            "DYNAMIC_RF",
            None,
            ratio,
        )

    if (
        ONE_RATIO_MIN <= ratio <
        ONE_RATIO_MAX
    ):
        return (
            "STATIC_WEIGHT",
            "ONE",
            ratio,
        )

    if (
        TWO_RATIO_MIN <= ratio <
        TWO_RATIO_MAX
    ):
        return (
            "STATIC_WEIGHT",
            "TWO",
            ratio,
        )

    return (
        "UNCERTAIN",
        "UNCERTAIN",
        ratio,
    )


def hierarchical_predict_dataframe(
    dataframe,
    dynamic_model,
):
    rows = []

    for _, row in dataframe.iterrows():
        stage, static_prediction, ratio = (
            stage1_route(
                float(
                    row["final_delta_g"]
                )
            )
        )

        if stage == "DYNAMIC_RF":
            x = pd.DataFrame([
                row[
                    DYNAMIC_FEATURES
                ].to_dict()
            ])

            prediction = (
                dynamic_model
                .predict(x)[0]
            )

        else:
            prediction = static_prediction

        rows.append({
            "round": row["round"],
            "sample_uid": row["sample_uid"],
            "event_id": int(row["event_id"]),
            "label": row["label"],
            "final_delta_g": float(
                row["final_delta_g"]
            ),
            "pill_ratio": ratio,
            "stage": stage,
            "prediction": prediction,
            "correct": (
                prediction ==
                row["label"]
            ),
        })

    return pd.DataFrame(rows)


# ============================================================
# OUTPUT HELPERS
# ============================================================

def save_confusion_matrix(
    y_true,
    y_pred,
    title,
    output_path,
):
    display_labels = (
        LABELS +
        ["UNCERTAIN"]
    )

    cm = confusion_matrix(
        y_true,
        y_pred,
        labels=display_labels,
    )

    fig, ax = plt.subplots(
        figsize=(8.5, 7.5)
    )

    disp = ConfusionMatrixDisplay(
        confusion_matrix=cm,
        display_labels=display_labels,
    )

    disp.plot(
        ax=ax,
        values_format="d",
    )

    ax.set_title(title)

    fig.tight_layout()

    fig.savefig(
        output_path,
        dpi=200,
        bbox_inches="tight",
    )

    plt.close(fig)


def save_report(
    y_true,
    y_pred,
    output_path,
):
    report = classification_report(
        y_true,
        y_pred,
        labels=LABELS,
        output_dict=True,
        zero_division=0,
    )

    (
        pd.DataFrame(report)
        .T
        .to_csv(output_path)
    )


# ============================================================
# 1) EXTRACT BOTH ROUNDS
# ============================================================

round1 = extract_features(
    ROUND1_EVENTS,
    ROUND1_SAMPLES,
    "round1",
)

round2 = extract_features(
    ROUND2_EVENTS,
    ROUND2_SAMPLES,
    "round2",
)

combined = pd.concat(
    [round1, round2],
    ignore_index=True,
)

round1.to_csv(
    RESULT_DIR /
    "round1_features.csv",
    index=False,
)

round2.to_csv(
    RESULT_DIR /
    "round2_features.csv",
    index=False,
)

combined.to_csv(
    RESULT_DIR /
    "combined_100_features.csv",
    index=False,
)


# ============================================================
# 2) STRICT ROUND-2 HOLDOUT
# Train ONLY on round 1, test on round 2.
# ============================================================

round1_dynamic = round1[
    round1["label"].isin(
        ZERO_DELTA_CLASSES
    )
].copy()

dynamic_holdout_model = make_rf()

dynamic_holdout_model.fit(
    round1_dynamic[
        DYNAMIC_FEATURES
    ],
    round1_dynamic["label"],
)

hierarchical_round2 = (
    hierarchical_predict_dataframe(
        round2,
        dynamic_holdout_model,
    )
)

hierarchical_holdout_accuracy = (
    accuracy_score(
        hierarchical_round2["label"],
        hierarchical_round2["prediction"],
    )
)

hierarchical_round2.to_csv(
    RESULT_DIR /
    "hierarchical_round2_holdout_predictions.csv",
    index=False,
)

save_report(
    hierarchical_round2["label"],
    hierarchical_round2["prediction"],
    RESULT_DIR /
    "hierarchical_round2_holdout_report.csv",
)

save_confusion_matrix(
    hierarchical_round2["label"],
    hierarchical_round2["prediction"],
    (
        "Hierarchical Model: Round 1 Train -> Round 2 Test\n"
        f"Accuracy = {hierarchical_holdout_accuracy:.3f}"
    ),
    RESULT_DIR /
    "hierarchical_round2_holdout_confusion_matrix.png",
)


# ============================================================
# 3) FLAT 5-CLASS RF COMPARISON
# Train ONLY on round 1, test on round 2.
# ============================================================

flat_model = make_rf()

flat_model.fit(
    round1[FLAT_FEATURES],
    round1["label"],
)

flat_prediction = flat_model.predict(
    round2[FLAT_FEATURES]
)

flat_round2 = round2[
    [
        "round",
        "sample_uid",
        "event_id",
        "label",
        "final_delta_g",
    ]
].copy()

flat_round2[
    "prediction"
] = flat_prediction

flat_round2[
    "correct"
] = (
    flat_round2["label"] ==
    flat_round2["prediction"]
)

flat_holdout_accuracy = (
    accuracy_score(
        flat_round2["label"],
        flat_round2["prediction"],
    )
)

flat_round2.to_csv(
    RESULT_DIR /
    "flat_rf_round2_holdout_predictions.csv",
    index=False,
)

save_report(
    flat_round2["label"],
    flat_round2["prediction"],
    RESULT_DIR /
    "flat_rf_round2_holdout_report.csv",
)

save_confusion_matrix(
    flat_round2["label"],
    flat_round2["prediction"],
    (
        "Flat 5-Class RF: Round 1 Train -> Round 2 Test\n"
        f"Accuracy = {flat_holdout_accuracy:.3f}"
    ),
    RESULT_DIR /
    "flat_rf_round2_holdout_confusion_matrix.png",
)


# ============================================================
# 4) COMBINED 100-EVENT HIERARCHICAL 5-FOLD CV
#
# Important:
# This is NOT an independent blind test.
# It estimates internal separability after both rounds are included.
# ============================================================

combined_dynamic = combined[
    combined["label"].isin(
        ZERO_DELTA_CLASSES
    )
].copy()

cv = StratifiedKFold(
    n_splits=5,
    shuffle=True,
    random_state=42,
)

dynamic_cv_pred = (
    cross_val_predict(
        make_rf(),
        combined_dynamic[
            DYNAMIC_FEATURES
        ],
        combined_dynamic["label"],
        cv=cv,
        method="predict",
    )
)

dynamic_cv_lookup = dict(
    zip(
        combined_dynamic.index,
        dynamic_cv_pred,
    )
)

combined_cv_rows = []

for idx, row in combined.iterrows():
    stage, static_prediction, ratio = (
        stage1_route(
            float(
                row["final_delta_g"]
            )
        )
    )

    if stage == "DYNAMIC_RF":
        prediction = (
            dynamic_cv_lookup[idx]
        )
    else:
        prediction = (
            static_prediction
        )

    combined_cv_rows.append({
        "round": row["round"],
        "sample_uid": row["sample_uid"],
        "event_id": int(row["event_id"]),
        "label": row["label"],
        "final_delta_g": float(
            row["final_delta_g"]
        ),
        "pill_ratio": ratio,
        "stage": stage,
        "prediction": prediction,
        "correct": (
            prediction ==
            row["label"]
        ),
    })

combined_cv = pd.DataFrame(
    combined_cv_rows
)

combined_cv_accuracy = (
    accuracy_score(
        combined_cv["label"],
        combined_cv["prediction"],
    )
)

combined_cv.to_csv(
    RESULT_DIR /
    "hierarchical_combined_100_cv_predictions.csv",
    index=False,
)

save_report(
    combined_cv["label"],
    combined_cv["prediction"],
    RESULT_DIR /
    "hierarchical_combined_100_cv_report.csv",
)

save_confusion_matrix(
    combined_cv["label"],
    combined_cv["prediction"],
    (
        "Hierarchical Model: Combined 100 Events, 5-Fold CV\n"
        f"Accuracy = {combined_cv_accuracy:.3f}"
    ),
    RESULT_DIR /
    "hierarchical_combined_100_cv_confusion_matrix.png",
)


# ============================================================
# 5) TRAIN FINAL DYNAMIC RF ON BOTH ROUNDS
#
# This is the model to freeze BEFORE collecting a future blind round.
# ============================================================

final_dynamic_model = make_rf()

final_dynamic_model.fit(
    combined_dynamic[
        DYNAMIC_FEATURES
    ],
    combined_dynamic["label"],
)

joblib.dump(
    final_dynamic_model,
    RESULT_DIR /
    "hierarchical_dynamic_rf.joblib",
)

importance = pd.DataFrame({
    "feature": DYNAMIC_FEATURES,
    "rf_importance":
        final_dynamic_model
        .feature_importances_,
}).sort_values(
    "rf_importance",
    ascending=False,
)

importance.to_csv(
    RESULT_DIR /
    "dynamic_rf_feature_importance.csv",
    index=False,
)

top = (
    importance
    .head(15)
    .sort_values(
        "rf_importance",
        ascending=True,
    )
)

fig, ax = plt.subplots(
    figsize=(9, 7)
)

ax.barh(
    top["feature"],
    top["rf_importance"],
)

ax.set_xlabel(
    "Random Forest feature importance"
)

ax.set_title(
    "Hierarchical Dynamic RF: Top 15 Features"
)

fig.tight_layout()

fig.savefig(
    RESULT_DIR /
    "dynamic_rf_feature_importance.png",
    dpi=200,
    bbox_inches="tight",
)

plt.close(fig)


# ============================================================
# 6) SAVE MODEL CONFIG
# ============================================================

config = {
    "pill_weight_g": PILL_WEIGHT_G,
    "stage1": {
        "zero_abs_ratio_max":
            ZERO_RATIO_MAX,
        "one_ratio_min":
            ONE_RATIO_MIN,
        "one_ratio_max":
            ONE_RATIO_MAX,
        "two_ratio_min":
            TWO_RATIO_MIN,
        "two_ratio_max":
            TWO_RATIO_MAX,
    },
    "dynamic_classes":
        ZERO_DELTA_CLASSES,
    "dynamic_features":
        DYNAMIC_FEATURES,
    "notes": (
        "ONE/TWO are classified from final weight change. "
        "Only near-zero net change is sent to the dynamic RF. "
        "Out-of-window values return UNCERTAIN."
    ),
}

with open(
    RESULT_DIR /
    "hierarchical_model_config.json",
    "w",
    encoding="utf-8",
) as f:
    json.dump(
        config,
        f,
        indent=2,
        ensure_ascii=False,
    )


# ============================================================
# 7) SUMMARY
# ============================================================

comparison = pd.DataFrame([
    {
        "evaluation":
            "Flat RF: round1 train -> round2 test",
        "accuracy":
            flat_holdout_accuracy,
        "independent_holdout":
            True,
    },
    {
        "evaluation":
            "Hierarchical: round1 train -> round2 test",
        "accuracy":
            hierarchical_holdout_accuracy,
        "independent_holdout":
            True,
    },
    {
        "evaluation":
            "Hierarchical: combined 100-event 5-fold CV",
        "accuracy":
            combined_cv_accuracy,
        "independent_holdout":
            False,
    },
])

comparison.to_csv(
    RESULT_DIR /
    "model_comparison.csv",
    index=False,
)

hier_errors = hierarchical_round2[
    ~hierarchical_round2["correct"]
]

flat_errors = flat_round2[
    ~flat_round2["correct"]
]

summary = f"""
MEDBOX HIERARCHICAL MODEL - ROUND 2 RESULT
==========================================

Data
----
Round 1: {len(round1)} events
Round 2: {len(round2)} events
Combined: {len(combined)} events

Current pill weight
-------------------
{PILL_WEIGHT_G:.3f} g

Stage 1
-------
|ratio| < {ZERO_RATIO_MAX:.2f}
    -> DYNAMIC_RF
       classify NONE / RETURN / DISTURBANCE

{ONE_RATIO_MIN:.2f} <= ratio < {ONE_RATIO_MAX:.2f}
    -> ONE

{TWO_RATIO_MIN:.2f} <= ratio < {TWO_RATIO_MAX:.2f}
    -> TWO

Anything else
    -> UNCERTAIN

Round-2 holdout result
----------------------
Flat 5-class RF:
    accuracy = {flat_holdout_accuracy:.3f}

Hierarchical model:
    accuracy = {hierarchical_holdout_accuracy:.3f}

Hierarchical errors:
{hier_errors[["event_id", "label", "prediction", "stage", "final_delta_g"]].to_string(index=False)}

Why the hierarchical holdout is better
--------------------------------------
The deterministic weight stage protects ONE/TWO from being confused
with large hand-pressure disturbances. Round 2 intentionally contains
strong ONE interactions and lighter DISTURBANCE interactions.

Remaining weakness
------------------
Most remaining round-2 errors are light DISTURBANCE events being
classified as NONE or RETURN by the dynamic RF trained only on round 1.
This is expected because round 1 contained much stronger disturbance
patterns.

Combined 100-event internal CV
------------------------------
Hierarchical 5-fold CV accuracy = {combined_cv_accuracy:.3f}

This is NOT an independent blind-test score because both rounds
participate in cross-validation.

Final frozen model
------------------
The dynamic RF has now been retrained on both rounds:
    {len(combined_dynamic)} events
    classes = NONE / RETURN / DISTURBANCE

Use the saved model + fixed Stage-1 thresholds for the NEXT blind
validation round. Do not change the model after seeing the blind-test
labels if you want a defensible validation result.
""".strip()

with open(
    RESULT_DIR /
    "model_summary.txt",
    "w",
    encoding="utf-8",
) as f:
    f.write(summary)

print()
print("=" * 68)
print("MEDBOX HIERARCHICAL MODEL")
print("=" * 68)
print(
    f"Flat RF round1 -> round2 accuracy: "
    f"{flat_holdout_accuracy:.3f}"
)
print(
    f"Hierarchical round1 -> round2 accuracy: "
    f"{hierarchical_holdout_accuracy:.3f}"
)
print(
    f"Hierarchical combined 100-event CV: "
    f"{combined_cv_accuracy:.3f}"
)
print()
print("Results saved to:")
print(RESULT_DIR)
print()
print("Hierarchical round-2 errors:")
print(
    hier_errors[
        [
            "event_id",
            "label",
            "prediction",
            "stage",
            "final_delta_g",
        ]
    ].to_string(index=False)
)
