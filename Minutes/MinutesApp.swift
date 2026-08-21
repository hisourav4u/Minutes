import SwiftUI
import AppKit
import UserNotifications

@main
struct MinutesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: state)
        } label: {
            Image(systemName: state.phase.symbol)
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }
}

// MARK: - state

@MainActor
final class AppState: ObservableObject {

    enum Phase: Equatable {
        case idle
        case recording
        case processing(String)
        case failed(String)

        var symbol: String {
            switch self {
            case .idle: return "waveform"
            case .recording: return "record.circle.fill"
            case .processing: return "gearshape.fill"
            case .failed: return "exclamationmark.triangle.fill"
            }
        }
    }

    @Published var phase: Phase = .idle
    @Published var elapsedText = ""
    @Published var lastNoteURL: URL? {
        didSet { UserDefaults.standard.set(lastNoteURL?.path, forKey: "lastNote") }
    }
    @Published var keepAudio = UserDefaults.standard.bool(forKey: "keepAudio") {
        didSet { UserDefaults.standard.set(keepAudio, forKey: "keepAudio") }
    }

    private let recorder = Recorder()
    private var ticker: Timer?

    init() {
        if let p = UserDefaults.standard.string(forKey: "lastNote"),
           FileManager.default.fileExists(atPath: p) {
            lastNoteURL = URL(fileURLWithPath: p)
        }
    }

    func toggle() {
        switch phase {
        case .idle, .failed: start()
        case .recording: stop()
        case .processing: break
        }
    }

    private func start() {
        phase = .processing("Starting capture…")
        Task {
            do {
                try await recorder.start()
                phase = .recording
                startTicker()
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func stop() {
        stopTicker()
        phase = .processing("Finishing recording…")
        Task {
            guard let output = await recorder.stop() else {
                phase = .idle
                return
            }
            let keep = keepAudio
            // Whisper + claude run for minutes on long meetings — keep them
            // far away from the main actor.
            let result: Result<Pipeline.Result, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    return .success(try Pipeline.process(output, keepAudio: keep) { step in
                        Task { @MainActor in self.phase = .processing(step) }
                    })
                } catch {
                    return .failure(error)
                }
            }.value

            switch result {
            case .success(let r):
                lastNoteURL = r.noteURL
                phase = .idle
                notify(
                    title: r.summaryFailed ? "Note saved (summary skipped)" : "Meeting note ready",
                    body: r.noteURL.lastPathComponent)
            case .failure(let error):
                // Audio stays on disk on failure — the recording is not lost.
                phase = .failed(error.localizedDescription)
                notify(title: "Minutes failed", body: error.localizedDescription)
            }
        }
    }

    // MARK: helpers

    private func startTicker() {
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let s = Int(self.recorder.elapsed)
                self.elapsedText = String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
        elapsedText = ""
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

// MARK: - menu

struct MenuContent: View {
    @ObservedObject var state: AppState

    var body: some View {
        switch state.phase {
        case .idle:
            Button("Start Recording") { state.toggle() }
        case .recording:
            Text("Recording \(state.elapsedText)")
            Button("Stop & Make Notes") { state.toggle() }
        case .processing(let step):
            Text(step)
        case .failed(let msg):
            Text(msg).lineLimit(4)
            Button("Start Recording") { state.toggle() }
        }

        Divider()

        Button("Open Last Note") {
            if let url = state.lastNoteURL { NSWorkspace.shared.open(url) }
        }
        .disabled(state.lastNoteURL == nil)

        Button("Open Notes Folder") {
            try? FileManager.default.createDirectory(
                at: Pipeline.notesRoot, withIntermediateDirectories: true)
            NSWorkspace.shared.open(Pipeline.notesRoot)
        }

        Divider()

        Toggle("Keep Audio Files", isOn: $state.keepAudio)

        Divider()

        Button("Quit Minutes") { NSApp.terminate(nil) }
    }
}
