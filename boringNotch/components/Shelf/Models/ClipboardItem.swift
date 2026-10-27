//
//  ClipboardItem.swift
//  boringNotch
//
//  One entry in the clipboard history, plus the small types around it.
//

import AppKit
import Defaults
import Foundation
import SwiftUI

enum ClipboardContent: Codable, Equatable, Sendable {
    /// Plain text, with the RTF version kept when it's small so formatting survives a re-copy.
    case text(String, rtf: Data?)
    case link(URL)
    /// A PNG in the history's image folder, named by its hash.
    case image(fileName: String, pixelSize: CGSize)
    case files([URL])
}

struct ClipboardItem: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var content: ClipboardContent
    var firstCopiedAt: Date
    var lastCopiedAt: Date
    var copyCount: Int
    var isPinned: Bool
    var sourceBundleID: String?
    var sourceAppName: String?

    init(
        id: UUID = UUID(),
        content: ClipboardContent,
        date: Date = Date(),
        sourceBundleID: String? = nil,
        sourceAppName: String? = nil
    ) {
        self.id = id
        self.content = content
        self.firstCopiedAt = date
        self.lastCopiedAt = date
        self.copyCount = 1
        self.isPinned = false
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
    }

    /// Two copies with the same key are the same entry.
    var identityKey: String {
        switch content {
        case .text(let string, _):
            return "text:" + string
        case .link(let url):
            return "link:" + url.absoluteString
        case .image(let fileName, _):
            return "image:" + fileName
        case .files(let urls):
            return "files:" + urls.map(\.standardizedFileURL.path).joined(separator: "\n")
        }
    }

    /// What "Copy as plain text" puts on the pasteboard.
    var plainText: String? {
        switch content {
        case .text(let string, _):
            return string
        case .link(let url):
            return url.absoluteString
        case .files(let urls):
            return urls.map(\.path).joined(separator: "\n")
        case .image:
            return nil
        }
    }

    var hasRichText: Bool {
        if case .text(_, let rtf) = content { return rtf != nil }
        return false
    }

    /// A "#RGB" or "#RRGGBB" string gets a swatch.
    var hexColor: Color? {
        guard case .text(let string, _) = content else { return nil }
        return Self.color(fromHex: string.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func matches(_ filter: ClipboardFilter) -> Bool {
        switch filter {
        case .all: return true
        case .pinned: return isPinned
        case .text: if case .text = content { return true }
        case .links: if case .link = content { return true }
        case .images: if case .image = content { return true }
        case .files: if case .files = content { return true }
        }
        return false
    }

    private static func color(fromHex string: String) -> Color? {
        guard string.hasPrefix("#") else { return nil }
        var hex = String(string.dropFirst())
        guard hex.count == 3 || hex.count == 6,
              hex.allSatisfy(\.isHexDigit) else { return nil }
        if hex.count == 3 {
            hex = hex.map { "\($0)\($0)" }.joined()
        }
        guard let value = UInt32(hex, radix: 16) else { return nil }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

enum ClipboardFilter: String, CaseIterable, Identifiable {
    case all
    case pinned
    case text
    case links
    case images
    case files

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .all: return "All"
        case .pinned: return "Pinned"
        case .text: return "Text"
        case .links: return "Links"
        case .images: return "Images"
        case .files: return "Files"
        }
    }

    var icon: String {
        switch self {
        case .all: return "square.stack"
        case .pinned: return "pin.fill"
        case .text: return "text.alignleft"
        case .links: return "link"
        case .images: return "photo"
        case .files: return "doc"
        }
    }
}

enum ClipboardRetention: String, CaseIterable, Identifiable, Defaults.Serializable {
    case day
    case week
    case month
    case forever

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .day: return "1 day"
        case .week: return "7 days"
        case .month: return "30 days"
        case .forever: return "Forever"
        }
    }

    var interval: TimeInterval? {
        switch self {
        case .day: return 24 * 60 * 60
        case .week: return 7 * 24 * 60 * 60
        case .month: return 30 * 24 * 60 * 60
        case .forever: return nil
        }
    }
}

/// An app whose copies are never recorded.
struct ClipboardIgnoredApp: Codable, Hashable, Identifiable, Defaults.Serializable {
    var bundleID: String
    var name: String

    var id: String { bundleID }

    /// Password managers and the keychain, so secrets stay out of the history by default.
    static let defaults: [ClipboardIgnoredApp] = [
        .init(bundleID: "com.1password.1password", name: "1Password"),
        .init(bundleID: "com.agilebits.onepassword7", name: "1Password 7"),
        .init(bundleID: "com.bitwarden.desktop", name: "Bitwarden"),
        .init(bundleID: "com.apple.keychainaccess", name: "Keychain Access"),
        .init(bundleID: "com.apple.Passwords", name: "Passwords"),
        .init(bundleID: "org.keepassxc.keepassxc", name: "KeePassXC"),
        .init(bundleID: "com.lastpass.LastPass", name: "LastPass"),
        .init(bundleID: "com.dashlane.dashlanephonefinal", name: "Dashlane"),
        .init(bundleID: "in.sinew.Enpass-Desktop", name: "Enpass"),
    ]
}
