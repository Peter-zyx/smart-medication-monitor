import Foundation

struct MedicationEventRecord: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let eventID: Int
    let timestamp: Date
    let medicationName: String
    let expectedDose: Int
    let prediction: MedicationPrediction
    let weightChange: Double
    let confidence: Double?

    init(
        id: UUID = UUID(),
        eventID: Int,
        timestamp: Date = .now,
        medicationName: String,
        expectedDose: Int,
        prediction: MedicationPrediction,
        weightChange: Double,
        confidence: Double?
    ) {
        self.id = id
        self.eventID = eventID
        self.timestamp = timestamp
        self.medicationName = medicationName
        self.expectedDose = expectedDose
        self.prediction = prediction
        self.weightChange = weightChange
        self.confidence = confidence
    }
}

extension MedicationPrediction {
    var presentation: ResultPresentation {
        switch self {
        case .one:
            ResultPresentation(
                title: "Medication removed",
                message: "1 tablet detected",
                guidance: "This is medication-removal evidence. It does not medically confirm ingestion.",
                symbol: "checkmark.circle.fill",
                tone: .positive
            )
        case .two:
            ResultPresentation(
                title: "Possible dose issue",
                message: "More medication than expected may have been removed.",
                guidance: "Please verify your dose before continuing.",
                symbol: "exclamationmark.triangle.fill",
                tone: .warning
            )
        case .none:
            ResultPresentation(
                title: "No medication removed",
                message: "The device did not detect meaningful medication removal.",
                guidance: "Check the medication box manually if this was unexpected.",
                symbol: "minus.circle.fill",
                tone: .neutral
            )
        case .returned:
            ResultPresentation(
                title: "Medication returned",
                message: "Medication appears to have been removed and placed back.",
                guidance: "The dose is not recorded as removed.",
                symbol: "arrow.uturn.backward.circle.fill",
                tone: .warning
            )
        case .disturbance:
            ResultPresentation(
                title: "Interaction detected",
                message: "Medication status could not be confirmed.",
                guidance: "Please check the medication box manually.",
                symbol: "waveform.path.ecg.rectangle.fill",
                tone: .warning
            )
        case .uncertain:
            ResultPresentation(
                title: "Unable to confirm medication event",
                message: "The signal fell outside the configured decision ranges.",
                guidance: "Please check manually.",
                symbol: "questionmark.circle.fill",
                tone: .neutral
            )
        }
    }
}

struct ResultPresentation: Sendable {
    enum Tone: Sendable {
        case positive
        case warning
        case neutral
    }

    let title: String
    let message: String
    let guidance: String
    let symbol: String
    let tone: Tone
}

