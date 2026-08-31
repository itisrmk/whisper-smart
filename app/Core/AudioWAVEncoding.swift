import Foundation

enum AudioWAVEncoding {
    /// Bulk float32 → int16 LE conversion, run at the capture tap so the
    /// session buffer holds int16 for the rest of its life. Storing captured
    /// audio as int16 rather than float32 halves the resident cost of a
    /// recording (32 KB/s instead of 64 KB/s at 16 kHz).
    static func int16Samples<S: Sequence>(from samples: S) -> [Int16] where S.Element == Float {
        var pcm = [Int16]()
        pcm.reserveCapacity(samples.underestimatedCount)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            pcm.append(Int16(clamped * Float(Int16.max)).littleEndian)
        }
        return pcm
    }

    /// Base64 of int16 LE PCM, taken directly over the sample buffer's own
    /// storage. `Data(bytesNoCopy:)` borrows rather than duplicating, so a
    /// long recording is not copied a second time just to be encoded; the
    /// borrowed `Data` never escapes the closure.
    static func base64PCM<C: Collection>(_ samples: C) -> String where C.Element == Int16 {
        guard !samples.isEmpty else { return "" }
        // `Array` and `ArraySlice` both answer this without copying, which is
        // the whole point; the `Array(samples)` fallback only runs for exotic
        // collections that have no contiguous storage to borrow.
        if let encoded = samples.withContiguousStorageIfAvailable(base64OverStorage) {
            return encoded
        }
        return Array(samples).withUnsafeBufferPointer(base64OverStorage)
    }

    private static func base64OverStorage(_ buffer: UnsafeBufferPointer<Int16>) -> String {
        guard let base = buffer.baseAddress else { return "" }
        return Data(
            bytesNoCopy: UnsafeMutableRawPointer(mutating: base),
            count: buffer.count * MemoryLayout<Int16>.size,
            deallocator: .none
        ).base64EncodedString()
    }

    static func make16BitMonoWAV(samples: [Int16], sampleRate: Int) -> Data {
        let subchunk2Size = UInt32(samples.count * MemoryLayout<Int16>.size)
        let chunkSize = UInt32(36) + subchunk2Size
        let byteRate = UInt32(sampleRate * 2)
        let blockAlign: UInt16 = 2
        let bitsPerSample: UInt16 = 16

        var wav = Data(capacity: 44 + Int(subchunk2Size))
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
        samples.withUnsafeBytes { wav.append($0.bindMemory(to: UInt8.self)) }
        return wav
    }

    private static func littleEndianData<T: FixedWidthInteger>(_ value: T) -> Data {
        var little = value.littleEndian
        return Swift.withUnsafeBytes(of: &little) { Data($0) }
    }
}
