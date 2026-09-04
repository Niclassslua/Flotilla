import SwiftUI
import SessionKit
import DesignSystem

struct CommandPaletteView: View {
    let projects: [Project]
    let sessions: [Session]
    let perform: (WorkspaceCommand) -> Void
    let openProject: (UUID) -> Void
    let openSession: (UUID) -> Void
    let onDismiss: () -> Void

    @State private var query = ""
    @FocusState private var isFocused: Bool
    @State private var selectedIndex: Int = 0

    private var allMatchingCommands: [WorkspaceCommand] {
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

    private var totalCount: Int {
        allMatchingCommands.count + matchingProjects.count + matchingSessions.count
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search commands and sessions", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($isFocused)
                    // Belt and suspenders alongside the `.onKeyPress` below and
                    // `EscapeKeyCatcher` at the presentation layer: a focused
                    // NSTextField can consume Escape internally via its own
                    // `cancelOperation:` handling before either ever sees it.
                    .onKeyPress(.escape) {
                        onDismiss()
                        return .handled
                    }
                    .accessibilityIdentifier("CommandPalette.Search")
                Button {
                    onDismiss()
                } label: {
                    Text("esc")
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .onKeyPress { press in
                if press.key == .return {
                    if selectedIndex < allMatchingCommands.count {
                        let command = allMatchingCommands[selectedIndex]
                        onDismiss()
                        perform(command)
                    } else if selectedIndex < allMatchingCommands.count + matchingProjects.count {
                        let idx = selectedIndex - allMatchingCommands.count
                        let project = matchingProjects[idx]
                        onDismiss()
                        openProject(project.id)
                    } else if selectedIndex < totalCount {
                        let idx = selectedIndex - allMatchingCommands.count - matchingProjects.count
                        let session = matchingSessions[idx]
                        onDismiss()
                        openSession(session.id)
                    }
                    return .handled
                } else if press.key == .escape {
                    onDismiss()
                    return .handled
                } else if press.key == .upArrow {
                    withAnimation { selectedIndex = max(0, selectedIndex - 1) }
                    return .handled
                } else if press.key == .downArrow {
                    withAnimation { selectedIndex = min(totalCount - 1, selectedIndex + 1) }
                    return .handled
                }
                return .ignored
            }

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    PaletteSectionTitle("Navigation")
                    ForEach(Array(allMatchingCommands.enumerated()), id: \.offset) { idx, command in
                        PaletteRow(
                            title: command.title,
                            subtitle: command.subtitle,
                            systemImage: command.systemImage
                        ) {
                            onDismiss()
                            perform(command)
                        }
                        .background(selectedIndex == idx ? Color.accentColor.opacity(0.2) : .clear)
                    }

                    if !matchingProjects.isEmpty {
                        PaletteSectionTitle("Projects")
                        ForEach(Array(matchingProjects.enumerated()), id: \.offset) { idx, project in
                            PaletteRow(
                                title: project.name,
                                subtitle: project.rootPath.path,
                                systemImage: "folder"
                            ) {
                                onDismiss()
                                openProject(project.id)
                            }
                            .background(selectedIndex == allMatchingCommands.count + idx ? Color.accentColor.opacity(0.2) : .clear)
                        }
                    }

                    if !matchingSessions.isEmpty {
                        PaletteSectionTitle("Active sessions")
                        ForEach(Array(matchingSessions.enumerated()), id: \.element.id) { idx, session in
                            PaletteRow(
                                title: session.title,
                                subtitle: "\(session.agent.displayName) · \(session.goal)",
                                systemImage: "terminal"
                            ) {
                                onDismiss()
                                openSession(session.id)
                            }
                            .background(selectedIndex == allMatchingCommands.count + matchingProjects.count + idx ? Color.accentColor.opacity(0.2) : .clear)
                        }
                    }

                    if allMatchingCommands.isEmpty && matchingProjects.isEmpty && matchingSessions.isEmpty {
                        ContentUnavailableView.search(text: query)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 36)
                    }
                }
                .padding(10)
            }
        }
        // A real `.sheet` used to size its own window to this frame's ideal
        // values exactly; presented as an in-window overlay instead (so it can
        // be dismissed by clicking outside — a genuine sheet never supports
        // that), a proposed size that's just a floor lets it expand to fill
        // the whole window. `maxWidth`/`maxHeight` pin it back to the size it
        // was always meant to be.
        .frame(minWidth: 540, idealWidth: 620, maxWidth: 620, minHeight: 460, idealHeight: 500, maxHeight: 500)
        .background(FlotillaColors.surface)
        // A real `.sheet` window got rounded corners and a shadow from AppKit
        // for free; as a floating overlay, this view has to draw its own.
        .clipShape(RoundedRectangle(cornerRadius: FlotillaRadius.modal, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FlotillaRadius.modal, style: .continuous)
                .strokeBorder(FlotillaColors.separator, lineWidth: FlotillaBorderWidth.hairline)
        }
        .flotillaShadow(.level3)
        // Without `.contain`, SwiftUI exposes this identifier on several
        // descendants independently (the search icon, the field, the esc
        // label, the card itself) rather than scoping it to one container —
        // ambiguous for both real accessibility tools and UI tests querying
        // by identifier.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("CommandPaletteView")
        .onAppear { isFocused = true; selectedIndex = 0 }
        .onDisappear { isFocused = false }
        .onExitCommand { onDismiss() }
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
                if systemImage == "arrow.triangle.branch" {
                    GitIcon(size: 16)
                        .foregroundStyle(.tint)
                        .frame(width: 24)
                } else {
                    Image(systemName: systemImage)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.tint)
                        .frame(width: 24)
                }
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
    @Environment(\.workspaceNavigator) private var navigator

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
            .overlay {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
            }

            Divider()

            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    ForEach(shortcutGroups, id: \.0) { group in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(group.0)
                                .font(.headline)
                                .padding(.bottom, 8)
                            ForEach(group.1, id: \.0) { shortcut in
                                HStack {
                                    Text(shortcut.0)
                                        .foregroundStyle(.primary)
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
                        .background(FlotillaColors.surface, in: RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(FlotillaColors.separator)
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 760, height: 500)
        .background(FlotillaColors.canvas)
        .accessibilityIdentifier("KeyboardShortcuts")
    }

    private var shortcutGroups: [(String, [(String, String)])] {
        [
            ("Navigation", [
                ("New session", "⌘N"),
                ("Command palette", "⌘K"),
                ("Overview", "⌘1"),
                ("Sessions", "⌘2"),
                ("Projects", "⌘3"),
            ]),
            ("Layout", [
                ("Focus", "⌘⌃1"),
                ("Grid", "⌘⌃2"),
                ("Board", "⌘⌃3"),
            ]),
            ("Session Lens", [
                ("Terminal", "⌘⇧T"),
                ("Files", "⌘⇧F"),
                ("Instructions", "⌘⇧I"),
                ("Changes", "⌘⇧G"),
            ]),
            ("Session", [
                ("Previous session", "⌘⌥↑"),
                ("Next session", "⌘⌥↓"),
                ("Restart session", "⌘R"),
                ("Delete session", "⌘⌫"),
            ]),
            ("Application", [
                ("Settings", "⌘,"),
                ("Toggle sidebar", "⌃⌘S"),
                ("Close sheet", "Esc"),
            ]),
        ]
    }
}

struct RestoreSessionsView: View {
    @Environment(\.dismiss) private var dismiss

    let sessions: [Session]
    let restore: (UUID) -> Void

    @State private var selectedIDs: Set<UUID> = []

    private var stoppedSessions: [Session] {
        // Only a crashed session is unambiguously stopped and needing a
        // manual restart. A cleanly-exited session now reads as
        // `readyForReview` and is restarted automatically on next launch.
        sessions.filter { $0.status == .crashed }
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
                .tint(FlotillaColors.accent)
                .disabled(selectedIDs.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 620, height: 480)
        .accessibilityIdentifier("RestoreSessions")
    }
}