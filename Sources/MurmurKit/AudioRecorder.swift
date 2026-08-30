import AVFoundation

public enum AudioRecorderError: Error, LocalizedError {
    case noInputDevice
    case converterUnavailable

    public var errorDescription: String? {
        switch self {
        case .noInputDevice: return "No microphone available"
        case .converterUnavailable: return "Audio converter failed"
        }
    }
}

/// Captures mic audio via AVAudioEngine and resamples it with ONE persistent
/// AVAudioConverter per recording session (per-buffer converters lose resampler
/// state and click at buffer boundaries).
///
/// Two modes, chosen via `outputMode` before `start()`:
///  - `.batchInt16` (default): 16 kHz mono Int16 accumulated and returned by
///    `stop()` — the WAV path for Groq / whisper.cpp.
///  - `.streamingFloat32`: 24 kHz mono Float32 delivered live via `onChunk`
///    (nothing accumulated) — the Kyutai streaming path.
public final class AudioRecorder {
    /// Batch (Int16 WAV) sample rate.
    public static let targetSampleRate = 16_000.0
    /// Streaming (Float32) sample rate — what the Kyutai server expects.
    public static let streamingSampleRate = 24_000.0

    public enum OutputMode { case batchInt16, streamingFloat32 }

    /// Normalized-RMS floor (full-scale [0,1]) below which a batch capture is
    /// treated as non-speech (silence / muted mic / room tone). Guards against
    /// Whisper hallucinating canned phrases ("Thank you for watching") on
    /// near-silent audio, which the cloud API gives no decoder knob to prevent.
    public static let speechRMSFloor: Float = 0.004

    /// True if the captured Int16 audio carries enough energy to be speech.
    /// Pure (testable); accumulates in Double so long clips don't overflow.
    public static func hasSpeechEnergy(_ samples: [Int16],
                                       floor: Float = speechRMSFloor) -> Bool {
        guard !samples.isEmpty else { return false }
        var sumSquares = 0.0
        for sample in samples {
            let normalized = Double(sample) / 32768.0
            sumSquares += normalized * normalized
        }
        let rms = (sumSquares / Double(samples.count)).squareRoot()
        return Float(rms) >= floor
    }

    /// Removes DC offset and peak-normalizes to `targetPeak` (fraction of full
    /// scale), so a consistent level reaches the model when mic gain / distance
    /// varies between utterances. `maxGain` caps amplification so quiet captures
    /// aren't blown up into noise. Pure (testable). Run this AFTER
    /// `hasSpeechEnergy` so genuine silence is never amplified. Returns the input
    /// unchanged when empty, silent (no AC component), or already at level.
    public static func normalize(_ samples: [Int16],
                                 targetPeak: Float = 0.9,
                                 maxGain: Float = 10) -> [Int16] {
        guard !samples.isEmpty else { return samples }
        let mean = samples.reduce(0.0) { $0 + Double($1) } / Double(samples.count)
        var peak = 0.0
        for sample in samples { peak = max(peak, abs(Double(sample) - mean)) }
        guard peak > 0 else { return samples } // pure DC / silence — nothing to scale
        let gain = min(Double(maxGain), Double(targetPeak) * 32768.0 / peak)
        if abs(gain - 1) < 0.01, abs(mean) < 1 { return samples } // already at level, no DC
        var out = [Int16](repeating: 0, count: samples.count)
        for i in samples.indices {
            let scaled = (Double(samples[i]) - mean) * gain
            out[i] = Int16(max(-32768.0, min(32767.0, scaled.rounded())))
        }
        return out
    }

    /// Set before `start()`. Defaults to the original 16 kHz Int16 batch path.
    public var outputMode: OutputMode = .batchInt16

    /// Streaming mode only: fired on the audio thread with each converted
    /// 24 kHz mono Float32 buffer. Must not block (enqueue and return).
    public var onChunk: (([Float]) -> Void)?

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Int16] = []
    private var configChangeObserver: NSObjectProtocol?

    public private(set) var isRecording = false

    /// Fired (on an arbitrary thread) when the input device changes
    /// mid-recording, e.g. AirPods connecting. The session must be aborted.
    public var onConfigurationChange: (() -> Void)?

    public init() {}

    public func start() throws {
        let streaming = (outputMode == .streamingFloat32)

        lock.lock()
        samples = []
        if !streaming { samples.reserveCapacity(Int(Self.targetSampleRate) * 60) }
        lock.unlock()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioRecorderError.noInputDevice
        }
        let outRate = streaming ? Self.streamingSampleRate : Self.targetSampleRate
        let commonFormat: AVAudioCommonFormat = streaming ? .pcmFormatFloat32 : .pcmFormatInt16
        guard let outputFormat = AVAudioFormat(commonFormat: commonFormat,
                                               sampleRate: outRate,
                                               channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioRecorderError.converterUnavailable
        }
        converter.primeMethod = .none
        converter.sampleRateConverterQuality = .max // best anti-aliasing on the downsample

        let ratio = outRate / inputFormat.sampleRate
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.convertAndAppend(buffer, converter: converter,
                                   outputFormat: outputFormat, ratio: ratio)
        }

        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self, self.isRecording else { return }
            self.onConfigurationChange?()
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            removeObserver()
            throw error
        }
        isRecording = true
    }

    /// Stops the engine and returns everything captured (empty in streaming mode,
    /// where audio is delivered live via `onChunk`).
    @discardableResult
    public func stop() -> [Int16] {
        guard isRecording else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        removeObserver()
        isRecording = false

        lock.lock()
        let captured = samples
        samples = []
        lock.unlock()
        return captured
    }

    public func cancel() {
        _ = stop()
    }

    // MARK: realtime path — runs on the audio thread

    private func convertAndAppend(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter,
                                  outputFormat: AVAudioFormat, ratio: Double) {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return
        }
        var fed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow // NOT .endOfStream — the stream continues
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return }

        if outputMode == .streamingFloat32 {
            guard let channelData = output.floatChannelData else { return }
            let chunk = Array(UnsafeBufferPointer(start: channelData[0],
                                                  count: Int(output.frameLength)))
            onChunk?(chunk)
        } else {
            guard let channelData = output.int16ChannelData else { return }
            lock.lock()
            samples.append(contentsOf: UnsafeBufferPointer(start: channelData[0],
                                                           count: Int(output.frameLength)))
            lock.unlock()
        }
    }

    private func removeObserver() {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
    }
}
