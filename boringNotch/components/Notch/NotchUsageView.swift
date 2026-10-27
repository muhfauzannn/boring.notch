//
//  NotchUsageView.swift
//  boringNotch
//
//  The Usage tab: Claude and ChatGPT plan usage, plus the closed-notch warning.
//

import Defaults
import SwiftUI

struct NotchUsageView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var usageManager = AIUsageManager.shared

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(usageManager.enabledServices) { service in
                UsageCard(service: service, state: usageManager.state(for: service))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 2)
        .transition(.opacity)
        .blur(radius: vm.notchState == .closed ? 30 : 0)
        .task {
            await usageManager.refresh()
        }
    }
}

struct AIServiceLogo: View {
    let service: AIService
    var size: CGFloat = 12
    var color: Color = .white

    var body: some View {
        Image(service.logoAsset)
            .renderingMode(service == .chatgpt ? .template : .original)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .foregroundStyle(color)
            .frame(width: size, height: size)
    }
}

struct UsageCard: View {
    let service: AIService
    let state: UsageState

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            switch state {
            case .loaded(let snapshot):
                ForEach(Array(snapshot.windows.prefix(2).enumerated()), id: \.offset) { _, window in
                    UsageWindowRow(window: window, tint: service.tint)
                }
            case .failed(let message):
                statusText(message)
            case .idle, .loading:
                statusText("Loading usage…")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: MusicPlayerImageSizes.cornerRadiusInset.opened).fill(.white.opacity(0.05)))
    }

    private var header: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 6)
                .fill(service == .claude ? service.tint.opacity(0.16) : Color(nsColor: .secondarySystemFill))
                .frame(width: 20, height: 20)
                .overlay { AIServiceLogo(service: service, size: service == .claude ? 13 : 12) }
            Text(service.displayName)
                .font(.headline)
                .foregroundStyle(.white)
            Spacer(minLength: 4)
            if case .loaded(let snapshot) = state {
                if let plan = snapshot.plan {
                    Text(plan)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.gray)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color(nsColor: .secondarySystemFill)))
                }
            }
        }
    }

    private func statusText(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.gray)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
    }
}

struct UsageWindowRow: View {
    let window: UsageWindow
    let tint: Color
    @Default(.aiUsageWarnThreshold) private var warnAt

    private var barColor: Color {
        if window.usedPercent >= 95 { return .red }
        if window.usedPercent >= warnAt { return .yellow }
        return tint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(window.label)
                    .foregroundStyle(.gray)
                    .fontWeight(.medium)
                Spacer()
                Text("\(Int(window.usedPercent.rounded()))%")
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(window.usedPercent >= warnAt ? barColor : .white)
            }
            .font(.subheadline)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.14))
                    Capsule().fill(barColor)
                        .frame(width: max(6, geo.size.width * window.usedPercent / 100))
                }
            }
            .frame(height: 6)

            if let resetsAt = window.resetsAt {
                Text(resetText(resetsAt))
                    .font(.caption2)
                    .foregroundStyle(.gray)
            }
        }
        .animation(.smooth, value: window.usedPercent)
    }

    private func resetText(_ date: Date) -> String {
        let seconds = date.timeIntervalSinceNow
        guard seconds > 0 else { return "Resetting now" }
        if seconds < 24 * 3600 {
            let hours = Int(seconds) / 3600
            let minutes = (Int(seconds) % 3600) / 60
            return hours > 0 ? "Resets in \(hours)h \(minutes)m" : "Resets in \(minutes)m"
        }
        return "Resets " + date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

/// Closed-notch warning shown when a usage window crosses the threshold, styled like the battery notification.
struct AIUsageWarningView: View {
    @ObservedObject var usageManager = AIUsageManager.shared
    let closedNotchWidth: CGFloat

    var body: some View {
        if let service = usageManager.warningService, let window = usageManager.warningWindow {
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    AIServiceLogo(service: service, size: 14)
                    Text("\(service.displayName) \(Int(window.usedPercent.rounded()))%")
                        .font(.subheadline)
                        .foregroundStyle(.white)
                }
                .frame(width: 120, alignment: .leading)

                Rectangle()
                    .fill(.black)
                    .frame(width: closedNotchWidth + 10)

                HStack(spacing: 6) {
                    if let resetsAt = window.resetsAt {
                        Text(resetsAt, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.gray)
                            .lineLimit(1)
                    }
                    UsageRing(percent: window.usedPercent, color: window.usedPercent >= 95 ? .red : .yellow)
                        .frame(width: 18, height: 18)
                }
                .frame(width: 120, alignment: .trailing)
            }
        }
    }
}

struct UsageRing: View {
    let percent: Double
    let color: Color

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.16), lineWidth: 3)
            Circle()
                .trim(from: 0, to: percent / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

#Preview {
    HStack(spacing: 12) {
        UsageCard(service: .claude, state: .loaded(UsageSnapshot(
            plan: "Max",
            windows: [
                UsageWindow(label: "5-hour", usedPercent: 62, resetsAt: Date().addingTimeInterval(8040)),
                UsageWindow(label: "Weekly", usedPercent: 41, resetsAt: Date().addingTimeInterval(260_000))
            ],
            updatedAt: Date())))
        UsageCard(service: .chatgpt, state: .loaded(UsageSnapshot(
            plan: "Plus",
            windows: [
                UsageWindow(label: "5-hour", usedPercent: 23, resetsAt: Date().addingTimeInterval(14_520)),
                UsageWindow(label: "Weekly", usedPercent: 88, resetsAt: Date().addingTimeInterval(400_000))
            ],
            updatedAt: Date())))
    }
    .padding()
    .frame(width: 600)
    .background(.black)
}
