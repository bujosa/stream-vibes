import SwiftUI

struct AITaskCenterView: View {
    @Environment(AIService.self) private var ai

    private let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let foreground = ai.foregroundOperation {
                AIFetchOverlayView(
                    title: foreground.title,
                    progressMessage: foreground.progressMessage,
                    isMinimized: false,
                    canCancel: foreground.canCancel,
                    onToggleMinimize: {
                        ai.minimizeOperation(id: foreground.id)
                    },
                    onCancel: {
                        ai.cancelOperation(id: foreground.id)
                    }
                )
                .transition(.opacity)
            }

            VStack(alignment: .trailing, spacing: 12) {
                if ai.isJobsPanelVisible {
                    jobsPanel
                }
            }
            .padding(20)
        }
        .task {
            ai.pruneExpiredOperations()
        }
        .animation(.easeInOut(duration: 0.25), value: ai.operations)
        .animation(.easeInOut(duration: 0.25), value: ai.isJobsPanelVisible)
    }

    private var compactDock: some View {
        VStack(alignment: .trailing, spacing: 10) {
            ForEach(ai.dockOperations) { operation in
                activeTaskCard(for: operation)
            }

            if !ai.recentOperations.isEmpty {
                jobsLauncher
            }
        }
    }

    private var jobsLauncher: some View {
        Button {
            ai.showJobsPanel()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "list.bullet.rectangle.portrait")
                    .font(.callout.weight(.semibold))

                VStack(alignment: .leading, spacing: 2) {
                    Text("View Jobs")
                        .font(.caption.bold())
                    Text("\(ai.recentOperations.count) recent")
                        .font(.caption2)
                        .foregroundStyle(SVTheme.textSecondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
            .background(SVTheme.surface.opacity(0.94))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(SVTheme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(SVTheme.textPrimary)
    }

    private var jobsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("AI Jobs")
                        .font(.headline)
                        .foregroundStyle(SVTheme.textPrimary)

                    Text(panelSubtitle)
                        .font(.caption)
                        .foregroundStyle(SVTheme.textSecondary)
                }

                Spacer()

                if !ai.recentOperations.isEmpty {
                    Button("Clear Done") {
                        ai.clearFinishedOperations()
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SVTheme.accent)
                }

                Button {
                    ai.hideJobsPanel()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.bold())
                }
                .buttonStyle(.plain)
                .foregroundStyle(SVTheme.textSecondary)
            }

            if !ai.activeOperations.isEmpty {
                sectionLabel("Running")
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(ai.activeOperations) { operation in
                            jobRow(for: operation)
                        }
                    }
                }
                .frame(maxHeight: min(CGFloat(ai.activeOperations.count) * 96, 240))
            }

            if !ai.recentOperations.isEmpty {
                sectionLabel("Recent")
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(ai.recentOperations.prefix(8)) { operation in
                            jobRow(for: operation)
                        }
                    }
                }
                .frame(maxHeight: 320)
            } else if ai.activeOperations.isEmpty {
                Text("No recent jobs yet.")
                    .font(.caption)
                    .foregroundStyle(SVTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(width: 380)
        .background(.ultraThinMaterial)
        .background(SVTheme.surface.opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(SVTheme.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
    }

    private var panelSubtitle: String {
        let runningCount = ai.activeOperations.count
        let recentCount = ai.recentOperations.count

        if runningCount > 0 && recentCount > 0 {
            return "\(runningCount) running, \(recentCount) recent"
        }
        if runningCount > 0 {
            return "\(runningCount) running"
        }
        return "\(recentCount) recent"
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(SVTheme.textSecondary)
            .textCase(.uppercase)
    }

    private func activeTaskCard(for operation: AIOperationSnapshot) -> some View {
        HStack(spacing: 12) {
            statusIcon(for: operation)

            VStack(alignment: .leading, spacing: 4) {
                Text(operation.title)
                    .font(.caption.bold())
                    .foregroundStyle(SVTheme.textPrimary)
                    .lineLimit(1)

                if let message = operation.progressMessage, !message.isEmpty {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(SVTheme.textSecondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                ai.showJobsPanel()
            } label: {
                Image(systemName: "list.bullet")
                    .font(.caption.bold())
            }
            .buttonStyle(.plain)
            .foregroundStyle(SVTheme.accent)

            Button {
                ai.restoreOperation(id: operation.id)
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.caption.bold())
            }
            .buttonStyle(.plain)
            .foregroundStyle(SVTheme.accent)

            if operation.canCancel {
                Button {
                    ai.cancelOperation(id: operation.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.bold())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 320)
        .background(.ultraThinMaterial)
        .background(SVTheme.surface.opacity(0.94))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(SVTheme.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
    }

    private func jobRow(for operation: AIOperationSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                statusIcon(for: operation)

                VStack(alignment: .leading, spacing: 4) {
                    Text(operation.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(SVTheme.textPrimary)
                        .lineLimit(2)

                    Text(statusText(for: operation))
                        .font(.caption)
                        .foregroundStyle(statusColor(for: operation))

                    if let summary = operation.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(SVTheme.textSecondary)
                            .lineLimit(3)
                    } else if let message = operation.progressMessage, !message.isEmpty {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(SVTheme.textSecondary)
                            .lineLimit(3)
                    }
                }

                Spacer(minLength: 8)

                HStack(spacing: 8) {
                    if operation.status == .running {
                        Button("Open") {
                            ai.restoreOperation(id: operation.id)
                        }
                        .buttonStyle(.plain)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(SVTheme.accent)

                        if operation.canCancel {
                            Button {
                                ai.cancelOperation(id: operation.id)
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                        }
                    } else {
                        if ai.canRerunOperation(id: operation.id) {
                            Button("Run Again") {
                                ai.rerunOperation(id: operation.id)
                            }
                            .buttonStyle(.plain)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(SVTheme.accent)
                        }

                        Button {
                            ai.dismissOperation(id: operation.id)
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(SVTheme.textSecondary)
                    }
                }
            }

            Text(timeText(for: operation))
                .font(.caption2)
                .foregroundStyle(SVTheme.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(SVTheme.surface.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(SVTheme.border.opacity(0.8), lineWidth: 1)
        )
    }

    private func statusIcon(for operation: AIOperationSnapshot) -> some View {
        ZStack {
            Circle()
                .fill(statusColor(for: operation).opacity(0.14))
                .frame(width: 36, height: 36)

            if operation.status == .running {
                ProgressView()
                    .controlSize(.small)
                    .tint(statusColor(for: operation))
            } else {
                Image(systemName: statusSymbol(for: operation))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(statusColor(for: operation))
            }
        }
    }

    private func statusSymbol(for operation: AIOperationSnapshot) -> String {
        switch operation.status {
        case .running:
            return "sparkles"
        case .completed:
            return "checkmark"
        case .failed:
            return "exclamationmark"
        case .cancelled:
            return "slash.circle"
        }
    }

    private func statusColor(for operation: AIOperationSnapshot) -> Color {
        switch operation.status {
        case .running:
            return SVTheme.accent
        case .completed:
            return .green
        case .failed:
            return .red
        case .cancelled:
            return .orange
        }
    }

    private func statusText(for operation: AIOperationSnapshot) -> String {
        switch operation.status {
        case .running:
            return "Running"
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Canceled"
        }
    }

    private func timeText(for operation: AIOperationSnapshot) -> String {
        if let completedAt = operation.completedAt {
            return "Finished " + relativeFormatter.localizedString(for: completedAt, relativeTo: Date())
        }
        return "Started " + relativeFormatter.localizedString(for: operation.startedAt, relativeTo: Date())
    }
}
