import Foundation
import SessionKit
import ProcessKit

/// The slice of `SessionProcessManager` that relaunching a session needs.
///
/// It exists so `HandoffService` can be tested without standing up a real
/// process manager, tmux probe and PTY factory to assert something as simple
/// as "the source was killed before the destination started". `SessionProcessManager`
/// is otherwise the one collaborator in the app layer with no protocol seam,
/// and this is deliberately the narrowest one that does the job rather than an
/// interface over the whole class.
@MainActor
protocol SessionProcessStarting: AnyObject {
    /// Launches `session` under the agent it currently names.
    func startSession(_ session: Session, deliverGoal: Bool) throws

    /// Stops the running process for this session.
    func terminate(sessionID: UUID)

    /// Destroys the server-side tmux session.
    ///
    /// Both this and `terminate(sessionID:)` are required before a relaunch
    /// that must run a *different* binary: while a tmux session survives,
    /// `new-session -A` reattaches to it and never runs the command after
    /// `--`, so the relaunch silently keeps the old agent alive.
    func killServerSideSession(sessionID: UUID)
}

extension SessionProcessManager: SessionProcessStarting {
    func startSession(_ session: Session, deliverGoal: Bool) throws {
        try start(session: session, deliverGoal: deliverGoal)
    }
}
