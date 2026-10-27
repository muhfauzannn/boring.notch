//
//  ClipboardHistoryView.swift
//  boringNotch
//
//  The Clipboard side of the shelf: a filter bar and a row of cards, newest first.
//

import AppKit
import Defaults
import SwiftUI

struct ClipboardHistoryView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var history = ClipboardHistoryViewModel.shared
    @Default(.clipboardHistoryPaused) var isPaused
    @Default(.clipboardCloseAfterCopy) var closeAfterCopy

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ClipboardToolbar()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.03))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if history.isEmpty {
            if isPaused {
                ClipboardEmptyState(
                    icon: "pause.circle",
                    title: "Clipboard history is paused",
                    subtitle: "New copies aren't being saved."
                ) {
                    Button("Resume") { history.setPaused(false) }
                        .buttonStyle(ClipboardPillButtonStyle(prominent: true))
                }
            } else {
                ClipboardEmptyState(
                    icon: "list.clipboard",
                    title: "Copy something to start",
                    subtitle: "Text, links, images and files you copy show up here."
                )
            }
        } else if history.visibleItems.isEmpty {
            ClipboardEmptyState(
                icon: history.filter.icon,
                title: history.filter == .pinned ? "No pinned items" : "Nothing here yet",
                subtitle: history.filter == .pinned ? "Right-click a card or hover it to pin it." : nil
            )
        } else {
            cards
        }
    }

    private var cards: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    ForEach(history.visibleItems) { item in
                        ClipboardCard(
                            item: item,
                            isCurrent: history.currentItemID == item.id,
                            isCopied: history.justCopiedID == item.id,
                            onCopy: { copy(item) }
                        )
                        .id(item.id)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                }
            }
            .scrollIndicators(.never)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            // A new copy lands at the front, so bring the front into view
            .onChange(of: history.items.first?.id) { _, id in
                guard let id else { return }
                withAnimation(.smooth) { proxy.scrollTo(id, anchor: .leading) }
            }
            .onChange(of: history.filter) {
                guard let id = history.visibleItems.first?.id else { return }
                proxy.scrollTo(id, anchor: .leading)
            }
        }
    }

    private func copy(_ item: ClipboardItem, plainTextOnly: Bool = false) {
        history.copy(item, plainTextOnly: plainTextOnly)
        guard closeAfterCopy else { return }
        // Long enough to see the "Copied" check
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            vm.close()
        }
    }
}

// MARK: - Toolbar

private struct ClipboardToolbar: View {
    @ObservedObject var history = ClipboardHistoryViewModel.shared
    @Default(.clipboardHistoryPaused) var isPaused
    @Namespace private var animation

    /// Kinds with nothing in them are hidden, unless selected.
    private var filters: [ClipboardFilter] {
        ClipboardFilter.allCases.filter { $0 == .all || $0 == history.filter || history.count(for: $0) > 0 }
    }

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                ForEach(filters) { filter in
                    chip(for: filter)
                }
            }
            .animation(.smooth, value: filters)

            Spacer(minLength: 4)

            if isPaused {
                Label("Paused", systemImage: "pause.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(Capsule().fill(Color.orange.opacity(0.15)))
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }

            ClipboardIconButton(
                icon: isPaused ? "play.fill" : "pause.fill",
                help: isPaused ? "Resume recording" : "Pause recording"
            ) {
                withAnimation(.smooth) { history.setPaused(!isPaused) }
            }

            Menu {
                Button("Clear History") { history.clear() }
                    .disabled(history.isEmpty)
                Button("Clear Including Pinned", role: .destructive) { history.clear(includingPinned: true) }
                    .disabled(history.count(for: .pinned) == 0)
                Divider()
                Button("Settings…") {
                    SettingsWindowController.shared.showWindow()
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 20)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.gray)
        }
        .frame(height: 22)
    }

    private func chip(for filter: ClipboardFilter) -> some View {
        let selected = history.filter == filter
        return Button {
            withAnimation(.smooth(duration: 0.25)) { history.filter = filter }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: filter.icon)
                    .font(.system(size: 9, weight: .semibold))
                Text(filter.title)
                if filter == .all {
                    Text("\(history.items.count)")
                        .monospacedDigit()
                        .foregroundStyle(selected ? Color.white.opacity(0.6) : Color.gray.opacity(0.7))
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(selected ? .white : .gray)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background {
                if selected {
                    Capsule()
                        .fill(Color(nsColor: .secondarySystemFill))
                        .matchedGeometryEffect(id: "clipboardFilter", in: animation)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Card

struct ClipboardCard: View {
    let item: ClipboardItem
    let isCurrent: Bool
    let isCopied: Bool
    let onCopy: () -> Void

    @ObservedObject private var history = ClipboardHistoryViewModel.shared
    @State private var hovering = false
    @State private var thumbnail: NSImage?

    private static let width: CGFloat = 136
    private let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    var body: some View {
        ZStack(alignment: .topLeading) {
            if case .image = item.content {
                imageBackground
            }
            VStack(alignment: .leading, spacing: 6) {
                header
                preview
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(8)
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(shape.fill(Color.white.opacity(hovering ? 0.1 : 0.06)))
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(
                isCurrent ? Color.accentColor.opacity(0.7) : Color.white.opacity(hovering ? 0.14 : 0.07),
                lineWidth: isCurrent ? 1.5 : 1
            )
        }
        .overlay {
            if isCopied {
                copiedOverlay
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(.smooth(duration: 0.18), value: hovering)
        .contentShape(shape)
        .onHover { hovering = $0 }
        .onTapGesture(perform: onCopy)
        .onDrag { ClipboardPasteboard.itemProvider(for: item) }
        .contextMenu { menuItems }
        .help(tooltip)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Copies this item")
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 5) {
            ClipboardSourceIcon(bundleID: item.sourceBundleID, fallback: kindIcon)
                .frame(width: 14, height: 14)
            Text(kindLabel)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isImage ? .white : .gray)
                .lineLimit(1)

            Spacer(minLength: 2)

            if hovering {
                HStack(spacing: 3) {
                    ClipboardIconButton(
                        icon: item.isPinned ? "pin.slash.fill" : "pin.fill",
                        help: item.isPinned ? "Unpin" : "Pin",
                        size: 18
                    ) {
                        history.togglePin(item)
                    }
                    ClipboardIconButton(icon: "xmark", help: "Delete", size: 18) {
                        history.delete(item)
                    }
                }
                .transition(.opacity)
            } else {
                if item.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                        .rotationEffect(.degrees(30))
                }
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(Self.shortAge(from: item.lastCopiedAt, to: context.date))
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(isImage ? Color.white.opacity(0.8) : Color.gray.opacity(0.8))
                }
            }
        }
        .frame(height: 18)
        .shadow(color: isImage ? .black.opacity(0.5) : .clear, radius: 2)
    }

    // MARK: Previews

    @ViewBuilder
    private var preview: some View {
        switch item.content {
        case .text(let string, _):
            if let color = item.hexColor {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(color)
                        .frame(width: 30, height: 30)
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(.white.opacity(0.2), lineWidth: 1)
                        }
                    Text(string.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                }
            } else {
                Text(Self.previewText(string))
                    .font(Self.looksLikeCode(string)
                          ? .system(size: 10.5, design: .monospaced)
                          : .system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
            }
        case .link(let url):
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: "globe")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Text(Self.host(of: url))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                Text(Self.pathAndQuery(of: url))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.gray)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        case .image(_, let size):
            VStack {
                Spacer(minLength: 0)
                Text("\(Int(size.width)) × \(Int(size.height))")
                    .font(.system(size: 9.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.black.opacity(0.55)))
            }
        case .files(let urls):
            HStack(alignment: .top, spacing: 6) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: urls.first?.path ?? ""))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(urls.first?.lastPathComponent ?? "")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(2)
                        .truncationMode(.middle)
                    if urls.count > 1 {
                        Text("+\(urls.count - 1) more")
                            .font(.system(size: 10))
                            .foregroundStyle(.gray)
                    }
                }
            }
        }
    }

    private var imageBackground: some View {
        ZStack(alignment: .top) {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: Self.width)
                    .frame(maxHeight: .infinity)
                    .clipped()
            } else {
                Color.white.opacity(0.04)
                Image(systemName: "photo")
                    .font(.system(size: 20))
                    .foregroundStyle(.gray)
                    .frame(maxHeight: .infinity)
            }
            // Keeps the header readable on light images
            LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 34)
        }
        .task(id: item.id) {
            guard case .image(let fileName, _) = item.content else { return }
            if let cached = ClipboardThumbnailCache.cached(fileName) {
                thumbnail = cached
            } else {
                let image = await ClipboardThumbnailCache.thumbnail(for: fileName)
                withAnimation(.easeOut(duration: 0.2)) { thumbnail = image }
            }
        }
    }

    private var copiedOverlay: some View {
        shape
            .fill(.black.opacity(0.6))
            .overlay {
                VStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .symbolEffect(.bounce, value: isCopied)
                    Text("Copied")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
    }

    // MARK: Context menu

    @ViewBuilder
    private var menuItems: some View {
        Button("Copy") { onCopy() }
        if item.hasRichText {
            Button("Copy as Plain Text") { history.copy(item, plainTextOnly: true) }
        }
        Button(item.isPinned ? "Unpin" : "Pin") { history.togglePin(item) }
        Button("Add to Shelf") { history.addToShelf(item) }

        switch item.content {
        case .link(let url):
            Button("Open Link") { NSWorkspace.shared.open(url) }
        case .files(let urls):
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        case .image(let fileName, _):
            Button("Open Image") {
                NSWorkspace.shared.open(ClipboardStorageService.shared.imageURL(for: fileName))
            }
        case .text:
            EmptyView()
        }

        Divider()
        Button("Delete", role: .destructive) { history.delete(item) }
    }

    // MARK: Helpers

    private var isImage: Bool {
        if case .image = item.content { return true }
        return false
    }

    private var kindIcon: String {
        switch item.content {
        case .text: return item.hexColor != nil ? "paintpalette" : "text.alignleft"
        case .link: return "link"
        case .image: return "photo"
        case .files: return "doc"
        }
    }

    private var kindLabel: LocalizedStringKey {
        switch item.content {
        case .text: return item.hexColor != nil ? "Color" : "Text"
        case .link: return "Link"
        case .image: return "Image"
        case .files(let urls): return urls.count == 1 ? "File" : "\(urls.count) Files"
        }
    }

    private var tooltip: String {
        var lines: [String] = []
        if let text = item.plainText {
            lines.append(String(text.prefix(400)))
        }
        if let app = item.sourceAppName {
            lines.append(String(localized: "Copied from \(app)"))
        }
        if item.copyCount > 1 {
            lines.append(String(localized: "Copied \(item.copyCount) times"))
        }
        return lines.joined(separator: "\n")
    }

    /// Drops the indentation shared by every line, so indented code doesn't start halfway across the card.
    private static func previewText(_ string: String) -> String {
        let lines = string.trimmingCharacters(in: .newlines).components(separatedBy: .newlines).prefix(8)
        let indents = lines
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix(while: { $0 == " " || $0 == "\t" }).count }
        let shared = indents.min() ?? 0
        return lines.map { String($0.dropFirst(min(shared, $0.count))) }.joined(separator: "\n")
    }

    private static func looksLikeCode(_ string: String) -> Bool {
        guard string.contains("\n") else { return false }
        let markers = ["{", "};", "=>", "</", "func ", "def ", "import ", "const ", "let "]
        return markers.contains { string.contains($0) }
    }

    private static func host(of url: URL) -> String {
        let host = url.host ?? url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private static func pathAndQuery(of url: URL) -> String {
        var rest = url.path
        if let query = url.query { rest += "?" + query }
        return rest.isEmpty || rest == "/" ? url.absoluteString : rest
    }

    /// "now", "5m", "3h", "2d"
    private static func shortAge(from date: Date, to now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return String(localized: "now")
        case ..<3600: return String(localized: "\(Int(seconds / 60))m")
        case ..<86400: return String(localized: "\(Int(seconds / 3600))h")
        default: return String(localized: "\(Int(seconds / 86400))d")
        }
    }
}

// MARK: - Shelf mode switch

/// The small rail on the left of the shelf that switches between files and clipboard history.
struct ShelfModePicker: View {
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Namespace private var animation

    var body: some View {
        VStack(spacing: 4) {
            ForEach(ShelfMode.allCases, id: \.self) { mode in
                let selected = coordinator.shelfMode == mode
                Button {
                    withAnimation(.smooth) { coordinator.shelfMode = mode }
                } label: {
                    Image(systemName: mode.icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(selected ? .white : .gray)
                        .frame(width: 30, height: 30)
                        .background {
                            if selected {
                                Circle()
                                    .fill(Color(nsColor: .secondarySystemFill))
                                    .matchedGeometryEffect(id: "shelfMode", in: animation)
                            }
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(mode.title)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.white.opacity(0.05)))
        .frame(maxHeight: .infinity)
    }
}

extension ShelfMode {
    var icon: String {
        switch self {
        case .files: return "tray.fill"
        case .clipboard: return "list.clipboard.fill"
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .files: return "Files"
        case .clipboard: return "Clipboard"
        }
    }
}

// MARK: - Small pieces

private struct ClipboardEmptyState<Accessory: View>: View {
    let icon: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey?
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .symbolVariant(.fill)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white, .gray)
                .imageScale(.large)
            Text(title)
                .foregroundStyle(.gray)
                .font(.system(.body, design: .rounded))
                .fontWeight(.medium)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.gray.opacity(0.7))
            }
            accessory()
        }
        .multilineTextAlignment(.center)
    }
}

extension ClipboardEmptyState where Accessory == EmptyView {
    init(icon: String, title: LocalizedStringKey, subtitle: LocalizedStringKey?) {
        self.init(icon: icon, title: title, subtitle: subtitle) { EmptyView() }
    }
}

private struct ClipboardIconButton: View {
    let icon: String
    let help: LocalizedStringKey
    var size: CGFloat = 22
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.45, weight: .bold))
                .foregroundStyle(hovering ? .white : .gray)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.black.opacity(hovering ? 0.55 : 0.35)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

private struct ClipboardPillButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(prominent ? .white : .gray)
            .padding(.horizontal, 12)
            .frame(height: 22)
            .background(Capsule().fill(prominent ? Color.accentColor : Color.white.opacity(0.1)))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// The icon of the app something was copied from, or a symbol for the kind of item.
private struct ClipboardSourceIcon: View {
    let bundleID: String?
    let fallback: String

    @MainActor private static var cache: [String: NSImage] = [:]

    var body: some View {
        if let icon = Self.icon(for: bundleID) {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: fallback)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.gray)
        }
    }

    @MainActor
    private static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = cache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = icon
        return icon
    }
}
