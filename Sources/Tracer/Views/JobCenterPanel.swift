import SwiftUI

struct JobCenterPanel: View {
    @ObservedObject var jobs: JobCenterStore
    let cancel: (JobRecord) -> Void

    @State private var filter: JobCenterFilter = .all
    @State private var now = Date()

    private var activeRecords: [JobRecord] {
        jobs.activeRecords
    }

    private var visibleRecords: [JobRecord] {
        switch filter {
        case .all:
            return Array(jobs.recentRecords.prefix(180))
        case .active:
            return activeRecords
        case .issues:
            return jobs.recentRecords.filter { $0.state == .failed || $0.state == .cancelled }
        case .finished:
            return jobs.recentRecords.filter { $0.state.isTerminal }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 7) {
                    if visibleRecords.isEmpty {
                        emptyState
                    } else {
                        ForEach(visibleRecords) { record in
                            JobRecordRow(record: record, now: now) {
                                cancel(record)
                            }
                        }
                    }
                }
                .padding(10)
            }
        }
        .background(TracerTheme.panelBackground)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { tick in
            if !activeRecords.isEmpty {
                now = tick
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Label("Job Center", systemImage: "list.bullet.clipboard")
                .font(.system(size: 11, weight: .semibold))

            Text("\(activeRecords.count) active")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(activeRecords.isEmpty ? .secondary : TracerTheme.accentBright)

            if jobs.unreadIssueCount > 0 {
                Label("\(jobs.unreadIssueCount)", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.orange)
            }

            Text("ok \(jobs.metrics.succeeded) / fail \(jobs.metrics.failed)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)

            Picker("Filter", selection: $filter) {
                ForEach(JobCenterFilter.allCases) { filter in
                    Text(filter.displayName).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 280)

            Spacer()

            if !jobs.staleActiveRecords().isEmpty {
                Label("\(jobs.staleActiveRecords().count) stale", systemImage: "clock.badge.exclamationmark")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.orange)
            }

            Button {
                jobs.clearFinished()
            } label: {
                Label("Clear Finished", systemImage: "checkmark.circle")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(jobs.recentRecords.allSatisfy { !$0.state.isTerminal })
            .help("Clear completed job records")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(TracerTheme.headerBackground)
        .overlay(Rectangle().fill(TracerTheme.hairline).frame(height: 1), alignment: .bottom)
    }

    private var emptyState: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .foregroundColor(.secondary)
            Text("No jobs in this view.")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
    }
}

private enum JobCenterFilter: String, CaseIterable, Identifiable {
    case all
    case active
    case issues
    case finished

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return "All"
        case .active: return "Active"
        case .issues: return "Issues"
        case .finished: return "Finished"
        }
    }
}

private struct JobRecordRow: View {
    let record: JobRecord
    let now: Date
    let cancel: () -> Void

    private var timeEstimate: TaskTimeEstimate {
        TaskTimeEstimator.estimate(kind: record.kind,
                                   progress: record.progress,
                                   startedAt: record.startedAt,
                                   now: now)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: record.systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(stateColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(record.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Text(record.stage)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Text(record.detail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let error = record.structuredError {
                    Text("\(error.code): \(error.message)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.red.opacity(0.9))
                        .lineLimit(2)
                        .textSelection(.enabled)
                }

                if record.isActive {
                    if let progress = timeEstimate.displayProgress {
                        ProgressView(value: min(max(progress, 0), 1))
                            .progressViewStyle(.linear)
                    } else {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack(spacing: 6) {
                        Text(timeEstimate.progressLabel)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(TracerTheme.accentBright)
                        Text(timeEstimate.summaryLabel)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 5) {
                Text(record.state.displayName)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(stateColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(stateColor.opacity(0.12)))

                Text(timeSummary)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)

                if record.isActive {
                    Text("hb \(TaskTimeEstimator.durationLabel(record.heartbeatAge(now: now)))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(record.heartbeatAge(now: now) > 120 ? .orange : .secondary.opacity(0.8))
                }
            }
            .frame(width: 112, alignment: .trailing)

            if record.canCancel && record.isActive {
                Button(action: cancel) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundColor(.secondary)
                .help("Cancel job")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(TracerTheme.viewportBackground.opacity(record.isActive ? 0.92 : 0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(record.state == .failed ? Color.red.opacity(0.6) : TracerTheme.hairline,
                        lineWidth: record.state == .failed ? 1.2 : 1)
        )
    }

    private var stateColor: Color {
        switch record.state {
        case .queued: return .secondary
        case .running: return TracerTheme.accentBright
        case .cancelling: return .orange
        case .succeeded: return .green
        case .failed: return .red
        case .cancelled: return .orange
        }
    }

    private var timeSummary: String {
        if record.isActive {
            return "\(TaskTimeEstimator.durationLabel(now.timeIntervalSince(record.startedAt))) elapsed"
        }
        return TaskTimeEstimator.durationLabel(record.duration)
    }
}
