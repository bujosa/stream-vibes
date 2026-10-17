import SwiftUI

struct PlatformBadgeRow: View {
    let platforms: [PlatformAvailability]

    var body: some View {
        if !platforms.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(platforms) { platform in
                        HStack(spacing: 6) {
                            Image(systemName: platform.platform.symbolName)
                                .font(.caption.bold())
                            Text(platform.platform.label)
                                .font(.caption.bold())
                            if let availability = platform.availability, !availability.isEmpty {
                                Text(availability.capitalized)
                                    .font(.caption2)
                                    .foregroundStyle(SVTheme.textSecondary)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(SVTheme.platformColor(platform.platform).opacity(0.16))
                        .foregroundStyle(SVTheme.platformColor(platform.platform))
                        .clipShape(Capsule())
                    }
                }
            }
        }
    }
}

struct PlatformSelectionSection: View {
    @Binding var platforms: [PlatformAvailability]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Platforms (optional)")
                .font(.subheadline)
                .foregroundStyle(SVTheme.textSecondary)

            FlexiblePlatformGrid(platforms: $platforms)

            if !platforms.isEmpty {
                PlatformBadgeRow(platforms: platforms)
            }
        }
    }
}

private struct FlexiblePlatformGrid: View {
    @Binding var platforms: [PlatformAvailability]

    private let columns = [
        GridItem(.adaptive(minimum: 120, maximum: 180), spacing: 8)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(StreamingPlatform.allCases.filter { $0 != .other }) { platform in
                let isSelected = platforms.contains { $0.platform == platform }
                Button {
                    toggle(platform)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: platform.symbolName)
                        Text(platform.label)
                            .lineLimit(1)
                    }
                    .font(.caption.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(isSelected ? SVTheme.platformColor(platform).opacity(0.18) : SVTheme.card)
                    .foregroundStyle(isSelected ? SVTheme.platformColor(platform) : SVTheme.textSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(isSelected ? SVTheme.platformColor(platform).opacity(0.45) : SVTheme.border, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func toggle(_ platform: StreamingPlatform) {
        if let index = platforms.firstIndex(where: { $0.platform == platform }) {
            platforms.remove(at: index)
        } else {
            platforms.append(PlatformAvailability(platform: platform, availability: "streaming", url: nil))
        }
    }
}
