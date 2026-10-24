import DesignSystem
import SessionKit
import SwiftUI

/// What the miniature window is acting out.
enum TourScene: Int, CaseIterable, Sendable {
    case parallel, signals, handoff, review, phone
    /// One tile per chosen agent — the crew page's live preview.
    case crew
    /// The chosen agents on the chosen project, ready to go.
    case launch
}

/// A miniature Flotilla window that acts out how the app works. It is the
/// stage of the whole welcome sheet: the tour plays scenes on it, and the
/// setup pages show the user's own fleet taking shape in it.
struct OnboardingTourWindow: View {
    let scene: TourScene
    let agents: [AgentKind]
    var projectName: String?
    var isLaunching = false
    /// Freezes the animation on one frame, for previews and captures.
    var pinnedTick: Int?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let storySessions = [
        (title: "Fix login redirect", branch: "fix-login-redirect"),
        (title: "Polish dark mode", branch: "dark-mode-polish"),
        (title: "Add rate limits", branch: "api-rate-limits"),
    ]
    private static let launchTitles = ["Fix login redirect", "Polish dark mode", "Add rate limits", "Write release notes", "Speed up CI"]

    private var crew: [AgentKind] {
        agents.isEmpty ? [.claudeCode, .codexCLI] : agents
    }

    private var isFleetScene: Bool { scene == .crew || scene == .launch }

    private var sessionCount: Int {
        if isFleetScene { return crew.count }
        // The phone takes the third tile's room.
        return scene == .phone ? 2 : Self.storySessions.count
    }

    var body: some View {
        Group {
            if let pinnedTick {
                stage(tick: pinnedTick)
            } else if reduceMotion {
                stage(tick: 2)
            } else {
                TimelineView(.periodic(from: .now, by: 1.4)) { context in
                    stage(tick: Int(context.date.timeIntervalSinceReferenceDate / 1.4))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        switch scene {
        case .parallel: "Three agents working side by side, each on its own branch"
        case .signals: "Session statuses change, and a notification appears when an agent is waiting"
        case .handoff: "A session is handed from one agent to another with its conversation intact"
        case .review: "A diff under review, with a line comment being sent back to the agent"
        case .phone: "A permission request arrives on an iPhone and is approved"
        case .crew, .launch: "Your fleet: \(crew.map(\.displayName).formatted(.list(type: .and)))"
        }
    }

    /// The Mac window, joined by an iPhone for the companion scene — side by
    /// side, the way Apple shows a Mac and an iPhone working together.
    private func stage(tick: Int) -> some View {
        HStack(spacing: 20) {
            window(tick: tick)
            if scene == .phone {
                CompanionPhone(agent: crew[0], isApproved: isApproved(tick: tick))
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.5), value: scene)
    }

    private func window(tick: Int) -> some View {
        VStack(spacing: 0) {
            titleBar
            HStack(spacing: 0) {
                sidebar(tick: tick)
                    .frame(width: 168)
                Divider()
                detail(tick: tick)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(FlotillaColors.canvas)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(FlotillaColors.separatorStrong.opacity(0.6))
        }
        .overlay(alignment: .topTrailing) {
            if scene == .signals, let waiting = waitingIndex(tick: tick) {
                notification(index: waiting)
                    .padding(.top, 34)
                    .padding(.trailing, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        .animation(.smooth(duration: 0.45), value: tick)
        .animation(.smooth(duration: 0.45), value: scene)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: crew)
        .animation(.smooth(duration: 0.5), value: isLaunching)
    }

    // MARK: Chrome

    private var titleBar: some View {
        HStack(spacing: 6) {
            ForEach([Color.red, .yellow, .green], id: \.self) { color in
                Circle().fill(color.opacity(0.85)).frame(width: 9, height: 9)
            }
            Spacer()
            Text(projectName.map { "Flotilla — \($0)" } ?? "Flotilla")
                .font(FlotillaTypography.caption2.weight(.semibold))
                .foregroundStyle(FlotillaColors.textSecondary)
            Spacer()
            Color.clear.frame(width: 39, height: 9)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(FlotillaColors.sidebar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func sidebar(tick: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(isFleetScene ? "YOUR FLEET" : "FLEET")
                .font(.system(size: 9, weight: .semibold))
                .tracking(FlotillaTypography.Tracking.loose)
                .foregroundStyle(FlotillaColors.textTertiary)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            ForEach(0..<sessionCount, id: \.self) { index in
                let status = status(index: index, tick: tick)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(StatusPresentation.color(for: status))
                            .frame(width: 6, height: 6)
                        Text(title(index: index))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(FlotillaColors.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        ProviderLogo(agent: agent(index: index, tick: tick))
                            .frame(width: 10, height: 10)
                    }
                    Text(subtitle(index: index))
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(scene == .parallel ? FlotillaColors.accent : FlotillaColors.textTertiary)
                        .lineLimit(1)
                        .padding(.leading, 11)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    focusedIndex == index ? FlotillaColors.textPrimary.opacity(0.08) : .clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
            Spacer()
        }
        .padding(8)
        .background(FlotillaColors.sidebar.opacity(0.7))
    }

    private var focusedIndex: Int? {
        scene == .handoff || scene == .review ? 0 : nil
    }

    // MARK: State

    private func title(index: Int) -> String {
        switch scene {
        case .crew: crew[index].displayName
        case .launch: Self.launchTitles[index % Self.launchTitles.count]
        default: Self.storySessions[index].title
        }
    }

    private func subtitle(index: Int) -> String {
        switch scene {
        case .crew: crew[index].onboardingTagline
        case .launch: projectName ?? "your-project"
        default: Self.storySessions[index].branch
        }
    }

    private func status(index: Int, tick: Int) -> SessionStatus? {
        switch scene {
        case .signals:
            let cycle: [SessionStatus] = [.working, .working, .waitingForInput, .readyForReview]
            return cycle[(tick + index * 3) % cycle.count]
        case .review:
            return index == 0 ? .readyForReview : .working
        case .phone:
            return index == 0 && !isApproved(tick: tick) ? .waitingForInput : .working
        case .crew:
            return nil
        case .launch:
            return isLaunching ? .working : nil
        case .parallel, .handoff:
            return .working
        }
    }

    private func statusLabel(_ status: SessionStatus?) -> String {
        guard status == nil else { return StatusPresentation.label(for: status) }
        return scene == .launch ? "Ready to launch" : "Ready"
    }

    private func waitingIndex(tick: Int) -> Int? {
        (0..<sessionCount).first { status(index: $0, tick: tick) == .waitingForInput }
    }

    private func isApproved(tick: Int) -> Bool {
        // Reduce Motion freezes on tick 2, which keeps the request on screen.
        scene == .phone && tick % 3 == 0
    }

    private var handoffTarget: AgentKind {
        crew.dropFirst().first ?? (crew[0] == .codexCLI ? .claudeCode : .codexCLI)
    }

    private func isHandedOff(tick: Int) -> Bool {
        scene == .handoff && tick % 3 != 0
    }

    private func agent(index: Int, tick: Int) -> AgentKind {
        if index == 0 && isHandedOff(tick: tick) { return handoffTarget }
        return crew[index % crew.count]
    }

    // MARK: Detail

    @ViewBuilder
    private func detail(tick: Int) -> some View {
        switch scene {
        case .parallel, .signals, .phone, .crew, .launch: grid(tick: tick)
        case .handoff: handoff(tick: tick)
        case .review: review
        }
    }

    /// Rows of up to three tiles that share the pane's height, like Mission Control.
    private func grid(tick: Int) -> some View {
        let rows = stride(from: 0, to: sessionCount, by: 3).map { Array($0..<min($0 + 3, sessionCount)) }
        return VStack(spacing: 8) {
            ForEach(rows, id: \.first) { row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.self) { index in
                        tile(index: index, tick: tick, compact: sessionCount > 3)
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                }
            }
        }
        .padding(10)
    }

    private func tile(index: Int, tick: Int, compact: Bool) -> some View {
        let status = status(index: index, tick: tick)
        let isWaiting = status == .waitingForInput
        let showsBranch = !isFleetScene
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ProviderLogo(agent: agent(index: index, tick: tick)).frame(width: 10, height: 10)
                Text(title(index: index))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(FlotillaColors.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Circle().fill(StatusPresentation.color(for: status)).frame(width: 6, height: 6)
            }
            Text(statusLabel(status))
                .font(.system(size: 8.5))
                .foregroundStyle(isWaiting ? FlotillaColors.statusWaitingForInput : FlotillaColors.textSecondary)
            if showsBranch {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.branch")
                    Text(Self.storySessions[index].branch).lineLimit(1)
                }
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(scene == .parallel ? FlotillaColors.accent : FlotillaColors.textTertiary)
                .padding(.horizontal, scene == .parallel ? 5 : 0)
                .padding(.vertical, scene == .parallel ? 2 : 0)
                .background(scene == .parallel ? FlotillaColors.accent.opacity(0.14) : .clear, in: Capsule())
            }
            terminal(lines: compact ? 5 : 14, isLive: status != nil)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(FlotillaColors.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isWaiting ? FlotillaColors.statusWaitingForInput : FlotillaColors.separator, lineWidth: isWaiting ? 1.5 : 1)
        }
        .shadow(color: isWaiting ? FlotillaColors.statusWaitingForInput.opacity(0.4) : .clear, radius: 8)
    }

    private func handoff(tick: Int) -> some View {
        let handedOff = isHandedOff(tick: tick)
        let current = agent(index: 0, tick: tick)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    ProviderLogo(agent: current).frame(width: 11, height: 11)
                    Text(current.displayName)
                }
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(FlotillaColors.textPrimary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(FlotillaColors.surfaceElevated, in: Capsule())
                .id(current)
                .transition(.scale.combined(with: .opacity))
                Text(Self.storySessions[0].title)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(FlotillaColors.textSecondary)
                Spacer()
                HStack(spacing: 3) {
                    Image(systemName: "arrow.left.arrow.right")
                    Text(handedOff ? "Handed off" : "Hand Off to \(handoffTarget.displayName)")
                }
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(handedOff ? FlotillaColors.textSecondary : .white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(handedOff ? FlotillaColors.surfaceElevated : Color.purple, in: Capsule())
            }
            VStack(alignment: .leading, spacing: 6) {
                bubble(isUser: true, width: 0.5)
                bubble(isUser: false, width: 0.75)
                bubble(isUser: true, width: 0.4)
                bubble(isUser: false, width: 0.65)
                if handedOff {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(FlotillaColors.success)
                        Text("Conversation carried over · 42 turns")
                            .foregroundStyle(FlotillaColors.textSecondary)
                    }
                    .font(.system(size: 9))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
                    .transition(.opacity)
                    HStack(spacing: 5) {
                        ProviderLogo(agent: handoffTarget).frame(width: 10, height: 10)
                        Capsule().fill(FlotillaColors.textTertiary.opacity(0.45)).frame(width: 140, height: 5)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(FlotillaColors.terminalCanvas.opacity(0.7), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(10)
    }

    private func bubble(isUser: Bool, width: CGFloat) -> some View {
        GeometryReader { proxy in
            HStack {
                if isUser { Spacer(minLength: 0) }
                Capsule()
                    .fill(isUser ? FlotillaColors.accent.opacity(0.35) : FlotillaColors.textTertiary.opacity(0.35))
                    .frame(width: proxy.size.width * width, height: 6)
                if !isUser { Spacer(minLength: 0) }
            }
        }
        .frame(height: 6)
    }

    private var review: some View {
        let lines: [(kind: Character, text: String)] = [
            (" ", "func handleRedirect(_ url: URL) {"),
            ("-", "    guard let token = session.token else { return }"),
            ("+", "    guard let token = session.validToken() else {"),
            ("+", "        return router.showLogin()"),
            ("+", "    }"),
            (" ", "    router.open(url, token: token)"),
            (" ", "}"),
        ]
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                Text("LoginRouter.swift")
                    .font(.system(size: 9.5, weight: .semibold))
                Text("+3 −1")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(FlotillaColors.textSecondary)
                Spacer()
            }
            .font(.system(size: 9.5))
            .foregroundStyle(FlotillaColors.textPrimary)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    Text("\(String(line.kind)) \(line.text)")
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(FlotillaColors.textPrimary.opacity(line.kind == " " ? 0.6 : 1))
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(lineBackground(line.kind))
                    if index == 3 {
                        comment
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .background(FlotillaColors.terminalCanvas.opacity(0.7), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Spacer(minLength: 0)
            HStack {
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "paperplane.fill")
                    Text("Send Review to \(crew[0].displayName)")
                }
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(FlotillaColors.accent, in: Capsule())
            }
        }
        .padding(10)
    }

    private func lineBackground(_ kind: Character) -> Color {
        switch kind {
        case "+": FlotillaColors.diffAddedSurface
        case "-": FlotillaColors.diffRemovedSurface
        default: .clear
        }
    }

    private var comment: some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(FlotillaColors.textSecondary)
            Text("Also clear the stale token before showing login.")
                .font(.system(size: 9))
                .foregroundStyle(FlotillaColors.textPrimary)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FlotillaColors.surfaceElevated, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    private func terminal(lines: Int, isLive: Bool) -> some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 5) {
                ForEach(0..<lines, id: \.self) { line in
                    Capsule()
                        .fill(FlotillaColors.textTertiary.opacity(isLive ? 0.32 : 0.12))
                        .frame(width: proxy.size.width * [0.8, 0.5, 0.68, 0.35, 0.6, 0.45][line % 6], height: 3)
                }
            }
            .padding(6)
        }
        .frame(maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .background(FlotillaColors.terminalCanvas.opacity(0.7), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private func notification(index: Int) -> some View {
        let agent = agent(index: index, tick: 0)
        return HStack(spacing: 6) {
            ProviderLogo(agent: agent).frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(agent.displayName) needs your input")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(FlotillaColors.textPrimary)
                Text(Self.storySessions[index].title)
                    .font(.system(size: 8.5))
                    .foregroundStyle(FlotillaColors.textSecondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
    }
}

/// An iPhone running the companion, mid-permission request. Laid out at real
/// iPhone size (393 × 852 pt) after the companion's session screen and
/// `PermissionCard`, then scaled to fit, so it reads like a product shot.
private struct CompanionPhone: View {
    let agent: AgentKind
    let isApproved: Bool

    private static let screen = CGSize(width: 393, height: 852)

    var body: some View {
        GeometryReader { proxy in
            let scale = proxy.size.height / Self.screen.height
            screen
                .frame(width: Self.screen.width, height: Self.screen.height)
                .scaleEffect(scale, anchor: .topLeading)
        }
        .aspectRatio(Self.screen.width / Self.screen.height, contentMode: .fit)
        .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
    }

    private var screen: some View {
        VStack(spacing: 0) {
            statusBar
            sessionHeader
            transcript
            Spacer(minLength: 0)
            permissionCard
            Capsule()
                .fill(FlotillaColors.textPrimary.opacity(0.8))
                .frame(width: 134, height: 5)
                .padding(.top, 14)
                .padding(.bottom, 8)
        }
        .background(FlotillaColors.canvas)
        .clipShape(RoundedRectangle(cornerRadius: 56, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 56, style: .continuous)
                .strokeBorder(Color(white: 0.22), lineWidth: 12)
        }
        .overlay(alignment: .top) {
            Capsule().fill(.black).frame(width: 124, height: 36).padding(.top, 18)
        }
    }

    private var statusBar: some View {
        HStack {
            Text("9:41")
                .font(.system(size: 17, weight: .semibold))
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "cellularbars")
                Image(systemName: "wifi")
                Image(systemName: "battery.100percent")
            }
            .font(.system(size: 15, weight: .semibold))
        }
        .foregroundStyle(FlotillaColors.textPrimary)
        .padding(.horizontal, 44)
        .frame(height: 62)
        .padding(.top, 8)
    }

    private var sessionHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                ProviderLogo(agent: agent).frame(width: 24, height: 24)
                Circle()
                    .fill(isApproved ? FlotillaColors.statusWorking : FlotillaColors.statusWaitingForInput)
                    .frame(width: 9, height: 9)
                Text(isApproved ? "Working" : "Needs Permission")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isApproved ? FlotillaColors.statusWorking : FlotillaColors.statusWaitingForInput)
                Text("· \(agent.displayName)")
                    .font(.system(size: 16))
                    .foregroundStyle(FlotillaColors.textSecondary)
            }
            Text("Fix login redirect")
                .font(.system(size: 15))
                .foregroundStyle(FlotillaColors.textSecondary)
            Text(isApproved ? "Running npm test · 3m" : "Waiting for you · 3m")
                .font(.system(size: 15))
                .foregroundStyle(FlotillaColors.textTertiary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FlotillaColors.surface)
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("The login redirect loops once the token expires. Find out why and fix it.")
                .font(.system(size: 17))
                .foregroundStyle(FlotillaColors.textPrimary)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(FlotillaColors.accent.opacity(0.2), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .padding(.leading, 56)
                .frame(maxWidth: .infinity, alignment: .trailing)
            toolRow("swift test --filter LoginRouterTests", status: .failed)
            Text("The router reuses the expired token. I switched it to validToken() and want to run the suite.")
                .font(.system(size: 17))
                .foregroundStyle(FlotillaColors.textPrimary)
            toolRow("npm test", status: isApproved ? .running : .pending)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
    }

    private enum ToolStatus { case failed, pending, running }

    private func toolRow(_ command: String, status: ToolStatus) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "apple.terminal")
                .foregroundStyle(FlotillaColors.textSecondary)
            Text("shell · \(command)")
                .font(.system(size: 15, design: .monospaced))
                .foregroundStyle(FlotillaColors.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
            switch status {
            case .failed:
                Image(systemName: "xmark.circle.fill").foregroundStyle(FlotillaColors.danger)
            case .pending:
                Image(systemName: "lock.fill").foregroundStyle(FlotillaColors.statusWaitingForInput)
            case .running:
                Image(systemName: "circle.dotted").foregroundStyle(FlotillaColors.textTertiary)
            }
        }
        .font(.system(size: 16))
    }

    @ViewBuilder
    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isApproved {
                Label("Allowed · npm test", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(FlotillaColors.success)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            } else {
                Label("Permission", systemImage: "lock.open.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(FlotillaColors.statusWaitingForInput)
                Text("Bash")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(FlotillaColors.textPrimary)
                Text("npm test")
                    .font(.system(size: 17, design: .monospaced))
                    .foregroundStyle(FlotillaColors.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(FlotillaColors.surfaceElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Text("Allow approves this one request. Always allow for this session remembers the choice — see More.")
                    .font(.system(size: 13))
                    .foregroundStyle(FlotillaColors.textSecondary)
                HStack(spacing: 10) {
                    Text("Deny")
                        .foregroundStyle(FlotillaColors.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(FlotillaColors.surfaceElevated, in: Capsule())
                    Text("Allow")
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(FlotillaColors.accent, in: Capsule())
                    Image(systemName: "ellipsis")
                        .foregroundStyle(FlotillaColors.textPrimary)
                        .frame(width: 50, height: 50)
                        .background(FlotillaColors.surfaceElevated, in: Circle())
                }
                .font(.system(size: 17, weight: .semibold))
                .padding(.top, 4)
            }
        }
        .padding(18)
        .background(FlotillaColors.surface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .padding(.horizontal, 14)
    }
}

#Preview("Tour window") {
    OnboardingTourWindow(scene: .phone, agents: [.claudeCode, .codexCLI])
        .frame(width: 620, height: 290)
        .padding(40)
}
