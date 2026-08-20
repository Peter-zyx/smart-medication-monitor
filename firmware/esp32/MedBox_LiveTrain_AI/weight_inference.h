#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>

#include "weight_model_generated.h"

namespace medbox_weight_inference {

static constexpr size_t kFeatureCount = 24;
static constexpr double kZeroAbsRatioMax = 0.30;
static constexpr double kOneRatioMin = 0.50;
static constexpr double kOneRatioMax = 1.50;
static constexpr double kTwoRatioMin = 1.50;
static constexpr double kTwoRatioMax = 2.50;
static constexpr double kBelowBaselineThresholdG = 0.4;
static constexpr size_t kEndWindow = 10;

static_assert(
    medbox_weight_model::kFeatureCount == kFeatureCount,
    "Generated RF feature count does not match the ESP32 extractor"
);

struct WeightSample {
    uint32_t timeMs;
    double weightG;
};

enum class Stage : uint8_t {
    DynamicRandomForest,
    StaticWeight,
    Uncertain,
};

struct Prediction {
    const char* label;
    Stage stage;
    double finalDeltaG;
    double pillRatio;
    double confidence;
    bool hasConfidence;
};

struct Features {
    double values[kFeatureCount];
};

inline double quantizeForWire(double value) {
    return std::round(value * 1000.0) / 1000.0;
}

inline double populationStd(const WeightSample* samples, size_t start, size_t count) {
    if (count == 0) {
        return 0.0;
    }
    double mean = 0.0;
    for (size_t index = 0; index < count; ++index) {
        mean += samples[start + index].weightG;
    }
    mean /= static_cast<double>(count);

    double squaredDeviation = 0.0;
    for (size_t index = 0; index < count; ++index) {
        const double difference = samples[start + index].weightG - mean;
        squaredDeviation += difference * difference;
    }
    return std::sqrt(squaredDeviation / static_cast<double>(count));
}

inline bool extractFeatures(
    double beforeG,
    const WeightSample* samples,
    size_t count,
    Features& output
) {
    if (samples == nullptr || count == 0) {
        return false;
    }

    double minWeight = samples[0].weightG;
    double maxWeight = samples[0].weightG;
    size_t minIndex = 0;
    size_t maxIndex = 0;
    double maxRise = samples[0].weightG - beforeG;
    double minRelative = maxRise;
    double maxAbsoluteDeviation = std::fabs(maxRise);
    double sumWeight = 0.0;
    size_t belowCount = 0;
    size_t longestBelow = 0;
    size_t currentBelow = 0;
    size_t belowEpisodes = 0;
    bool wasBelow = false;

    for (size_t index = 0; index < count; ++index) {
        const double weight = samples[index].weightG;
        const double relative = weight - beforeG;
        sumWeight += weight;

        if (weight > maxWeight) {
            maxWeight = weight;
            maxIndex = index;
        }
        if (weight < minWeight) {
            minWeight = weight;
            minIndex = index;
        }
        maxRise = std::max(maxRise, relative);
        minRelative = std::min(minRelative, relative);
        maxAbsoluteDeviation = std::max(maxAbsoluteDeviation, std::fabs(relative));

        const bool below = weight <= beforeG - kBelowBaselineThresholdG;
        if (below) {
            ++belowCount;
            ++currentBelow;
            longestBelow = std::max(longestBelow, currentBelow);
            if (!wasBelow) {
                ++belowEpisodes;
            }
        } else {
            currentBelow = 0;
        }
        wasBelow = below;
    }

    const double meanWeight = sumWeight / static_cast<double>(count);
    double weightSquaredDeviation = 0.0;
    for (size_t index = 0; index < count; ++index) {
        const double difference = samples[index].weightG - meanWeight;
        weightSquaredDeviation += difference * difference;
    }
    const double stdWeight = std::sqrt(weightSquaredDeviation / static_cast<double>(count));

    double maxStepUp = 0.0;
    double maxStepDown = 0.0;
    double meanAbsoluteStep = 0.0;
    double stdStep = 0.0;
    size_t changeSmall = 0;
    size_t changeMedium = 0;
    size_t changeLarge = 0;

    if (count > 1) {
        const size_t stepCount = count - 1;
        maxStepUp = samples[1].weightG - samples[0].weightG;
        maxStepDown = maxStepUp;
        double stepSum = 0.0;
        for (size_t index = 1; index < count; ++index) {
            const double step = samples[index].weightG - samples[index - 1].weightG;
            const double absoluteStep = std::fabs(step);
            maxStepUp = std::max(maxStepUp, step);
            maxStepDown = std::min(maxStepDown, step);
            meanAbsoluteStep += absoluteStep;
            stepSum += step;
            changeSmall += absoluteStep >= 0.5;
            changeMedium += absoluteStep >= 2.0;
            changeLarge += absoluteStep >= 5.0;
        }
        meanAbsoluteStep /= static_cast<double>(stepCount);
        const double meanStep = stepSum / static_cast<double>(stepCount);
        double stepSquaredDeviation = 0.0;
        for (size_t index = 1; index < count; ++index) {
            const double step = samples[index].weightG - samples[index - 1].weightG;
            const double difference = step - meanStep;
            stepSquaredDeviation += difference * difference;
        }
        stdStep = std::sqrt(stepSquaredDeviation / static_cast<double>(stepCount));
    }

    const size_t window = std::min(kEndWindow, count);
    double startMean = 0.0;
    double endMean = 0.0;
    for (size_t index = 0; index < window; ++index) {
        startMean += samples[index].weightG;
        endMean += samples[count - window + index].weightG;
    }
    startMean /= static_cast<double>(window);
    endMean /= static_cast<double>(window);

    double absoluteArea = 0.0;
    double signedArea = 0.0;
    if (count > 1) {
        for (size_t index = 1; index < count; ++index) {
            const double deltaTime = static_cast<double>(samples[index].timeMs - samples[index - 1].timeMs);
            const double previousRelative = samples[index - 1].weightG - beforeG;
            const double currentRelative = samples[index].weightG - beforeG;
            absoluteArea += 0.5 * (
                std::fabs(previousRelative) + std::fabs(currentRelative)
            ) * deltaTime;
            signedArea += 0.5 * (previousRelative + currentRelative) * deltaTime;
        }
    }

    // Keep this assignment order byte-for-byte aligned with the JSON feature list.
    output.values[0] = maxWeight - minWeight;
    output.values[1] = stdWeight;
    output.values[2] = maxRise;
    output.values[3] = -minRelative;
    output.values[4] = maxAbsoluteDeviation;
    output.values[5] = static_cast<double>(samples[maxIndex].timeMs);
    output.values[6] = static_cast<double>(samples[minIndex].timeMs);
    output.values[7] = count > 1
        ? static_cast<double>(samples[count - 1].timeMs - samples[0].timeMs)
        : 0.0;
    output.values[8] = maxStepUp;
    output.values[9] = maxStepDown;
    output.values[10] = meanAbsoluteStep;
    output.values[11] = stdStep;
    output.values[12] = static_cast<double>(changeSmall);
    output.values[13] = static_cast<double>(changeMedium);
    output.values[14] = static_cast<double>(changeLarge);
    output.values[15] = static_cast<double>(belowCount) / static_cast<double>(count);
    output.values[16] = static_cast<double>(longestBelow);
    output.values[17] = static_cast<double>(belowEpisodes);
    output.values[18] = beforeG - startMean;
    output.values[19] = populationStd(samples, 0, window);
    output.values[20] = populationStd(samples, count - window, window);
    output.values[21] = absoluteArea;
    output.values[22] = signedArea;
    output.values[23] = static_cast<double>(count);
    return true;
}

inline bool predictDynamic(const Features& features, const char*& label, double& confidence) {
    double probabilities[3] = {0.0, 0.0, 0.0};

    for (size_t treeIndex = 0; treeIndex < medbox_weight_model::kTreeCount; ++treeIndex) {
        int32_t nodeIndex = medbox_weight_model::readTreeRoot(treeIndex);
        bool reachedLeaf = false;
        for (size_t depth = 0; depth < 32; ++depth) {
            if (nodeIndex < 0 || static_cast<size_t>(nodeIndex) >= medbox_weight_model::kNodeCount) {
                return false;
            }
            const auto node = medbox_weight_model::readNode(static_cast<size_t>(nodeIndex));
            if (node.feature < 0) {
                probabilities[0] += static_cast<double>(node.probability0);
                probabilities[1] += static_cast<double>(node.probability1);
                probabilities[2] += static_cast<double>(node.probability2);
                reachedLeaf = true;
                break;
            }
            if (static_cast<size_t>(node.feature) >= kFeatureCount) {
                return false;
            }
            nodeIndex = features.values[node.feature] <= node.threshold
                ? node.left
                : node.right;
        }
        if (!reachedLeaf) {
            return false;
        }
    }

    size_t bestClass = 0;
    if (probabilities[1] > probabilities[bestClass]) {
        bestClass = 1;
    }
    if (probabilities[2] > probabilities[bestClass]) {
        bestClass = 2;
    }
    static const char* kLabels[3] = {"DISTURBANCE", "NONE", "RETURN"};
    label = kLabels[bestClass];
    confidence = probabilities[bestClass] / static_cast<double>(medbox_weight_model::kTreeCount);
    return true;
}

inline Prediction classify(
    double beforeG,
    double afterG,
    const WeightSample* samples,
    size_t sampleCount,
    double pillWeightG
) {
    const double finalDelta = beforeG - afterG;
    if (!(pillWeightG > 0.0) || !std::isfinite(pillWeightG)) {
        return {"UNCERTAIN", Stage::Uncertain, finalDelta, NAN, NAN, false};
    }
    const double ratio = finalDelta / pillWeightG;

    if (std::fabs(ratio) < kZeroAbsRatioMax) {
        Features features = {};
        const char* label = "UNCERTAIN";
        double confidence = NAN;
        if (!extractFeatures(beforeG, samples, sampleCount, features) ||
            !predictDynamic(features, label, confidence)) {
            return {"UNCERTAIN", Stage::Uncertain, finalDelta, ratio, NAN, false};
        }
        return {label, Stage::DynamicRandomForest, finalDelta, ratio, confidence, true};
    }

    if (ratio >= kOneRatioMin && ratio < kOneRatioMax) {
        return {"ONE", Stage::StaticWeight, finalDelta, ratio, NAN, false};
    }
    if (ratio >= kTwoRatioMin && ratio < kTwoRatioMax) {
        return {"TWO", Stage::StaticWeight, finalDelta, ratio, NAN, false};
    }
    return {"UNCERTAIN", Stage::Uncertain, finalDelta, ratio, NAN, false};
}

}  // namespace medbox_weight_inference
