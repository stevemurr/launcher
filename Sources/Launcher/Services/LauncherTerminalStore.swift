import Combine
import Foundation

/// Lightweight launcher-facing state for one retained native terminal.
///
/// The Ghostty view, controller, and PTY remain owned by the corresponding
/// ``LauncherTerminalSession`` in ``LauncherTerminalStore``. Keeping those
/// resources out of this value makes summaries safe to publish and render in
/// launcher results.
struct LauncherTerminalSummary: Identifiable, Equatable {
    let id: ShellSessionID
    let displayName: String
    var phase: LauncherTerminalPhase
    var workingDirectory: String
    var isPinned = false
}

/// Owns every persistent native terminal session in Launcher.
///
/// Selection is intentionally separate from surface visibility. Selecting a
/// session hides the previous surface, but the view that mounts the selection
/// decides when the replacement is actually visible and ready for focus.
@MainActor
final class LauncherTerminalStore: ObservableObject {
    @Published private(set) var summaries: [LauncherTerminalSummary] = []
    @Published private(set) var selectedSessionID: ShellSessionID?

    private var sessions: [ShellSessionID: LauncherTerminalSession] = [:]
    private var observations: [ShellSessionID: AnyCancellable] = [:]
    private var nextSessionNumber = 1
    private let makeSession: @MainActor () -> LauncherTerminalSession

    init(
        makeSession: @escaping @MainActor () -> LauncherTerminalSession = {
            LauncherTerminalSession()
        }
    ) {
        self.makeSession = makeSession
    }

    var selectedSession: LauncherTerminalSession? {
        guard let selectedSessionID else { return nil }
        return sessions[selectedSessionID]
    }

    func session(for id: ShellSessionID) -> LauncherTerminalSession? {
        sessions[id]
    }

    @discardableResult
    func createSession(select: Bool = true) -> LauncherTerminalSummary {
        let id = ShellSessionID()
        let displayName = "Shell \(nextSessionNumber)"
        nextSessionNumber += 1

        let session = makeSession()
        let summary = LauncherTerminalSummary(
            id: id,
            displayName: displayName,
            phase: session.phase,
            workingDirectory: session.workingDirectory
        )
        sessions[id] = session
        summaries.append(summary)
        observe(session, id: id)

        if select {
            selectSession(id)
        }
        return summary
    }

    /// Returns the retained native session for an externally supplied identity,
    /// creating it exactly once. Production creation should use
    /// ``createSession(select:)`` so this store remains the authority for IDs and
    /// display names; this bridge remains useful for focused compatibility tests.
    @discardableResult
    func ensureSession(
        id: ShellSessionID,
        displayName: String,
        select: Bool = true
    ) -> LauncherTerminalSession {
        if let session = sessions[id] {
            if select { selectSession(id) }
            return session
        }

        let session = makeSession()
        let summary = LauncherTerminalSummary(
            id: id,
            displayName: displayName,
            phase: session.phase,
            workingDirectory: session.workingDirectory
        )

        sessions[id] = session
        summaries.append(summary)
        observe(session, id: id)
        reserveGeneratedName(after: displayName)

        if select {
            selectSession(id)
        }
        return session
    }

    @discardableResult
    func selectSession(_ id: ShellSessionID) -> Bool {
        guard sessions[id] != nil,
              summaries.first(where: { $0.id == id })?.isPinned != true else { return false }
        guard selectedSessionID != id else { return true }

        selectedSession?.setVisible(false)
        selectedSessionID = id
        return true
    }

    func clearSelection() {
        selectedSession?.setVisible(false)
        selectedSessionID = nil
    }

    /// A pinned surface belongs to its own window and must never be selected
    /// (and therefore hidden or remounted) by the launcher panel.
    @discardableResult
    func setPinned(_ pinned: Bool, for id: ShellSessionID) -> Bool {
        guard let index = summaries.firstIndex(where: { $0.id == id }) else { return false }
        if pinned, selectedSessionID == id { clearSelection() }
        summaries[index].isPinned = pinned
        return true
    }

    @discardableResult
    func closeSession(_ id: ShellSessionID) -> Bool {
        guard let session = sessions[id],
              let index = summaries.firstIndex(where: { $0.id == id }) else {
            return false
        }

        session.setVisible(false)
        if selectedSessionID == id {
            selectedSessionID = nil
        }
        observations.removeValue(forKey: id)?.cancel()
        sessions.removeValue(forKey: id)
        session.terminate()
        summaries.remove(at: index)
        return true
    }

    func terminateAll() {
        selectedSessionID = nil

        let retainedSessions = Array(sessions.values)
        observations.values.forEach { $0.cancel() }
        observations.removeAll()
        sessions.removeAll()
        summaries.removeAll()

        for session in retainedSessions {
            session.setVisible(false)
            session.terminate()
        }
    }

    private func observe(_ session: LauncherTerminalSession, id: ShellSessionID) {
        observations[id] = session.$phase
            .combineLatest(session.$workingDirectory)
            .sink { [weak self, weak session] phase, workingDirectory in
                guard let self, let session,
                      self.sessions[id] === session,
                      let index = self.summaries.firstIndex(where: { $0.id == id }) else {
                    return
                }

                var summary = self.summaries[index]
                guard summary.phase != phase
                    || summary.workingDirectory != workingDirectory else {
                    return
                }
                summary.phase = phase
                summary.workingDirectory = workingDirectory
                self.summaries[index] = summary
            }
    }

    private func reserveGeneratedName(after displayName: String) {
        let prefix = "Shell "
        guard displayName.hasPrefix(prefix),
              let number = Int(displayName.dropFirst(prefix.count)) else {
            return
        }
        nextSessionNumber = max(nextSessionNumber, number + 1)
    }
}
