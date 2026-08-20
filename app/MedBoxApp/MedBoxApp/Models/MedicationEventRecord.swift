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
    let visionAction: VisionAction?
    let visionConfidence: Double?

    init(
        id: UUID = UUID(),
        eventID: Int,
        timestamp: Date = .now,
        medicationName: String,
        expectedDose: Int,
        prediction: MedicationPrediction,
        weightChange: Double,
        confidence: Double?,
        visionAction: VisionAction? = nil,
        visionConfidence: Double? = nil
    ) {
        self.id = id
        self.eventID = eventID
        self.timestamp = timestamp
        self.medicationName = medicationName
        self.expectedDose = expectedDose
        self.prediction = prediction
        self.weightChange = weightChange
        self.confidence = confidence
        self.visionAction = visionAction
        self.visionConfidence = visionConfidence
    }

    var isSupportedByMultipleSignals: Bool {
        prediction.removedUnitCount == expectedDose && visionAction == .take
    }

    func attachingVision(_ result: VisionResult) -> MedicationEventRecord {
        guard result.eventID == eventID else { return self }
        return MedicationEventRecord(
            id: id,
            eventID: eventID,
            timestamp: timestamp,
            medicationName: medicationName,
            expectedDose: expectedDose,
            prediction: prediction,
            weightChange: weightChange,
            confidence: confidence,
            visionAction: result.action,
            visionConfidence: result.confidence
        )
    }
}

private extension MedicationPrediction {
    var removedUnitCount: Int? {
        switch self {
        case .one: 1
        case .two: 2
        case .none, .returned, .disturbance, .uncertain: nil
        }
    }
}

extension VisionAction {
    func displayTitle(language: AppLanguage) -> String {
        switch self {
        case .take: language.text("Ingestion-like action detected", "检测到类似服药的动作")
        case .drink: language.text("Drinking action detected", "检测到饮水动作")
        case .touchFace: language.text("Face-touch action detected", "检测到触碰面部动作")
        case .adjust: language.text("Adjustment action detected", "检测到整理动作")
        case .pickOnly: language.text("Pick-up action detected", "检测到仅拿起动作")
        case .none: language.text("No target camera action", "未检测到目标动作")
        case .uncertain: language.text("Camera action uncertain", "相机动作不确定")
        }
    }

    var symbol: String {
        switch self {
        case .take: "camera.metering.center.weighted"
        case .drink: "cup.and.saucer.fill"
        case .touchFace: "hand.raised.fill"
        case .adjust: "person.crop.circle.badge.questionmark"
        case .pickOnly: "hand.point.up.left.fill"
        case .none: "camera.fill"
        case .uncertain: "camera.badge.ellipsis"
        }
    }
}

extension MedicationPrediction {
    func presentation(language: AppLanguage) -> ResultPresentation {
        switch self {
        case .one:
            ResultPresentation(
                title: language.text("Medication removed", "检测到药物取出"),
                message: language.text("1 tablet detected", "检测到取出 1 片药物"),
                guidance: language.text(
                    "This is medication-removal evidence. It does not medically confirm ingestion.",
                    "这是药物被取出的证据，不能医学确认药物已被吞服。"
                ),
                symbol: "checkmark.circle.fill",
                tone: .positive
            )
        case .two:
            ResultPresentation(
                title: language.text("Possible dose issue", "可能存在剂量问题"),
                message: language.text(
                    "More medication than expected may have been removed.",
                    "取出的药物可能超过预期剂量。"
                ),
                guidance: language.text("Please verify your dose before continuing.", "请核对剂量后再继续。"),
                symbol: "exclamationmark.triangle.fill",
                tone: .warning
            )
        case .none:
            ResultPresentation(
                title: language.text("No medication removed", "未检测到药物取出"),
                message: language.text(
                    "The device did not detect meaningful medication removal.",
                    "设备未检测到明显的药物取出。"
                ),
                guidance: language.text(
                    "Check the medication box manually if this was unexpected.",
                    "如果结果不符合预期，请手动检查药盒。"
                ),
                symbol: "minus.circle.fill",
                tone: .neutral
            )
        case .returned:
            ResultPresentation(
                title: language.text("Medication returned", "药物已放回"),
                message: language.text(
                    "Medication appears to have been removed and placed back.",
                    "药物似乎被取出后又放回。"
                ),
                guidance: language.text("The dose is not recorded as removed.", "本次不会记录为药物已取出。"),
                symbol: "arrow.uturn.backward.circle.fill",
                tone: .warning
            )
        case .disturbance:
            ResultPresentation(
                title: language.text("Interaction detected", "检测到操作"),
                message: language.text("Medication status could not be confirmed.", "无法确认药物状态。"),
                guidance: language.text("Please check the medication box manually.", "请手动检查药盒。"),
                symbol: "waveform.path.ecg.rectangle.fill",
                tone: .warning
            )
        case .uncertain:
            ResultPresentation(
                title: language.text("Unable to confirm medication event", "无法确认用药事件"),
                message: language.text(
                    "The signal fell outside the configured decision ranges.",
                    "信号超出已配置的判断范围。"
                ),
                guidance: language.text("Please check manually.", "请手动检查。"),
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
