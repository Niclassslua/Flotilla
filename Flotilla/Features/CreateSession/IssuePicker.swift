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

/// A project's open issues, fetched when the launcher opens so the picker
/// shows them without waiting on GitHub.
@MainActor @Observable
final class IssueFeed {
    /// The Issues tab's page size; `gh` returns most recently updated first.
    // ponytail: search only covers these; page or fall back to `gh --search` if backlogs outgrow it.
    static let limit = 100

    private(set) var issues: [GhIssue] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private var loadedRepository: URL?

    /// Local search: `#12`/`12` match by number prefix, anything else by title or label.
    func issues(matching query: String) -> [GhIssue] {
        let query = query.trimmingCharacters(in: CharacterSet(charactersIn: "#").union(.whitespaces))
        guard !query.isEmpty else { return issues }
        return issues.filter { issue in
            String(issue.number).hasPrefix(query)
                || issue.title.localizedStandardContains(query)
                || issue.labels.contains { $0.localizedStandardContains(query) }
        }
    }

    func load(ghService: any GhServiceProtocol, repository: URL) async {
        if loadedRepository != repository {
            issues = []
            loadedRepository = repository
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let found = try await ghService.openIssues(search: "", limit: Self.limit, at: repository)
            guard !Task.isCancelled else { return }
            issues = found
            errorMessage = nil
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }
}

/// Shows a repository's open issues from `feed`, filtered locally as you
/// type, and returns the chosen one.
/// The list sits beside a preview of the highlighted issue; arrow keys move,
/// Return picks.
struct IssuePickerView: View {
    let feed: IssueFeed
    let onPick: (GhIssue) -> Void

    @State private var query = ""
    @State private var highlighted: Int?
    @FocusState private var isSearchFocused: Bool
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                searchField
                list
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: 310)
            .background(FlotillaColors.textTertiary.opacity(0.04))
            Divider()
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 620, height: 380)
        .onAppear { isSearchFocused = true }
        .onChange(of: issues.map(\.number), initial: true) { _, numbers in
            highlighted = numbers.isEmpty ? nil : 0
        }
    }

    private var issues: [GhIssue] { feed.issues(matching: query) }
    private var isLoading: Bool { feed.isLoading }
    private var errorMessage: String? { feed.errorMessage }

    private var highlightedIssue: GhIssue? {
        highlighted.flatMap { issues.indices.contains($0) ? issues[$0] : nil }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(FlotillaColors.textTertiary)
            TextField("Search open issues", text: $query)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .onKeyPress(.downArrow) { move(1) }
                .onKeyPress(.upArrow) { move(-1) }
                .onKeyPress(.return) {
                    if let highlightedIssue { onPick(highlightedIssue) }
                    return .handled
                }
                .accessibilityIdentifier("IssuePicker.Search")
            if isLoading && !issues.isEmpty {
                ProgressView().controlSize(.mini)
            }
        }
        .font(FlotillaTypography.callout)
        .padding(.horizontal, FlotillaSpacing.small)
        .padding(.vertical, 6)
        .background(FlotillaColors.textTertiary.opacity(0.10), in: RoundedRectangle(cornerRadius: FlotillaRadius.control + 1, style: .continuous))
        .padding(10)
    }

    @ViewBuilder
    private var list: some View {
        if let errorMessage {
            ContentUnavailableView("Couldn’t Load Issues", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
        } else if isLoading && issues.isEmpty {
            listSkeleton
        } else if issues.isEmpty {
            ContentUnavailableView(
                query.isEmpty ? "No Open Issues" : "No Matches",
                systemImage: "number",
                description: Text(query.isEmpty ? "This repository has no open issues." : "No open issue matches “\(query)”.")
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(issues.enumerated()), id: \.element.id) { index, issue in
                            row(issue, isHighlighted: index == highlighted)
                                .id(issue.id)
                                .onTapGesture { onPick(issue) }
                                .onHover { if $0 { highlighted = index } }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                }
                .onChange(of: highlighted) { _, index in
                    if let index, issues.indices.contains(index) { proxy.scrollTo(issues[index].id) }
                }
            }
            .accessibilityIdentifier("IssuePicker.List")
        }
    }

    private func row(_ issue: GhIssue, isHighlighted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(issue.title)
                .font(FlotillaTypography.callout)
                .foregroundStyle(isHighlighted ? FlotillaColors.textPrimary : FlotillaColors.textSecondary)
                .lineLimit(1)
            HStack(spacing: 4) {
                Text("#\(issue.number)")
                    .font(FlotillaTypography.caption3.monospacedDigit())
                    .foregroundStyle(FlotillaColors.textTertiary)
                ForEach(issue.labels.prefix(3), id: \.self) { label in
                    IssueLabelTag(name: label, hex: issue.labelColors[label])
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, FlotillaSpacing.small)
        .padding(.vertical, 6)
        .background(isHighlighted ? FlotillaColors.accent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("IssuePicker.Row-\(issue.number)")
    }

    @ViewBuilder
    private var preview: some View {
        if let issue = highlightedIssue {
            VStack(alignment: .leading, spacing: FlotillaSpacing.medium) {
                HStack(spacing: 6) {
                    Image(systemName: "smallcircle.filled.circle")
                    Text("Open").fontWeight(.semibold)
                    Text("·  #\(issue.number)")
                        .monospacedDigit()
                        .foregroundStyle(FlotillaColors.textTertiary)
                }
                .font(FlotillaTypography.caption)
                .foregroundStyle(FlotillaColors.success)
                Text(issue.title)
                    .font(FlotillaTypography.headline)
                    .foregroundStyle(FlotillaColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if !issue.labels.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(issue.labels, id: \.self) { label in
                            IssueLabelTag(name: label, hex: issue.labelColors[label], size: .large)
                        }
                    }
                }
                if let updated = issue.updatedAt {
                    Label {
                        Text("Updated \(updated, format: .relative(presentation: .named))")
                    } icon: {
                        Image(systemName: "clock")
                    }
                    .font(FlotillaTypography.caption)
                    .foregroundStyle(FlotillaColors.textTertiary)
                }
                Text("The issue’s title and body become the session goal, and the branch is named after it.")
                    .font(FlotillaTypography.caption)
                    .foregroundStyle(FlotillaColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                HStack {
                    Button("Open on GitHub", systemImage: "arrow.up.right") { openURL(issue.url) }
                        .buttonStyle(.borderless)
                    Spacer()
                    Button("Start from #\(issue.number)") { onPick(issue) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("IssuePicker.Start")
                }
                .font(FlotillaTypography.caption)
            }
            .padding(FlotillaSpacing.large)
        } else if isLoading && errorMessage == nil {
            previewSkeleton
        } else {
            Color.clear
        }
    }

    // MARK: - Skeletons
    // Mirror `row` and `preview` so nothing jumps when the issues land.

    private var listSkeleton: some View {
        HomeSkeletonPulse {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(0..<6, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 4) {
                        HomeSkeletonBlock(width: 270 * HomeSkeletonRatio.title(index), height: 11)
                            .padding(.vertical, 2)
                        HStack(spacing: 4) {
                            HomeSkeletonBlock(width: 26, height: 8)
                            HomeSkeletonBlock(width: 30 + 40 * HomeSkeletonRatio.subtitle(index), height: 13, radius: 6.5)
                            if index % 2 == 0 { HomeSkeletonBlock(width: 38, height: 13, radius: 6.5) }
                        }
                    }
                    .padding(.horizontal, FlotillaSpacing.small)
                    .padding(.vertical, 6)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading issues")
    }

    private var previewSkeleton: some View {
        HomeSkeletonPulse {
            VStack(alignment: .leading, spacing: FlotillaSpacing.medium) {
                HomeSkeletonBlock(width: 90, height: 10)
                VStack(alignment: .leading, spacing: 6) {
                    HomeSkeletonBlock(width: 240, height: 15)
                    HomeSkeletonBlock(width: 150, height: 15)
                }
                HStack(spacing: 5) {
                    HomeSkeletonBlock(width: 44, height: 17, radius: 8.5)
                    HomeSkeletonBlock(width: 56, height: 17, radius: 8.5)
                }
                HomeSkeletonBlock(width: 130, height: 10)
                VStack(alignment: .leading, spacing: 5) {
                    HomeSkeletonBlock(width: 250, height: 9)
                    HomeSkeletonBlock(width: 180, height: 9)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(FlotillaSpacing.large)
        }
        .accessibilityHidden(true)
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard !issues.isEmpty else { return .handled }
        let next = (highlighted ?? (delta > 0 ? -1 : issues.count)) + delta
        highlighted = min(max(next, 0), issues.count - 1)
        return .handled
    }
}

/// A GitHub label tinted with its own colour; labels without one stay grey.
/// The text leans toward the primary text colour so dark labels stay legible
/// in dark mode and pale ones in light mode.
struct IssueLabelTag: View {
    enum Size { case small, large }

    let name: String
    let hex: String?
    var size: Size = .small

    var body: some View {
        let tint = hex.flatMap(PlatformColor.init(hexString:)).map(Color.init) ?? FlotillaColors.textSecondary
        Text(name)
            .font(size == .small ? FlotillaTypography.caption3.weight(.medium) : FlotillaTypography.caption2.weight(.medium))
            .foregroundStyle(tint.mix(with: FlotillaColors.textPrimary, by: 0.35))
            .padding(.horizontal, size == .small ? 5 : 7)
            .padding(.vertical, size == .small ? 1 : 2)
            .background(tint.opacity(0.15), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: FlotillaBorderWidth.hairline))
    }
}
