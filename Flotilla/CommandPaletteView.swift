import SwiftUI
import SessionKit
import DesignSystem

struct CommandPaletteView: View {
    @Environment(\.dismiss) private var dismiss

    let projects: [Project]
    let sessions: [Session]
    let perform: (WorkspaceCommand) -> Void
    let openProject: (UUID) -> Void
    let openSession: (UUID) -> Void

    @State private var query = ""

    private var matchingCommands: [WorkspaceCommand] {
        guard !query.isEmpty else { return WorkspaceCommand.allCases }
        return WorkspaceCommand.allCases.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.subtitle.localizedCaseInsensitiveContains(query)
        }
    }

    private var matchingSessions: [Session] {
        guard !query.isEmpty else { return sessions }
        return sessions.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.goal.localizedCaseInsensitiveContains(query)
                || $0.agent.displayName.localizedCaseInsensitiveContains(query)
        }
    }

    private var matchingProjects: [Project] {
        guard !query.isEmpty else { return projects }
        return projects.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.rootPath.path.localizedCaseInsensitiveContains(query)
        }
    }

    private var navigationCommands: [WorkspaceCommand] {
        matchingCommands.filter { [.showHome, .showProjects, .showSessions, .showGrid, .showSettings].contains($0) }
    }

    private var actionCommands: [WorkspaceCommand] {
        matchingCommands.filter { !navigationCommands.contains($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search commands and sessions", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .accessibilityIdentifier("CommandPalette.Search")
                Text("esc")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    PaletteSectionTitle("Navigation")
                    ForEach(navigationCommands) { command in
                        PaletteRow(
                            title: command.title,
                            subtitle: command.subtitle,
                            systemImage: command.systemImage
                        ) {
                            dismiss()
                            perform(command)
                        }
                    }

                    if !actionCommands.isEmpty {
                        PaletteSectionTitle("Actions")
                        ForEach(actionCommands) { command in
                            PaletteRow(
                                title: command.title,
                                subtitle: command.subtitle,
                                systemImage: command.systemImage
                            ) {
                                dismiss()
                                perform(command)
                            }
                        }
                    }

                    if !matchingProjects.isEmpty {
                        PaletteSectionTitle("Projects")
                        ForEach(matchingProjects) { project in
                            PaletteRow(
                                title: project.name,
                                subtitle: project.rootPath.path,
                                systemImage: "folder"
                            ) {
                                dismiss()
                                openProject(project.id)
                            }
                        }
                    }

                    if !matchingSessions.isEmpty {
                        PaletteSectionTitle("Active sessions")
                        ForEach(matchingSessions) { session in
                            PaletteRow(
                                title: session.title,
                                subtitle: "\(session.agent.displayName) · \(session.goal)",
                                systemImage: "terminal"
                            ) {
                                dismiss()
                                openSession(session.id)
                            }
                        }
                    }

                    if matchingCommands.isEmpty && matchingProjects.isEmpty && matchingSessions.isEmpty {
                        ContentUnavailableView.search(text: query)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 36)
                    }
                }
                .padding(10)
            }
        }
        .frame(width: 680, height: 560)
        .background(FlotillaPalette.panel)
    }
}

private struct PaletteSectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.7)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 9)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }
}

private struct PaletteRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                Image(systemName: "return")
                    .font(.caption)
                    .foregroundStyle(.quaternary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("CommandPalette.Row-\(title)")
    }
}

struct KeyboardShortcutsView: View {
    @Environment(\.dismiss) private var dismiss

    private let groups: [(String, [(String, String)])] = [
        ("Navigation", [
            ("New session", "⌘N"),
            ("Command palette", "⌘K"),
            ("Sessions", "⌘2"),
            ("Projects", "⌘1")
        ]),
        ("Session", [
            ("Terminal", "⌘⇧T"),
            ("Review changes", "⌘⇧G"),
            ("Files", "⌘⇧F"),
            ("Grid", "⌘⇧M")
        ]),
        ("Application", [
            ("Settings", "⌘,"),
            ("Toggle sidebar", "⌃⌘S"),
            ("Close sheet", "Esc")
        ])
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keyboard Shortcuts")
                        .font(.title2.weight(.semibold))
                    Text("Move through Flotilla without leaving the keyboard.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)

            Divider()

            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    ForEach(groups, id: \.0) { group in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(group.0)
                                .font(.headline)
                                .padding(.bottom, 8)
                            ForEach(group.1, id: \.0) { shortcut in
                                HStack {
                                    Text(shortcut.0)
                                    Spacer()
                                    Text(shortcut.1)
                                        .font(.callout.monospaced())
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                                }
                                .padding(.vertical, 7)
                                if shortcut.0 != group.1.last?.0 { Divider() }
                            }
                        }
                        .padding(16)
                        .background(FlotillaPalette.panel, in: RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(FlotillaPalette.subtleStroke)
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 760, height: 500)
        .background(FlotillaPalette.canvas)
        .accessibilityIdentifier("KeyboardShortcuts")
    }
}

struct RestoreSessionsView: View {
    @Environment(\.dismiss) private var dismiss

    let sessions: [Session]
    let restore: (UUID) -> Void

    @State private var selectedIDs: Set<UUID> = []

    private var stoppedSessions: [Session] {
        sessions.filter { $0.status == .finished || $0.status == .crashed }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Restore Sessions")
                        .font(.title2.weight(.semibold))
                    Text("Restart selected agents in their existing working directories.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            if stoppedSessions.isEmpty {
                ContentUnavailableView(
                    "Nothing to Restore",
                    systemImage: "checkmark.circle",
                    description: Text("Finished and crashed sessions will appear here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(stoppedSessions, selection: $selectedIDs) { session in
                    HStack(spacing: 10) {
                        Image(systemName: selectedIDs.contains(session.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selectedIDs.contains(session.id) ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.title)
                            Text("\(session.agent.displayName) · \(session.workingDirectory.path)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .tag(session.id)
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Select All") {
                    selectedIDs = Set(stoppedSessions.map(\.id))
                }
                .disabled(stoppedSessions.isEmpty)
                Button("Restore \(selectedIDs.count)") {
                    for id in selectedIDs { restore(id) }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedIDs.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 620, height: 480)
        .accessibilityIdentifier("RestoreSessions")
    }
}
