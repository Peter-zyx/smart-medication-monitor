import Foundation

public enum BLEParseError: Error, Equatable, LocalizedError {
    case empty
    case missingFields(type: String, expected: Int, actual: Int)
    case invalidInteger(field: String, value: String)
    case invalidNumber(field: String, value: String)
    case invalidValue(field: String, value: String)

    public var errorDescription: String? {
        switch self {
        case .empty:
            "The BLE message was empty."
        case let .missingFields(type, expected, actual):
            "\(type) requires \(expected) fields but received \(actual)."
        case let .invalidInteger(field, value):
            "\(field) is not a valid integer: \(value)"
        case let .invalidNumber(field, value):
            "\(field) is not a valid number: \(value)"
        case let .invalidValue(field, value):
            "\(field) has an unsupported value: \(value)"
        }
    }
}

public struct BLEMessageParser: Sendable {
    public init() {}

    public func parse(_ rawMessage: String) throws -> BLEMessage {
        let raw = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw BLEParseError.empty }

        let fields = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let type = fields[0].uppercased()

        switch type {
        case "O":
            try require(fields, type: type, count: 2)
            return .opened(eventID: try integer(fields[1], field: "event_id"))
        case "C":
            try require(fields, type: type, count: 2)
            return .closed(eventID: try integer(fields[1], field: "event_id"))
        case "E":
            try require(fields, type: type, count: 3)
            return .eventEnded(
                eventID: try integer(fields[1], field: "event_id"),
                removedWeight: try number(fields[2], field: "removed_weight")
            )
        case "READY":
            try require(fields, type: type, count: 2)
            return .ready(eventID: try integer(fields[1], field: "event_id"))
        case "AI":
            guard fields.count == 4 || fields.count == 5 else {
                throw BLEParseError.missingFields(type: type, expected: 4, actual: fields.count)
            }
            guard let prediction = MedicationPrediction(rawValue: fields[2].uppercased()) else {
                throw BLEParseError.invalidValue(field: "prediction", value: fields[2])
            }
            return .ai(
                AIResult(
                    eventID: try integer(fields[1], field: "event_id"),
                    prediction: prediction,
                    finalDelta: try number(fields[3], field: "final_delta"),
                    confidence: fields.count == 5
                        ? try number(fields[4], field: "confidence")
                        : nil
                )
            )
        case "W":
            try require(fields, type: type, count: 2)
            return .weight(try number(fields[1], field: "weight"))
        case "S":
            try require(fields, type: type, count: 5)
            guard let mode = DeviceMode(rawValue: fields[4].uppercased()) else {
                throw BLEParseError.invalidValue(field: "mode", value: fields[4])
            }
            return .status(
                MedicationStatus(
                    name: fields[1],
                    pillWeight: try number(fields[2], field: "pill_weight"),
                    expectedDose: try integer(fields[3], field: "dose"),
                    mode: mode
                )
            )
        case "MODE":
            try require(fields, type: type, count: 2)
            guard let mode = DeviceMode(rawValue: fields[1].uppercased()) else {
                throw BLEParseError.invalidValue(field: "mode", value: fields[1])
            }
            return .mode(mode)
        case "BUSY":
            try require(fields, type: type, count: 2)
            guard let operation = DeviceOperation(rawValue: fields[1].uppercased()) else {
                throw BLEParseError.invalidValue(field: "operation", value: fields[1])
            }
            return .busy(operation)
        case "OK":
            guard fields.count >= 2 else {
                throw BLEParseError.missingFields(type: type, expected: 2, actual: fields.count)
            }
            switch fields[1].uppercased() {
            case "ZERO":
                try require(fields, type: "OK|ZERO", count: 2)
                return .zeroed
            case "LEARN":
                try require(fields, type: "OK|LEARN", count: 5)
                return .learned(
                    name: fields[2],
                    pillWeight: try number(fields[3], field: "pill_weight"),
                    expectedDose: try integer(fields[4], field: "dose")
                )
            default:
                return .unknown(raw: raw)
            }
        case "ERR":
            guard fields.count >= 2 else {
                throw BLEParseError.missingFields(type: type, expected: 2, actual: fields.count)
            }
            return .error(code: fields.dropFirst().joined(separator: "|"))
        default:
            return .unknown(raw: raw)
        }
    }

    private func require(_ fields: [String], type: String, count: Int) throws {
        guard fields.count == count else {
            throw BLEParseError.missingFields(type: type, expected: count, actual: fields.count)
        }
    }

    private func integer(_ value: String, field: String) throws -> Int {
        guard let parsed = Int(value) else {
            throw BLEParseError.invalidInteger(field: field, value: value)
        }
        return parsed
    }

    private func number(_ value: String, field: String) throws -> Double {
        guard let parsed = Double(value), parsed.isFinite else {
            throw BLEParseError.invalidNumber(field: field, value: value)
        }
        return parsed
    }
}

