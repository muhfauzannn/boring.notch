// Idle cat eyes. See MOTION.md for the rig and timing rules.
import AppKit
import SwiftUI

enum IdleCatChoreography {
    static let period: Double = 24_000

    static let lookX: IdleMotionKeys = [
        .init(0, 0), .init(1300, 0), .init(1850, 2), .init(3400, 2), .init(4000, 0),
        .init(6500, 0), .init(7100, -2.1), .init(9200, -2.1), .init(9800, 0.4),
        .init(12_500, 0.4), .init(13_100, 1.6), .init(15_200, 1.6), .init(15_800, 0),
        .init(18_200, 0), .init(18_800, -0.9), .init(21_000, -0.9), .init(21_700, 0), .init(24_000, 0)
    ]
    static let lookY: IdleMotionKeys = [
        .init(0, 0), .init(1300, 0), .init(1850, -0.6), .init(3400, -0.6), .init(4000, 0),
        .init(12_500, 0), .init(13_100, 0.4), .init(15_200, 0.4), .init(15_800, 0), .init(24_000, 0)
    ]
    static let lid: IdleMotionKeys = [
        .init(0, 0), .init(3700, 0), .init(3810, 1), .init(3850, 1), .init(4040, 0, out: true),
        .init(7350, 0), .init(7460, 1), .init(7500, 1), .init(7690, 0, out: true),
        .init(7890, 0), .init(8000, 1), .init(8040, 1), .init(8230, 0, out: true),
        .init(12_350, 0), .init(12_460, 1), .init(12_500, 1), .init(12_690, 0, out: true),
        // One slower, sleepy cat blink, followed by a long comfortable hold.
        .init(16_250, 0), .init(16_550, 1), .init(16_650, 1), .init(17_100, 0, out: true),
        .init(21_250, 0), .init(21_360, 1), .init(21_400, 1), .init(21_590, 0, out: true), .init(24_000, 0)
    ]
    static let squint: IdleMotionKeys = [
        .init(0, 0), .init(13_700, 0), .init(14_350, 0.18), .init(15_050, 0.18), .init(15_700, 0), .init(24_000, 0)
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
            let eyeWidth = min(28, max(0, wingWidth - 8))
            let eyeHeight = min(17, max(0, size.height - 10))
            guard eyeWidth > 0, eyeHeight > 0 else { return }
            for side in [-1.0, 1.0] {
                let centerX = side < 0 ? wingWidth / 2 : size.width - wingWidth / 2
                let breathe = CGFloat(idleMotionWave(t, period: 6000)) * 0.25
                let centerY = size.height / 2 + breathe
                let blinkTime = max(0, t - (side > 0 ? 18 : 0))
                let openness = max(0, 1 - idleMotionTrack(blinkTime, IdleCatChoreography.lid)
                                    - idleMotionTrack(t, IdleCatChoreography.squint))
                drawEye(context, center: CGPoint(x: centerX, y: centerY), width: eyeWidth,
                        height: eyeHeight, side: CGFloat(side), openness: CGFloat(openness), time: t)
            }
        }
        .frame(width: notchWidth + 10 + wingWidth * 2)
        .accessibilityHidden(true)
    }

    private func drawEye(_ context: GraphicsContext, center: CGPoint, width: CGFloat, height: CGFloat,
                         side: CGFloat, openness: CGFloat, time: Double) {
        let left = CGPoint(x: center.x - width / 2, y: center.y + side * 0.35)
        let right = CGPoint(x: center.x + width / 2, y: center.y - side * 0.35)
        let closedCurve = center.y - height * 0.12
        let upperY = closedCurve - height * 0.48 * openness
        let lowerY = closedCurve + height * 0.68 * openness
        let controlX = width * 0.24
        var outline = Path()
        outline.move(to: left)
        outline.addCurve(to: right,
                         control1: CGPoint(x: left.x + controlX, y: upperY),
                         control2: CGPoint(x: right.x - controlX, y: upperY))
        outline.addCurve(to: left,
                         control1: CGPoint(x: right.x - controlX, y: lowerY),
                         control2: CGPoint(x: left.x + controlX, y: lowerY))
        outline.closeSubpath()

        let paleMint = Color(red: 0.79, green: 0.98, blue: 0.64)
        let leafGreen = Color(red: 0.46, green: 0.78, blue: 0.44)
        context.fill(outline, with: .linearGradient(Gradient(colors: [paleMint, leafGreen]),
            startPoint: CGPoint(x: center.x, y: center.y - height / 2),
            endPoint: CGPoint(x: center.x, y: center.y + height / 2)))

        context.drawLayer { eye in
            eye.clip(to: outline)
            let pupilX = center.x + CGFloat(idleMotionTrack(time, IdleCatChoreography.lookX))
            let pupilY = center.y + CGFloat(idleMotionTrack(time, IdleCatChoreography.lookY))
            let pupil = CGRect(x: pupilX - 1.8, y: pupilY - height, width: 3.6, height: height * 2)
            eye.fill(Path(roundedRect: pupil, cornerRadius: 1.8), with: .color(.black))
            let glint = CGRect(x: pupilX - 3.1, y: pupilY - 3.4, width: 2.4, height: 2.4)
            eye.fill(Path(ellipseIn: glint), with: .color(.white))
        }

        // The same upper curve becomes a soft closed-eye arc as its area approaches zero.
        // No swapping drawings or masked-out white rim around a shut eyelid.
        var lid = Path()
        lid.move(to: left)
        lid.addCurve(to: right,
                     control1: CGPoint(x: left.x + controlX, y: upperY),
                     control2: CGPoint(x: right.x - controlX, y: upperY))
        context.stroke(lid, with: .color(paleMint), style: StrokeStyle(lineWidth: 0.9, lineCap: .round))
    }
}

#Preview {
    IdleCatEyesView(notchWidth: 185, wingWidth: 38, height: 32)
        .background(.black)
        .padding()
}
