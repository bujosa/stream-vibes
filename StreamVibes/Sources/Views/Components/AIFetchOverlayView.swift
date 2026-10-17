import Combine
import SwiftUI

struct AIFetchOverlayView: View {
    let title: String
    let progressMessage: String?
    let isMinimized: Bool
    let canCancel: Bool
    let onToggleMinimize: () -> Void
    let onCancel: () -> Void

    @State private var sparkleRotation: Double = 0
    @State private var pulseScale: CGFloat = 1.0
    @State private var glowOpacity: Double = 0.3
    @State private var particleOffset1: CGFloat = 0
    @State private var particleOffset2: CGFloat = 0
    @State private var particleOffset3: CGFloat = 0
    @State private var appeared = false
    @State private var dotCount = 0

    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    init(
        title: String = "Extracting with AI Magic",
        progressMessage: String?,
        isMinimized: Bool,
        canCancel: Bool,
        onToggleMinimize: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.title = title
        self.progressMessage = progressMessage
        self.isMinimized = isMinimized
        self.canCancel = canCancel
        self.onToggleMinimize = onToggleMinimize
        self.onCancel = onCancel
    }

    var body: some View {
        Group {
            if isMinimized {
                minimizedCard
            } else {
                expandedOverlay
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.4)) {
                appeared = true
            }

            // Sparkle rotation
            withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) {
                sparkleRotation = 360
            }

            // Pulse scale
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                pulseScale = 1.08
            }

            // Glow pulse
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                glowOpacity = 0.6
            }

            // Floating particles
            withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) {
                particleOffset1 = -20
            }
            withAnimation(.easeInOut(duration: 3.0).repeatForever(autoreverses: true)) {
                particleOffset2 = -25
            }
            withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                particleOffset3 = -15
            }
        }
        .onReceive(timer) { _ in
            dotCount = (dotCount + 1) % 4
        }
    }

    private var expandedOverlay: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(SVTheme.background.opacity(0.75))
                .ignoresSafeArea()

            Circle()
                .fill(
                    RadialGradient(
                        colors: [SVTheme.accent.opacity(glowOpacity), .clear],
                        center: .center,
                        startRadius: 20,
                        endRadius: 180
                    )
                )
                .frame(width: 360, height: 360)
                .scaleEffect(pulseScale)

            VStack(spacing: 28) {
                animatedIcon(size: 120, centerIcon: 48)

                Text(title)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(SVTheme.textPrimary)

                if let message = displayMessage {
                    Text(message)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(SVTheme.textSecondary)
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.3), value: message)
                }

                progressBar(width: 200)

                HStack(spacing: 10) {
                    Button("Minimize", action: onToggleMinimize)
                        .buttonStyle(.bordered)

                    if canCancel {
                        Button("Cancel", role: .destructive, action: onCancel)
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(28)
            .opacity(appeared ? 1 : 0)
            .scaleEffect(appeared ? 1 : 0.9)
        }
    }

    private var minimizedCard: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                HStack(spacing: 12) {
                    animatedIcon(size: 42, centerIcon: 18)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.caption.bold())
                            .foregroundStyle(SVTheme.textPrimary)
                        if let message = displayMessage {
                            Text(message)
                                .font(.caption2)
                                .foregroundStyle(SVTheme.textSecondary)
                                .lineLimit(2)
                        }
                    }

                    Button {
                        onToggleMinimize()
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(SVTheme.accent)

                    if canCancel {
                        Button(role: .destructive, action: onCancel) {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
                .background(SVTheme.surface.opacity(0.92))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(SVTheme.border, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.25), radius: 10)
                .padding(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(true)
    }

    private var displayMessage: String? {
        guard let progressMessage else { return nil }
        return progressMessage + String(repeating: ".", count: dotCount)
    }

    private func animatedIcon(size: CGFloat, centerIcon: CGFloat) -> some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Image(systemName: "sparkle")
                    .font(.system(size: max(8, centerIcon * 0.28), weight: .semibold))
                    .foregroundStyle(SVTheme.accent.opacity(0.6))
                    .offset(
                        x: cos(sparkleRotation * .pi / 180 + Double(i) * 2.094) * (size * 0.42),
                        y: sin(sparkleRotation * .pi / 180 + Double(i) * 2.094) * (size * 0.42)
                    )
            }

            Image(systemName: "sparkle")
                .font(.system(size: max(7, centerIcon * 0.2)))
                .foregroundStyle(SVTheme.accentLight.opacity(0.5))
                .offset(x: -size * 0.25, y: particleOffset1 - size * 0.33)

            Image(systemName: "sparkle")
                .font(.system(size: max(6, centerIcon * 0.16)))
                .foregroundStyle(SVTheme.accent.opacity(0.4))
                .offset(x: size * 0.29, y: particleOffset2 - size * 0.16)

            Image(systemName: "sparkle")
                .font(.system(size: max(7, centerIcon * 0.24)))
                .foregroundStyle(SVTheme.accentLight.opacity(0.3))
                .offset(x: size * 0.08, y: particleOffset3 - size * 0.41)

            Image(systemName: "wand.and.stars")
                .font(.system(size: centerIcon, weight: .medium))
                .foregroundStyle(
                    LinearGradient(
                        colors: [SVTheme.accent, SVTheme.accentLight],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .scaleEffect(pulseScale)
        }
        .frame(width: size, height: size)
    }

    private func progressBar(width: CGFloat) -> some View {
        Capsule()
            .fill(SVTheme.surfaceLight)
            .frame(width: width, height: 4)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [SVTheme.accent, SVTheme.accentLight],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: appeared ? width : 0)
                    .animation(.easeInOut(duration: 30).repeatCount(1, autoreverses: false), value: appeared)
            }
            .clipShape(Capsule())
    }
}
