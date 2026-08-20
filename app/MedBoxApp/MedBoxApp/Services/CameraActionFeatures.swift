import CoreGraphics
import Foundation
import UIKit

struct ActionLandmark: Sendable {
    let x: Float
    let y: Float
    let z: Float
    let visibility: Float
}

enum CameraActionFeatureError: Error {
    case invalidFrameShape
    case imageConversionFailed
}

enum CameraActionFeatureExtractor {
    static let sampledFrames = 24
    static let temporalBins = 6
    static let frameFeatureCount = 184
    static let modelFeatureCount = 2_576

    private static let poseIDs = Array(0..<23)
    private static let handKeyIDs = [0, 4, 8, 12, 16, 20]

    static func frameFeatures(
        image: UIImage,
        pose: [ActionLandmark]?,
        hands inputHands: [[ActionLandmark]]
    ) throws -> [Float] {
        let shoulders: (centerX: Float, centerY: Float, scale: Float)
        if let pose, pose.count > 22 {
            let centerX = (pose[11].x + pose[12].x) / 2
            let centerY = (pose[11].y + pose[12].y) / 2
            shoulders = (centerX, centerY, max(distance(pose[11], pose[12]), 0.08))
        } else {
            shoulders = (0.5, 0.5, 0.25)
        }

        var values: [Float] = []
        values.reserveCapacity(frameFeatureCount)
        for landmarkID in poseIDs {
            guard let pose, pose.count > landmarkID else {
                values.append(contentsOf: [0, 0, 0, 0])
                continue
            }
            let point = pose[landmarkID]
            values.append((point.x - shoulders.centerX) / shoulders.scale)
            values.append((point.y - shoulders.centerY) / shoulders.scale)
            values.append(point.z / shoulders.scale)
            values.append(point.visibility)
        }

        var derived: [String: Float] = ["pose_present": pose == nil ? 0 : 1]
        if let pose, pose.count > 22 {
            let mouth = midpoint(pose[9], pose[10])
            let nose = pose[0]
            for (side, pointIDs, earID) in [
                ("left", [15, 19, 21], 7),
                ("right", [16, 20, 22], 8),
            ] {
                let ear = pose[earID]
                for (name, pointID) in zip(["wrist", "index", "thumb"], pointIDs) {
                    let point = pose[pointID]
                    derived["\(side)_\(name)_to_mouth"] = distance(point, mouth) / shoulders.scale
                    derived["\(side)_\(name)_to_nose"] = distance(point, nose) / shoulders.scale
                    derived["\(side)_\(name)_to_ear"] = distance(point, ear) / shoulders.scale
                }
            }
        } else {
            for side in ["left", "right"] {
                for point in ["wrist", "index", "thumb"] {
                    for target in ["mouth", "nose", "ear"] {
                        derived["\(side)_\(point)_to_\(target)"] = 0
                    }
                }
            }
        }
        for key in derived.keys.sorted() {
            values.append(derived[key, default: 0])
        }

        let hands = inputHands
            .filter { $0.count >= 21 }
            .sorted { $0[0].x < $1[0].x }
        for slot in 0..<2 {
            var handValues: [String: Float] = [:]
            if slot < hands.count {
                let hand = hands[slot]
                let wrist = hand[0]
                let palmScale = max(distance(hand[0], hand[9]), 0.02)
                handValues["present"] = 1
                handValues["palm_scale"] = palmScale / shoulders.scale
                for landmarkID in handKeyIDs {
                    let point = hand[landmarkID]
                    handValues["key_\(landmarkID)_global_x"] =
                        (point.x - shoulders.centerX) / shoulders.scale
                    handValues["key_\(landmarkID)_global_y"] =
                        (point.y - shoulders.centerY) / shoulders.scale
                    handValues["key_\(landmarkID)_local_x"] = (point.x - wrist.x) / palmScale
                    handValues["key_\(landmarkID)_local_y"] = (point.y - wrist.y) / palmScale
                }
                for (name, tipID) in zip(["index", "middle", "ring", "pinky"], [8, 12, 16, 20]) {
                    handValues["pinch_\(name)"] = distance(hand[4], hand[tipID]) / palmScale
                }
                for (name, tipID) in zip(
                    ["thumb", "index", "middle", "ring", "pinky"],
                    [4, 8, 12, 16, 20]
                ) {
                    handValues["open_\(name)"] = distance(hand[tipID], wrist) / palmScale
                }
            } else {
                handValues = ["present": 0, "palm_scale": 0]
                for landmarkID in handKeyIDs {
                    for coordinate in ["global_x", "global_y", "local_x", "local_y"] {
                        handValues["key_\(landmarkID)_\(coordinate)"] = 0
                    }
                }
                for name in ["index", "middle", "ring", "pinky"] {
                    handValues["pinch_\(name)"] = 0
                }
                for name in ["thumb", "index", "middle", "ring", "pinky"] {
                    handValues["open_\(name)"] = 0
                }
            }
            for key in handValues.keys.sorted() {
                values.append(handValues[key, default: 0])
            }
        }

        values.append(Float(min(hands.count, 2)))
        let brightness = try brightnessStatistics(image)
        values.append(brightness.mean)
        values.append(brightness.standardDeviation)

        guard values.count == frameFeatureCount else {
            throw CameraActionFeatureError.invalidFrameShape
        }
        return values
    }

    static func temporalSummary(_ sequence: [[Float]], bins: Int = temporalBins) throws -> [Float] {
        guard sequence.count >= 2,
              bins > 0,
              sequence.count >= bins,
              let featureCount = sequence.first?.count,
              featureCount > 0,
              sequence.allSatisfy({ $0.count == featureCount }) else {
            throw CameraActionFeatureError.invalidFrameShape
        }

        var means = Array(repeating: Float(0), count: featureCount)
        var minimums = Array(repeating: Float.greatestFiniteMagnitude, count: featureCount)
        var maximums = Array(repeating: -Float.greatestFiniteMagnitude, count: featureCount)
        for frame in sequence {
            for index in 0..<featureCount {
                means[index] += frame[index]
                minimums[index] = min(minimums[index], frame[index])
                maximums[index] = max(maximums[index], frame[index])
            }
        }
        let frameCount = Float(sequence.count)
        for index in means.indices { means[index] /= frameCount }

        var standardDeviations = Array(repeating: Float(0), count: featureCount)
        var deltaMeans = Array(repeating: Float(0), count: featureCount)
        var deltaMaximums = Array(repeating: Float(0), count: featureCount)
        for (frameIndex, frame) in sequence.enumerated() {
            for index in 0..<featureCount {
                let offset = frame[index] - means[index]
                standardDeviations[index] += offset * offset
                if frameIndex > 0 {
                    let delta = abs(frame[index] - sequence[frameIndex - 1][index])
                    deltaMeans[index] += delta
                    deltaMaximums[index] = max(deltaMaximums[index], delta)
                }
            }
        }
        for index in 0..<featureCount {
            standardDeviations[index] = sqrt(standardDeviations[index] / frameCount)
            deltaMeans[index] /= Float(sequence.count - 1)
        }

        var output = means + standardDeviations + minimums + maximums
        output += deltaMeans + deltaMaximums + sequence[0] + sequence[sequence.count - 1]

        let baseBinSize = sequence.count / bins
        let extra = sequence.count % bins
        var start = 0
        for bin in 0..<bins {
            let size = baseBinSize + (bin < extra ? 1 : 0)
            let end = start + size
            var binMeans = Array(repeating: Float(0), count: featureCount)
            for frame in sequence[start..<end] {
                for index in 0..<featureCount { binMeans[index] += frame[index] }
            }
            for index in 0..<featureCount { binMeans[index] /= Float(size) }
            output += binMeans
            start = end
        }
        return output
    }

    private static func midpoint(_ lhs: ActionLandmark, _ rhs: ActionLandmark) -> ActionLandmark {
        ActionLandmark(
            x: (lhs.x + rhs.x) / 2,
            y: (lhs.y + rhs.y) / 2,
            z: (lhs.z + rhs.z) / 2,
            visibility: (lhs.visibility + rhs.visibility) / 2
        )
    }

    private static func distance(_ lhs: ActionLandmark, _ rhs: ActionLandmark) -> Float {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }

    private static func brightnessStatistics(_ image: UIImage) throws -> (mean: Float, standardDeviation: Float) {
        guard let cgImage = image.cgImage else { throw CameraActionFeatureError.imageConversionFailed }
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var bytes = Array(repeating: UInt8(0), count: bytesPerRow * height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &bytes,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
              ) else {
            throw CameraActionFeatureError.imageConversionFailed
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var sum = Double(0)
        var squareSum = Double(0)
        for offset in stride(from: 0, to: bytes.count, by: bytesPerPixel) {
            // Matches OpenCV's 8-bit RGB-to-gray fixed-point conversion.
            let gray = (
                Int(bytes[offset]) * 4_899
                    + Int(bytes[offset + 1]) * 9_617
                    + Int(bytes[offset + 2]) * 1_868
                    + 8_192
            ) >> 14
            let normalized = Double(gray) / 255
            sum += normalized
            squareSum += normalized * normalized
        }
        let count = Double(width * height)
        let mean = sum / count
        let variance = max(0, squareSum / count - mean * mean)
        return (Float(mean), Float(sqrt(variance)))
    }
}
