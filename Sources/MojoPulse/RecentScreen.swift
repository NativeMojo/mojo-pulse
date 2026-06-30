import SwiftUI

/// The Recent activity domain screen, reached by drilling in from the popover
/// home. The *log* of events that have happened (distinct from the active
/// incident cards on home), grouped Today / Yesterday / Earlier the way Mail
/// and Messages do. Tapping a row opens its detail; the full searchable history
/// (with CSV export) is the one breakout to a window.
struct RecentScreen: View {
    @ObservedObject var history: HistoryStore
    var onSelectEvent: (IncidentRecord) -> Void = { _ in }
    var onShowFullHistory: () -> Void = {}

    private static let rel: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if history.recent.isEmpty {
                Text("Nothing recent. Pulse logs events here as they happen.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(groups, id: \.title) { group in
                    section(group.title) {
                        ForEach(group.records) { eventRow($0) }
                    }
                }
            }
            breakout
        }
    }

    // MARK: Grouping

    private struct DayGroup { let title: String; let records: [IncidentRecord] }

    private var groups: [DayGroup] {
        let cal = Calendar.current
        var today: [IncidentRecord] = []
        var yesterday: [IncidentRecord] = []
        var earlier: [IncidentRecord] = []
        for r in history.recent {
            if cal.isDateInToday(r.startedAt) { today.append(r) }
            else if cal.isDateInYesterday(r.startedAt) { yesterday.append(r) }
            else { earlier.append(r) }
        }
        var out: [DayGroup] = []
        if !today.isEmpty { out.append(DayGroup(title: "Today", records: today)) }
        if !yesterday.isEmpty { out.append(DayGroup(title: "Yesterday", records: yesterday)) }
        if !earlier.isEmpty { out.append(DayGroup(title: "Earlier", records: earlier)) }
        return out
    }

    // MARK: Rows

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.4)
                .padding(.bottom, 2)
            content()
        }
    }

    private func eventRow(_ r: IncidentRecord) -> some View {
        Button { onSelectEvent(r) } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(SeverityColors.color(for: r.severity, fallbackQuiet: false))
                    .frame(width: 8, height: 8)
                    .frame(width: 20)
                Text(r.title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Text(Self.rel.localizedString(for: r.startedAt, relativeTo: Date()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var breakout: some View {
        Button(action: onShowFullHistory) {
            HStack(spacing: 6) {
                Text("Open full history").font(.caption)
                Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Color.accentColor)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }
}
