import SwiftUI
import AppKit
import SessionKit
import DesignSystem

/// Codebase Context & Agent Rules Studio (Design 2).
/// Inspects and edits project rules (AGENTS.md, CLAUDE.md, .cursorrules),
/// skills, and codebase architecture to prime AI agents with high-quality context.
struct ProjectContextStudioView: View {
    let project: Project
    @Bindable var store: AppStore

    @State private var studioTab: StudioTab = .rules
    @State private var showCreatedNotification = false
    @State private var createdFileName = ""

    private enum StudioTab: String, CaseIterable, Identifiable {
        case rules = "Rules & Instructions"
        case files = "Codebase Browser"

        var id: Self { self }

        var icon: String {
            switch self {
            case .rules: "doc.badge.gearshape"
            case .files: "folder"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            topControlBar
            Divider()

            switch studioTab {
            case .rules:
                RulesPanelView(rootURL: project.rootPath, filter: .all)
                    .id(project.id.uuidString + "-rules")
            case .files:
                FileBrowserView(rootURL: project.rootPath)
                    .id(project.id.uuidString + "-files")
            }
        }
        .background(FlotillaColors.canvas)
        .overlay(alignment: .bottomTrailing) {
            if showCreatedNotification {
                HStack(spacing: FlotillaSpacing.small) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(FlotillaColors.statusWorking)
                    Text("Created \(createdFileName)")
                        .font(FlotillaTypography.caption.weight(.medium))
                }
                .padding(.horizontal, FlotillaSpacing.medium)
                .padding(.vertical, FlotillaSpacing.small)
                .background(FlotillaColors.surfaceElevated, in: RoundedRectangle(cornerRadius: FlotillaRadius.card))
                .overlay {
                    RoundedRectangle(cornerRadius: FlotillaRadius.card)
                        .strokeBorder(FlotillaColors.statusWorking.opacity(0.4))
                }
                .padding(FlotillaSpacing.large)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: - Top Control Bar

    private var topControlBar: some View {
        HStack(spacing: FlotillaSpacing.medium) {
            Picker("Context View", selection: $studioTab) {
                ForEach(StudioTab.allCases) { tab in
                    Label(tab.rawValue, systemImage: tab.icon).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)

            Spacer()

            Menu {
                Button("Create AGENTS.md Guide") {
                    createTemplateFile(named: "AGENTS.md", content: defaultAgentsGuide)
                }
                Button("Create CLAUDE.md Rules") {
                    createTemplateFile(named: "CLAUDE.md", content: defaultClaudeRules)
                }
                Button("Create .cursorrules") {
                    createTemplateFile(named: ".cursorrules", content: defaultCursorRules)
                }
            } label: {
                Label("Add Rule Template", systemImage: "plus.bubble")
                    .font(FlotillaTypography.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([project.rootPath])
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: FlotillaIconSize.small))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Reveal project in Finder")
        }
        .padding(.horizontal, FlotillaSpacing.medium)
        .padding(.vertical, FlotillaSpacing.small)
        .background(FlotillaColors.surfaceElevated)
    }

    // MARK: - Template File Creation

    private func createTemplateFile(named fileName: String, content: String) {
        let fileURL = project.rootPath.appendingPathComponent(fileName)
        guard !FileManager.default.fileExists(atPath: fileURL.path) else {
            createdFileName = "\(fileName) (already exists)"
            showNotification()
            return
        }
        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            createdFileName = fileName
            showNotification()
        } catch {
            store.lastOperationError = "Failed to create \(fileName): \(error.localizedDescription)"
        }
    }

    private func showNotification() {
        withAnimation(FlotillaMotion.snappy.curve) {
            showCreatedNotification = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(FlotillaMotion.snappy.curve) {
                showCreatedNotification = false
            }
        }
    }

    // MARK: - Default Templates

    private var defaultAgentsGuide: String {
        """
        # \(project.name) — Agent Guide

        > Guidelines and architecture reference for AI coding assistants working on \(project.name).

        ## Project Overview
        - **Language / Stack:** 
        - **Build System:** 
        - **Primary Entrypoint:** 

        ## Development Commands
        - **Build:** 
        - **Test:** 
        - **Lint:** 

        ## Architecture & Conventions
        - 
        """
    }

    private var defaultClaudeRules: String {
        """
        # Claude Code Rules for \(project.name)

        ## Guidelines
        - Always run unit tests before and after making code changes.
        - Maintain strict concurrency and type safety.
        - Keep functions focused and modular.
        """
    }

    private var defaultCursorRules: String {
        """
        # Rules for \(project.name)

        - Follow clean architecture patterns.
        - Ensure all public APIs are properly documented.
        - Never modify generated files directly.
        """
    }
}
