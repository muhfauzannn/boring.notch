//
//  ClipboardHistoryViewModel.swift
//  boringNotch
//
//  Watches the pasteboard and keeps the clipboard history.
//

import AppKit
import Combine
import Defaults
import SwiftUI

@MainActor
final class ClipboardHistoryViewModel: ObservableObject {
    static let shared = ClipboardHistoryViewModel()

    /// Most recent copy first.
    @Published private(set) var items: [ClipboardItem] = []
    @Published var filter: ClipboardFilter = .all
    /// The entry that's on the pasteboard right now.
    @Published private(set) var currentItemID: ClipboardItem.ID?
    /// Set for a moment after a card is clicked, for the "Copied" flash.
    @Published private(set) var justCopiedID: ClipboardItem.ID?

    private let storage = ClipboardStorageService.shared
    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var lastPrune = Date()
    private var saveTask: Task<Void, Never>?
    private var flashTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    private static let pollInterval: TimeInterval = 0.5

    var isEmpty: Bool { items.isEmpty }

    /// Recording only happens while the feature and the shelf are on and the user hasn't paused it.
    var isMonitoring: Bool { timer != nil }

    var visibleItems: [ClipboardItem] {
        items.filter { $0.matches(filter) }
    }

    func count(for filter: ClipboardFilter) -> Int {
        filter == .all ? items.count : items.filter { $0.matches(filter) }.count
    }

    private init() {
        if Defaults[.clipboardSaveToDisk] {
            items = storage.load()
        }
        prune()
        removeUnusedImages()

        Defaults.publisher(keys: .clipboardHistoryEnabled, .clipboardHistoryPaused, .boringShelf, options: [])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.updateMonitoring() }
            }
            .store(in: &cancellables)

        Defaults.publisher(keys: .clipboardHistoryLimit, .clipboardRetention, options: [])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.prune() }
            }
            .store(in: &cancellables)

        Defaults.publisher(.clipboardSaveToDisk, options: [])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                Task { @MainActor in
                    guard let self else { return }
                    if change.newValue {
                        self.scheduleSave()
                    } else {
                        self.storage.deleteSavedHistory()
                    }
                }
            }
            .store(in: &cancellables)

        // A copy made just before quitting may still be waiting on the save delay
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, Defaults[.clipboardSaveToDisk] else { return }
                    self.saveTask?.cancel()
                    self.storage.save(self.items, synchronously: true)
                }
            }
            .store(in: &cancellables)

        updateMonitoring()
    }

    // MARK: - Monitoring

    private func updateMonitoring() {
        let shouldMonitor = Defaults[.clipboardHistoryEnabled] && Defaults[.boringShelf] && !Defaults[.clipboardHistoryPaused]
        guard shouldMonitor != isMonitoring else { return }

        if shouldMonitor {
            // Whatever was copied while paused or off stays out of the history
            lastChangeCount = NSPasteboard.general.changeCount
            let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
            timer.tolerance = 0.2
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            timer?.invalidate()
            timer = nil
        }
        objectWillChange.send()
    }

    func setPaused(_ paused: Bool) {
        Defaults[.clipboardHistoryPaused] = paused
    }

    private func poll() {
        if Date().timeIntervalSince(lastPrune) > 60 * 60 {
            prune()
        }

        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount

        let source = NSWorkspace.shared.frontmostApplication
        if let bundleID = source?.bundleIdentifier,
           Defaults[.clipboardIgnoredApps].contains(where: { $0.bundleID == bundleID }) {
            return
        }

        let options = ClipboardCaptureOptions(
            captureImages: Defaults[.clipboardCaptureImages],
            captureFiles: Defaults[.clipboardCaptureFiles],
            ignorePrivateContent: Defaults[.clipboardIgnorePrivateContent]
        )
        guard let capture = ClipboardPasteboard.read(pasteboard, options: options) else { return }

        switch capture {
        case .content(let content):
            record(content, source: source)
        case .imageData(let data):
            let storage = storage
            Task {
                let stored = await Task.detached(priority: .userInitiated) {
                    storage.storeImage(data)
                }.value
                guard let stored else { return }
                self.record(.image(fileName: stored.fileName, pixelSize: stored.pixelSize), source: source)
            }
        }
    }

    private func record(_ content: ClipboardContent, source: NSRunningApplication?) {
        var item = ClipboardItem(
            content: content,
            sourceBundleID: source?.bundleIdentifier,
            sourceAppName: source?.localizedName
        )

        var updated = items
        // Copying the same thing again moves it to the front instead of adding a second card
        if let index = updated.firstIndex(where: { $0.identityKey == item.identityKey }) {
            var existing = updated.remove(at: index)
            existing.content = content
            existing.lastCopiedAt = item.lastCopiedAt
            existing.copyCount += 1
            existing.sourceBundleID = item.sourceBundleID ?? existing.sourceBundleID
            existing.sourceAppName = item.sourceAppName ?? existing.sourceAppName
            item = existing
        }
        updated.insert(item, at: 0)

        withAnimation(.smooth) {
            items = updated
            currentItemID = item.id
        }
        prune()
        scheduleSave()
    }

    // MARK: - Actions

    func copy(_ item: ClipboardItem, plainTextOnly: Bool = false) {
        lastChangeCount = ClipboardPasteboard.write(item, plainTextOnly: plainTextOnly)

        // Cards stay where they are, so the one just clicked doesn't jump away
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index].lastCopiedAt = Date()
            items[index].copyCount += 1
        }
        currentItemID = item.id
        scheduleSave()

        flashTask?.cancel()
        withAnimation(.smooth(duration: 0.2)) { justCopiedID = item.id }
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.3)) { self?.justCopiedID = nil }
        }
    }

    func togglePin(_ item: ClipboardItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        withAnimation(.smooth) {
            items[index].isPinned.toggle()
        }
        // An unpinned item past the limits goes with the next prune, not right under the pointer
        scheduleSave()
    }

    func delete(_ item: ClipboardItem) {
        withAnimation(.smooth) {
            items.removeAll { $0.id == item.id }
        }
        if currentItemID == item.id { currentItemID = nil }
        removeUnusedImages()
        scheduleSave()
    }

    /// Clears the history, keeping pinned items unless asked not to.
    func clear(includingPinned: Bool = false) {
        withAnimation(.smooth) {
            items.removeAll { includingPinned || !$0.isPinned }
        }
        if let current = currentItemID, !items.contains(where: { $0.id == current }) {
            currentItemID = nil
        }
        if filter != .all && visibleItems.isEmpty {
            filter = .all
        }
        removeUnusedImages()
        scheduleSave()
    }

    func addToShelf(_ item: ClipboardItem) {
        switch item.content {
        case .text(let string, _):
            ShelfStateViewModel.shared.add([ShelfItem(kind: .text(string: string))])
        case .link(let url):
            ShelfStateViewModel.shared.add([ShelfItem(kind: .link(url: url))])
        case .files(let urls):
            let shelfItems = urls.compactMap { url -> ShelfItem? in
                guard let bookmark = try? Bookmark(url: url) else { return nil }
                return ShelfItem(kind: .file(bookmark: bookmark.data))
            }
            ShelfStateViewModel.shared.add(shelfItems)
        case .image(let fileName, _):
            let url = storage.imageURL(for: fileName)
            Task {
                guard let data = try? Data(contentsOf: url),
                      let tempURL = await TemporaryFileStorageService.shared.createTempFile(
                          for: .data(data, suggestedName: "Clipboard Image.png")
                      ),
                      let bookmark = try? Bookmark(url: tempURL) else { return }
                ShelfStateViewModel.shared.add([ShelfItem(kind: .file(bookmark: bookmark.data), isTemporary: true)])
            }
        }
    }

    // MARK: - Limits and saving

    /// Drops unpinned items past the age and count limits. Pinned items are always kept.
    private func prune() {
        lastPrune = Date()
        var kept = items
        if let maxAge = Defaults[.clipboardRetention].interval {
            let cutoff = Date().addingTimeInterval(-maxAge)
            kept.removeAll { !$0.isPinned && $0.lastCopiedAt < cutoff }
        }

        let limit = max(1, Defaults[.clipboardHistoryLimit])
        var unpinned = 0
        kept = kept.filter { item in
            if item.isPinned { return true }
            unpinned += 1
            return unpinned <= limit
        }

        guard kept.count != items.count else { return }
        items = kept
        if let current = currentItemID, !items.contains(where: { $0.id == current }) {
            currentItemID = nil
        }
        removeUnusedImages()
        scheduleSave()
    }

    private func removeUnusedImages() {
        let inUse = Set(items.compactMap { item -> String? in
            if case .image(let fileName, _) = item.content { return fileName }
            return nil
        })
        storage.removeImages(notIn: inUse)
    }

    private func scheduleSave() {
        guard Defaults[.clipboardSaveToDisk] else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            self.storage.save(self.items)
        }
    }
}
