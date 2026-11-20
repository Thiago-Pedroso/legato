import AVFoundation
import AudioToolbox
import FluidAudio
import LegatoCore

/// Captures the microphone and hands back 16 kHz mono samples.
final class Recorder {
    private var engine: AVAudioEngine?
    private var captured: [Float] = []
    private var rate: Double = 0
    private let lock = NSLock()
    private var peak: CGFloat = 0
    private var pending = 0
    /// Loudness from 0 to 1, delivered on the main thread while recording.
    var onLevel: ((CGFloat) -> Void)?

    var isRecording: Bool { engine != nil }

    /// Records from `device`, or from the system's default input when it is nil.
    func start(device: AudioDeviceID? = nil) throws {
        // A fresh engine each time picks up whatever microphone is current (AirPods, external).
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if var device, let unit = input.audioUnit {
            AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device,
                UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(
                domain: "Legato", code: 1,
                userInfo: [NSLocalizedDescriptionKey: L.t("No microphone found", "Nenhum microfone encontrado")])
        }
        lock.lock()
        captured = []
        rate = format.sampleRate
        lock.unlock()
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, let channel = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            let samples = UnsafeBufferPointer(start: channel, count: count)
            var sum: Float = 0
            for sample in samples { sum += sample * sample }
            self.lock.lock()
            self.captured.append(contentsOf: samples)
            self.lock.unlock()
            let decibels = 10 * log10(max(sum / Float(max(count, 1)), 1e-10))
            // Report the loudest moment of each ~60 ms, a pace the eye can follow.
            self.peak = max(self.peak, CGFloat(max(0, min(1, (decibels + 52) / 40))))
            self.pending += count
            guard Double(self.pending) >= format.sampleRate * 0.06 else { return }
            let level = self.peak
            self.peak = 0
            self.pending = 0
            DispatchQueue.main.async { self.onLevel?(level) }
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    /// Stops and returns what was captured, resampled for the speech engines.
    func stop() -> [Float] {
        guard let engine else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        lock.lock()
        let samples = captured
        let rate = self.rate
        captured = []
        lock.unlock()
        if rate == Double(WAV.sampleRate) { return samples }
        return (try? AudioConverter().resample(samples, from: rate)) ?? []
    }
}
