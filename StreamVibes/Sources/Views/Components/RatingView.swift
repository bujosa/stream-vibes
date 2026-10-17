import SwiftUI

struct RatingStarsView: View {
    let score: Double
    let maxScore: Double = 10

    var filledStars: Int {
        Int(score / 2)
    }

    var hasHalfStar: Bool {
        score.truncatingRemainder(dividingBy: 2) >= 0.5
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                Image(systemName: starName(for: index))
                    .foregroundStyle(index < filledStars || (index == filledStars && hasHalfStar) ? SVTheme.star : SVTheme.textMuted.opacity(0.3))
                    .font(.caption)
            }

            Text(String(format: "%.1f", score))
                .font(.caption.bold())
                .foregroundStyle(SVTheme.textPrimary)
                .padding(.leading, 2)
        }
    }

    private func starName(for index: Int) -> String {
        if index < filledStars {
            return "star.fill"
        } else if index == filledStars && hasHalfStar {
            return "star.leadinghalf.filled"
        }
        return "star"
    }
}

struct ScoreBadge: View {
    let score: Double
    var size: Font = .headline

    var color: Color {
        if score >= 8 { return SVTheme.success }
        if score >= 6 { return SVTheme.star }
        if score >= 4 { return .orange }
        return .red
    }

    var body: some View {
        Text(String(format: "%.1f", score))
            .font(size.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
