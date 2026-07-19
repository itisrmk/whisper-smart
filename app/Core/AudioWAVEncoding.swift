import Foundation

enum AudioWAVEncoding {
    /// Bulk float32 → int16 LE PCM conversion. Single preallocated buffer;
    /// avoids the per-sample `Data.append` cost on long recordings.
    static func int16PCMData<S: Sequence>(samples: S) -> Data where S.Element == Float {
        var pcm = [Int16]()
        pcm.reserveCapacity(samples.underestimatedCount)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            pcm.append(Int16(clamped * Float(Int16.max)).littleEndian)
        }
        return pcm.withUnsafeBytes { Data($0) }
    }

    static func make16BitMonoWAV(samples: [Float], sampleRate: Int) -> Data {
        let pcmData = int16PCMData(samples: samples)

        let subchunk2Size = UInt32(pcmData.count)
        let chunkSize = UInt32(36) + subchunk2Size
        let byteRate = UInt32(sampleRate * 2)
        let blockAlign: UInt16 = 2
        let bitsPerSample: UInt16 = 16

        var wav = Data(capacity: 44 + pcmData.count)
        wav.append(Data("RIFF".utf8))
        wav.append(littleEndianData(chunkSize))
        wav.append(Data("WAVE".utf8))
        wav.append(Data("fmt ".utf8))
        wav.append(littleEndianData(UInt32(16)))
        wav.append(littleEndianData(UInt16(1)))
        wav.append(littleEndianData(UInt16(1)))
        wav.append(littleEndianData(UInt32(sampleRate)))
        wav.append(littleEndianData(byteRate))
        wav.append(littleEndianData(blockAlign))
        wav.append(littleEndianData(bitsPerSample))
        wav.append(Data("data".utf8))
        wav.append(littleEndianData(subchunk2Size))
        wav.append(pcmData)
        return wav
    }

    private static func littleEndianData<T: FixedWidthInteger>(_ value: T) -> Data {
        var little = value.littleEndian
        return Swift.withUnsafeBytes(of: &little) { Data($0) }
    }
}
