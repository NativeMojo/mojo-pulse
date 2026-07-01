import SwiftUI

/// Placeholder for the planned Disk Usage tool. Stubbed for now so the Disk
/// tile has a real destination; the full visual space map lands later.
struct DiskUsageView: View {
    var body: some View {
        ComingSoonDetail(
            icon: "internaldrive",
            title: "Disk Usage",
            blurb: "A visual map of what's filling your disk — by folder and category — so you can find and reclaim space fast."
        )
    }
}

/// Shared "coming soon" placeholder body, styled like the other detail panels.
private struct ComingSoonDetail: View {
    let icon: String
    let title: String
    let blurb: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.title3.weight(.semibold))
            }
            Text(blurb)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Image(systemName: "hammer")
                Text("Coming soon")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(width: 360, alignment: .leading)
    }
}
