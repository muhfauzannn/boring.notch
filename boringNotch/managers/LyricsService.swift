//
//  LyricsService.swift
//  boringNotch
//
//  Looks up time-synced lyrics on LRCLIB (https://lrclib.net), parses LRC
//  and caches the results on disk.
//

import CryptoKit
import Foundation

struct LyricLine: Identifiable, Equatable, Codable {
    let id: Int
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    let isInterlude: Bool

    /// Progress through the line, finishing slightly before the next line starts.
    func progress(at position: TimeInterval) -> Double {
        let length = max(0.3, (end - start) * 0.92)
        return min(max((position - start) / length, 0), 1)
    }
}

struct LyricsResult: Codable, Equatable {
    var synced: [LyricLine]
    var plain: String
    var isInstrumental: Bool

    static let empty = LyricsResult(synced: [], plain: "", isInstrumental: false)

    var isEmpty: Bool { synced.isEmpty && plain.isEmpty && !isInstrumental }
}

private struct LRCLibRecord: Decodable {
    let trackName: String?
    let artistName: String?
    let albumName: String?
    let duration: Double?
    let instrumental: Bool?
    let plainLyrics: String?
    let syncedLyrics: String?

    var hasSynced: Bool { !(syncedLyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var hasPlain: Bool { !(plainLyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

actor LyricsService {
    static let shared = LyricsService()

    /// Gaps between lines at least this long are shown as an instrumental break.
    static let interludeThreshold: TimeInterval = 4
    /// A synced result whose length differs more than this is probably another version of the song.
    private static let maxDurationMismatch: TimeInterval = 15

    private let session: URLSession
    private let cacheDirectory: URL?
    private var memoryCache: [String: LyricsResult] = [:]

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.httpAdditionalHeaders = ["User-Agent": "boringNotch (https://github.com/TheBoredTeam/boring.notch)"]
        session = URLSession(configuration: config)

        cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("boringNotch/Lyrics", isDirectory: true)
        if let cacheDirectory {
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
    }

    // MARK: - Lookup

    func lyrics(title: String, artist: String, album: String, duration: TimeInterval) async -> LyricsResult {
        let cleanTitle = Self.cleanTitle(title)
        let cleanArtist = Self.normalized(artist)
        let cleanAlbum = Self.normalized(album)
        let key = Self.cacheKey(title: cleanTitle, artist: cleanArtist)

        if let cached = memoryCache[key] { return cached }
        if let cached = readDiskCache(key) {
            memoryCache[key] = cached
            return cached
        }

        var record: LRCLibRecord?
        if !cleanAlbum.isEmpty, duration > 0 {
            record = await exactMatch(title: cleanTitle, artist: cleanArtist, album: cleanAlbum, duration: duration)
        }
        if record?.hasSynced != true,
           let found = await bestSearchMatch(title: cleanTitle, artist: cleanArtist, duration: duration),
           record == nil || found.hasSynced {
            record = found
        }

        let result = record.map { Self.makeResult(from: $0, duration: duration) } ?? .empty
        memoryCache[key] = result
        // Misses stay in memory only, so the next launch can try again
        if !result.isEmpty { writeDiskCache(result, key: key) }
        return result
    }

    private func exactMatch(title: String, artist: String, album: String, duration: TimeInterval) async -> LRCLibRecord? {
        var components = URLComponents(string: "https://lrclib.net/api/get")
        components?.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "album_name", value: album),
            URLQueryItem(name: "duration", value: String(Int(duration.rounded()))),
        ]
        guard let url = components?.url else { return nil }
        return await fetch(LRCLibRecord.self, from: url)
    }

    private func bestSearchMatch(title: String, artist: String, duration: TimeInterval) async -> LRCLibRecord? {
        var components = URLComponents(string: "https://lrclib.net/api/search")
        components?.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        var records: [LRCLibRecord] = []
        if let url = components?.url {
            records = await fetch([LRCLibRecord].self, from: url) ?? []
        }
        if records.isEmpty {
            components?.queryItems = [URLQueryItem(name: "q", value: "\(artist) \(title)")]
            if let url = components?.url {
                records = await fetch([LRCLibRecord].self, from: url) ?? []
            }
        }
        return records.max { Self.score($0, duration: duration) < Self.score($1, duration: duration) }
    }

    private static func score(_ record: LRCLibRecord, duration: TimeInterval) -> Double {
        var score: Double = 0
        if record.hasSynced { score += 100 }
        if record.hasPlain { score += 10 }
        if duration > 0, let recordDuration = record.duration {
            let diff = abs(recordDuration - duration)
            score += diff <= 2 ? 50 : (diff <= 10 ? 20 : -diff)
        }
        return score
    }

    private func fetch<T: Decodable>(_ type: T.Type, from url: URL) async -> T? {
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            return nil
        }
    }

    private static func makeResult(from record: LRCLibRecord, duration: TimeInterval) -> LyricsResult {
        var synced: [LyricLine] = []
        let durationMatches = duration <= 0 || record.duration == nil
            || abs((record.duration ?? 0) - duration) <= maxDurationMismatch
        if durationMatches, let lrc = record.syncedLyrics {
            synced = parseLRC(lrc, duration: duration > 0 ? duration : (record.duration ?? 0))
        }

        var plain = (record.plainLyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if plain.isEmpty, !synced.isEmpty {
            plain = synced.filter { !$0.isInterlude }.map(\.text).joined(separator: "\n")
        }
        return LyricsResult(synced: synced, plain: plain, isInstrumental: record.instrumental ?? false)
    }

    // MARK: - LRC parsing

    private static let timestampRegex = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#)
    private static let wordTimestampRegex = try! NSRegularExpression(pattern: #"<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>"#)

    /// Parses LRC into a timeline. Handles several timestamps on one line, 1–3 digit
    /// fractions and enhanced-LRC word stamps, and turns long gaps into interlude lines.
    static func parseLRC(_ lrc: String, duration: TimeInterval) -> [LyricLine] {
        var entries: [(time: TimeInterval, text: String)] = []

        for rawLine in lrc.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let nsLine = line as NSString
            var cursor = 0
            var times: [TimeInterval] = []

            while cursor < nsLine.length,
                  let match = timestampRegex.firstMatch(in: line, range: NSRange(location: cursor, length: nsLine.length - cursor)),
                  match.range.location == cursor {
                let minutes = Double(nsLine.substring(with: match.range(at: 1))) ?? 0
                let seconds = Double(nsLine.substring(with: match.range(at: 2))) ?? 0
                var fraction: Double = 0
                let fractionRange = match.range(at: 3)
                if fractionRange.location != NSNotFound {
                    let digits = nsLine.substring(with: fractionRange)
                    fraction = (Double(digits) ?? 0) / pow(10, Double(digits.count))
                }
                times.append(minutes * 60 + seconds + fraction)
                cursor = match.range.location + match.range.length
            }
            // Metadata tags such as [ar:...] have no numeric timestamp and are skipped here
            guard !times.isEmpty else { continue }

            var text = nsLine.substring(from: cursor)
            text = wordTimestampRegex.stringByReplacingMatches(
                in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "")
            text = text.trimmingCharacters(in: .whitespaces)
            for time in times { entries.append((time, text)) }
        }

        entries.sort { $0.time < $1.time }
        return buildTimeline(entries, duration: duration)
    }

    private static func buildTimeline(_ entries: [(time: TimeInterval, text: String)], duration: TimeInterval) -> [LyricLine] {
        guard let firstSung = entries.first(where: { !$0.text.isEmpty }) else { return [] }

        var starts: [(time: TimeInterval, text: String, isInterlude: Bool)] = []
        if firstSung.time >= interludeThreshold {
            starts.append((0, "", true))
        }
        for (index, entry) in entries.enumerated() {
            if entry.text.isEmpty {
                // Blank stamps mark breaks; short ones just extend the previous line
                let next = index + 1 < entries.count ? entries[index + 1].time : max(duration, entry.time)
                guard next - entry.time >= interludeThreshold, starts.last?.isInterlude != true else { continue }
                starts.append((entry.time, "", true))
            } else {
                starts.append((entry.time, entry.text, false))
            }
        }

        return starts.enumerated().map { index, item in
            let end: TimeInterval
            if index + 1 < starts.count {
                end = starts[index + 1].time
            } else {
                end = duration > item.time ? duration : item.time + 5
            }
            return LyricLine(id: index, start: item.time, end: end, text: item.text, isInterlude: item.isInterlude)
        }
    }

    // MARK: - Query cleanup

    private static let titleNoiseRegexes: [NSRegularExpression] = [
        // "Song (Remastered 2011)", "Song [feat. X]"
        try! NSRegularExpression(
            pattern: #"\s*[\(\[][^\)\]]*\b(remaster(ed)?|feat\.?|ft\.?|with|version|edit|mono|stereo|deluxe|bonus|live|mix)\b[^\)\]]*[\)\]]"#,
            options: .caseInsensitive),
        // "Song - Remastered 2011", "Song - Radio Edit"
        try! NSRegularExpression(
            pattern: #"\s+-\s+.*\b(remaster(ed)?|version|edit|mono|stereo|live|mix)\b.*$"#,
            options: .caseInsensitive),
    ]

    static func cleanTitle(_ title: String) -> String {
        var result = normalized(title)
        for regex in titleNoiseRegexes {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(location: 0, length: (result as NSString).length), withTemplate: "")
        }
        result = result.trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? normalized(title) : result
    }

    static func normalized(_ string: String) -> String {
        string
            .folding(options: .diacriticInsensitive, locale: .current)
            .replacingOccurrences(of: "\u{FFFD}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Disk cache

    private static func cacheKey(title: String, artist: String) -> String {
        let digest = SHA256.hash(data: Data("\(artist.lowercased())|\(title.lowercased())".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func readDiskCache(_ key: String) -> LyricsResult? {
        guard let url = cacheDirectory?.appendingPathComponent("\(key).json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LyricsResult.self, from: data)
    }

    private func writeDiskCache(_ result: LyricsResult, key: String) {
        guard let url = cacheDirectory?.appendingPathComponent("\(key).json"),
              let data = try? JSONEncoder().encode(result) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
