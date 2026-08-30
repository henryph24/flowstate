import Foundation

/// Builds a complete in-memory WAV file (44-byte RIFF header + PCM data)
/// from 16-bit mono samples. Assumes a little-endian host (all macOS targets).
public enum WAVEncoder {
    public static func encode(samples: [Int16], sampleRate: UInt32) -> Data {
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let blockAlign = channels * (bitsPerSample / 8)
        let byteRate = sampleRate * UInt32(blockAlign)
        let dataSize = UInt32(samples.count * 2)

        var data = Data(capacity: 44 + samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        appendLE(&data, 36 + dataSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendLE(&data, UInt32(16))            // fmt chunk size
        appendLE(&data, UInt16(1))             // PCM
        appendLE(&data, channels)
        appendLE(&data, sampleRate)
        appendLE(&data, byteRate)
        appendLE(&data, blockAlign)
        appendLE(&data, bitsPerSample)
        data.append(contentsOf: Array("data".utf8))
        appendLE(&data, dataSize)
        samples.withUnsafeBufferPointer { buf in
            data.append(UnsafeBufferPointer(
                start: UnsafeRawPointer(buf.baseAddress!).assumingMemoryBound(to: UInt8.self),
                count: buf.count * 2))
        }
        return data
    }

    private static func appendLE<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
}
