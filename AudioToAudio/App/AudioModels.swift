import AVFoundation
import Foundation
import UniformTypeIdentifiers

struct SourceAudioMetadata: Equatable {
    let sourceURL: URL
    let durationSeconds: Double
    let fileSizeBytes: Int64
    let channelCount: Int
    let sampleRate: Double

    var sourceSummary: String {
        "\(channelCount)ch • \(Int(sampleRate.rounded())) Hz • \(formatSeconds(durationSeconds))"
    }
}

struct AudioEnergyAnalysis: Equatable {
    let frameDurationSeconds: Double
    let energyTimeline: [Double]
    let waveformBins: [Double]
}

struct OutputPresetOption: Identifiable, Hashable {
    static let autoID = "auto"

    let id: String
    let title: String

    var isAuto: Bool { id == Self.autoID }
}

struct OutputFileTypeOption: Identifiable, Hashable {
    static let autoID = "auto"

    let id: String
    let title: String

    var isAuto: Bool { id == Self.autoID }
}

enum AudioModelError: LocalizedError {
    case noAudioTrack
    case noAudioExportCapability
    case failedToReadAudioData

    var errorDescription: String? {
        switch self {
        case .noAudioTrack:
            return L10n.tr("error.no_audio_track")
        case .noAudioExportCapability:
            return L10n.tr("error.no_audio_export_capability")
        case .failedToReadAudioData:
            return L10n.tr("error.failed_to_read_audio")
        }
    }
}

extension AudioContainer {
    var avFileType: AVFileType {
        AVFileType(rawValue: identifier)
    }

    var fileExtension: String {
        if let preferred = UTType(identifier)?.preferredFilenameExtension {
            return preferred
        }

        switch identifier {
        case AudioContainer.m4a.identifier:
            return "m4a"
        case AudioContainer.mp3.identifier:
            return "mp3"
        case AudioContainer.caf.identifier:
            return "caf"
        case AudioContainer.wav.identifier:
            return "wav"
        case AudioContainer.aiff.identifier:
            return "aif"
        case AudioContainer.aifc.identifier:
            return "aifc"
        case AudioContainer.quickTimeAudio.identifier:
            return "qta"
        default:
            return "m4a"
        }
    }

    var label: String {
        switch identifier {
        case AudioContainer.m4a.identifier:
            return "M4A"
        case AudioContainer.mp3.identifier:
            return "MP3"
        case AudioContainer.caf.identifier:
            return "CAF"
        case AudioContainer.wav.identifier:
            return "WAV"
        case AudioContainer.aiff.identifier:
            return "AIFF"
        case AudioContainer.aifc.identifier:
            return "AIFC"
        case AudioContainer.quickTimeAudio.identifier:
            return "QuickTime Audio"
        default:
            if let utType = UTType(identifier), let ext = utType.preferredFilenameExtension {
                return ext.uppercased()
            }
            return identifier
        }
    }
}

extension AudioPresetCapability {
    var shortTitle: String {
        switch presetName {
        case AVAssetExportPresetAppleM4A:
            return "Apple M4A"
        case AVAssetExportPresetPassthrough:
            return "Passthrough"
        case AVAssetExportPresetHighestQuality:
            return "Highest"
        case AVAssetExportPresetMediumQuality:
            return "Medium"
        case AVAssetExportPresetLowQuality:
            return "Low"
        default:
            return presetName.replacingOccurrences(of: "AVAssetExportPreset", with: "")
        }
    }
}

func audioFileTypeLabel(_ identifier: String) -> String {
    AudioContainer(identifier: identifier).label
}

func sortAudioFileTypeIdentifiers(_ identifiers: [String]) -> [String] {
    identifiers.sorted { lhs, rhs in
        audioFileTypePriority(lhs) < audioFileTypePriority(rhs)
    }
}

private func audioFileTypePriority(_ identifier: String) -> Int {
    if let index = AudioContainer.preferredAutoOrder.firstIndex(where: { $0.identifier == identifier }) {
        return index
    }
    return Int.max
}

func humanReadableSize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func formatSeconds(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else {
        return "0.00"
    }
    let totalCentiseconds = Int((seconds * 100).rounded())
    let totalSeconds = totalCentiseconds / 100
    let centiseconds = totalCentiseconds % 100

    if totalSeconds < 60 {
        let whole = Double(totalCentiseconds) / 100.0
        return String(format: "%.2f", whole)
    }

    let secondsPart = totalSeconds % 60
    let minutesTotal = totalSeconds / 60

    if minutesTotal < 60 {
        return String(
            format: "%d:%02d.%02d",
            minutesTotal,
            secondsPart,
            centiseconds
        )
    }

    let hours = minutesTotal / 60
    let minutesPart = minutesTotal % 60
    return String(
        format: "%d:%02d:%02d.%02d",
        hours,
        minutesPart,
        secondsPart,
        centiseconds
    )
}

func clamped(_ value: Double, in range: ClosedRange<Double>) -> Double {
    min(max(value, range.lowerBound), range.upperBound)
}

func waveformBins(from energyFrames: [Double], count: Int) -> [Double] {
    guard !energyFrames.isEmpty, count > 0 else {
        return []
    }

    let bucketSize = max(1, energyFrames.count / count)
    var bins: [Double] = []
    bins.reserveCapacity(count)

    var index = 0
    while index < energyFrames.count {
        let end = min(energyFrames.count, index + bucketSize)
        let segment = energyFrames[index..<end]
        let peak = segment.max() ?? 0
        bins.append(peak)
        index = end
    }

    if bins.count > count {
        bins = Array(bins.prefix(count))
    } else if bins.count < count {
        bins.append(contentsOf: Array(repeating: bins.last ?? 0, count: count - bins.count))
    }

    return bins
}
