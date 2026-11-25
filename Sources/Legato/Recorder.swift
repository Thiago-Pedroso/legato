import AVFoundation
import AudioToolbox
import FluidAudio
import LegatoCore

/// Captures the microphone and hands back 16 kHz mono samples.
///
/// Opening a microphone is slow: building an audio engine takes about a tenth of a second, and
/// well over a second the first time in a process. So an engine is built ahead of time, and all
/// the audio work happens on a queue of its own: the key press never waits for it, and the
/// screen never freezes while a Bluetooth headset wakes up.
final class Recorder {
    /// Loudness from 0 to 1, delivered on the main thread while recording.
    var onLevel: ((CGFloat) -> Void)?
    /// The microphone could not be opened, delivered on the main thread. The recording is over.
    var onFailure: ((Error) -> Void)?

    /// Main thread only, like `start` and `stop`.
    private(set) var isRecording = false
    private var generation = 0

    private let queue = DispatchQueue(label: "Legato recorder", qos: .userInteractive)
    // Owned by `queue`.
    private var spare: AVAudioEngine?
    private var engine: AVAudioEngine?
    private var wanted: AudioDeviceID?
    private var observer: NSObjectProtocol?
    private var reopenings = 0
    private var openGeneration = 0
    // Shared with the audio thread, under `lock`.
    private let lock = NSLock()
    private var captured: [Float] = []
    private var rate: Double = 0
    /// Audio from before the microphone changed format, already at 16 kHz.
    private var earlier: [Float] = []
    // Audio thread only.
    private var peak: CGFloat = 0
    private var pending = 0

    /// Builds the engine for the next recording in the background. `fresh` replaces one built
    /// earlier, for when the audio hardware may have changed under it, as after sleep.
    func prepare(fresh: Bool = false) {
        queue.async { [self] in
            if fresh || spare == nil { spare = Self.makeEngine() }
        }
    }

    /// Starts recording from `device`, or from the system's default input when it is nil.
    /// Returns at once; if the microphone cannot be opened, `onFailure` says so.
    func start(device: AudioDeviceID? = nil) {
        isRecording = true
        generation += 1
        let generation = self.generation
        queue.async { [self] in
            lock.withLock {
                captured = []
                earlier = []
            }
            reopenings = 0
            openGeneration = generation
            do {
                do {
                    try open(spare ?? Self.makeEngine(), device: device)
                } catch {
                    // An engine built before sleep or before a device left can be stale.
                    spare = nil
                    try open(Self.makeEngine(), device: device)
                }
                spare = nil
            } catch {
                fail(error, generation: generation)
            }
        }
    }

    /// Stops and returns what was captured, resampled for the speech engines.
    func stop() -> [Float] {
        guard isRecording else { return [] }
        isRecording = false
        generation += 1
        let samples = queue.sync { () -> [Float] in
            close()
            let (segment, rate, earlier) = lock.withLock { (captured, self.rate, self.earlier) }
            lock.withLock {
                captured = []
                self.earlier = []
            }
            return earlier + Self.resample(segment, from: rate)
        }
        prepare()
        return samples
    }

    // MARK: On the queue

    private static func makeEngine() -> AVAudioEngine {
        let engine = AVAudioEngine()
        // Building the input node is the slow part.
        _ = engine.inputNode
        return engine
    }

    private func open(_ engine: AVAudioEngine, device: AudioDeviceID?) throws {
        let input = engine.inputNode
        // Without a choice the engine follows the system default by itself; naming that device
        // would only make it reconfigure after starting.
        if var id = device, let unit = input.audioUnit, Self.current(unit) != id {
            AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id,
                UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        engine.prepare()
        // Read after `prepare`: right after a switch the input still reports the old microphone's
        // format, and a tap in the wrong format hears nothing.
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(
                domain: "Legato", code: 1,
                userInfo: [NSLocalizedDescriptionKey: L.t("No microphone found", "Nenhum microfone encontrado")])
        }
        lock.withLock { rate = format.sampleRate }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.receive(buffer)
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
        wanted = device
        // A Bluetooth headset switches to its call profile when its microphone opens, and a
        // microphone can be unplugged mid-dictation. The engine then stops and has to be reopened.
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.queue.async { self?.reopen() }
        }
    }

    private func reopen() {
        guard let engine, reopenings < 3 else { return }
        // Switching to a chosen microphone announces a change of its own, after which the engine
        // runs on in the same format. Only a stopped engine or a new format needs reopening.
        let tapped = lock.withLock { self.rate }
        if engine.isRunning, engine.inputNode.inputFormat(forBus: 0).sampleRate == tapped {
            return
        }
        reopenings += 1
        close()
        let segment = lock.withLock { captured }
        let converted = Self.resample(segment, from: tapped)
        lock.withLock {
            earlier += converted
            captured = []
        }
        // A chosen microphone that went away hands over to the default one.
        let device = wanted.flatMap { id in AudioDevices.inputs().contains { $0.id == id } ? id : nil }
        do {
            try open(Self.makeEngine(), device: device)
        } catch {
            fail(error, generation: openGeneration)
        }
    }

    private func close() {
        guard let engine else { return }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    private func fail(_ error: Error, generation: Int) {
        DispatchQueue.main.async { [self] in
            guard generation == self.generation, isRecording else { return }
            isRecording = false
            onFailure?(error)
        }
    }

    private static func current(_ unit: AudioUnit) -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, &size)
        return status == noErr ? id : nil
    }

    private static func resample(_ samples: [Float], from rate: Double) -> [Float] {
        if samples.isEmpty || rate == Double(WAV.sampleRate) { return samples }
        return (try? AudioConverter().resample(samples, from: rate)) ?? []
    }

    // MARK: On the audio thread

    private func receive(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        let samples = UnsafeBufferPointer(start: channel, count: count)
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        lock.withLock { captured.append(contentsOf: samples) }
        let decibels = 10 * log10(max(sum / Float(max(count, 1)), 1e-10))
        // Report the loudest moment of each ~60 ms, a pace the eye can follow.
        peak = max(peak, CGFloat(max(0, min(1, (decibels + 52) / 40))))
        pending += count
        guard Double(pending) >= buffer.format.sampleRate * 0.06 else { return }
        let level = peak
        peak = 0
        pending = 0
        DispatchQueue.main.async { self.onLevel?(level) }
    }
}
