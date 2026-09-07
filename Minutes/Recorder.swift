import AVFoundation
import ScreenCaptureKit

/// Records two synchronized tracks:
///   mic.wav    — the user's own voice (AVAudioEngine input tap)
///   system.wav — everyone else (ScreenCaptureKit system-audio capture)
///
/// System audio is tapped inside the OS, before output routing, so earphones
/// or speakers make no difference to what gets captured.
///
/// Both tracks are written as 16 kHz mono Int16 WAV from the start — exactly
/// what whisper.cpp wants — so there is no conversion step at stop time.
final class Recorder: NSObject {

    struct Output {
        let directory: URL
        let micURL: URL
        let systemURL: URL
        let startedAt: Date
    }

    private(set) var output: Output?

    // Whisper's native input format. Converting live also keeps files small:
    // ~115 MB/hour for both tracks together instead of >1 GB of 48k float.
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    // ── mic ──────────────────────────────────────────────────────────────────
    private let engine = AVAudioEngine()
    private var micFile: AVAudioFile?
    private var micConverter: AVAudioConverter?
    private let micQueue = DispatchQueue(label: "minutes.mic.write")

    // ── system ───────────────────────────────────────────────────────────────
    private var stream: SCStream?
    private var systemFile: AVAudioFile?
    private var systemConverter: AVAudioConverter?
    private let systemQueue = DispatchQueue(label: "minutes.system.write")

    private var running = false

    // MARK: - lifecycle

    func start() async throws {
        guard !running else { return }

        // Mic permission first — the system prompt must come from a user action.
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else { throw RecorderError.microphoneDenied }

        let stamp = Self.stampFormatter.string(from: Date())
        let dir = Self.recordingsRoot.appendingPathComponent(stamp, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let out = Output(
            directory: dir,
            micURL: dir.appendingPathComponent("mic.wav"),
            systemURL: dir.appendingPathComponent("system.wav"),
            startedAt: Date())

        micFile = try Self.makeWav(at: out.micURL, format: targetFormat)
        systemFile = try Self.makeWav(at: out.systemURL, format: targetFormat)

        try await startSystemCapture()
        try startMicCapture()

        output = out
        running = true
    }

    /// Stops both captures and returns what was recorded.
    func stop() async -> Output? {
        guard running else { return nil }
        running = false

        NotificationCenter.default.removeObserver(
            self, name: .AVAudioEngineConfigurationChange, object: engine)
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil

        // Serialise behind any in-flight writes, then close the files.
        micQueue.sync { self.micFile = nil }
        systemQueue.sync { self.systemFile = nil }
        micConverter = nil
        systemConverter = nil

        let out = output
        output = nil
        return out
    }

    var elapsed: TimeInterval {
        guard running, let started = output?.startedAt else { return 0 }
        return Date().timeIntervalSince(started)
    }

    // MARK: - mic capture

    private func startMicCapture() throws {
        try installMicTap()
        engine.prepare()
        try engine.start()

        // AirPods connecting or dying mid-meeting changes the input device.
        // The engine stops and the tap format goes stale — without this the
        // mic track silently ends the moment the device switches.
        NotificationCenter.default.addObserver(
            self, selector: #selector(engineConfigurationChanged),
            name: .AVAudioEngineConfigurationChange, object: engine)
    }

    @objc private func engineConfigurationChanged(_ note: Notification) {
        guard running else { return }
        // The notification arrives on an arbitrary thread while the engine is
        // torn down. Rebuild tap + converter against the new device format.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.running else { return }
            self.engine.inputNode.removeTap(onBus: 0)
            self.micConverter = nil
            do {
                try self.installMicTap()
                self.engine.prepare()
                try self.engine.start()
            } catch {
                NSLog("Minutes: mic restart after device change failed: \(error)")
            }
        }
    }

    private func installMicTap() throws {
        // Clear any tap left behind by a previous start/config-change — installing a
        // second tap on a bus that already has one throws an ObjC exception that
        // takes down the whole app (SIGABRT), which is not catchable in Swift.
        engine.inputNode.removeTap(onBus: 0)

        // Use the input node's *hardware* format, not outputFormat. When the default
        // input device is unusable (none selected, an output-only device, a Bluetooth
        // mic mid-switch), the format can come back with a valid sample rate but ZERO
        // channels — installTap then throws. Guard both so we surface a clean error
        // instead of crashing.
        let format = engine.inputNode.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecorderError.noInputDevice
        }

        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) {
            [weak self] buffer, _ in
            guard let self else { return }
            self.micQueue.async {
                guard let file = self.micFile else { return }
                if self.micConverter == nil || self.micConverter!.inputFormat != buffer.format {
                    self.micConverter = AVAudioConverter(from: buffer.format, to: self.targetFormat)
                }
                guard let conv = self.micConverter else { return }
                Self.append(buffer, via: conv, to: file, targetFormat: self.targetFormat)
            }
        }
    }

    // MARK: - system capture

    private func startSystemCapture() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw RecorderError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 16_000
        config.channelCount = 1
        // Audio is the point; make the mandatory video leg as cheap as possible.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: systemQueue)
        // Some SCStream builds refuse to start without a screen output attached.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: nil)
        try await stream.startCapture()
        self.stream = stream
    }

    // MARK: - shared write path

    /// Converts a buffer of any device format to the 16 kHz target and appends
    /// it. The converter is persistent per track, which matters: sample-rate
    /// conversion keeps filter state across calls, and recreating it every
    /// buffer would click at each boundary.
    private static func append(
        _ buffer: AVAudioPCMBuffer, via converter: AVAudioConverter,
        to file: AVAudioFile, targetFormat: AVAudioFormat
    ) {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var fed = false
        var err: NSError?
        let status = converter.convert(to: out, error: &err) { _, inputStatus in
            if fed { inputStatus.pointee = .noDataNow; return nil }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status != .error, out.frameLength > 0 {
            do { try file.write(from: out) }
            catch { NSLog("Minutes: write failed: \(error)") }
        }
    }

    private static func makeWav(at url: URL, format: AVAudioFormat) throws -> AVAudioFile {
        try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ],
            commonFormat: .pcmFormatInt16,
            interleaved: true)
    }

    // MARK: - paths

    static var supportRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Minutes", isDirectory: true)
    }
    static var recordingsRoot: URL {
        supportRoot.appendingPathComponent("recordings", isDirectory: true)
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

// MARK: - SCStreamOutput

extension Recorder: SCStreamOutput {
    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, running, sampleBuffer.isValid else { return }
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: desc)

        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else { return }
        pcm.frameLength = frames

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames),
            into: pcm.mutableAudioBufferList)
        guard status == noErr else { return }

        // Already on systemQueue (the sampleHandlerQueue) — write directly.
        guard let file = systemFile else { return }
        if systemConverter == nil || systemConverter!.inputFormat != format {
            systemConverter = AVAudioConverter(from: format, to: targetFormat)
        }
        guard let conv = systemConverter else { return }
        Self.append(pcm, via: conv, to: file, targetFormat: targetFormat)
    }
}

enum RecorderError: LocalizedError {
    case microphoneDenied
    case noDisplay
    case noInputDevice

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Microphone access denied. Enable it in System Settings → Privacy & Security → Microphone."
        case .noDisplay:
            return "No display found for system-audio capture. Check Screen Recording permission in System Settings → Privacy & Security."
        case .noInputDevice:
            return "No usable microphone was found. Pick an input device in System Settings → Sound → Input (or reconnect your mic), then try again."
        }
    }
}
