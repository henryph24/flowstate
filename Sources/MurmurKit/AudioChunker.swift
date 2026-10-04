import Foundation

/// Splits long push-to-talk audio into pieces a local model transcribes in one
/// pass (Parakeet's attention cost grows with the square of the length;
/// Qwen3-ASR's context holds about three minutes). Each cut lands in the
/// quietest 100 ms window of the last seconds before the limit, so a word is
/// not split in two.
public enum AudioChunker {
    /// Audio from `WAVEncoder` (16-bit mono PCM) as WAVs of at most
    /// `maxSeconds` each. Shorter audio, or bytes in any other format, come
    /// back whole.
    public static func split(wav: Data, maxSeconds: Double, searchSeconds: Double = 8) -> [Data] {
        guard let (samples, rate) = decode(wav) else { return [wav] }
        let cuts = cutPoints(samples: samples, sampleRate: rate, maxSeconds: maxSeconds,
                             searchSeconds: searchSeconds)
        guard !cuts.isEmpty else { return [wav] }
        let bounds = [0] + cuts + [samples.count]
        return zip(bounds, bounds.dropFirst()).map { start, end in
            WAVEncoder.encode(samples: Array(samples[start..<end]), sampleRate: UInt32(rate))
        }
    }

    /// Transcribes `wav` piece by piece with `transcribe` and joins the texts
    /// in order. A failed piece is retried once, so one transient error (a
    /// server that crashed and respawns) does not discard a long dictation.
    public static func transcribe(wav: Data, maxSeconds: Double,
                                  _ transcribe: (Data) async throws -> String) async throws -> String {
        var parts: [String] = []
        for piece in split(wav: wav, maxSeconds: maxSeconds) {
            let text: String
            do {
                text = try await transcribe(piece)
            } catch {
                if Task.isCancelled { throw error }
                Log.info("chunk transcription failed (\(error.localizedDescription)); retrying once")
                text = try await transcribe(piece)
            }
            if !text.isEmpty { parts.append(text) }
        }
        return parts.joined(separator: " ")
    }

    /// Sample indices where each chunk after the first starts. Every chunk is
    /// at most `maxSeconds` long; every chunk but the last spans at least half
    /// the limit and the last at least min(1 s, half the limit), rounded down
    /// to a sample, so no sliver reaches the model. A limit that is not a
    /// positive finite number cuts nothing.
    public static func cutPoints(samples: [Int16], sampleRate: Int, maxSeconds: Double,
                                 searchSeconds: Double) -> [Int] {
        guard maxSeconds.isFinite, maxSeconds > 0, sampleRate > 0 else { return [] }
        let maxLength = max(2, Int(min(maxSeconds * Double(sampleRate), Double(Int32.max))))
        let window = max(2, sampleRate / 10)
        let hop = window / 2
        let seconds = searchSeconds.isFinite ? max(0, searchSeconds) : 0
        let search = min(Int(min(seconds * Double(sampleRate), Double(Int32.max))), maxLength / 2)
        let minTail = min(sampleRate, maxLength / 2)
        var cuts: [Int] = []
        var start = 0
        while samples.count - start > maxLength {
            let limit = start + maxLength
            let latest = min(limit, samples.count - minTail)
            var best = latest
            var bestEnergy = Double.infinity
            var offset = max(start + 1, limit - search)
            while offset + window <= latest {
                var energy = 0.0
                for sample in samples[offset..<(offset + window)] {
                    energy += Double(sample) * Double(sample)
                }
                if energy <= bestEnergy { // ties go late: longer chunks
                    bestEnergy = energy
                    best = offset + window / 2
                }
                offset += hop
            }
            cuts.append(best)
            start = best
        }
        return cuts
    }

    /// Samples and rate of a 16-bit mono PCM WAV; nil for anything else.
    static func decode(_ wav: Data) -> (samples: [Int16], sampleRate: Int)? {
        let bytes = [UInt8](wav)
        guard bytes.count >= 12, bytes[0..<4].elementsEqual("RIFF".utf8),
              bytes[8..<12].elementsEqual("WAVE".utf8) else { return nil }
        func uint(_ at: Int, _ size: Int) -> Int {
            (0..<size).reduce(0) { $0 | Int(bytes[at + $1]) << (8 * $1) }
        }
        var offset = 12
        var sampleRate: Int?
        while offset + 8 <= bytes.count {
            let size = uint(offset + 4, 4)
            let body = offset + 8
            guard body + size <= bytes.count else { return nil }
            if bytes[offset..<(offset + 4)].elementsEqual("fmt ".utf8) {
                guard size >= 16, uint(body, 2) == 1, uint(body + 2, 2) == 1,
                      uint(body + 14, 2) == 16 else { return nil }
                sampleRate = uint(body + 4, 4)
            } else if bytes[offset..<(offset + 4)].elementsEqual("data".utf8) {
                guard let sampleRate, sampleRate > 0 else { return nil }
                let samples = Data(bytes[body..<(body + size - size % 2)])
                    .withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
                return (samples, sampleRate)
            }
            offset = body + size + size % 2
        }
        return nil
    }
}
