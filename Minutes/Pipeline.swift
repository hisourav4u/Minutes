import Foundation

/// Turns a finished recording into a markdown note:
///   1. whisper.cpp transcribes each track (local, nothing leaves the machine)
///   2. the two tracks merge by timestamp into a Me/Them transcript
///   3. `claude -p` writes the summary
///   4. everything lands in one markdown file under ~/Documents/MeetingNotes
///
/// Steps 1–2 always produce something; if claude is unavailable or fails, the
/// note ships with the transcript and a note saying the summary was skipped.
enum Pipeline {

    struct Result {
        let noteURL: URL
        let summaryFailed: Bool
    }

    // MARK: - entry

    static func process(_ rec: Recorder.Output, keepAudio: Bool,
                        progress: @escaping (String) -> Void) throws -> Result {
        let whisper = try findWhisper()
        let model = try findModel()

        progress("Transcribing your mic…")
        let mine = try transcribe(rec.micURL, whisper: whisper, model: model)
        progress("Transcribing the others…")
        let theirs = try transcribe(rec.systemURL, whisper: whisper, model: model)

        let segments = merge(mine: mine, theirs: theirs)
        let transcript = render(segments)
        let duration = segments.last.map { $0.end } ?? 0

        progress("Summarizing…")
        var summaryFailed = false
        var summary: String
        if transcript.isEmpty {
            summary = "_Nothing was transcribed — the recording appears to be silent._"
        } else if let s = summarize(transcript: transcript), !s.isEmpty {
            summary = s
        } else {
            summaryFailed = true
            summary = "_Summary unavailable (claude CLI failed or missing). Transcript below._"
        }

        let noteURL = try writeNote(
            startedAt: rec.startedAt, duration: duration,
            summary: summary, transcript: transcript)

        if !keepAudio && !transcript.isEmpty {
            try? FileManager.default.removeItem(at: rec.directory)
        }
        return Result(noteURL: noteURL, summaryFailed: summaryFailed)
    }

    // MARK: - whisper

    struct Segment {
        let start: TimeInterval
        var end: TimeInterval
        let speaker: String
        var text: String
    }

    private static func transcribe(_ wav: URL, whisper: URL, model: URL) throws -> [(TimeInterval, TimeInterval, String)] {
        let outPrefix = wav.deletingPathExtension()
        let p = Process()
        p.executableURL = whisper
        p.arguments = [
            "-m", model.path,
            "-f", wav.path,
            "-l", "en",
            "-oj",                      // JSON with per-segment offsets
            "-of", outPrefix.path,
            "-np",                      // no progress spam
        ]
        let sink = Pipe()
        p.standardOutput = sink
        p.standardError = sink
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let log = String(data: sink.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw PipelineError.whisperFailed(String(log.suffix(400)))
        }

        let jsonURL = outPrefix.appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: jsonURL) }
        let data = try Data(contentsOf: jsonURL)
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let items = root["transcription"] as? [[String: Any]]
        else { throw PipelineError.whisperFailed("unexpected JSON shape") }

        var out: [(TimeInterval, TimeInterval, String)] = []
        for item in items {
            guard
                let offsets = item["offsets"] as? [String: Any],
                let from = (offsets["from"] as? NSNumber)?.doubleValue,
                let to = (offsets["to"] as? NSNumber)?.doubleValue,
                let text = (item["text"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                !text.isEmpty
            else { continue }
            // Whisper marks non-speech with bracketed tokens in varying case
            // and spacing ("[ Silence ]", "(music)", "[BLANK_AUDIO]") — drop
            // any segment that is only such a token.
            let bare = text.lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]() \t"))
            if text.hasPrefix("[") || text.hasPrefix("(") {
                if ["blank_audio", "silence", "music", "applause", "laughter",
                    "inaudible", "noise"].contains(bare) { continue }
            }
            out.append((from / 1000, to / 1000, text))
        }
        return out
    }

    // MARK: - merge

    /// Interleaves both tracks by start time and coalesces consecutive
    /// segments of the same speaker into one turn.
    private static func merge(
        mine: [(TimeInterval, TimeInterval, String)],
        theirs: [(TimeInterval, TimeInterval, String)]
    ) -> [Segment] {
        var all = mine.map { Segment(start: $0.0, end: $0.1, speaker: "Me", text: $0.2) }
            + theirs.map { Segment(start: $0.0, end: $0.1, speaker: "Them", text: $0.2) }
        all.sort { $0.start < $1.start }

        // Coalesce consecutive same-speaker segments, but cap a turn at ~45 s:
        // a long monologue must break into timestamped paragraphs, or an hour
        // of mostly one voice renders as a single unreadable blob.
        let maxTurn: TimeInterval = 45
        var merged: [Segment] = []
        for seg in all {
            if var last = merged.last, last.speaker == seg.speaker,
               seg.start - last.end < 2.0, seg.end - last.start <= maxTurn {
                last.text += " " + seg.text
                last.end = max(last.end, seg.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(seg)
            }
        }
        return merged
    }

    private static func render(_ segments: [Segment]) -> String {
        segments.map { "[\(clock($0.start))] **\($0.speaker):** \($0.text)" }
            .joined(separator: "\n")
    }

    private static func clock(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }

    // MARK: - summary

    private static let summaryPrompt = """
        Below is a meeting transcript with two speakers: "Me" (the user) and \
        "Them" (all other participants, captured as one system-audio track). \
        Write concise meeting notes in markdown with these sections, omitting \
        any that would be empty: ## TL;DR (2-3 lines), ## Decisions, \
        ## Action items (bullet per item, bold the owner, use "Me" for the user), \
        ## Open questions, ## Key points. Be strictly factual — do not invent \
        names, dates, or commitments that are not in the transcript. Output \
        only the markdown, no preamble.
        """

    private static func summarize(transcript: String) -> String? {
        guard let claude = firstExisting([
            "\(NSHomeDirectory())/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]) else { return nil }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: claude)
        p.arguments = ["-p", summaryPrompt]

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr

        do {
            try p.run()
        } catch { return nil }

        stdin.fileHandleForWriting.write(transcript.data(using: .utf8)!)
        stdin.fileHandleForWriting.closeFile()

        // Read before waiting — a large summary can fill the pipe and deadlock
        // a process that is blocked on write while we are blocked on exit.
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        _ = stderr.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        guard p.terminationStatus == 0 else { return nil }
        return String(data: out, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - note

    static var notesRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingNotes", isDirectory: true)
    }

    private static func writeNote(
        startedAt: Date, duration: TimeInterval,
        summary: String, transcript: String
    ) throws -> URL {
        try FileManager.default.createDirectory(at: notesRoot, withIntermediateDirectories: true)

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HHmm"
        df.locale = Locale(identifier: "en_US_POSIX")
        let stamp = df.string(from: startedAt)

        let titleDF = DateFormatter()
        titleDF.dateStyle = .full
        titleDF.timeStyle = .short

        let url = notesRoot.appendingPathComponent("\(stamp).md")
        let body = """
        # Meeting — \(titleDF.string(from: startedAt))

        _Duration: \(clock(duration)) · transcribed locally by whisper.cpp_

        \(summary)

        ---

        ## Transcript

        \(transcript.isEmpty ? "_(empty)_" : transcript)
        """
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - tool discovery

    private static func findWhisper() throws -> URL {
        if let p = firstExisting([
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli",
            "/opt/homebrew/bin/whisper-cpp",
            "/usr/local/bin/whisper-cpp",
        ]) { return URL(fileURLWithPath: p) }
        throw PipelineError.toolMissing("whisper-cli not found — brew install whisper-cpp")
    }

    /// Best model available wins. large-v3-turbo outranks medium deliberately:
    /// near large-v3 accuracy at medium-class speed, similar size.
    private static func findModel() throws -> URL {
        let dir = Recorder.supportRoot.appendingPathComponent("models", isDirectory: true)
        for name in ["ggml-large-v3-turbo.bin", "ggml-large-v3.bin", "ggml-medium.bin",
                     "ggml-small.bin", "ggml-base.bin", "ggml-tiny.bin"] {
            let url = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        throw PipelineError.toolMissing("no whisper model in \(dir.path) — run setup.sh")
    }

    private static func firstExisting(_ paths: [String]) -> String? {
        paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

enum PipelineError: LocalizedError {
    case whisperFailed(String)
    case toolMissing(String)

    var errorDescription: String? {
        switch self {
        case .whisperFailed(let log): return "Transcription failed: \(log)"
        case .toolMissing(let what): return what
        }
    }
}
