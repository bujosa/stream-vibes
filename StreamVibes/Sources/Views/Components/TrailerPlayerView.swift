import SwiftUI
import WebKit
import AVKit
import AppKit

struct TrailerPlayerView: View {
    let urlString: String
    var onPlaybackBlocked: (() -> Void)? = nil
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let videoID = Self.youtubeVideoID(from: urlString) {
                YouTubePlayerView(videoID: videoID, onPlaybackBlocked: onPlaybackBlocked)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else if let url = URL(string: urlString) {
                VideoPlayer(player: AVPlayer(url: url))
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            // YouTube can reject some in-app embeds (error 153); always provide fallback.
            if let url = URL(string: urlString) {
                Button {
                    openURL(url)
                } label: {
                    Label("Open trailer in browser", systemImage: "safari")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    static func youtubeVideoID(from urlString: String) -> String? {
        guard let url = URL(string: urlString),
              let host = url.host?.lowercased() else { return nil }

        if host.contains("youtube.com") {
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            if let v = components?.queryItems?.first(where: { $0.name == "v" })?.value, !v.isEmpty {
                return v
            }
            let parts = url.pathComponents.filter { $0 != "/" }
            if let shortsIndex = parts.firstIndex(of: "shorts"), parts.indices.contains(shortsIndex + 1) {
                return parts[shortsIndex + 1]
            }
            if let embedIndex = parts.firstIndex(of: "embed"), parts.indices.contains(embedIndex + 1) {
                return parts[embedIndex + 1]
            }
            return nil
        } else if host.contains("youtu.be") {
            let id = url.pathComponents.dropFirst().first
            return (id?.isEmpty == false) ? id : nil
        }
        return nil
    }
}

struct YouTubePlayerView: NSViewRepresentable {
    let videoID: String
    var onPlaybackBlocked: (() -> Void)?

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var onPlaybackBlocked: (() -> Void)?
        var hasReportedBlocked = false
        var lastLoadedVideoID: String?

        init(onPlaybackBlocked: (() -> Void)?) {
            self.onPlaybackBlocked = onPlaybackBlocked
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            inspectForPlaybackBlock(webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            reportBlockedOnce()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            reportBlockedOnce()
        }

        // Open popups/new-window requests (including some YouTube actions) in the default browser.
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
            }
            return nil
        }

        private func inspectForPlaybackBlock(_ webView: WKWebView) {
            let script = "document.body ? document.body.innerText : ''"
            webView.evaluateJavaScript(script) { [weak self] result, _ in
                guard let self, let bodyText = (result as? String)?.lowercased() else { return }
                let blockedSignals = [
                    "error 153",
                    "video player configuration error",
                    "watch video on youtube"
                ]
                if blockedSignals.contains(where: { bodyText.contains($0) }) {
                    self.reportBlockedOnce()
                }
            }
        }

        private func reportBlockedOnce() {
            guard !hasReportedBlocked else { return }
            hasReportedBlocked = true
            onPlaybackBlocked?()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPlaybackBlocked: onPlaybackBlocked)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.allowsAirPlayForMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsMagnification = true
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onPlaybackBlocked = onPlaybackBlocked
        guard context.coordinator.lastLoadedVideoID != videoID else { return }
        context.coordinator.lastLoadedVideoID = videoID
        context.coordinator.hasReportedBlocked = false

        guard let embedURL = URL(
            string: "https://www.youtube.com/embed/\(videoID)?autoplay=1&playsinline=1&rel=0&modestbranding=1&fs=1&enablejsapi=1&origin=https://streamvibes.app"
        ) else {
            return
        }
        let html = """
        <!doctype html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0">
          <style>
            html, body { margin: 0; background: #000; height: 100%; overflow: hidden; }
            .frame { position: fixed; inset: 0; width: 100vw; height: 100vh; border: 0; }
          </style>
        </head>
        <body>
          <iframe
            class="frame"
            src="\(embedURL.absoluteString)"
            title="YouTube trailer"
            allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share; fullscreen"
            allowfullscreen
            referrerpolicy="origin"
          ></iframe>
        </body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: URL(string: "https://streamvibes.app"))
    }
}

struct TrailerModalView: View {
    @Environment(\.openURL) private var openURL
    let urlString: String
    let title: String
    var onDismiss: () -> Void
    @State private var mode: PlaybackMode = .inApp
    @State private var hasAutoOpenedBrowser = false
    @State private var fallbackMessage: String?

    enum PlaybackMode {
        case inApp
        case browser
    }

    private var trailerURL: URL? {
        URL(string: urlString)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack {
                Text("Trailer · \(title)")
                    .font(.headline)
                    .foregroundStyle(SVTheme.textPrimary)

                Spacer()

                HStack(spacing: 8) {
                    Button("Play in app") { mode = .inApp }
                        .buttonStyle(.borderedProminent)
                        .tint(mode == .inApp ? SVTheme.accent : SVTheme.card)
                        .controlSize(.small)

                    Button("Open in Browser") {
                        mode = .browser
                        openInBrowser()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Button { onDismiss() } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(SVTheme.surface)

            if let fallbackMessage {
                Text(fallbackMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
            }

            // Player area — fills all remaining space
            if mode == .inApp {
                TrailerPlayerView(urlString: urlString) {
                    mode = .browser
                    fallbackMessage = "In-app player was blocked by YouTube. Opening in browser..."
                    if !hasAutoOpenedBrowser {
                        hasAutoOpenedBrowser = true
                        openInBrowser()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    Text("Opening trailer in browser gives the most reliable playback when YouTube blocks embeds.")
                        .font(.caption)
                        .foregroundStyle(SVTheme.textMuted)
                    Button {
                        openInBrowser()
                    } label: {
                        Label("Open trailer in browser", systemImage: "safari")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SVTheme.accent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
    }

    private func openInBrowser() {
        if let trailerURL {
            openURL(trailerURL)
        }
    }
}
