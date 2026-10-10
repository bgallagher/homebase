import Foundation
import RackoonCore

/// One streamed action (a stack or container action, an apt install): its output so far, its state, and the size of
/// the terminal that shows it. Shared by the Docker and Updates screens.
@MainActor @Observable
final class ActionOutput: Identifiable {
    enum Phase: Equatable { case starting, running, succeeded, failed(Int32?), cancelled }

    nonisolated let id = UUID()
    /// What the run belongs to: a compose project name, "Standalone", or "updates". Screens show only their own.
    let scope: String
    let title: String
    private(set) var phase: Phase = .starting
    /// Everything received, in chunks. The terminal view feeds only the chunks it has not shown yet.
    private(set) var chunks: [String] = []
    private(set) var cols = 100
    private(set) var rows = 24
    @ObservationIgnored private var sized = false
    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored private var sawFinish = false
    @ObservationIgnored private var exitCode: Int32?

    init(scope: String, title: String) {
        self.scope = scope
        self.title = title
    }

    var isRunning: Bool { phase == .starting || phase == .running }

    /// Starts a run. `work` is handed the terminal's real size (so the remote pty matches it) and a sink for events,
    /// and should return when the command has finished. Events cross to the main actor through a stream, which keeps
    /// them in order. `completion` runs on the main actor once the output is complete.
    static func launch(scope: String, title: String, intro: String? = nil,
                       work: @escaping @Sendable (_ cols: Int, _ rows: Int, _ onEvent: @escaping @Sendable (ActionStreamEvent) -> Void) async -> Void,
                       completion: @escaping @MainActor () -> Void) -> ActionOutput {
        let run = ActionOutput(scope: scope, title: title)
        if let intro { run.apply(.output(intro)) }
        let (events, continuation) = AsyncStream<ActionStreamEvent>.makeStream()
        let consumer = Task { @MainActor in
            for await event in events { run.apply(event) }
        }
        run.task = Task { @MainActor in
            await run.waitForTerminalSize()
            await work(run.cols, run.rows, { continuation.yield($0) })
            continuation.finish()
            await consumer.value
            run.finish(cancelled: Task.isCancelled)
            completion()
        }
        return run
    }

    /// The terminal view tells us its real size, so the remote pty (and compose's cursor-moving progress) matches it.
    func reportSize(cols: Int, rows: Int) {
        guard cols > 10, rows > 2 else { return }
        self.cols = cols
        self.rows = rows
        sized = true
    }

    /// The Output tab has to be on screen before the size is known. Wait for it briefly, then use what we have.
    func waitForTerminalSize() async {
        for _ in 0..<30 where !sized { try? await Task.sleep(for: .milliseconds(50)) }
        if sized { try? await Task.sleep(for: .milliseconds(250)) }   // the first report can be a default size, before layout settles
        phase = .running
    }

    func apply(_ event: ActionStreamEvent) {
        switch event {
        case .output(let text): chunks.append(text)
        case .finished(let code): sawFinish = true; exitCode = code
        }
    }

    func finish(cancelled: Bool) {
        if cancelled { phase = .cancelled }
        else if sawFinish, exitCode == 0 { phase = .succeeded }
        else { phase = .failed(exitCode) }
    }
}
