import AVFoundation
import CoreMedia
import Foundation
import UniformTypeIdentifiers

struct AudioSourceInspector {
    func inspect(url: URL) async throws -> SourceAudioMetadata {
        try SecureMediaFileManager.shared.validateReadableLocalFile(url)

        let asset = AVURLAsset(url: url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = audioTracks.first else {
            throw AudioModelError.noAudioTrack
        }

        async let durationValue = asset.load(.duration)
        async let formatDescriptions = audioTrack.load(.formatDescriptions)

        let durationSeconds = try await durationValue.seconds
        let descriptions = try await formatDescriptions

        let streamDescription = descriptions
            .compactMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
            .first

        let sampleRate = Double(streamDescription?.mSampleRate ?? 44_100)
        let channelCount = max(1, Int(streamDescription?.mChannelsPerFrame ?? 2))

        let values = try url.resourceValues(forKeys: [.fileSizeKey, .fileAllocatedSizeKey])
        let fileSize = Int64(values.fileSize ?? values.fileAllocatedSize ?? 0)

        return SourceAudioMetadata(
            sourceURL: url,
            durationSeconds: durationSeconds,
            fileSizeBytes: fileSize,
            channelCount: channelCount,
            sampleRate: sampleRate
        )
    }

    func audioExportCapabilities(for sourceURL: URL) -> [AudioPresetCapability] {
        guard (try? SecureMediaFileManager.shared.validateReadableLocalFile(sourceURL)) != nil else {
            return []
        }

        let asset = AVURLAsset(url: sourceURL)
        var presetList = AVAssetExportSession.exportPresets(compatibleWith: asset)
        if !presetList.contains(AVAssetExportPresetAppleM4A) {
            presetList.append(AVAssetExportPresetAppleM4A)
        }

        var capabilities: [AudioPresetCapability] = []
        for preset in presetList {
            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
                continue
            }

            let audioTypes = session.supportedFileTypes
                .map(\.rawValue)
                .filter { isAudioTypeIdentifier($0) }

            let augmentedAudioTypes = sortAudioFileTypeIdentifiers(dedupe(audioTypes + customAudioFileTypeIdentifiers()))
            guard !augmentedAudioTypes.isEmpty else { continue }
            capabilities.append(AudioPresetCapability(presetName: preset, fileTypeIdentifiers: augmentedAudioTypes))
        }

        return sortCapabilities(capabilities)
    }

    func analyzeEnergyTimeline(url: URL, durationSeconds: Double) async throws -> AudioEnergyAnalysis {
        try SecureMediaFileManager.shared.validateReadableLocalFile(url)

        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = tracks.first else {
            throw AudioModelError.noAudioTrack
        }

        let formatDescriptions = try await audioTrack.load(.formatDescriptions)
        guard let formatDescription = formatDescriptions.first,
              let stream = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee
        else {
            throw AudioModelError.failedToReadAudioData
        }

        let channelCount = max(1, Int(stream.mChannelsPerFrame))
        let sampleRate = max(8_000, Double(stream.mSampleRate))

        let targetFrames = 12_000.0
        let frameDurationSeconds = max(0.01, durationSeconds / targetFrames)
        let samplesPerFrame = max(1, Int((sampleRate * frameDurationSeconds).rounded()))

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: audioTrack,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsNonInterleaved: false
            ]
        )

        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw AudioModelError.failedToReadAudioData
        }

        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? AudioModelError.failedToReadAudioData
        }

        var energyFrames: [Double] = []
        energyFrames.reserveCapacity(12_000)

        var sumSquares = 0.0
        var sampleCounter = 0

        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                break
            }

            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                continue
            }

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
                  length >= MemoryLayout<Float>.size
            else {
                continue
            }

            let floatCount = length / MemoryLayout<Float>.size
            rawPointer.withMemoryRebound(to: Float.self, capacity: floatCount) { floatPointer in
                let frameCount = floatCount / channelCount
                guard frameCount > 0 else { return }

                for frameIndex in 0..<frameCount {
                    let base = frameIndex * channelCount
                    var mono: Float = 0
                    for channel in 0..<channelCount {
                        mono += floatPointer[base + channel]
                    }
                    mono /= Float(channelCount)

                    sumSquares += Double(mono * mono)
                    sampleCounter += 1

                    if sampleCounter >= samplesPerFrame {
                        let rms = sqrt(sumSquares / Double(sampleCounter))
                        energyFrames.append(rms)
                        sampleCounter = 0
                        sumSquares = 0
                    }
                }
            }
        }

        if sampleCounter > 0 {
            let rms = sqrt(sumSquares / Double(sampleCounter))
            energyFrames.append(rms)
        }

        guard !energyFrames.isEmpty else {
            throw AudioModelError.failedToReadAudioData
        }

        guard reader.status == .completed || reader.status == .reading else {
            throw reader.error ?? AudioModelError.failedToReadAudioData
        }

        let maxEnergy = max(energyFrames.max() ?? 1, 0.000_001)
        let normalized = energyFrames.map { min(1, max(0, $0 / maxEnergy)) }

        return AudioEnergyAnalysis(
            frameDurationSeconds: frameDurationSeconds,
            energyTimeline: normalized,
            waveformBins: waveformBins(from: normalized, count: 220)
        )
    }

    private func isAudioTypeIdentifier(_ identifier: String) -> Bool {
        if let utType = UTType(identifier), utType.conforms(to: .audio) {
            return true
        }

        let knownAudioTypes: Set<String> = [
            AudioContainer.m4a.identifier,
            AudioContainer.mp3.identifier,
            AudioContainer.caf.identifier,
            AudioContainer.wav.identifier,
            AudioContainer.aiff.identifier,
            AudioContainer.aifc.identifier,
            AudioContainer.quickTimeAudio.identifier
        ]

        return knownAudioTypes.contains(identifier)
    }

    private func customAudioFileTypeIdentifiers() -> [String] {
        [
            AudioContainer.wav.identifier,
            AudioContainer.aiff.identifier,
            AudioContainer.caf.identifier
        ]
    }

    private func dedupe(_ identifiers: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        for identifier in identifiers where !seen.contains(identifier) {
            seen.insert(identifier)
            ordered.append(identifier)
        }

        return ordered
    }

    private func sortCapabilities(_ capabilities: [AudioPresetCapability]) -> [AudioPresetCapability] {
        let preferredOrder = [
            AVAssetExportPresetAppleM4A,
            AVAssetExportPresetPassthrough,
            AVAssetExportPresetHighestQuality,
            AVAssetExportPresetMediumQuality,
            AVAssetExportPresetLowQuality
        ]

        return capabilities.sorted { lhs, rhs in
            let leftRank = preferredOrder.firstIndex(of: lhs.presetName) ?? Int.max
            let rightRank = preferredOrder.firstIndex(of: rhs.presetName) ?? Int.max
            if leftRank == rightRank {
                return lhs.presetName < rhs.presetName
            }
            return leftRank < rightRank
        }
    }
}
