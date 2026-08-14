import SwiftUI
import SessionKit
import DesignSystem

/// Maps SessionKit's domain status into presentation — kept in the App
/// layer so DesignSystem and SessionKit stay decoupled from each other.
enum StatusPresentation {
    static func color(for status: SessionStatus) -> Color {
        switch status {
        case .working: return FlotillaPalette.ocean
        case .idle: return .secondary
        case .waitingForInput: return .orange
        case .finished: return .blue
        case .crashed: return .red
        }
    }

    static func label(for status: SessionStatus) -> String {
        switch status {
        case .working: return "Working"
        case .idle: return "Idle"
        case .waitingForInput: return "Waiting for Input"
        case .finished: return "Finished"
        case .crashed: return "Crashed"
        }
    }
}
