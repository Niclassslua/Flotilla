import SwiftUI
import AppKit
import SessionKit
import DesignSystem

/// Dedicated rules, instructions, and skills sheet for a project.
/// Wraps RulesPanelView with 1-click template file creation (AGENTS.md, CLAUDE.md, .cursorrules).
struct ProjectRulesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let project: Project
    @Bindable var store: AppStore

    @State private var showCreatedNotification = false
    @State private var createdFileName = ""

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            RulesPanelView(rootURL: project.rootPath, filter: .all)
                .id(project.id.uuidString + "-rules")
        }
        .frame(minWidth: 800, minHeight: 540)
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

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: FlotillaSpacing.medium) {
            Image(systemName: "doc.badge.gearshape")
                .font(.system(size: FlotillaIconSize.medium))
                .foregroundStyle(FlotillaColors.accent)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(project.name) — Rules & Instructions")
                    .font(FlotillaTypography.headline)
                    .foregroundStyle(FlotillaColors.textPrimary)
                Text(project.rootPath.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(FlotillaColors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

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
            .help("Reveal in Finder")

            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, FlotillaSpacing.large)
        .padding(.vertical, FlotillaSpacing.medium)
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
