import AVFoundation
import Foundation
import UniformTypeIdentifiers

enum AudioToAudioServiceError: LocalizedError {
    case cannotCreateExportSession
    case unsupportedFileType
    case missingOutput
    case cancelled
    case noAudioTrack

    var errorDescription: String? {
        switch self {
        case .cannotCreateExportSession:
            return L10n.tr("error.cannot_create_export_session")
        case .unsupportedFileType:
            return L10n.tr("error.unsupported_file_type")
        case .missingOutput:
            return L10n.tr("error.missing_output")
        case .cancelled:
            return L10n.tr("error.cancelled")
        case .noAudioTrack:
            return L10n.tr("error.no_audio_track")
        }
    }
}

final class AudioToAudioService {
    private struct ActiveJob {
        let outputURL: URL
        let cancelHandler: () -> Void
        var isCancelled: Bool
    }

    private let lock = NSLock()
    private var activeJob: ActiveJob?

    func cancelCurrentJob() {
        let job: ActiveJob? = {
            lock.lock()
            defer { lock.unlock() }
            return activeJob
        }()

        guard let job else { return }
        lock.lock()
        activeJob?.isCancelled = true
        lock.unlock()

        job.cancelHandler()
        try? FileManager.default.removeItem(at: job.outputURL)
    }

    func trim(
        sourceURL: URL,
        plan: AudioToAudioPlan,
        progressHandler: ((Double) -> Void)? = nil
    ) async throws -> URL {
        try SecureMediaFileManager.shared.validateReadableLocalFile(sourceURL)

        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let sourceTrack = tracks.first else {
            throw AudioToAudioServiceError.noAudioTrack
        }

        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw AudioToAudioServiceError.cannotCreateExportSession
        }

        let start = CMTime(seconds: plan.clipStartSeconds, preferredTimescale: 600)
        let duration = CMTime(seconds: plan.clipDurationSeconds, preferredTimescale: 600)
        let sourceRange = CMTimeRange(start: start, duration: duration)

        try compositionTrack.insertTimeRange(sourceRange, of: sourceTrack, at: .zero)

        let session = AVAssetExportSession(asset: composition, presetName: plan.presetName)
            ?? AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A)
        guard let session else {
            throw AudioToAudioServiceError.cannotCreateExportSession
        }

        var selectedType = AVFileType(rawValue: plan.fileTypeIdentifier)
        if supportsCustomAudioFileWriting(typeIdentifier: selectedType.rawValue) {
            let outputURL = try makeOutputURL(fileTypeIdentifier: selectedType.rawValue)
            return try await writeAudioFile(
                from: composition,
                track: compositionTrack,
                audioMix: buildAudioMix(
                    track: compositionTrack,
                    clipDurationSeconds: plan.clipDurationSeconds,
                    fadeInSeconds: plan.fadeInSeconds,
                    fadeOutSeconds: plan.fadeOutSeconds
                ),
                clipDurationSeconds: plan.clipDurationSeconds,
                outputURL: outputURL,
                fileTypeIdentifier: selectedType.rawValue,
                progressHandler: progressHandler
            )
        }

        if !session.supportedFileTypes.contains(selectedType) {
            if let fallback = session.supportedFileTypes.first(where: { fileType in
                if let type = UTType(fileType.rawValue) {
                    return type.conforms(to: .audio)
                }
                return false
            }) {
                selectedType = fallback
            } else {
                throw AudioToAudioServiceError.unsupportedFileType
            }
        }

        let outputURL = try makeOutputURL(fileTypeIdentifier: selectedType.rawValue)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: outputURL.path) {
            try? fileManager.removeItem(at: outputURL)
        }

        session.outputURL = outputURL
        session.outputFileType = selectedType
        session.shouldOptimizeForNetworkUse = plan.optimizeForNetworkUse
        session.audioMix = buildAudioMix(
            track: compositionTrack,
            clipDurationSeconds: plan.clipDurationSeconds,
            fadeInSeconds: plan.fadeInSeconds,
            fadeOutSeconds: plan.fadeOutSeconds
        )

        registerActiveJob(outputURL: outputURL) {
            session.cancelExport()
        }
        defer { clearActiveJob(outputURL: outputURL) }

        var progressTask: Task<Void, Never>?
        progressTask = Task {
            while !Task.isCancelled {
                let status = session.status
                if status == .exporting || status == .waiting {
                    progressHandler?(Double(session.progress))
                }
                if status == .completed || status == .cancelled || status == .failed {
                    break
                }
                try? await Task.sleep(for: .milliseconds(120))
            }
        }

        do {
            let resultURL: URL = try await withCheckedThrowingContinuation { continuation in
                session.exportAsynchronously {
                    progressTask?.cancel()

                    switch session.status {
                    case .completed:
                        guard fileManager.fileExists(atPath: outputURL.path) else {
                            continuation.resume(throwing: AudioToAudioServiceError.missingOutput)
                            return
                        }
                        do {
                            try SecureMediaFileManager.shared.hardenFile(at: outputURL)
                        } catch {
                            try? fileManager.removeItem(at: outputURL)
                            continuation.resume(throwing: error)
                            return
                        }
                        progressHandler?(1.0)
                        continuation.resume(returning: outputURL)
                    case .failed:
                        try? fileManager.removeItem(at: outputURL)
                        continuation.resume(throwing: session.error ?? AudioToAudioServiceError.missingOutput)
                    case .cancelled:
                        try? fileManager.removeItem(at: outputURL)
                        continuation.resume(throwing: AudioToAudioServiceError.cancelled)
                    default:
                        try? fileManager.removeItem(at: outputURL)
                        continuation.resume(throwing: session.error ?? AudioToAudioServiceError.missingOutput)
                    }
                }
            }

            return resultURL
        } catch {
            progressTask?.cancel()
            throw error
        }
    }

    private func buildAudioMix(
        track: AVCompositionTrack,
        clipDurationSeconds: Double,
        fadeInSeconds: Double,
        fadeOutSeconds: Double
    ) -> AVAudioMix? {
        guard fadeInSeconds > 0 || fadeOutSeconds > 0 else {
            return nil
        }

        let params = AVMutableAudioMixInputParameters(track: track)
        let fullDuration = CMTime(seconds: clipDurationSeconds, preferredTimescale: 600)
        params.setVolume(1, at: .zero)

        if fadeInSeconds > 0 {
            let fadeIn = CMTime(seconds: min(fadeInSeconds, clipDurationSeconds), preferredTimescale: 600)
            params.setVolumeRamp(
                fromStartVolume: 0,
                toEndVolume: 1,
                timeRange: CMTimeRange(start: .zero, duration: fadeIn)
            )
        }

        if fadeOutSeconds > 0 {
            let fadeOut = CMTime(seconds: min(fadeOutSeconds, clipDurationSeconds), preferredTimescale: 600)
            let fadeOutStart = CMTimeSubtract(fullDuration, fadeOut)
            params.setVolumeRamp(
                fromStartVolume: 1,
                toEndVolume: 0,
                timeRange: CMTimeRange(start: CMTimeMaximum(.zero, fadeOutStart), duration: fadeOut)
            )
        }

        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        return mix
    }

    private func registerActiveJob(outputURL: URL, cancelHandler: @escaping () -> Void) {
        lock.lock()
        activeJob = ActiveJob(outputURL: outputURL, cancelHandler: cancelHandler, isCancelled: false)
        lock.unlock()
    }

    private func clearActiveJob(outputURL: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard activeJob?.outputURL == outputURL else { return }
        activeJob = nil
    }

    private func isCancellationRequested(for outputURL: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let activeJob, activeJob.outputURL == outputURL else { return false }
        return activeJob.isCancelled
    }

    private func makeOutputURL(fileTypeIdentifier: String) throws -> URL {
        let container = AudioContainer(identifier: fileTypeIdentifier)
        return try SecureMediaFileManager.shared.makeManagedOutputURL(
            preferredExtension: container.fileExtension,
            prefix: "audio-to-audio"
        )
    }

    private func supportsCustomAudioFileWriting(typeIdentifier: String) -> Bool {
        let supportedIdentifiers: Set<String> = [
            AudioContainer.wav.identifier,
            AudioContainer.aiff.identifier,
            AudioContainer.caf.identifier
        ]

        return supportedIdentifiers.contains(typeIdentifier)
    }

    private func writeAudioFile(
        from asset: AVAsset,
        track: AVCompositionTrack,
        audioMix: AVAudioMix?,
        clipDurationSeconds: Double,
        outputURL: URL,
        fileTypeIdentifier: String,
        progressHandler: ((Double) -> Void)?
    ) async throws -> URL {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(
            audioTracks: [track],
            audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsNonInterleaved: false
            ]
        )
        output.audioMix = audioMix
        output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else {
            throw AudioToAudioServiceError.cannotCreateExportSession
        }

        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? AudioToAudioServiceError.cannotCreateExportSession
        }

        registerActiveJob(outputURL: outputURL) {
            reader.cancelReading()
        }
        defer { clearActiveJob(outputURL: outputURL) }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: outputURL.path) {
            try? fileManager.removeItem(at: outputURL)
        }

        var audioFile: AVAudioFile?
        var processedFrames: AVAudioFramePosition = 0
        var expectedTotalFrames: AVAudioFramePosition = 0

        while reader.status == .reading {
            if isCancellationRequested(for: outputURL) {
                reader.cancelReading()
                try? fileManager.removeItem(at: outputURL)
                throw AudioToAudioServiceError.cancelled
            }

            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                break
            }

            guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let streamDescriptionPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
            else {
                continue
            }

            let streamDescription = streamDescriptionPointer.pointee
            let sampleRate = max(streamDescription.mSampleRate, 44_100)
            let channelCount = max(Int(streamDescription.mChannelsPerFrame), 1)

            if audioFile == nil {
                let settings = audioFileWriteSettings(
                    for: fileTypeIdentifier,
                    sampleRate: sampleRate,
                    channelCount: channelCount
                )
                audioFile = try AVAudioFile(
                    forWriting: outputURL,
                    settings: settings,
                    commonFormat: .pcmFormatFloat32,
                    interleaved: true
                )
                expectedTotalFrames = AVAudioFramePosition(max(1, Int64((clipDurationSeconds * sampleRate).rounded())))
            }

            guard let pcmBuffer = makePCMBuffer(from: sampleBuffer, streamDescription: streamDescription) else {
                continue
            }

            try audioFile?.write(from: pcmBuffer)
            processedFrames += AVAudioFramePosition(pcmBuffer.frameLength)

            if expectedTotalFrames > 0 {
                let progress = min(1, Double(processedFrames) / Double(expectedTotalFrames))
                progressHandler?(progress)
            }
        }

        switch reader.status {
        case .completed:
            guard fileManager.fileExists(atPath: outputURL.path) else {
                throw AudioToAudioServiceError.missingOutput
            }
            try SecureMediaFileManager.shared.hardenFile(at: outputURL)
            progressHandler?(1.0)
            return outputURL
        case .cancelled:
            try? fileManager.removeItem(at: outputURL)
            throw AudioToAudioServiceError.cancelled
        case .failed:
            try? fileManager.removeItem(at: outputURL)
            throw reader.error ?? AudioToAudioServiceError.missingOutput
        default:
            try? fileManager.removeItem(at: outputURL)
            throw AudioToAudioServiceError.missingOutput
        }
    }

    private func audioFileWriteSettings(
        for fileTypeIdentifier: String,
        sampleRate: Double,
        channelCount: Int
    ) -> [String: Any] {
        let isBigEndian = fileTypeIdentifier == AudioContainer.aiff.identifier

        return [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: isBigEndian,
            AVLinearPCMIsNonInterleaved: false
        ]
    }

    private func makePCMBuffer(
        from sampleBuffer: CMSampleBuffer,
        streamDescription: AudioStreamBasicDescription
    ) -> AVAudioPCMBuffer? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return nil
        }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0 else { return nil }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: streamDescription.mSampleRate,
            channels: AVAudioChannelCount(streamDescription.mChannelsPerFrame),
            interleaved: true
        ),
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else {
            return nil
        }

        buffer.frameLength = frameCount

        var length = 0
        var rawPointer: UnsafeMutablePointer<Int8>?
        let result = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &rawPointer
        )

        guard result == kCMBlockBufferNoErr,
              let rawPointer,
              let destination = buffer.mutableAudioBufferList.pointee.mBuffers.mData
        else {
            return nil
        }

        memcpy(destination, rawPointer, length)
        return buffer
    }
}
