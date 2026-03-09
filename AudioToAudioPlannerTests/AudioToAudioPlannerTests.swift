import Foundation
import Testing
@testable import AudioToAudioPlanner

struct AudioToAudioPlannerTests {
    private let planner = AudioToAudioPlanner()

    @Test
    func resolvePlanUsesPreferredPresetAndType() throws {
        let capabilities = [
            AudioPresetCapability(
                presetName: "AVAssetExportPresetAppleM4A",
                fileTypeIdentifiers: [AudioContainer.m4a.identifier, AudioContainer.wav.identifier]
            )
        ]

        let settings = AudioToAudioSettings(
            preferredPresetName: "AVAssetExportPresetAppleM4A",
            preferredFileTypeIdentifier: AudioContainer.wav.identifier,
            optimizeForNetworkUse: true,
            clipStartSeconds: 2,
            clipEndSeconds: 10,
            fadeInSeconds: 5,
            fadeOutSeconds: 5
        )

        let plan = try planner.resolvePlan(
            sourceDurationSeconds: 30,
            capabilities: capabilities,
            settings: settings
        )

        #expect(plan.presetName == "AVAssetExportPresetAppleM4A")
        #expect(plan.fileTypeIdentifier == AudioContainer.wav.identifier)
        #expect(plan.clipStartSeconds == 2)
        #expect(plan.clipDurationSeconds == 8)
        #expect(plan.fadeInSeconds == 4)
        #expect(plan.fadeOutSeconds == 4)
    }

    @Test
    func autoSelectionPrefersM4A() throws {
        let capabilities = [
            AudioPresetCapability(
                presetName: "CustomPreset",
                fileTypeIdentifiers: [AudioContainer.wav.identifier, AudioContainer.m4a.identifier]
            )
        ]

        let plan = try planner.resolvePlan(
            sourceDurationSeconds: 15,
            capabilities: capabilities,
            settings: .default
        )

        #expect(plan.fileTypeIdentifier == AudioContainer.m4a.identifier)
    }

    @Test
    func resolvePlanRejectsUnsupportedPreset() {
        let capabilities = [
            AudioPresetCapability(
                presetName: "AVAssetExportPresetAppleM4A",
                fileTypeIdentifiers: [AudioContainer.m4a.identifier]
            )
        ]

        let settings = AudioToAudioSettings(
            preferredPresetName: "AVAssetExportPresetPassthrough",
            preferredFileTypeIdentifier: nil,
            optimizeForNetworkUse: true,
            clipStartSeconds: 0,
            clipEndSeconds: nil,
            fadeInSeconds: 0,
            fadeOutSeconds: 0
        )

        #expect(throws: AudioToAudioPlannerError.unsupportedPreset) {
            _ = try planner.resolvePlan(
                sourceDurationSeconds: 15,
                capabilities: capabilities,
                settings: settings
            )
        }
    }

    @Test
    func resolvePlanRejectsUnsupportedFileType() {
        let capabilities = [
            AudioPresetCapability(
                presetName: "AVAssetExportPresetAppleM4A",
                fileTypeIdentifiers: [AudioContainer.m4a.identifier]
            )
        ]

        let settings = AudioToAudioSettings(
            preferredPresetName: "AVAssetExportPresetAppleM4A",
            preferredFileTypeIdentifier: AudioContainer.wav.identifier,
            optimizeForNetworkUse: true,
            clipStartSeconds: 0,
            clipEndSeconds: nil,
            fadeInSeconds: 0,
            fadeOutSeconds: 0
        )

        #expect(throws: AudioToAudioPlannerError.unsupportedFileType) {
            _ = try planner.resolvePlan(
                sourceDurationSeconds: 15,
                capabilities: capabilities,
                settings: settings
            )
        }
    }

    @Test
    func resolvePlanRejectsInvalidClipRange() {
        let capabilities = [
            AudioPresetCapability(
                presetName: "AVAssetExportPresetAppleM4A",
                fileTypeIdentifiers: [AudioContainer.m4a.identifier]
            )
        ]

        let settings = AudioToAudioSettings(
            preferredPresetName: nil,
            preferredFileTypeIdentifier: nil,
            optimizeForNetworkUse: true,
            clipStartSeconds: 12,
            clipEndSeconds: 3,
            fadeInSeconds: 0,
            fadeOutSeconds: 0
        )

        #expect(throws: AudioToAudioPlannerError.invalidClipRange) {
            _ = try planner.resolvePlan(
                sourceDurationSeconds: 15,
                capabilities: capabilities,
                settings: settings
            )
        }
    }

    @Test
    func resolvePlanRejectsInvalidSourceDuration() {
        let capabilities = [
            AudioPresetCapability(
                presetName: "AVAssetExportPresetAppleM4A",
                fileTypeIdentifiers: [AudioContainer.m4a.identifier]
            )
        ]

        #expect(throws: AudioToAudioPlannerError.invalidSourceDuration) {
            _ = try planner.resolvePlan(
                sourceDurationSeconds: 0,
                capabilities: capabilities,
                settings: .default
            )
        }

        #expect(throws: AudioToAudioPlannerError.invalidSourceDuration) {
            _ = try planner.resolvePlan(
                sourceDurationSeconds: -1,
                capabilities: capabilities,
                settings: .default
            )
        }
    }

    @Test
    func resolvePlanRejectsNoPresetCapabilities() {
        #expect(throws: AudioToAudioPlannerError.noPresetCapabilities) {
            _ = try planner.resolvePlan(
                sourceDurationSeconds: 10,
                capabilities: [],
                settings: .default
            )
        }
    }

    @Test
    func resolvePlanClampsRangeAndNegativeFades() throws {
        let capabilities = [
            AudioPresetCapability(
                presetName: "AVAssetExportPresetAppleM4A",
                fileTypeIdentifiers: [AudioContainer.m4a.identifier]
            )
        ]

        let settings = AudioToAudioSettings(
            preferredPresetName: nil,
            preferredFileTypeIdentifier: nil,
            optimizeForNetworkUse: false,
            clipStartSeconds: -3,
            clipEndSeconds: 99,
            fadeInSeconds: -2,
            fadeOutSeconds: -7
        )

        let plan = try planner.resolvePlan(
            sourceDurationSeconds: 12,
            capabilities: capabilities,
            settings: settings
        )

        #expect(plan.clipStartSeconds == 0)
        #expect(plan.clipDurationSeconds == 12)
        #expect(plan.fadeInSeconds == 0)
        #expect(plan.fadeOutSeconds == 0)
        #expect(plan.optimizeForNetworkUse == false)
    }

    @Test
    func resolvePlanClampsFadesToHalfForTinyClip() throws {
        let capabilities = [
            AudioPresetCapability(
                presetName: "AVAssetExportPresetAppleM4A",
                fileTypeIdentifiers: [AudioContainer.m4a.identifier]
            )
        ]

        let settings = AudioToAudioSettings(
            preferredPresetName: nil,
            preferredFileTypeIdentifier: nil,
            optimizeForNetworkUse: true,
            clipStartSeconds: 9.8,
            clipEndSeconds: 10.0,
            fadeInSeconds: 5.0,
            fadeOutSeconds: 7.0
        )

        let plan = try planner.resolvePlan(
            sourceDurationSeconds: 10.0,
            capabilities: capabilities,
            settings: settings
        )

        #expect(abs(plan.clipDurationSeconds - 0.2) < 0.000_001)
        #expect(abs(plan.fadeInSeconds - 0.1) < 0.000_001)
        #expect(abs(plan.fadeOutSeconds - 0.1) < 0.000_001)
    }

    @Test
    func autoPresetSelectionUsesPreferredPresetOrder() throws {
        let capabilities = [
            AudioPresetCapability(
                presetName: "AVAssetExportPresetMediumQuality",
                fileTypeIdentifiers: [AudioContainer.wav.identifier]
            ),
            AudioPresetCapability(
                presetName: "AVAssetExportPresetPassthrough",
                fileTypeIdentifiers: [AudioContainer.wav.identifier]
            ),
            AudioPresetCapability(
                presetName: "AVAssetExportPresetAppleM4A",
                fileTypeIdentifiers: [AudioContainer.m4a.identifier]
            )
        ]

        let plan = try planner.resolvePlan(
            sourceDurationSeconds: 10,
            capabilities: capabilities,
            settings: .default
        )

        #expect(plan.presetName == "AVAssetExportPresetAppleM4A")
    }

    @Test
    func autoPresetSelectionFallsBackToFirstCapability() throws {
        let capabilities = [
            AudioPresetCapability(
                presetName: "MyCustomPresetA",
                fileTypeIdentifiers: [AudioContainer.wav.identifier]
            ),
            AudioPresetCapability(
                presetName: "MyCustomPresetB",
                fileTypeIdentifiers: [AudioContainer.m4a.identifier]
            )
        ]

        let plan = try planner.resolvePlan(
            sourceDurationSeconds: 10,
            capabilities: capabilities,
            settings: .default
        )

        #expect(plan.presetName == "MyCustomPresetA")
    }

    @Test
    func autoFileTypeFallsBackToFirstUnknownIdentifier() throws {
        let unknownA = "public.audio-custom-a"
        let unknownB = "public.audio-custom-b"
        let capabilities = [
            AudioPresetCapability(
                presetName: "CustomPreset",
                fileTypeIdentifiers: [unknownA, unknownB]
            )
        ]

        let plan = try planner.resolvePlan(
            sourceDurationSeconds: 10,
            capabilities: capabilities,
            settings: .default
        )

        #expect(plan.fileTypeIdentifier == unknownA)
    }

    @Test
    func autoFileTypeUsesPreferredContainerOrderNotCapabilityOrder() throws {
        let capabilities = [
            AudioPresetCapability(
                presetName: "CustomPreset",
                fileTypeIdentifiers: [AudioContainer.wav.identifier, AudioContainer.caf.identifier]
            )
        ]

        let plan = try planner.resolvePlan(
            sourceDurationSeconds: 10,
            capabilities: capabilities,
            settings: .default
        )

        #expect(plan.fileTypeIdentifier == AudioContainer.caf.identifier)
    }

    @Test
    func resolvePlanRejectsPresetWithNoOutputFileTypes() {
        let capabilities = [
            AudioPresetCapability(
                presetName: "AVAssetExportPresetAppleM4A",
                fileTypeIdentifiers: []
            )
        ]

        #expect(throws: AudioToAudioPlannerError.unsupportedFileType) {
            _ = try planner.resolvePlan(
                sourceDurationSeconds: 10,
                capabilities: capabilities,
                settings: .default
            )
        }
    }

    @Test
    func suggestBoundariesFindsNearbyLowEnergyAnchors() {
        let timeline: [Double] = [
            0.8, 0.9, 0.95, 0.3, 0.12, 0.07, 0.5, 0.7,
            0.8, 0.85, 0.77, 0.2, 0.09, 0.04, 0.5, 0.75
        ]

        let suggestion = planner.suggestBoundaries(
            requestedStartSeconds: 0.2,
            requestedEndSeconds: 1.2,
            sourceDurationSeconds: 1.6,
            energyTimeline: timeline,
            frameDurationSeconds: 0.1,
            maxShiftSeconds: 0.5,
            minClipDurationSeconds: 0.3
        )

        #expect(suggestion != nil)
        #expect((suggestion?.suggestedStartSeconds ?? 0) >= 0.3)
        #expect((suggestion?.suggestedStartSeconds ?? 0) <= 0.6)
        #expect((suggestion?.suggestedEndSeconds ?? 0) >= 1.1)
        #expect((suggestion?.suggestedEndSeconds ?? 0) <= 1.4)
        #expect((suggestion?.confidence ?? 0) > 0)
    }

    @Test
    func suggestBoundariesReturnsNilWhenNoChangeNeeded() {
        let timeline = Array(repeating: 0.5, count: 40)

        let suggestion = planner.suggestBoundaries(
            requestedStartSeconds: 0.5,
            requestedEndSeconds: 2.5,
            sourceDurationSeconds: 4,
            energyTimeline: timeline,
            frameDurationSeconds: 0.1,
            maxShiftSeconds: 0.2,
            minClipDurationSeconds: 0.3
        )

        #expect(suggestion == nil)
    }

    @Test
    func suggestBoundariesReturnsNilForInvalidInputs() {
        let timeline = Array(repeating: 0.4, count: 10)

        #expect(
            planner.suggestBoundaries(
                requestedStartSeconds: 0.2,
                requestedEndSeconds: 0.8,
                sourceDurationSeconds: 0,
                energyTimeline: timeline,
                frameDurationSeconds: 0.1
            ) == nil
        )

        #expect(
            planner.suggestBoundaries(
                requestedStartSeconds: 0.2,
                requestedEndSeconds: 0.8,
                sourceDurationSeconds: 2,
                energyTimeline: timeline,
                frameDurationSeconds: 0
            ) == nil
        )

        #expect(
            planner.suggestBoundaries(
                requestedStartSeconds: 0.2,
                requestedEndSeconds: 0.8,
                sourceDurationSeconds: 2,
                energyTimeline: [0.4, 0.3, 0.2],
                frameDurationSeconds: 0.1
            ) == nil
        )
    }

    @Test
    func suggestBoundariesClampsOutOfBoundsRangeAndRespectsMinDuration() {
        let timeline: [Double] = [0.9, 0.9, 0.8, 0.1, 0.0, 0.2, 0.9, 1.0, 0.9, 0.1]

        let suggestion = planner.suggestBoundaries(
            requestedStartSeconds: 0.7,
            requestedEndSeconds: 0.8,
            sourceDurationSeconds: 1.0,
            energyTimeline: timeline,
            frameDurationSeconds: 0.1,
            maxShiftSeconds: 0.5,
            minClipDurationSeconds: 0.5
        )

        #expect(suggestion != nil)
        #expect((suggestion?.suggestedStartSeconds ?? -1) >= 0)
        #expect((suggestion?.suggestedEndSeconds ?? 2) <= 1.0)
        #expect(((suggestion?.suggestedEndSeconds ?? 0) - (suggestion?.suggestedStartSeconds ?? 0)) >= 0.5)
    }

    @Test
    func suggestBoundariesHandlesReversedRequestedRange() {
        let timeline: [Double] = [
            10, 10, 10, 0, 0, 0, 0, 0, 10, 10,
            10, 10, 10, 10, 10, 0, 0, 0, 0, 0
        ]

        let suggestion = planner.suggestBoundaries(
            requestedStartSeconds: 1.0,
            requestedEndSeconds: 0.2,
            sourceDurationSeconds: 2.0,
            energyTimeline: timeline,
            frameDurationSeconds: 0.1,
            maxShiftSeconds: 0.5,
            minClipDurationSeconds: 0.4
        )

        #expect(suggestion != nil)
        #expect(abs((suggestion?.suggestedStartSeconds ?? 0) - 0.5) < 0.000_001)
        #expect(abs((suggestion?.suggestedEndSeconds ?? 0) - 1.7) < 0.000_001)
        #expect(((suggestion?.suggestedEndSeconds ?? 0) - (suggestion?.suggestedStartSeconds ?? 0)) >= 0.4)
        #expect((suggestion?.confidence ?? -1) >= 0)
        #expect((suggestion?.confidence ?? 2) <= 1)
    }

    @Test
    func suggestBoundariesAllowsOneFrameShiftWhenMaxShiftSecondsIsZero() {
        let timeline: [Double] = [0, 0, 0, 10, 10, 10, 10, 10, 0, 0]

        let suggestion = planner.suggestBoundaries(
            requestedStartSeconds: 0.3,
            requestedEndSeconds: 0.7,
            sourceDurationSeconds: 1.0,
            energyTimeline: timeline,
            frameDurationSeconds: 0.1,
            maxShiftSeconds: 0,
            minClipDurationSeconds: 0.3
        )

        #expect(suggestion != nil)
        #expect(abs((suggestion?.suggestedStartSeconds ?? 0) - 0.2) < 0.000_001)
        #expect(abs((suggestion?.suggestedEndSeconds ?? 0) - 0.8) < 0.000_001)
    }

    @Test
    func confidenceLabelUsesExpectedThresholds() {
        let high = SmartTrimSuggestion(suggestedStartSeconds: 0, suggestedEndSeconds: 1, confidence: 0.66)
        let medium = SmartTrimSuggestion(suggestedStartSeconds: 0, suggestedEndSeconds: 1, confidence: 0.4)
        let low = SmartTrimSuggestion(suggestedStartSeconds: 0, suggestedEndSeconds: 1, confidence: 0.1)

        #expect(high.confidenceLabel == "High")
        #expect(medium.confidenceLabel == "Medium")
        #expect(low.confidenceLabel == "Low")
    }

    @Test
    func allOutputFileTypesDeduplicatesAndPreservesOrder() {
        let capabilities = [
            AudioPresetCapability(
                presetName: "A",
                fileTypeIdentifiers: [AudioContainer.m4a.identifier, AudioContainer.wav.identifier]
            ),
            AudioPresetCapability(
                presetName: "B",
                fileTypeIdentifiers: [AudioContainer.wav.identifier, AudioContainer.caf.identifier]
            )
        ]

        let list = planner.allOutputFileTypeIdentifiers(capabilities: capabilities)
        #expect(list == [AudioContainer.m4a.identifier, AudioContainer.wav.identifier, AudioContainer.caf.identifier])
    }

    @Test
    func allOutputFileTypesReturnsEmptyForEmptyCapabilities() {
        let list = planner.allOutputFileTypeIdentifiers(capabilities: [])
        #expect(list.isEmpty)
    }

    @Test
    func workflowHappyPathTransitions() throws {
        var state = AudioWorkflowState()

        state = try planner.transition(from: state, event: .sourceSelected)
        #expect(state.step == .trim)
        #expect(!state.isProcessing)

        state = try planner.transition(from: state, event: .trimStarted)
        #expect(state.step == .trim)
        #expect(state.isProcessing)

        state = try planner.transition(from: state, event: .trimSucceeded)
        #expect(state.step == .result)
        #expect(!state.isProcessing)

        state = try planner.transition(from: state, event: .restart)
        #expect(state.step == .source)
        #expect(!state.isProcessing)
    }

    @Test
    func workflowRejectsInvalidTransitions() {
        let state = AudioWorkflowState(step: .source, isProcessing: false)

        #expect(throws: AudioWorkflowError.invalidTransition) {
            _ = try planner.transition(from: state, event: .trimStarted)
        }

        #expect(throws: AudioWorkflowError.invalidTransition) {
            _ = try planner.transition(from: state, event: .trimSucceeded)
        }
    }

    @Test
    func workflowSupportsSourceClearedAndTrimFailed() throws {
        let cleared = try planner.transition(
            from: AudioWorkflowState(step: .result, isProcessing: true),
            event: .sourceCleared
        )
        #expect(cleared.step == .source)
        #expect(!cleared.isProcessing)

        let failed = try planner.transition(
            from: AudioWorkflowState(step: .trim, isProcessing: true),
            event: .trimFailed
        )
        #expect(failed.step == .trim)
        #expect(!failed.isProcessing)
    }

    @Test
    func workflowRejectsTrimFailedWhenNotProcessing() {
        #expect(throws: AudioWorkflowError.invalidTransition) {
            _ = try planner.transition(
                from: AudioWorkflowState(step: .trim, isProcessing: false),
                event: .trimFailed
            )
        }
    }

    @Test
    func workflowRejectsTrimSucceededOutsideTrimStep() {
        #expect(throws: AudioWorkflowError.invalidTransition) {
            _ = try planner.transition(
                from: AudioWorkflowState(step: .source, isProcessing: true),
                event: .trimSucceeded
            )
        }
    }

    @Test
    func workflowRejectsTrimFailedOutsideTrimStep() {
        #expect(throws: AudioWorkflowError.invalidTransition) {
            _ = try planner.transition(
                from: AudioWorkflowState(step: .result, isProcessing: true),
                event: .trimFailed
            )
        }
    }
}
