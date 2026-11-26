import AVFoundation
import AudioToolbox
import FluidAudio
import LegatoCore

/// Captures the microphone and hands back 16 kHz mono samples.
///
/// Opening a microphone is slow: building an audio engine takes about a tenth of a second, and
/// well over a second the first time in a process. So an engine is built ahead of time, and all
/// the audio work happens on a queue of its own: neither the key press nor the screen ever waits
/// for it, not even while a Bluetooth headset wakes up.
final class Recorder {
    /// How a recording ended.
    struct Ending {
        var samples: [Float]
        /// Why the microphone could not be opened or reopened, if it could not.
        var error: Error?
        /// The microphone was open for over a second and sent nothing.
        var silent = false
        var stats = Stats()
    }

    /// How the microphone behaved, for the diagnostics log.
    struct Stats {
        var device: String?
        var rate: Double = 0
        /// Seconds from `start` to the first sample that was not silence. Nil if none came.
        var soundDelay: Double?
        /// Seconds recorded after the key came up, while the speaker was finishing a word.
        var tail: Double = 0
        var reopenings = 0
    }

    /// Loudness from 0 to 1, delivered on the main thread while recording.
    var onLevel: ((CGFloat) -> Void)?
    /// The microphone failed while recording, delivered on the main thread. Call `stop` to get
    /// what was captured before it did, and the error.
    var onFailure: ((Error) -> Void)?

    /// Main thread only, like `start` and `stop`.
    private(set) var isRecording = false
    private var generation = 0

    private let queue = DispatchQueue(label: "Legato recorder", qos: .userInteractive)
    // Owned by `queue`.
    private var spare: (engine: AVAudioEngine, input: AudioDeviceID?)?
    private var engine: AVAudioEngine?
    private var wanted: AudioDeviceID?
    private var observer: NSObjectProtocol?
    private var reopenings = 0
    private var openGeneration = 0
    private var failure: Error?
    private var openedAt: CFAbsoluteTime?
    private var startedAt: CFAbsoluteTime = 0
    private var device: String?
    // Shared with the audio thread, under `lock`.
    private let lock = NSLock()
    private var captured: [Float] = []
    private var rate: Double = 0
    /// Loudness of each buffer, about a tenth of a second, in dBFS, to tell speech from the room.
    private var levels: [Float] = []
    private var firstSoundAt: CFAbsoluteTime?
    /// Which tap is current. A buffer from a tap being removed must not land in the next one.
    private var tap = 0
    /// Audio from before the microphone changed format, already at 16 kHz.
    private var earlier: [Float] = []
    // Audio thread only.
    private var peak: CGFloat = 0
    private var pending = 0

    /// Builds the engine for the next recording in the background. `fresh` replaces one built
    /// earlier, for when the audio hardware may have changed under it, as after sleep.
    func prepare(fresh: Bool = false) {
        queue.async { [self] in
            if fresh || spare == nil { spare = (Self.makeEngine(), AudioDevices.defaultInput) }
        }
    }

    /// Starts recording from the device `choose` names, or from the system's default input when
    /// it names none. `choose` runs off the main thread: asking Core Audio about devices is slow.
    /// Returns at once; if the microphone cannot be opened, `onFailure` says so.
    func start(device choose: @escaping () -> AudioDeviceID? = { nil }) {
        isRecording = true
        generation += 1
        let generation = self.generation
        let pressed = CFAbsoluteTimeGetCurrent()
        queue.async { [self] in
            lock.withLock {
                captured = []
                earlier = []
                levels = []
                firstSoundAt = nil
            }
            startedAt = pressed
            self.device = nil
            let device = choose()
            reopenings = 0
            openGeneration = generation
            failure = nil
            openedAt = nil
            // An engine built for another default microphone is not worth trusting.
            let ready = spare.flatMap { device != nil || $0.input == AudioDevices.defaultInput ? $0.engine : nil }
            spare = nil
            do {
                do {
                    try open(ready ?? Self.makeEngine(), device: device)
                } catch _ where ready != nil {
                    // An engine built before sleep or before a device left can be stale.
                    try open(Self.makeEngine(), device: device)
                }
            } catch {
                fail(error)
            }
        }
    }

    /// Stops, and hands what was captured, resampled for the speech engines, to `done` on the
    /// main thread. Waiting for a microphone that is still opening happens off the main thread.
    /// With `tail`, a speaker still mid-word when the key came up is heard to the end of it.
    func stop(tail: Bool = true, _ done: @escaping (Ending) -> Void) {
        guard isRecording else { return done(Ending(samples: [])) }
        isRecording = false
        generation += 1
        queue.async { [self] in
            let tailed = tail ? finishWord() : 0
            close()
            let (segment, rate, earlier, firstSound) = lock.withLock { () -> ([Float], Double, [Float], CFAbsoluteTime?) in
                defer {
                    captured = []
                    self.earlier = []
                    levels = []
                }
                return (captured, self.rate, self.earlier, firstSoundAt)
            }
            var ending = Ending(samples: earlier + Self.resample(segment, from: rate), error: failure)
            ending.silent = ending.samples.isEmpty && failure == nil
                && openedAt.map { CFAbsoluteTimeGetCurrent() - $0 > 1 } == true
            ending.stats = Stats(
                device: device, rate: rate, soundDelay: firstSound.map { $0 - startedAt }, tail: tailed,
                reopenings: reopenings)
            failure = nil
            openedAt = nil
            DispatchQueue.main.async { done(ending) }
        }
        prepare()
    }

    /// Keeps recording while the sound stays at speech level, up to `SpeechEdge.longestTail`.
    /// Returns how long it waited. A recording that ends in silence does not wait at all.
    private func finishWord() -> Double {
        guard engine != nil else { return 0 }
        let start = CFAbsoluteTimeGetCurrent()
        let (initial, count, speaking) = lock.withLock { () -> (Float, Int, Bool) in
            let threshold = SpeechEdge.threshold(levels: levels)
            return (threshold, levels.count, SpeechEdge.speaking(levels, above: threshold))
        }
        guard speaking else { return 0 }
        var (threshold, seen) = (initial, count)
        while CFAbsoluteTimeGetCurrent() - start < SpeechEdge.longestTail {
            usleep(10_000)
            let (count, still) = lock.withLock { (levels.count, SpeechEdge.speaking(levels, above: threshold)) }
            guard count > seen else { continue }
            seen = count
            if !still { break }
            // A rising floor, as when the room gets louder, must not keep the recording open.
            threshold = max(threshold, lock.withLock { SpeechEdge.threshold(levels: levels) })
        }
        return CFAbsoluteTimeGetCurrent() - start
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
        // A Bluetooth headset switches to its call profile when its microphone opens, and a
        // microphone can be unplugged mid-dictation. The engine then stops and has to be reopened.
        // Watched from before the start, so a change while starting is not missed.
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.queue.async { self?.reopen() }
        }
        do {
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
            let tap = lock.withLock { () -> Int in
                rate = format.sampleRate
                self.tap += 1
                return self.tap
            }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.receive(buffer, tap: tap)
            }
            do {
                try engine.start()
            } catch {
                input.removeTap(onBus: 0)
                throw error
            }
        } catch {
            NotificationCenter.default.removeObserver(observer)
            throw error
        }
        self.engine = engine
        self.observer = observer
        wanted = device
        if openedAt == nil { openedAt = CFAbsoluteTimeGetCurrent() }
        // Following the default, the engine records through an aggregate of its own; name the
        // microphone behind it instead.
        self.device = (device ?? AudioDevices.defaultInput).flatMap(AudioDevices.name(of:))
    }

    private func reopen() {
        guard let engine, reopenings < 3 else { return }
        // Switching to a chosen microphone announces a change of its own, after which the engine
        // runs on in the same format. Only a stopped engine or a new format needs reopening.
        let tapped = lock.withLock { rate }
        if engine.isRunning, engine.inputNode.inputFormat(forBus: 0).sampleRate == tapped {
            return
        }
        reopenings += 1
        close()
        let segment = lock.withLock { () -> [Float] in
            defer { captured = [] }
            return captured
        }
        let converted = Self.resample(segment, from: tapped)
        lock.withLock { earlier += converted }
        // A chosen microphone that went away hands over to the default one.
        let device = wanted.flatMap { id in AudioDevices.inputs().contains { $0.id == id } ? id : nil }
        do {
            try open(Self.makeEngine(), device: device)
        } catch {
            fail(error)
        }
    }

    private func close() {
        guard let engine else { return }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        lock.withLock { tap += 1 }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    /// Keeps the error for `stop`, and tells the controller if the recording is still on.
    private func fail(_ error: Error) {
        failure = error
        let generation = openGeneration
        DispatchQueue.main.async { [self] in
            guard generation == self.generation, isRecording else { return }
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

    private func receive(_ buffer: AVAudioPCMBuffer, tap: Int) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        let samples = UnsafeBufferPointer(start: channel, count: count)
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        let decibels = 10 * log10(max(sum / Float(max(count, 1)), 1e-10))
        let current = lock.withLock { () -> Bool in
            guard tap == self.tap else { return false }
            captured.append(contentsOf: samples)
            levels.append(decibels)
            // A microphone waking up, as a Bluetooth headset does, sends pure zeros at first.
            if firstSoundAt == nil, sum > 0 { firstSoundAt = CFAbsoluteTimeGetCurrent() }
            return true
        }
        guard current else { return }
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
