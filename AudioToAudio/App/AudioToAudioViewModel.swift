import Combine
import AVFoundation
import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AudioToAudioViewModel: ObservableObject {
    private enum SourceLoadError: LocalizedError {
        case nothingSelected

        var errorDescription: String? {
            switch self {
            case .nothingSelected:
                return L10n.tr("error.no_source_selected")
            }
        }
    }

    @Published var pickerItem: PhotosPickerItem?

    @Published var selectedPresetID: String = OutputPresetOption.autoID {
        didSet {
            if selectedPresetID != oldValue {
                ensureSelectedFileTypeIsSupported()
            }
            persistSettingsIfNeeded()
            validateCurrentPlan()
        }
    }

    @Published var selectedFileTypeID: String = OutputFileTypeOption.autoID {
        didSet {
            persistSettingsIfNeeded()
            validateCurrentPlan()
        }
    }

    @Published var optimizeForNetworkUse: Bool = true {
        didSet {
            persistSettingsIfNeeded()
            validateCurrentPlan()
        }
    }

    @Published var clipStartSeconds: Double = 0 {
        didSet {
            guard !isNormalizingClipRange else { return }
            normalizeClipRange()
            persistSettingsIfNeeded()
            validateCurrentPlan()
        }
    }

    @Published var useClipEnd: Bool = false {
        didSet {
            guard !isNormalizingClipRange else { return }
            normalizeClipRange()
            persistSettingsIfNeeded()
            validateCurrentPlan()
        }
    }

    @Published var clipEndSeconds: Double = 0 {
        didSet {
            guard !isNormalizingClipRange else { return }
            normalizeClipRange()
            persistSettingsIfNeeded()
            validateCurrentPlan()
        }
    }

    @Published var fadeInSeconds: Double = 0 {
        didSet {
            guard !isNormalizingFades else { return }
            normalizeFades()
            persistSettingsIfNeeded()
            validateCurrentPlan()
        }
    }

    @Published var fadeOutSeconds: Double = 0 {
        didSet {
            guard !isNormalizingFades else { return }
            normalizeFades()
            persistSettingsIfNeeded()
            validateCurrentPlan()
        }
    }

    @Published private(set) var workflowStep: AudioWorkflowStep = .source
    @Published private(set) var sourceMetadata: SourceAudioMetadata?
    @Published private(set) var capabilities: [AudioPresetCapability] = []
    @Published private(set) var energyAnalysis: AudioEnergyAnalysis?
    @Published private(set) var suggestedBoundaries: SmartTrimSuggestion?
    @Published private(set) var trimmedAudioURL: URL?
    @Published private(set) var trimmedFileSizeBytes: Int64?
    @Published private(set) var trimmedDurationSeconds: Double?

    @Published private(set) var statusMessage: String = L10n.tr("status.pick_source")
    @Published private(set) var errorMessage: String?
    @Published private(set) var validationMessage: String?
    @Published private(set) var isLoadingSourceDetails = false
    @Published private(set) var isTrimming = false
    @Published private(set) var isCancellingTrim = false
    @Published private(set) var trimProgress: Double?
    @Published private(set) var purchaseOptions: [PurchasePlanOption] = []
    @Published private(set) var hasPremiumAccess: Bool = false
    @Published private(set) var isPurchasingPlan: Bool = false
    @Published private(set) var isPaywallPresented: Bool = false
    @Published private(set) var previewPlayheadSeconds: Double = 0
    @Published private(set) var isPreviewPlaying: Bool = false
    @Published private(set) var isResultPreviewPlaying: Bool = false
    @Published private(set) var showcaseStepID: String?

    private let settingsStore = AudioSettingsStore()
    private let sourceInspector = AudioSourceInspector()
    private let trimService = AudioToAudioService()
    private let planner = AudioToAudioPlanner()
    private let purchaseManager = PurchaseManager()
    private let quotaStore = ConversionQuotaStore()
    private var previewPlayer: AVPlayer?
    private var previewPlayerSourceURL: URL?
    private var previewTimeObserverToken: Any?
    private var previewPlaybackEndSeconds: Double = 0
    private var resultPreviewPlayer: AVPlayer?
    private var resultPreviewPlayerSourceURL: URL?
    private var resultPreviewEndObserver: NSObjectProtocol?

    private var isRestoringSettings = false
    private var isNormalizingClipRange = false
    private var isNormalizingFades = false
    private var workflowState = AudioWorkflowState()
    private let minimumClipDurationSeconds = 0.1

    init() {
        SecureMediaFileManager.shared.prepareManagedTempDirectory()
        restoreSettings()
        applyShowcaseStateIfNeeded()
        Task {
            await refreshMonetizationState()
        }
    }

    var presetOptions: [OutputPresetOption] {
        var options = [OutputPresetOption(id: OutputPresetOption.autoID, title: L10n.tr("picker.auto"))]
        for capability in capabilities {
            options.append(OutputPresetOption(id: capability.presetName, title: capability.shortTitle))
        }
        return options
    }

    var fileTypeOptions: [OutputFileTypeOption] {
        var options = [OutputFileTypeOption(id: OutputFileTypeOption.autoID, title: L10n.tr("picker.auto"))]

        let identifiers = planner.allOutputFileTypeIdentifiers(capabilities: capabilities)

        for identifier in identifiers {
            options.append(OutputFileTypeOption(id: identifier, title: audioFileTypeLabel(identifier)))
        }

        return options
    }

    var sourceSummaryText: String? {
        sourceMetadata?.sourceSummary
    }

    var sourceSizeText: String? {
        guard let sourceMetadata else { return nil }
        return humanReadableSize(sourceMetadata.fileSizeBytes)
    }

    var outputSizeText: String? {
        guard let trimmedFileSizeBytes else { return nil }
        return humanReadableSize(trimmedFileSizeBytes)
    }

    var outputDurationText: String? {
        guard let trimmedDurationSeconds else { return nil }
        return formatSeconds(trimmedDurationSeconds)
    }

    var clipDurationRange: ClosedRange<Double> {
        let duration = sourceMetadata?.durationSeconds ?? 0
        return 0...max(duration, 0)
    }

    var effectiveClipEndSeconds: Double {
        guard let metadata = sourceMetadata else { return 0 }
        return useClipEnd ? clipEndSeconds : metadata.durationSeconds
    }

    var effectiveClipDurationSeconds: Double {
        max(0, effectiveClipEndSeconds - clipStartSeconds)
    }

    var canTrim: Bool {
        sourceMetadata != nil && !isLoadingSourceDetails && !isTrimming && validationMessage == nil
    }

    var canUseFreeConversionToday: Bool {
        quotaStore.canUseFreeConversionToday()
    }

    var canStartConversionToday: Bool {
        hasPremiumAccess || canUseFreeConversionToday
    }

    var canCancelTrim: Bool {
        isTrimming && !isCancellingTrim
    }

    var canExportResult: Bool {
        trimmedAudioURL != nil && !isTrimming
    }

    var premiumButtonTitle: String {
        hasPremiumAccess ? L10n.tr("Premium Active") : L10n.tr("Premium")
    }

    var trimProgressText: String? {
        guard let trimProgress else { return nil }
        return "\(Int((trimProgress * 100).rounded()))%"
    }

    var planSummaryText: String? {
        guard let plan = try? currentPlan() else {
            return nil
        }

        return [
            "\(L10n.tr("trim.file_type")): \(audioFileTypeLabel(plan.fileTypeIdentifier))",
            L10n.fmt("trim.fade_in_value", formatSeconds(plan.fadeInSeconds)),
            L10n.fmt("trim.fade_out_value", formatSeconds(plan.fadeOutSeconds))
        ].joined(separator: " • ")
    }

    var smartSuggestionText: String? {
        guard let suggestion = suggestedBoundaries else { return nil }
        let confidencePercent = "\(Int((suggestion.confidence * 100).rounded()))%"
        return "\(formatSeconds(suggestion.suggestedStartSeconds)) - \(formatSeconds(suggestion.suggestedEndSeconds)) • \(confidencePercent)"
    }

    var shouldShowShowcaseFormatList: Bool {
        showcaseStepID == "trim-formats-open"
    }

    var shouldAutoExpandAdvancedSettingsForShowcase: Bool {
        showcaseStepID == "trim-advanced"
    }

    func handlePickerChange() async {
        guard let pickerItem else { return }

        isLoadingSourceDetails = true
        errorMessage = nil
        statusMessage = L10n.tr("status.loading_source")

        do {
            guard let picked = try await pickerItem.loadTransferable(type: PickedMedia.self) else {
                throw SourceLoadError.nothingSelected
            }

            try await loadSource(from: picked.url)
        } catch {
            isLoadingSourceDetails = false
            statusMessage = L10n.tr("status.pick_source")
            errorMessage = localizedErrorMessage(error)
        }
    }

    func handleImportedFile(url: URL) async {
        isLoadingSourceDetails = true
        errorMessage = nil
        statusMessage = L10n.tr("status.loading_source")

        do {
            let localURL = try copyImportedFileToTemporaryLocation(from: url)
            try await loadSource(from: localURL)
        } catch {
            isLoadingSourceDetails = false
            statusMessage = L10n.tr("status.pick_source")
            errorMessage = localizedErrorMessage(error)
        }
    }

    func handleImportFailure(_ message: String) {
        errorMessage = L10n.fmt("error.file_import_failed_fmt", message)
    }

    func presentPaywall() {
        isPaywallPresented = true
        Task {
            await refreshMonetizationState()
        }
    }

    func dismissPaywall() {
        isPaywallPresented = false
    }

    func purchasePlan(planID: String) async {
        guard !isPurchasingPlan else { return }

        isPurchasingPlan = true
        errorMessage = nil

        do {
            let didPurchase = try await purchaseManager.purchase(productID: planID)
            if didPurchase {
                hasPremiumAccess = await purchaseManager.hasActiveEntitlement()
                if hasPremiumAccess {
                    statusMessage = L10n.tr("Premium unlocked. Unlimited usage enabled.")
                    isPaywallPresented = false
                }
            }
        } catch {
            errorMessage = localizedErrorMessage(error)
        }

        isPurchasingPlan = false
        await refreshMonetizationState()
    }

    func restorePurchases() async {
        guard !isPurchasingPlan else { return }

        isPurchasingPlan = true
        errorMessage = nil

        do {
            let hasRestoredAccess = try await purchaseManager.restorePurchases()
            if hasRestoredAccess {
                statusMessage = L10n.tr("Purchases restored. Unlimited usage enabled.")
                isPaywallPresented = false
            } else {
                statusMessage = L10n.tr("No active purchases found.")
            }
        } catch {
            errorMessage = localizedErrorMessage(error)
        }

        isPurchasingPlan = false
        await refreshMonetizationState()
    }

    func suggestSmartBoundaries() {
        guard let sourceMetadata,
              let energyAnalysis
        else {
            errorMessage = L10n.tr("error.no_source_selected")
            return
        }

        let selectionEnd = useClipEnd ? clipEndSeconds : sourceMetadata.durationSeconds

        suggestedBoundaries = planner.suggestBoundaries(
            requestedStartSeconds: clipStartSeconds,
            requestedEndSeconds: selectionEnd,
            sourceDurationSeconds: sourceMetadata.durationSeconds,
            energyTimeline: energyAnalysis.energyTimeline,
            frameDurationSeconds: energyAnalysis.frameDurationSeconds
        )

        if suggestedBoundaries == nil {
            statusMessage = L10n.tr("status.no_better_boundary")
        } else {
            statusMessage = L10n.tr("status.suggestion_ready")
        }
    }

    func applySmartSuggestion() {
        guard let suggestion = suggestedBoundaries,
              let sourceMetadata
        else {
            return
        }

        clipStartSeconds = clamped(suggestion.suggestedStartSeconds, in: 0...sourceMetadata.durationSeconds)
        clipEndSeconds = clamped(suggestion.suggestedEndSeconds, in: 0...sourceMetadata.durationSeconds)
        useClipEnd = true
        normalizeClipRange()
        statusMessage = L10n.tr("status.suggestion_applied")
    }

    func setTrimStart(_ value: Double) {
        guard let sourceMetadata else { return }
        let duration = sourceMetadata.durationSeconds
        let minGap = min(minimumClipDurationSeconds, max(duration, 0))
        useClipEnd = true
        clipStartSeconds = clamped(value, in: 0...max(0, duration - minGap))
        if clipEndSeconds - clipStartSeconds < minGap {
            clipEndSeconds = min(duration, clipStartSeconds + minGap)
        }
    }

    func setTrimEnd(_ value: Double) {
        guard let sourceMetadata else { return }
        let duration = sourceMetadata.durationSeconds
        let minGap = min(minimumClipDurationSeconds, max(duration, 0))
        useClipEnd = true
        clipEndSeconds = clamped(value, in: minGap...duration)
        if clipEndSeconds - clipStartSeconds < minGap {
            clipStartSeconds = max(0, clipEndSeconds - minGap)
        }
    }

    func movePreviewPlayhead(to seconds: Double) {
        guard sourceMetadata != nil else { return }
        let bounded = clampedPreviewPlayhead(seconds)
        previewPlayheadSeconds = bounded
        seekPreviewPlayerIfNeeded(to: bounded)
    }

    func togglePreviewPlayback() {
        if isPreviewPlaying {
            stopPreviewPlayback()
        } else {
            startPreviewPlayback()
        }
    }

    func toggleResultPreviewPlayback() {
        if isResultPreviewPlaying {
            stopResultPreviewPlayback(resetToStart: true)
        } else {
            startResultPreviewPlayback()
        }
    }

    func trim() async {
        guard let sourceMetadata else {
            errorMessage = L10n.tr("error.no_source_selected")
            return
        }

        hasPremiumAccess = await purchaseManager.hasActiveEntitlement()

        stopPreviewPlayback()
        stopResultPreviewPlayback(resetToStart: true)

        let plan: AudioToAudioPlan
        do {
            plan = try currentPlan()
        } catch {
            errorMessage = localizedErrorMessage(error)
            return
        }

        guard canStartConversionToday else {
            statusMessage = L10n.tr("Daily free limit reached.")
            errorMessage = L10n.tr("Free plan allows only 1 usage per day. Upgrade for unlimited usage.")
            isPaywallPresented = true
            return
        }

        do {
            workflowState = try planner.transition(from: workflowState, event: .trimStarted)
            applyWorkflowState()
        } catch {
            errorMessage = localizedErrorMessage(error)
            return
        }

        isTrimming = true
        isCancellingTrim = false
        trimProgress = 0
        removeManagedFileIfNeeded(trimmedAudioURL)
        trimmedAudioURL = nil
        trimmedFileSizeBytes = nil
        trimmedDurationSeconds = nil
        errorMessage = nil
        statusMessage = L10n.tr("status.trimming")

        do {
            let outputURL = try await trimService.trim(
                sourceURL: sourceMetadata.sourceURL,
                plan: plan,
                progressHandler: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.trimProgress = progress
                    }
                }
            )

            let values = try outputURL.resourceValues(forKeys: [.fileSizeKey, .fileAllocatedSizeKey])
            let size = Int64(values.fileSize ?? values.fileAllocatedSize ?? 0)

            workflowState = try planner.transition(from: workflowState, event: .trimSucceeded)
            applyWorkflowState()
            trimmedAudioURL = outputURL
            trimmedFileSizeBytes = size
            let outputDurationSeconds = (try? await AVURLAsset(url: outputURL).load(.duration).seconds) ?? plan.clipDurationSeconds
            trimmedDurationSeconds = outputDurationSeconds.isFinite ? max(0, outputDurationSeconds) : max(0, plan.clipDurationSeconds)

            if !hasPremiumAccess {
                quotaStore.recordFreeConversionToday()
            }

            statusMessage = L10n.tr("status.trim_finished")
        } catch {
            do {
                workflowState = try planner.transition(from: workflowState, event: .trimFailed)
                applyWorkflowState()
            } catch {
                workflowStep = .trim
            }

            if (error as? AudioToAudioServiceError) == .cancelled {
                statusMessage = L10n.tr("status.trimming_cancelled")
                errorMessage = nil
            } else {
                statusMessage = L10n.tr("status.trimming_failed")
                errorMessage = localizedErrorMessage(error)
            }
        }

        isTrimming = false
        isCancellingTrim = false
        trimProgress = nil
        validateCurrentPlan()
    }

#if DEBUG
    func debugResetLimitsForTesting() {
        quotaStore.debugResetFreeConversionsToday()
        errorMessage = nil
        statusMessage = L10n.tr("Debug: free conversion limit reset for today.")
    }
#endif

    func cancelTrim() {
        guard canCancelTrim else { return }
        isCancellingTrim = true
        statusMessage = L10n.tr("status.cancelling")
        trimService.cancelCurrentJob()
    }

    func sourceToTrim() {
        guard sourceMetadata != nil else { return }
        workflowStep = .trim
        workflowState.step = .trim
    }

    func stepBackToSource() {
        stopPreviewPlayback()
        stopResultPreviewPlayback(resetToStart: true)
        workflowStep = .source
        workflowState.step = .source
        workflowState.isProcessing = false
    }

    func restart() {
        stopPreviewPlayback()
        teardownPreviewPlayer()
        stopResultPreviewPlayback(resetToStart: true)
        teardownResultPreviewPlayer()

        removeManagedFileIfNeeded(sourceMetadata?.sourceURL)
        removeManagedFileIfNeeded(trimmedAudioURL)

        workflowStep = .source
        workflowState = AudioWorkflowState()

        sourceMetadata = nil
        capabilities = []
        energyAnalysis = nil
        suggestedBoundaries = nil
        trimmedAudioURL = nil
        trimmedFileSizeBytes = nil
        trimmedDurationSeconds = nil
        errorMessage = nil
        validationMessage = nil
        isTrimming = false
        isCancellingTrim = false
        trimProgress = nil
        statusMessage = L10n.tr("status.pick_source")
        previewPlayheadSeconds = 0
        isPreviewPlaying = false
        isResultPreviewPlaying = false

        clipStartSeconds = 0
        clipEndSeconds = 0
        useClipEnd = false
        fadeInSeconds = 0
        fadeOutSeconds = 0
        selectedPresetID = OutputPresetOption.autoID
        selectedFileTypeID = OutputFileTypeOption.autoID
        optimizeForNetworkUse = true

        persistSettingsIfNeeded()
    }

    private func loadSource(from sourceURL: URL) async throws {
        let metadata = try await sourceInspector.inspect(url: sourceURL)
        let capabilities = sourceInspector.audioExportCapabilities(for: sourceURL)

        guard !capabilities.isEmpty else {
            throw AudioModelError.noAudioExportCapability
        }

        let analysis = try await Task.detached(priority: .userInitiated) {
            try await AudioSourceInspector().analyzeEnergyTimeline(
                url: sourceURL,
                durationSeconds: metadata.durationSeconds
            )
        }.value

        if sourceMetadata?.sourceURL != sourceURL {
            teardownPreviewPlayer()
            teardownResultPreviewPlayer()
            removeManagedFileIfNeeded(sourceMetadata?.sourceURL)
        }
        removeManagedFileIfNeeded(trimmedAudioURL)

        sourceMetadata = metadata
        self.capabilities = capabilities
        energyAnalysis = analysis
        suggestedBoundaries = nil
        trimmedAudioURL = nil
        trimmedFileSizeBytes = nil
        trimmedDurationSeconds = nil
        errorMessage = nil

        resetTrimRangeToFullDuration(metadata.durationSeconds)
        ensureSelectedFileTypeIsSupported()

        do {
            workflowState = try planner.transition(from: workflowState, event: .sourceSelected)
            applyWorkflowState()
        } catch {
            workflowStep = .trim
            workflowState.step = .trim
            workflowState.isProcessing = false
        }

        statusMessage = L10n.tr("status.source_ready")
        isLoadingSourceDetails = false
        validateCurrentPlan()
    }

    private func copyImportedFileToTemporaryLocation(from url: URL) throws -> URL {
        try SecureMediaFileManager.shared.copyToManagedTemp(
            from: url,
            accessSecurityScopedResource: true
        )
    }

    private func removeManagedFileIfNeeded(_ url: URL?) {
        try? SecureMediaFileManager.shared.removeManagedFileIfPresent(url)
    }

    private func currentPlan() throws -> AudioToAudioPlan {
        guard let sourceMetadata else {
            throw AudioToAudioPlannerError.invalidSourceDuration
        }

        let end = useClipEnd ? clipEndSeconds : sourceMetadata.durationSeconds

        let settings = AudioToAudioSettings(
            preferredPresetName: nil,
            preferredFileTypeIdentifier: selectedFileTypeID == OutputFileTypeOption.autoID ? nil : selectedFileTypeID,
            optimizeForNetworkUse: optimizeForNetworkUse,
            clipStartSeconds: clipStartSeconds,
            clipEndSeconds: end,
            fadeInSeconds: fadeInSeconds,
            fadeOutSeconds: fadeOutSeconds
        )

        return try planner.resolvePlan(
            sourceDurationSeconds: sourceMetadata.durationSeconds,
            capabilities: capabilities,
            settings: settings
        )
    }

    private func normalizeClipRange() {
        guard !isNormalizingClipRange else { return }
        isNormalizingClipRange = true
        defer { isNormalizingClipRange = false }

        guard let sourceMetadata else {
            clipStartSeconds = 0
            clipEndSeconds = 0
            return
        }

        let duration = sourceMetadata.durationSeconds
        let minGap = min(minimumClipDurationSeconds, max(duration, 0))
        clipStartSeconds = clamped(clipStartSeconds, in: 0...max(0, duration - minGap))

        if !useClipEnd {
            clipEndSeconds = duration
        } else {
            clipEndSeconds = clamped(clipEndSeconds, in: 0...duration)
            if clipEndSeconds - clipStartSeconds < minGap {
                if clipStartSeconds + minGap <= duration {
                    clipEndSeconds = clipStartSeconds + minGap
                } else {
                    clipStartSeconds = max(0, duration - minGap)
                    clipEndSeconds = duration
                }
            }
        }

        normalizeFades()
        clampPreviewPlaybackToSelection()
    }

    private func resetTrimRangeToFullDuration(_ duration: Double) {
        useClipEnd = true
        clipStartSeconds = 0
        clipEndSeconds = max(0, duration)
        normalizeClipRange()
        previewPlayheadSeconds = clipStartSeconds
    }

    private func normalizeFades() {
        guard !isNormalizingFades else { return }
        isNormalizingFades = true
        defer { isNormalizingFades = false }

        let clipDuration = effectiveClipDurationSeconds
        let maxFade = max(0, clipDuration / 2)
        fadeInSeconds = clamped(fadeInSeconds, in: 0...maxFade)
        fadeOutSeconds = clamped(fadeOutSeconds, in: 0...maxFade)
    }

    private func validateCurrentPlan() {
        guard sourceMetadata != nil else {
            validationMessage = nil
            return
        }

        do {
            _ = try currentPlan()
            validationMessage = nil
        } catch {
            validationMessage = localizedErrorMessage(error)
        }
    }

    private func localizedErrorMessage(_ error: Error) -> String {
        guard let plannerError = error as? AudioToAudioPlannerError else {
            return error.localizedDescription
        }
        return localizedPlannerErrorDescription(plannerError)
    }

    private func localizedPlannerErrorDescription(_ error: AudioToAudioPlannerError) -> String {
        switch error {
        case .invalidClipRange:
            return localizedStaticMessage(
                from: Self.invalidClipRangeMessages,
                fallback: "The selected trim range is invalid."
            )
        case .invalidSourceDuration:
            return localizedStaticMessage(
                from: Self.invalidSourceDurationMessages,
                fallback: "The source duration is invalid."
            )
        case .noPresetCapabilities:
            return L10n.tr("error.no_audio_export_capability")
        case .unsupportedPreset, .unsupportedFileType:
            return L10n.tr("error.unsupported_file_type")
        }
    }

    private func localizedStaticMessage(from dictionary: [String: String], fallback: String) -> String {
        let preferred = Locale.preferredLanguages.map { $0.replacingOccurrences(of: "_", with: "-") }
        for locale in preferred {
            if let exact = dictionary[locale] {
                return exact
            }

            let components = locale.split(separator: "-")
            if components.count > 1 {
                for index in stride(from: components.count - 1, through: 1, by: -1) {
                    let key = components.prefix(index).joined(separator: "-")
                    if let value = dictionary[key] {
                        return value
                    }
                }
            }
        }
        return dictionary["en"] ?? fallback
    }

    private func ensureSelectedFileTypeIsSupported() {
        let available = Set(fileTypeOptions.map(\.id))
        if !available.contains(selectedFileTypeID) {
            selectedFileTypeID = OutputFileTypeOption.autoID
        }
    }

    private func refreshMonetizationState() async {
        purchaseOptions = await purchaseManager.loadPlanOptions()
        hasPremiumAccess = await purchaseManager.hasActiveEntitlement()
    }

    private func persistSettingsIfNeeded() {
        guard !isRestoringSettings else { return }

        let settings = AudioToAudioSettings(
            preferredPresetName: nil,
            preferredFileTypeIdentifier: selectedFileTypeID == OutputFileTypeOption.autoID ? nil : selectedFileTypeID,
            optimizeForNetworkUse: optimizeForNetworkUse,
            clipStartSeconds: clipStartSeconds,
            clipEndSeconds: useClipEnd ? clipEndSeconds : nil,
            fadeInSeconds: fadeInSeconds,
            fadeOutSeconds: fadeOutSeconds
        )

        settingsStore.saveDraftSettings(settings)
    }

    private func restoreSettings() {
        isRestoringSettings = true
        let settings = settingsStore.loadDraftSettings()

        selectedPresetID = OutputPresetOption.autoID
        selectedFileTypeID = settings.preferredFileTypeIdentifier ?? OutputFileTypeOption.autoID
        optimizeForNetworkUse = settings.optimizeForNetworkUse
        clipStartSeconds = settings.clipStartSeconds
        if let clipEnd = settings.clipEndSeconds {
            clipEndSeconds = clipEnd
            useClipEnd = true
        } else {
            clipEndSeconds = 0
            useClipEnd = false
        }

        fadeInSeconds = settings.fadeInSeconds
        fadeOutSeconds = settings.fadeOutSeconds
        isRestoringSettings = false
    }

    private func applyWorkflowState() {
        workflowStep = workflowState.step
    }

    private func applyShowcaseStateIfNeeded() {
        let arguments = ProcessInfo.processInfo.arguments
        let showcaseStep = parseShowcaseStep(from: arguments)
        guard let showcaseStep else {
            return
        }
        showcaseStepID = showcaseStep

        if showcaseStep == "main-empty" {
            workflowStep = .source
            statusMessage = L10n.tr("status.pick_source")
            return
        }

        let demoURL = FileManager.default.temporaryDirectory.appendingPathComponent("showcase-audio.m4a")
        sourceMetadata = SourceAudioMetadata(
            sourceURL: demoURL,
            durationSeconds: 42,
            fileSizeBytes: 3_145_728,
            channelCount: 2,
            sampleRate: 44_100
        )

        capabilities = [
            AudioPresetCapability(
                presetName: "AVAssetExportPresetAppleM4A",
                fileTypeIdentifiers: [
                    AudioContainer.mp3.identifier,
                    AudioContainer.wav.identifier,
                    AudioContainer.m4a.identifier,
                    AudioContainer.aiff.identifier,
                    AudioContainer.caf.identifier,
                    AudioContainer.aifc.identifier,
                    AudioContainer.quickTimeAudio.identifier
                ]
            )
        ]

        let bins = (0..<220).map { idx in
            let base = abs(sin(Double(idx) * 0.16))
            let accent = (idx % 22 == 0) ? 0.95 : base * 0.72
            return min(1, max(0.06, accent))
        }
        energyAnalysis = AudioEnergyAnalysis(frameDurationSeconds: 0.02, energyTimeline: bins, waveformBins: bins)

        clipStartSeconds = 5.4
        clipEndSeconds = 27.8
        useClipEnd = true
        previewPlayheadSeconds = clipStartSeconds
        if showcaseStep == "trim-advanced" {
            fadeInSeconds = 2.4
            fadeOutSeconds = 1.8
        } else {
            fadeInSeconds = 0.8
            fadeOutSeconds = 1.1
        }
        selectedPresetID = OutputPresetOption.autoID
        selectedFileTypeID = OutputFileTypeOption.autoID
        statusMessage = L10n.tr("status.source_ready")

        if showcaseStep == "done-window" {
            workflowStep = .result
            trimmedAudioURL = demoURL
            trimmedFileSizeBytes = 1_024_000
            trimmedDurationSeconds = max(0, clipEndSeconds - clipStartSeconds)
            statusMessage = L10n.tr("status.trim_finished")
        } else if showcaseStep == "paywall" {
            workflowStep = .source
            trimmedAudioURL = nil
            trimmedFileSizeBytes = nil
            trimmedDurationSeconds = nil
            purchaseOptions = [
                PurchasePlanOption(
                    id: PurchaseManager.weeklyProductID,
                    title: L10n.tr("Weekly"),
                    subtitle: L10n.tr("Unlimited usage, billed weekly"),
                    priceText: "$0.99",
                    isAvailable: true
                ),
                PurchasePlanOption(
                    id: PurchaseManager.monthlyProductID,
                    title: L10n.tr("Monthly"),
                    subtitle: L10n.tr("Unlimited usage, billed monthly"),
                    priceText: "$2.99",
                    isAvailable: true
                ),
                PurchasePlanOption(
                    id: PurchaseManager.lifetimeProductID,
                    title: L10n.tr("Forever"),
                    subtitle: L10n.tr("Unlimited usage forever"),
                    priceText: "$29.99",
                    isAvailable: true
                )
            ]
            isPaywallPresented = true
        } else {
            workflowStep = .trim
            trimmedAudioURL = nil
            trimmedFileSizeBytes = nil
            trimmedDurationSeconds = nil
        }
    }

    private func parseShowcaseStep(from arguments: [String]) -> String? {
        if let index = arguments.firstIndex(of: "-uiShowcaseStep"),
           arguments.indices.contains(index + 1)
        {
            let rawStep = arguments[index + 1]
            let allowedSteps: Set<String> = [
                "main-empty",
                "trim-selected",
                "trim-formats-open",
                "trim-advanced",
                "done-window",
                "paywall"
            ]
            return allowedSteps.contains(rawStep) ? rawStep : nil
        }

        if arguments.contains("--showcase-result") {
            return "done-window"
        }
        if arguments.contains("--showcase-trim") {
            return "trim-selected"
        }
        return nil
    }

    private func startPreviewPlayback() {
        guard let sourceMetadata else { return }

        do {
            try ensurePreviewPlayer(for: sourceMetadata.sourceURL)
        } catch {
            errorMessage = localizedErrorMessage(error)
            return
        }

        previewPlaybackEndSeconds = effectiveClipEndSeconds
        let thresholdSeconds = 0.01
        var startPosition = clampedPreviewPlayhead(previewPlayheadSeconds)
        let remaining = previewPlaybackEndSeconds - startPosition
        if remaining <= thresholdSeconds {
            startPosition = clipStartSeconds
        }
        previewPlayheadSeconds = startPosition
        seekPreviewPlayerIfNeeded(to: startPosition)
        previewPlayer?.play()
        isPreviewPlaying = true
    }

    private func stopPreviewPlayback() {
        previewPlayer?.pause()
        isPreviewPlaying = false
    }

    private func ensurePreviewPlayer(for sourceURL: URL) throws {
        if previewPlayerSourceURL == sourceURL, previewPlayer != nil {
            return
        }

        teardownPreviewPlayer()

        let item = AVPlayerItem(url: sourceURL)
        let player = AVPlayer(playerItem: item)
        let interval = CMTime(seconds: 0.03, preferredTimescale: 600)

        previewTimeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                self?.handlePreviewTick(seconds: time.seconds)
            }
        }

        previewPlayer = player
        previewPlayerSourceURL = sourceURL
    }

    private func handlePreviewTick(seconds: Double) {
        guard seconds.isFinite else { return }

        let bounded = clampedPreviewPlayhead(seconds)
        previewPlayheadSeconds = bounded

        guard isPreviewPlaying else { return }
        if bounded >= previewPlaybackEndSeconds - 0.015 {
            previewPlayheadSeconds = previewPlaybackEndSeconds
            stopPreviewPlayback()
            seekPreviewPlayerIfNeeded(to: previewPlaybackEndSeconds)
        }
    }

    private func clampPreviewPlaybackToSelection() {
        guard sourceMetadata != nil else {
            previewPlayheadSeconds = 0
            stopPreviewPlayback()
            return
        }

        previewPlayheadSeconds = clampedPreviewPlayhead(previewPlayheadSeconds)
        previewPlaybackEndSeconds = effectiveClipEndSeconds
        seekPreviewPlayerIfNeeded(to: previewPlayheadSeconds)

        if isPreviewPlaying && previewPlayheadSeconds >= previewPlaybackEndSeconds - 0.015 {
            stopPreviewPlayback()
        }
    }

    private func clampedPreviewPlayhead(_ seconds: Double) -> Double {
        guard sourceMetadata != nil else { return 0 }
        let lower = clipStartSeconds
        let upper = max(lower, effectiveClipEndSeconds)
        return clamped(seconds, in: lower...upper)
    }

    private func seekPreviewPlayerIfNeeded(to seconds: Double) {
        guard let previewPlayer else { return }
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        previewPlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func teardownPreviewPlayer() {
        if let previewTimeObserverToken {
            previewPlayer?.removeTimeObserver(previewTimeObserverToken)
            self.previewTimeObserverToken = nil
        }
        previewPlayer?.pause()
        previewPlayer = nil
        previewPlayerSourceURL = nil
    }

    private func startResultPreviewPlayback() {
        guard let trimmedAudioURL else { return }
        ensureResultPreviewPlayer(for: trimmedAudioURL)
        resultPreviewPlayer?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        resultPreviewPlayer?.play()
        isResultPreviewPlaying = true
    }

    private func stopResultPreviewPlayback(resetToStart: Bool) {
        resultPreviewPlayer?.pause()
        if resetToStart {
            resultPreviewPlayer?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        isResultPreviewPlaying = false
    }

    private func ensureResultPreviewPlayer(for sourceURL: URL) {
        if resultPreviewPlayerSourceURL == sourceURL, resultPreviewPlayer != nil {
            return
        }

        teardownResultPreviewPlayer()

        let item = AVPlayerItem(url: sourceURL)
        let player = AVPlayer(playerItem: item)
        resultPreviewEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.isResultPreviewPlaying = false
            self?.resultPreviewPlayer?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        resultPreviewPlayer = player
        resultPreviewPlayerSourceURL = sourceURL
    }

    private func teardownResultPreviewPlayer() {
        if let resultPreviewEndObserver {
            NotificationCenter.default.removeObserver(resultPreviewEndObserver)
            self.resultPreviewEndObserver = nil
        }
        resultPreviewPlayer?.pause()
        resultPreviewPlayer = nil
        resultPreviewPlayerSourceURL = nil
        isResultPreviewPlaying = false
    }

    private static let invalidClipRangeMessages: [String: String] = [
        "ar": "نطاق القص المحدد غير صالح.",
        "bg": "Избраният диапазон за изрязване е невалиден.",
        "ca": "L'interval de retall seleccionat no és vàlid.",
        "cs": "Vybraný rozsah ořezu je neplatný.",
        "da": "Det valgte trimområde er ugyldigt.",
        "de": "Der ausgewählte Zuschnittsbereich ist ungültig.",
        "el": "Το επιλεγμένο εύρος αποκοπής δεν είναι έγκυρο.",
        "en": "The selected trim range is invalid.",
        "es": "El rango de recorte seleccionado no es válido.",
        "fi": "Valittu leikkausalue ei kelpaa.",
        "fr": "La plage de découpe sélectionnée n'est pas valide.",
        "he": "טווח החיתוך שנבחר אינו חוקי.",
        "hi": "चुना गया ट्रिम रेंज मान्य नहीं है।",
        "hr": "Odabrani raspon izrezivanja nije valjan.",
        "hu": "A kiválasztott vágási tartomány érvénytelen.",
        "id": "Rentang pemotongan yang dipilih tidak valid.",
        "it": "L'intervallo di taglio selezionato non è valido.",
        "ja": "選択したトリム範囲は無効です。",
        "ko": "선택한 트림 범위가 올바르지 않습니다.",
        "ms": "Julat trim yang dipilih tidak sah.",
        "nb": "Valgt trimområde er ugyldig.",
        "nl": "Het geselecteerde trim-bereik is ongeldig.",
        "no": "Valgt trimområde er ugyldig.",
        "pl": "Wybrany zakres przycięcia jest nieprawidłowy.",
        "pt": "O intervalo de corte selecionado é inválido.",
        "ro": "Intervalul de tăiere selectat este invalid.",
        "ru": "Выбранный диапазон обрезки недопустим.",
        "sk": "Vybraný rozsah orezania je neplatný.",
        "sv": "Det valda trimintervallet är ogiltigt.",
        "th": "ช่วงตัดที่เลือกไม่ถูกต้อง",
        "tr": "Seçilen kırpma aralığı geçersiz.",
        "uk": "Вибраний діапазон обрізання недійсний.",
        "vi": "Phạm vi cắt đã chọn không hợp lệ.",
        "zh-Hans": "所选裁剪范围无效。",
        "zh-Hant": "所選裁剪範圍無效。"
    ]

    private static let invalidSourceDurationMessages: [String: String] = [
        "ar": "مدة المصدر غير صالحة.",
        "bg": "Продължителността на източника е невалидна.",
        "ca": "La durada de la font no és vàlida.",
        "cs": "Délka zdroje je neplatná.",
        "da": "Kildevarigheden er ugyldig.",
        "de": "Die Quelldauer ist ungültig.",
        "el": "Η διάρκεια της πηγής δεν είναι έγκυρη.",
        "en": "The source duration is invalid.",
        "es": "La duración de origen no es válida.",
        "fi": "Lähteen kesto ei ole kelvollinen.",
        "fr": "La durée de la source n'est pas valide.",
        "he": "משך המקור אינו חוקי.",
        "hi": "स्रोत की अवधि मान्य नहीं है।",
        "hr": "Trajanje izvora nije valjano.",
        "hu": "A forrás hossza érvénytelen.",
        "id": "Durasi sumber tidak valid.",
        "it": "La durata della sorgente non è valida.",
        "ja": "ソースの長さが無効です。",
        "ko": "소스 길이가 올바르지 않습니다.",
        "ms": "Tempoh sumber tidak sah.",
        "nb": "Kildens varighet er ugyldig.",
        "nl": "De bronduur is ongeldig.",
        "no": "Kildens varighet er ugyldig.",
        "pl": "Długość źródła jest nieprawidłowa.",
        "pt": "A duração da fonte é inválida.",
        "ro": "Durata sursei este invalidă.",
        "ru": "Длительность исходника недопустима.",
        "sk": "Dĺžka zdroja je neplatná.",
        "sv": "Källans längd är ogiltig.",
        "th": "ความยาวไฟล์ต้นฉบับไม่ถูกต้อง",
        "tr": "Kaynak süresi geçersiz.",
        "uk": "Тривалість джерела недійсна.",
        "vi": "Thời lượng nguồn không hợp lệ.",
        "zh-Hans": "源时长无效。",
        "zh-Hant": "來源時長無效。"
    ]
}
