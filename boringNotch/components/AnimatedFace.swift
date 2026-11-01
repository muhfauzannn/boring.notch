// Minimal, rounded bot eyes. See MOTION.md for the timing rules.
import AppKit
import SwiftUI

enum IdleCatChoreography {
    static let period: Double = 12_000

    static let lookX: IdleMotionKeys = [
        .init(0, 0), .init(1400, 0), .init(2000, 0.8), .init(3300, 0.8), .init(3900, 0),
        .init(6500, 0), .init(7100, -0.8), .init(8400, -0.8), .init(9000, 0), .init(12_000, 0)
    ]
    static let lid: IdleMotionKeys = [
        .init(0, 0), .init(3400, 0), .init(3510, 1), .init(3550, 1), .init(3740, 0, out: true),
        .init(7700, 0), .init(7810, 1), .init(7850, 1), .init(8040, 0, out: true),
        .init(11_250, 0), .init(11_360, 1), .init(11_400, 1), .init(11_590, 0, out: true), .init(12_000, 0)
    ]
}

struct IdleCatEyesView: View {
    let notchWidth: CGFloat
    let wingWidth: CGFloat
    let height: CGFloat
    @State private var isVisible = false
    @State private var screenAwake = true
    @State private var sessionActive = true

    var body: some View {
        IdleLoopClock(period: IdleCatChoreography.period, paused: !isVisible || !screenAwake || !sessionActive) { time in
            IdleCatEyesArtwork(time: time, notchWidth: notchWidth, wingWidth: wingWidth)
        }
        .frame(width: notchWidth + 10 + wingWidth * 2, height: height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.screensDidSleepNotification)) { _ in
            screenAwake = false
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.screensDidWakeNotification)) { _ in
            screenAwake = true
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidResignActiveNotification)) { _ in
            sessionActive = false
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidBecomeActiveNotification)) { _ in
            sessionActive = true
        }
    }
}

/// A deterministic frame, also used to inspect blinks and loop seams offline.
struct IdleCatEyesArtwork: View {
    let time: Double
    let notchWidth: CGFloat
    let wingWidth: CGFloat

    var body: some View {
        Canvas { context, size in
            let t = max(0, time).truncatingRemainder(dividingBy: IdleCatChoreography.period)
            let eyeWidth = min(8, max(0, wingWidth - 12))
            let eyeHeight = min(13, max(0, size.height - 12))
            guard eyeWidth > 0, eyeHeight > 0 else { return }
            let openness = CGFloat(max(0, 1 - idleMotionTrack(t, IdleCatChoreography.lid)))
            let glance = CGFloat(idleMotionTrack(t, IdleCatChoreography.lookX))
            for side in [-1.0, 1.0] {
                let centerX = side < 0 ? wingWidth / 2 : size.width - wingWidth / 2
                let width = eyeWidth + (1 - openness) * 2
                let height = min(2, eyeHeight) + max(0, eyeHeight - 2) * openness
                let eye = CGRect(x: centerX + glance - width / 2, y: (size.height - height) / 2,
                                 width: width, height: height)
                context.fill(Path(roundedRect: eye, cornerRadius: min(width, height) / 2), with: .color(.white))
            }
        }
        .frame(width: notchWidth + 10 + wingWidth * 2)
        .accessibilityHidden(true)
    }

}

#Preview {
    IdleCatEyesView(notchWidth: 185, wingWidth: 38, height: 32)
        .background(.black)
        .padding()
}
