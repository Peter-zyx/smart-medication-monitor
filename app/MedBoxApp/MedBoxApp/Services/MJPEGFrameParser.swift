import Foundation

/// Extracts complete JPEG images from an MJPEG byte stream.
///
/// The ESP32 stream includes multipart headers, so searching for JPEG start/end
/// markers keeps this parser independent of boundary names and chunk sizes.
struct MJPEGFrameParser {
    private static let startMarker = Data([0xFF, 0xD8])
    private static let endMarker = Data([0xFF, 0xD9])

    private(set) var bufferedByteCount = 0
    private var buffer = Data()
    private let maximumBufferSize: Int

    init(maximumBufferSize: Int = 4 * 1_024 * 1_024) {
        self.maximumBufferSize = maximumBufferSize
    }

    mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var frames: [Data] = []

        while let start = buffer.range(of: Self.startMarker)?.lowerBound {
            if start > buffer.startIndex {
                buffer.removeSubrange(buffer.startIndex..<start)
            }

            guard buffer.count > Self.startMarker.count,
                  let endRange = buffer.range(
                    of: Self.endMarker,
                    in: Self.startMarker.count..<buffer.count
                  ) else {
                break
            }

            let frameEnd = endRange.upperBound
            frames.append(buffer.subdata(in: buffer.startIndex..<frameEnd))
            buffer.removeSubrange(buffer.startIndex..<frameEnd)
        }

        trimIfNeeded()
        bufferedByteCount = buffer.count
        return frames
    }

    mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
        bufferedByteCount = 0
    }

    private mutating func trimIfNeeded() {
        guard buffer.count > maximumBufferSize else { return }

        // Retain a trailing 0xFF because it may be the first byte of a JPEG
        // start marker split across two URLSession callbacks.
        let trailingByte = buffer.last == 0xFF ? Data([0xFF]) : Data()
        buffer = trailingByte
    }
}
