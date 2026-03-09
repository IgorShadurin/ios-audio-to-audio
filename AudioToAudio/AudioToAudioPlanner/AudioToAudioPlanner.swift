import Foundation

public struct AudioContainer: Hashable, Codable, Sendable {
    public let identifier: String

    public init(identifier: String) {
        self.identifier = identifier
    }

    public static let m4a = AudioContainer(identifier: "com.apple.m4a-audio")
    public static let mp3 = AudioContainer(identifier: "public.mp3")
    public static let caf = AudioContainer(identifier: "com.apple.coreaudio-format")
    public static let wav = AudioContainer(identifier: "com.microsoft.waveform-audio")
    public static let aiff = AudioContainer(identifier: "public.aiff-audio")
    public static let aifc = AudioContainer(identifier: "public.aifc-audio")
    public static let quickTimeAudio = AudioContainer(identifier: "com.apple.quicktime-audio")

    public static let preferredAutoOrder: [AudioContainer] = [
        .mp3,
        .wav,
        .m4a,
        .aiff,
        .caf,
        .aifc,
        .quickTimeAudio
    ]
}

public struct AudioPresetCapability: Hashable, Codable, Sendable {
    public let presetName: String
    public let fileTypeIdentifiers: [String]

    public init(presetName: String, fileTypeIdentifiers: [String]) {
        self.presetName = presetName
        self.fileTypeIdentifiers = fileTypeIdentifiers
    }
}

public struct AudioToAudioSettings: Equatable, Codable, Sendable {
    public var preferredPresetName: String?
    public var preferredFileTypeIdentifier: String?
    public var optimizeForNetworkUse: Bool
    public var clipStartSeconds: Double
    public var clipEndSeconds: Double?
    public var fadeInSeconds: Double
    public var fadeOutSeconds: Double

    public init(
        preferredPresetName: String?,
        preferredFileTypeIdentifier: String?,
        optimizeForNetworkUse: Bool,
        clipStartSeconds: Double,
        clipEndSeconds: Double?,
        fadeInSeconds: Double,
        fadeOutSeconds: Double
    ) {
        self.preferredPresetName = preferredPresetName
        self.preferredFileTypeIdentifier = preferredFileTypeIdentifier
        self.optimizeForNetworkUse = optimizeForNetworkUse
        self.clipStartSeconds = clipStartSeconds
        self.clipEndSeconds = clipEndSeconds
        self.fadeInSeconds = fadeInSeconds
        self.fadeOutSeconds = fadeOutSeconds
    }

    public static let `default` = AudioToAudioSettings(
        preferredPresetName: nil,
        preferredFileTypeIdentifier: nil,
        optimizeForNetworkUse: true,
        clipStartSeconds: 0,
        clipEndSeconds: nil,
        fadeInSeconds: 0,
        fadeOutSeconds: 0
    )
}

public struct AudioToAudioPlan: Equatable, Sendable {
    public let presetName: String
    public let fileTypeIdentifier: String
    public let clipStartSeconds: Double
    public let clipDurationSeconds: Double
    public let fadeInSeconds: Double
    public let fadeOutSeconds: Double
    public let optimizeForNetworkUse: Bool
    public let reason: String

    public init(
        presetName: String,
        fileTypeIdentifier: String,
        clipStartSeconds: Double,
        clipDurationSeconds: Double,
        fadeInSeconds: Double,
        fadeOutSeconds: Double,
        optimizeForNetworkUse: Bool,
        reason: String
    ) {
        self.presetName = presetName
        self.fileTypeIdentifier = fileTypeIdentifier
        self.clipStartSeconds = clipStartSeconds
        self.clipDurationSeconds = clipDurationSeconds
        self.fadeInSeconds = fadeInSeconds
        self.fadeOutSeconds = fadeOutSeconds
        self.optimizeForNetworkUse = optimizeForNetworkUse
        self.reason = reason
    }
}

public struct SmartTrimSuggestion: Equatable, Sendable {
    public let suggestedStartSeconds: Double
    public let suggestedEndSeconds: Double
    public let confidence: Double

    public init(suggestedStartSeconds: Double, suggestedEndSeconds: Double, confidence: Double) {
        self.suggestedStartSeconds = suggestedStartSeconds
        self.suggestedEndSeconds = suggestedEndSeconds
        self.confidence = confidence
    }

    public var confidenceLabel: String {
        switch confidence {
        case 0.66...:
            return "High"
        case 0.33...:
            return "Medium"
        default:
            return "Low"
        }
    }
}

public enum AudioToAudioPlannerError: Error, Equatable, LocalizedError {
    case noPresetCapabilities
    case invalidSourceDuration
    case invalidClipRange
    case unsupportedPreset
    case unsupportedFileType

    public var errorDescription: String? {
        switch self {
        case .noPresetCapabilities:
            return "No compatible audio trim presets are available for this source."
        case .invalidSourceDuration:
            return "The source duration is invalid."
        case .invalidClipRange:
            return "The selected trim range is invalid."
        case .unsupportedPreset:
            return "The selected export preset is unsupported for this source."
        case .unsupportedFileType:
            return "The selected audio format is unsupported for the chosen preset."
        }
    }
}

public struct AudioToAudioPlanner {
    public init() {}

    public func resolvePlan(
        sourceDurationSeconds: Double,
        capabilities: [AudioPresetCapability],
        settings: AudioToAudioSettings
    ) throws -> AudioToAudioPlan {
        guard sourceDurationSeconds > 0 else {
            throw AudioToAudioPlannerError.invalidSourceDuration
        }

        guard !capabilities.isEmpty else {
            throw AudioToAudioPlannerError.noPresetCapabilities
        }

        let clipStart = max(0, settings.clipStartSeconds)
        let clipEndCandidate = settings.clipEndSeconds ?? sourceDurationSeconds
        let clipEnd = min(sourceDurationSeconds, clipEndCandidate)

        guard clipEnd > clipStart else {
            throw AudioToAudioPlannerError.invalidClipRange
        }

        let clipDuration = clipEnd - clipStart
        let fadeIn = max(0, min(settings.fadeInSeconds, clipDuration / 2))
        let fadeOut = max(0, min(settings.fadeOutSeconds, clipDuration / 2))

        let capability = try selectPreset(capabilities: capabilities, preferredPresetName: settings.preferredPresetName)
        let fileTypeIdentifier = try selectFileType(capability: capability, preferredFileTypeIdentifier: settings.preferredFileTypeIdentifier)

        return AudioToAudioPlan(
            presetName: capability.presetName,
            fileTypeIdentifier: fileTypeIdentifier,
            clipStartSeconds: clipStart,
            clipDurationSeconds: clipDuration,
            fadeInSeconds: fadeIn,
            fadeOutSeconds: fadeOut,
            optimizeForNetworkUse: settings.optimizeForNetworkUse,
            reason: "Resolved from source-compatible AVFoundation audio export capabilities"
        )
    }

    public func suggestBoundaries(
        requestedStartSeconds: Double,
        requestedEndSeconds: Double,
        sourceDurationSeconds: Double,
        energyTimeline: [Double],
        frameDurationSeconds: Double,
        maxShiftSeconds: Double = 0.45,
        minClipDurationSeconds: Double = 0.3
    ) -> SmartTrimSuggestion? {
        guard sourceDurationSeconds > 0,
              frameDurationSeconds > 0,
              energyTimeline.count >= 4
        else {
            return nil
        }

        let clampedStart = max(0, min(requestedStartSeconds, sourceDurationSeconds))
        let clampedEnd = max(clampedStart + minClipDurationSeconds, min(requestedEndSeconds, sourceDurationSeconds))

        let totalFrames = energyTimeline.count
        let minFrames = max(1, Int((minClipDurationSeconds / frameDurationSeconds).rounded()))
        let maxShiftFrames = max(1, Int((maxShiftSeconds / frameDurationSeconds).rounded()))

        let startIndex = timeToIndex(clampedStart, frameDurationSeconds: frameDurationSeconds, limit: totalFrames)
        var endIndex = timeToIndex(clampedEnd, frameDurationSeconds: frameDurationSeconds, limit: totalFrames)

        if endIndex - startIndex < minFrames {
            endIndex = min(totalFrames - 1, startIndex + minFrames)
        }

        let suggestedStart = bestBoundaryIndex(
            around: startIndex,
            minIndex: 0,
            maxIndex: max(0, endIndex - minFrames),
            maxShiftFrames: maxShiftFrames,
            energyTimeline: energyTimeline
        )

        let suggestedEnd = bestBoundaryIndex(
            around: endIndex,
            minIndex: min(totalFrames - 1, suggestedStart + minFrames),
            maxIndex: totalFrames - 1,
            maxShiftFrames: maxShiftFrames,
            energyTimeline: energyTimeline
        )

        guard suggestedEnd > suggestedStart else {
            return nil
        }

        let originalEnergy = localEnergy(at: startIndex, energyTimeline: energyTimeline) + localEnergy(at: endIndex, energyTimeline: energyTimeline)
        let suggestedEnergy = localEnergy(at: suggestedStart, energyTimeline: energyTimeline) + localEnergy(at: suggestedEnd, energyTimeline: energyTimeline)
        let improvement = max(0, (originalEnergy - suggestedEnergy) / max(originalEnergy, 0.0001))
        let shiftMagnitude = abs(suggestedStart - startIndex) + abs(suggestedEnd - endIndex)

        if shiftMagnitude == 0 {
            return nil
        }

        let confidence = min(1, max(0, 0.2 + (improvement * 0.8)))

        let suggestedStartSeconds = min(sourceDurationSeconds, Double(suggestedStart) * frameDurationSeconds)
        let suggestedEndSeconds = min(sourceDurationSeconds, Double(suggestedEnd) * frameDurationSeconds)

        return SmartTrimSuggestion(
            suggestedStartSeconds: suggestedStartSeconds,
            suggestedEndSeconds: max(suggestedStartSeconds + minClipDurationSeconds, suggestedEndSeconds),
            confidence: confidence
        )
    }

    public func allOutputFileTypeIdentifiers(capabilities: [AudioPresetCapability]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for capability in capabilities {
            for identifier in capability.fileTypeIdentifiers where !seen.contains(identifier) {
                seen.insert(identifier)
                ordered.append(identifier)
            }
        }
        return ordered.sorted { lhs, rhs in
            rankForFileTypeIdentifier(lhs) < rankForFileTypeIdentifier(rhs)
        }
    }

    public func transition(from state: AudioWorkflowState, event: AudioWorkflowEvent) throws -> AudioWorkflowState {
        switch event {
        case .sourceSelected:
            return AudioWorkflowState(step: .trim, isProcessing: false)
        case .sourceCleared:
            return AudioWorkflowState(step: .source, isProcessing: false)
        case .trimStarted:
            guard state.step == .trim, !state.isProcessing else {
                throw AudioWorkflowError.invalidTransition
            }
            return AudioWorkflowState(step: .trim, isProcessing: true)
        case .trimSucceeded:
            guard state.step == .trim, state.isProcessing else {
                throw AudioWorkflowError.invalidTransition
            }
            return AudioWorkflowState(step: .result, isProcessing: false)
        case .trimFailed:
            guard state.step == .trim, state.isProcessing else {
                throw AudioWorkflowError.invalidTransition
            }
            return AudioWorkflowState(step: .trim, isProcessing: false)
        case .restart:
            return AudioWorkflowState(step: .source, isProcessing: false)
        }
    }

    private func selectPreset(capabilities: [AudioPresetCapability], preferredPresetName: String?) throws -> AudioPresetCapability {
        if let preferredPresetName {
            guard let preferred = capabilities.first(where: { $0.presetName == preferredPresetName }) else {
                throw AudioToAudioPlannerError.unsupportedPreset
            }
            return preferred
        }

        let preferredPresetOrder = [
            "AVAssetExportPresetAppleM4A",
            "AVAssetExportPresetPassthrough",
            "AVAssetExportPresetHighestQuality",
            "AVAssetExportPresetMediumQuality",
            "AVAssetExportPresetLowQuality"
        ]

        for preset in preferredPresetOrder {
            if let capability = capabilities.first(where: { $0.presetName == preset }) {
                return capability
            }
        }

        return capabilities[0]
    }

    private func selectFileType(capability: AudioPresetCapability, preferredFileTypeIdentifier: String?) throws -> String {
        guard !capability.fileTypeIdentifiers.isEmpty else {
            throw AudioToAudioPlannerError.unsupportedFileType
        }

        if let preferredFileTypeIdentifier {
            guard capability.fileTypeIdentifiers.contains(preferredFileTypeIdentifier) else {
                throw AudioToAudioPlannerError.unsupportedFileType
            }
            return preferredFileTypeIdentifier
        }

        for preferred in AudioContainer.preferredAutoOrder {
            if capability.fileTypeIdentifiers.contains(preferred.identifier) {
                return preferred.identifier
            }
        }

        return capability.fileTypeIdentifiers[0]
    }

    private func rankForFileTypeIdentifier(_ identifier: String) -> Int {
        if let index = AudioContainer.preferredAutoOrder.firstIndex(where: { $0.identifier == identifier }) {
            return index
        }
        return Int.max
    }

    private func timeToIndex(_ seconds: Double, frameDurationSeconds: Double, limit: Int) -> Int {
        let raw = Int((seconds / frameDurationSeconds).rounded())
        return min(max(raw, 0), max(0, limit - 1))
    }

    private func bestBoundaryIndex(
        around targetIndex: Int,
        minIndex: Int,
        maxIndex: Int,
        maxShiftFrames: Int,
        energyTimeline: [Double]
    ) -> Int {
        guard minIndex <= maxIndex else {
            return targetIndex
        }

        let searchStart = max(minIndex, targetIndex - maxShiftFrames)
        let searchEnd = min(maxIndex, targetIndex + maxShiftFrames)
        if searchStart > searchEnd {
            return min(max(targetIndex, minIndex), maxIndex)
        }

        var bestIndex = targetIndex
        var bestScore = Double.greatestFiniteMagnitude

        for idx in searchStart...searchEnd {
            let normalizedDistance = Double(abs(idx - targetIndex)) / Double(max(1, maxShiftFrames))
            let distancePenalty = normalizedDistance * 0.22
            let score = localEnergy(at: idx, energyTimeline: energyTimeline) + distancePenalty
            if score < bestScore {
                bestScore = score
                bestIndex = idx
            }
        }

        return bestIndex
    }

    private func localEnergy(at index: Int, energyTimeline: [Double]) -> Double {
        let start = max(0, index - 2)
        let end = min(energyTimeline.count - 1, index + 2)
        var total = 0.0
        var count = 0

        for idx in start...end {
            total += energyTimeline[idx]
            count += 1
        }

        return count == 0 ? 0 : total / Double(count)
    }
}

public enum AudioWorkflowStep: String, Equatable, Codable, Sendable {
    case source
    case trim
    case result
}

public struct AudioWorkflowState: Equatable, Codable, Sendable {
    public var step: AudioWorkflowStep
    public var isProcessing: Bool

    public init(step: AudioWorkflowStep = .source, isProcessing: Bool = false) {
        self.step = step
        self.isProcessing = isProcessing
    }
}

public enum AudioWorkflowEvent: Equatable, Sendable {
    case sourceSelected
    case sourceCleared
    case trimStarted
    case trimSucceeded
    case trimFailed
    case restart
}

public enum AudioWorkflowError: Error, Equatable, LocalizedError {
    case invalidTransition

    public var errorDescription: String? {
        switch self {
        case .invalidTransition:
            return "This action is not allowed in the current workflow state."
        }
    }
}
