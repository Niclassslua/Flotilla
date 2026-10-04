import SwiftUI
import SessionKit
import GitKit
import DesignSystem

/// The launcher's issue control: "From Issue…" until an issue is linked, then
/// a chip naming it, with a link out and a way to unlink.
struct LauncherIssueControl: View {
    @Bindable var draft: SessionDraft
    let ghService: (any GhServiceProtocol)?
    @Binding var isPickerPresented: Bool
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let issue = draft.linkedIssue {
            linkedChip(issue)
        } else {
            Button {
                isPickerPresented = true
            } label: {
                Label("From Issue…", systemImage: "number")
                    .font(FlotillaTypography.caption.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(unavailableReason == nil ? FlotillaColors.textSecondary : FlotillaColors.textTertiary)
            .disabled(unavailableReason != nil)
            .help(unavailableReason ?? "Start from one of this project's open GitHub issues")
            .popover(isPresented: $isPickerPresented, arrowEdge: .bottom) {
                if let ghService, let repository = draft.issueRepository {
                    IssuePickerView(ghService: ghService, repository: repository) { issue in
                        draft.apply(issue: issue)
                        isPickerPresented = false
                    }
                }
            }
            .accessibilityIdentifier("CreateSession.FromIssue")
        }
    }

    private var unavailableReason: String? {
        if ghService == nil { return "Install the GitHub CLI (gh) to start from an issue." }
        if draft.issueRepository == nil { return "Choose a project to list its issues." }
        return nil
    }

    private func linkedChip(_ issue: IssueLink) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "number")
                .foregroundStyle(FlotillaColors.accent)
            Text("\(issue.number)")
                .font(FlotillaTypography.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(FlotillaColors.textPrimary)
            Text(issue.title)
                .font(FlotillaTypography.caption)
                .foregroundStyle(FlotillaColors.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Button {
                openURL(issue.url)
            } label: {
                Image(systemName: "arrow.up.right")
            }
            .buttonStyle(.plain)
            .foregroundStyle(FlotillaColors.textTertiary)
            .help("Open the issue on GitHub")
            Button {
                draft.clearIssue()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(FlotillaColors.textTertiary)
            .help("Unlink the issue and restore your goal")
            .accessibilityLabel("Unlink issue")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(FlotillaColors.accent.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("CreateSession.LinkedIssue")
    }
}

/// Searches a repository's open issues through `gh` and returns the chosen
/// one with its body loaded. Arrow keys move, Return picks.
struct IssuePickerView: View {
    let ghService: any GhServiceProtocol
    let repository: URL
    let onPick: (GhIssue) -> Void

    @State private var query = ""
    @State private var issues: [GhIssue] = []
    @State private var highlighted: Int?
    @State private var isLoading = true
    @State private var loadingNumber: Int?
    @State private var errorMessage: String?
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search open issues", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($isSearchFocused)
                .onKeyPress(.downArrow) { move(1) }
                .onKeyPress(.upArrow) { move(-1) }
                .onKeyPress(.return) {
                    if let highlighted, issues.indices.contains(highlighted) { pick(issues[highlighted]) }
                    return .handled
                }
                .padding(FlotillaSpacing.medium)
                .accessibilityIdentifier("IssuePicker.Search")
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 440, height: 360)
        .onAppear { isSearchFocused = true }
        .task(id: query) { await search() }
    }

    @ViewBuilder
    private var content: some View {
        if let errorMessage {
            ContentUnavailableView("Couldn’t Load Issues", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
        } else if isLoading && issues.isEmpty {
            ProgressView().controlSize(.small)
        } else if issues.isEmpty {
            ContentUnavailableView(
                query.isEmpty ? "No Open Issues" : "No Matches",
                systemImage: "number",
                description: Text(query.isEmpty ? "This repository has no open issues." : "No open issue matches “\(query)”.")
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(issues.enumerated()), id: \.element.id) { index, issue in
                            row(issue, isHighlighted: index == highlighted)
                                .id(issue.id)
                                .onTapGesture { pick(issue) }
                                .onHover { if $0 { highlighted = index } }
                        }
                    }
                }
                .onChange(of: highlighted) { _, index in
                    if let index, issues.indices.contains(index) { proxy.scrollTo(issues[index].id) }
                }
            }
            .accessibilityIdentifier("IssuePicker.List")
        }
    }

    private func row(_ issue: GhIssue, isHighlighted: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: FlotillaSpacing.small) {
            Text("#\(issue.number)")
                .font(FlotillaTypography.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(FlotillaColors.textTertiary)
                .frame(minWidth: 40, alignment: .trailing)
            VStack(alignment: .leading, spacing: 3) {
                Text(issue.title)
                    .font(FlotillaTypography.callout)
                    .foregroundStyle(FlotillaColors.textPrimary)
                    .lineLimit(2)
                if !issue.labels.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(issue.labels.prefix(3), id: \.self) { label in
                            Text(label)
                                .font(FlotillaTypography.caption3.weight(.medium))
                                .foregroundStyle(FlotillaColors.textSecondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(FlotillaColors.textTertiary.opacity(0.15), in: Capsule())
                        }
                    }
                }
            }
            Spacer(minLength: 4)
            if loadingNumber == issue.number {
                ProgressView().controlSize(.mini)
            } else if let updated = issue.updatedAt {
                Text(updated, format: .relative(presentation: .named))
                    .font(FlotillaTypography.caption2)
                    .foregroundStyle(FlotillaColors.textTertiary)
            }
        }
        .padding(.horizontal, FlotillaSpacing.medium)
        .padding(.vertical, 7)
        .background(isHighlighted ? FlotillaColors.accent.opacity(0.14) : .clear)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("IssuePicker.Row-\(issue.number)")
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard !issues.isEmpty else { return .handled }
        let next = (highlighted ?? (delta > 0 ? -1 : issues.count)) + delta
        highlighted = min(max(next, 0), issues.count - 1)
        return .handled
    }

    private func search() async {
        // Debounce typing; the first load runs immediately.
        if !query.isEmpty {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let found = try await ghService.openIssues(search: query, limit: 30, at: repository)
            guard !Task.isCancelled else { return }
            issues = found
            highlighted = found.isEmpty ? nil : 0
            errorMessage = nil
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// The list omits bodies to stay small, so the chosen issue is read once
    /// more, in full, before it fills the goal.
    private func pick(_ issue: GhIssue) {
        guard loadingNumber == nil else { return }
        loadingNumber = issue.number
        Task {
            defer { loadingNumber = nil }
            do {
                onPick(try await ghService.issue(number: issue.number, at: repository))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
