//
//  LyricsView.swift
//  boringNotch
//
//  Synced lyrics for the open notch and the one-line strip under the closed notch.
//

import Defaults
import SwiftUI

// MARK: - Lyrics tab

/// The Lyrics tab: a compact now-playing column next to the synced lyrics,
/// so the Home tab keeps its player, calendar and camera untouched.
struct NotchLyricsView: View {
    @ObservedObject private var musicManager = MusicManager.shared
    @Default(.playerColorTinting) private var playerColorTinting

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    musicManager.openMusicApp()
                } label: {
                    Image(nsImage: musicManager.albumArt)
                        .resizable()
                        .aspectRatio(1, contentMode: .fill)
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: MusicPlayerImageSizes.cornerRadiusInset.opened))
                        .scaleEffect(musicManager.isPlaying ? 1 : 0.9)
                        .animation(.smooth, value: musicManager.isPlaying)
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.bottom, 2)

                Text(musicManager.songTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(musicManager.artistName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(
                        playerColorTinting
                            ? Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.6)
                            : .gray
                    )
                    .lineLimit(1)

                HStack(spacing: 0) {
                    HoverButton(icon: "backward.fill", scale: .small) {
                        musicManager.previousTrack()
                    }
                    HoverButton(icon: musicManager.isPlaying ? "pause.fill" : "play.fill", scale: .small) {
                        musicManager.togglePlay()
                    }
                    HoverButton(icon: "forward.fill", scale: .small) {
                        musicManager.nextTrack()
                    }
                }
                .padding(.leading, -6)
            }
            .frame(width: 130, alignment: .leading)

            LyricsPanelView()
                .frame(maxWidth: .infinity)
        }
        .padding(.top, 2)
        // Fill the tab area exactly like Home does, so the header doesn't shift when switching tabs
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }
}

// MARK: - Lyrics panel

struct LyricsPanelView: View {
    @ObservedObject private var musicManager = MusicManager.shared

    var body: some View {
        ZStack {
            content
                .id(musicManager.lyricsTrackKey + (musicManager.isFetchingLyrics ? "-loading" : ""))
                .transition(.blurReplace)
        }
        .animation(.easeInOut(duration: 0.35), value: musicManager.lyricsTrackKey)
        .animation(.easeInOut(duration: 0.35), value: musicManager.isFetchingLyrics)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    @ViewBuilder
    private var content: some View {
        if musicManager.isFetchingLyrics {
            LyricsMessageView(icon: "text.quote", text: "Loading lyrics…")
        } else if !musicManager.syncedLyrics.isEmpty {
            SyncedLyricsScroller(lines: musicManager.syncedLyrics)
        } else if musicManager.isInstrumentalTrack {
            LyricsMessageView(icon: "music.note", text: "Instrumental")
        } else if !musicManager.currentLyrics.isEmpty {
            PlainLyricsView(text: musicManager.currentLyrics)
        } else {
            LyricsMessageView(icon: "text.quote", text: "No lyrics for this track")
        }
    }
}

private struct LyricsMessageView: View {
    let icon: String
    let text: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title2)
            Text(text)
                .font(.subheadline)
        }
        .foregroundStyle(.gray)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PlainLyricsView: View {
    let text: String

    var body: some View {
        ScrollView(.vertical) {
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
        }
        .scrollIndicators(.never)
        .mask(LyricsEdgeFade())
    }
}

private struct LyricsEdgeFade: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.2),
                .init(color: .black, location: 0.8),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

// MARK: - Synced scroller

private struct LyricHeightsKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// A hand-placed stack instead of a ScrollView, so every line gets its own spring,
/// delay, scale, opacity and blur based on its distance from the current line.
struct SyncedLyricsScroller: View {
    let lines: [LyricLine]

    @ObservedObject private var musicManager = MusicManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var heights: [Int: CGFloat] = [:]
    // Start on the current line so opening the tab doesn't scroll in from the top
    @State private var shownIndex: Int = MusicManager.shared.currentLyricIndex ?? 0
    @State private var jump: Int = 1
    @State private var hoveredID: Int?

    private let font = Font.system(size: 20, weight: .bold)
    private let spacing: CGFloat = 10
    private let window = 4
    private let scales: [CGFloat] = [1, 0.8, 0.77, 0.75, 0.74]
    private let opacities: [Double] = [1, 0.55, 0.28, 0.12, 0]
    private let blurs: [CGFloat] = [0, 1.2, 2.4, 3.6, 5]

    var body: some View {
        let active = min(shownIndex, max(lines.count - 1, 0))

        GeometryReader { geo in
            ZStack(alignment: .leading) {
                ForEach(visibleIndices(around: active), id: \.self) { index in
                    lineView(lines[index], distance: index - active, width: geo.size.width)
                        .offset(y: yOffset(for: index, active: active))
                        .animation(animation(forDistance: index - active), value: active)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .mask(LyricsEdgeFade())
        // Hidden until the lines are measured, then faded in, so they don't jump into place
        .opacity(heights.isEmpty ? 0 : 1)
        .animation(.easeOut(duration: 0.25), value: heights.isEmpty)
        .onPreferenceChange(LyricHeightsKey.self) { newHeights in
            // Measurements are layout, not motion: never animate them (e.g. inside a tab switch)
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                heights = newHeights
            }
        }
        .onAppear {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                shownIndex = musicManager.currentLyricIndex ?? 0
            }
        }
        .onChange(of: musicManager.currentLyricIndex) { _, newValue in
            let target = newValue ?? 0
            jump = abs(target - shownIndex)
            shownIndex = target
        }
    }

    private func visibleIndices(around active: Int) -> [Int] {
        guard !lines.isEmpty else { return [] }
        return Array(max(0, active - window)...min(lines.count - 1, active + window))
    }

    @ViewBuilder
    private func lineView(_ line: LyricLine, distance: Int, width: CGFloat) -> some View {
        let level = min(abs(distance), window)
        let isHovered = hoveredID == line.id
        // Lines already sung are a little dimmer than upcoming ones
        let baseOpacity = opacities[level] * (distance < 0 ? 0.75 : 1)

        Button {
            musicManager.seek(to: line.start + 0.01)
        } label: {
            Group {
                if line.isInterlude {
                    InterludeDots(isActive: distance == 0)
                } else if distance == 0 {
                    KaraokeLyricText(line: line, font: font)
                } else {
                    Text(line.text)
                        .font(font)
                        .foregroundStyle(.white)
                }
            }
            .frame(width: width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: LyricHeightsKey.self, value: [line.id: proxy.size.height])
                }
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .scaleEffect(scales[level], anchor: .leading)
        .opacity(isHovered ? max(baseOpacity, 0.85) : baseOpacity)
        .blur(radius: (isHovered || reduceMotion) ? 0 : blurs[level])
        .onHover { hovering in
            if hovering {
                hoveredID = line.id
            } else if hoveredID == line.id {
                hoveredID = nil
            }
        }
        // Far lines are offset outside the panel; keep them from catching clicks over the header
        .allowsHitTesting(abs(distance) <= 1)
        .accessibilityLabel(line.isInterlude ? "Instrumental break" : line.text)
    }

    private func scaledHeight(_ index: Int, active: Int) -> CGFloat {
        let level = min(abs(index - active), window)
        return (heights[index] ?? 26) * scales[level]
    }

    /// Vertical distance of a line's centre from the current line's centre.
    private func yOffset(for index: Int, active: Int) -> CGFloat {
        var y: CGFloat = 0
        if index > active {
            for k in active..<index {
                y += scaledHeight(k, active: active) / 2 + spacing + scaledHeight(k + 1, active: active) / 2
            }
        } else if index < active {
            for k in stride(from: active, to: index, by: -1) {
                y -= scaledHeight(k, active: active) / 2 + spacing + scaledHeight(k - 1, active: active) / 2
            }
        }
        return y
    }

    private func animation(forDistance distance: Int) -> Animation {
        if reduceMotion {
            return .easeInOut(duration: 0.25)
        }
        // A seek should settle at once instead of looking like a list scrolling past
        if jump > 2 {
            return .smooth(duration: 0.35)
        }
        // The current line and those above move at once; lines below trail by 25 ms each
        return .spring(response: 0.42, dampingFraction: 0.82)
            .delay(Double(max(0, distance)) * 0.025)
    }
}

// MARK: - Shared pieces

/// The current line, filling from left to right as it is sung.
struct KaraokeLyricText: View {
    let line: LyricLine
    let font: Font
    var alignment: TextAlignment = .leading

    @ObservedObject private var musicManager = MusicManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            text.foregroundStyle(.white)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !musicManager.isPlaying)) { context in
                let progress = line.progress(at: musicManager.lyricsPosition(at: context.date))
                let lead = min(max(progress - 0.04, 0), 1)
                let trail = min(max(progress + 0.04, lead), 1)

                text
                    .foregroundStyle(.white.opacity(0.45))
                    .overlay {
                        text
                            .foregroundStyle(.white)
                            .mask {
                                LinearGradient(
                                    stops: [
                                        .init(color: .white, location: lead),
                                        .init(color: .clear, location: trail),
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            }
                    }
            }
        }
    }

    private var text: some View {
        Text(line.text)
            .font(font)
            .multilineTextAlignment(alignment)
    }
}

/// Three breathing dots shown during an instrumental break.
struct InterludeDots: View {
    var isActive: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActive)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { dot in
                    let wave = (sin(time * 2 * .pi / 2.4 - Double(dot) * 0.6) + 1) / 2
                    Circle()
                        .fill(.white)
                        .frame(width: 7, height: 7)
                        .scaleEffect(isActive ? 0.9 + 0.22 * wave : 0.9)
                        .opacity(isActive ? 0.55 + 0.45 * wave : 0.6)
                }
            }
            .frame(height: 24, alignment: .leading)
        }
    }
}

// MARK: - Closed notch strip

private struct LyricLineChangeModifier: ViewModifier {
    let offset: CGFloat
    let blur: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .offset(y: offset)
            .blur(radius: blur)
            .opacity(opacity)
    }
}

extension AnyTransition {
    /// The old line lifts and blurs away while the new one rises into focus.
    static var lyricLineChange: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: LyricLineChangeModifier(offset: 10, blur: 4, opacity: 0),
                identity: LyricLineChangeModifier(offset: 0, blur: 0, opacity: 1)
            ),
            removal: .modifier(
                active: LyricLineChangeModifier(offset: -10, blur: 4, opacity: 0),
                identity: LyricLineChangeModifier(offset: 0, blur: 0, opacity: 1)
            )
        )
    }
}

struct ClosedLyricsStrip: View {
    let line: LyricLine
    let width: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            KaraokeLyricText(line: line, font: .system(size: 12, weight: .semibold), alignment: .center)
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.85)
                .id(line.id)
                .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.lyricLineChange)
        }
        .frame(width: max(0, width), height: 18)
        .padding(.bottom, 6)
    }
}

// MARK: - Toolbar button

/// Jumps to the Lyrics tab (turning it on if needed).
struct LyricsToggleButton: View {
    @Default(.showLyricsPanel) private var showLyricsPanel

    var body: some View {
        HoverButton(icon: "quote.bubble", scale: .medium) {
            showLyricsPanel = true
            withAnimation(.smooth) {
                BoringViewCoordinator.shared.currentView = .lyrics
            }
        }
    }
}
