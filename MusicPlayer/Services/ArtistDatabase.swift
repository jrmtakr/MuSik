import Foundation

struct ArtistCatalogEntry: Hashable {
    let canonicalName: String
    let genre: String
    let aliases: [String]
    let requiresSeparatedContext: Bool
}

struct ArtistExtractionResult: Hashable {
    let primaryArtist: String
    let allArtists: [String]
    let genre: String?
    let matchedFromCatalog: Bool
}

enum ArtistDatabase {
    private static let store: CatalogStore = CatalogStore(raw: rawCatalogData)
    private static let dynamicLock = NSLock()
    private static var dynamicEntries: [ArtistCatalogEntry] = []
    private static var dynamicByKey: [String: ArtistCatalogEntry] = [:]

    static var totalCatalogCount: Int {
        dynamicLock.lock()
        let extra = dynamicEntries.count
        dynamicLock.unlock()
        return store.entries.count + extra
    }

    static var allEntries: [ArtistCatalogEntry] {
        dynamicLock.lock()
        let combined = store.entries + dynamicEntries
        dynamicLock.unlock()
        return combined
    }

    static func isInStaticCatalog(_ name: String) -> Bool {
        let key = normalizeLookupKey(name)
        guard !key.isEmpty else { return false }
        return store.byNormalizedKey[key] != nil
    }

    static func registerDynamicArtists(_ entries: [ArtistCatalogEntry]) {
        dynamicLock.lock()
        defer { dynamicLock.unlock() }
        for entry in entries {
            let key = normalizeLookupKey(entry.canonicalName)
            guard !key.isEmpty, store.byNormalizedKey[key] == nil else { continue }
            if dynamicByKey[key] == nil {
                dynamicEntries.append(entry)
            } else {
                if let idx = dynamicEntries.firstIndex(where: { normalizeLookupKey($0.canonicalName) == key }) {
                    dynamicEntries[idx] = entry
                }
            }
            dynamicByKey[key] = entry
            for alias in entry.aliases {
                let ak = normalizeLookupKey(alias)
                if !ak.isEmpty && store.byNormalizedKey[ak] == nil {
                    dynamicByKey[ak] = entry
                }
            }
        }
    }

    static func lookup(_ name: String) -> ArtistCatalogEntry? {
        let key = normalizeLookupKey(name)
        guard !key.isEmpty else { return nil }
        if let hit = store.byNormalizedKey[key] {
            return hit
        }
        dynamicLock.lock()
        let dynHit = dynamicByKey[key]
        dynamicLock.unlock()
        return dynHit
    }

    static func genre(forArtist name: String) -> String? {
        lookup(name)?.genre
    }

    static func searchCatalog(query: String, limit: Int = 50) -> [ArtistCatalogEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let pool = allEntries
        guard !trimmed.isEmpty else {
            return Array(pool.prefix(limit))
        }
        let normQuery = normalizeLookupKey(trimmed)
        return pool.filter { entry in
            normalizeLookupKey(entry.canonicalName).contains(normQuery) ||
                entry.genre.localizedCaseInsensitiveContains(trimmed) ||
                entry.aliases.contains { normalizeLookupKey($0).contains(normQuery) }
        }
        .prefix(limit)
        .map { $0 }
    }

    // MARK: - Uploader Channel Detection & Query Cleaning

    private static let builtInKnownChannels: Set<String> = [
        "7clouds", "trap nation", "chill nation", "trap city", "cloudkid", "mrsuicidesheep",
        "suicide sheep", "syrebralvibes", "proximity", "majestic casual", "lyrical lemonade",
        "colors", "colorsxstudios", "rap nation", "bass nation", "indie nation", "house nation",
        "nocopyrightsounds", "ncs", "taz network", "nightcore reality", "wave music",
        "selected", "koala kontrol", "future house music", "spinnin records", "monstercat",
        "worldstarhiphop", "genius", "vevo", "chillcity", "arctic empire", "david dean burkhart",
        "alexrainbirdmusic", "chilledcow", "lofi girl", "unique vibes", "royal bass", "cloud vibes",
        "hybe labels", "smtown", "jyp entertainment", "yg entertainment", "starship", "cube entertainment",
        "sony music", "sony music japan", "universal music", "warner music", "warner music japan",
        "avex", "aniplex", "toho animation", "king records", "lantis"
    ]

    private static let channelKeywordTokens: [String] = [
        "lyrics", "lyric", "nightcore", "slowed", "reverb", "playlists", "playlist",
        "music channel", "official channel", "top hits", "vibes", "mixes", "mixtape",
        "unofficial", "audio only", "karaoke", "instrumental", "covers", "cover",
        "fanpage", "fan page", "archive", "vault", "records", "promotions", "promo",
        "network", "radio"
    ]

    static func looksLikeUploaderChannel(_ raw: String, customIgnoredChannels: Set<String> = []) -> Bool {
        let norm = normalizeLookupKey(raw)
        if norm.isEmpty { return false }
        if customIgnoredChannels.contains(norm) { return true }
        if builtInKnownChannels.contains(norm) { return true }
        if lookup(norm) != nil { return false }

        let padded = " \(norm) "
        for kw in channelKeywordTokens {
            if padded.contains(" \(kw) ") || norm.hasSuffix(kw) || norm.hasPrefix(kw) {
                return true
            }
        }
        if norm.contains("yt") && norm.count <= 14 { return true }
        return false
    }

    struct ParsedTrackHints: Sendable {
        let songTitle: String
        let artistHint: String?
        let allArtists: [String]
        let albumHint: String?
        let isExplicitSingle: Bool
        let alternatePair: (song: String, artist: String)?
    }

    /// Parses filenames/tags like `"Always - Ye (Bully).mp4"`, `"Babe - HyunA.mp4"`, `"Crank That (Soulja Boy).webm"`,
    /// or `"LOVE SCENARIO- iKON.mp4"`, cleanly separating song title, canonical artist, featured artists, and project tags.
    static func parseTrackHints(
        rawTitle: String,
        rawArtistTag: String? = nil,
        fileName: String? = nil,
        ignoredChannels: Set<String> = []
    ) -> ParsedTrackHints {
        let baseRaw = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (fileName ?? rawTitle)
            : rawTitle
        let trimmed = stripFileExtension(baseRaw).trimmingCharacters(in: .whitespacesAndNewlines)
        let (withoutNoise, featuredFromBrackets) = extractFeaturesAndStripNoise(from: trimmed)
        let (wholeStripped, wholeAlbum, wholeExplicitSingle, wholeParenArtist) = extractBracketedProjectTag(from: withoutNoise)

        let cleanedArtistTag = rawArtistTag.flatMap { cleanChannelOrTagNoise($0) }
        let tagIsChannel = cleanedArtistTag.map {
            isJunkArtistString($0) || looksLikeUploaderChannel($0, customIgnoredChannels: ignoredChannels)
        } ?? false

        // Find last separator match (`" - "`, `" — "`, `" – "`, `" | "`, or tight `")- "` / `"word- "` when spaced right).
        var matchedSplitRange: Range<String.Index>? = nil
        for separator in [" - ", " — ", " – ", " | "] {
            if let r = withoutNoise.range(of: separator, options: .backwards) {
                matchedSplitRange = r
                break
            }
        }
        if matchedSplitRange == nil,
           let tightRegex = try? NSRegularExpression(pattern: #"(?<=[^\s\-])[-–—]\s+"#),
           let lastMatch = tightRegex.matches(
               in: withoutNoise,
               range: NSRange(location: 0, length: (withoutNoise as NSString).length)
           ).last,
           let r = Range(lastMatch.range, in: withoutNoise) {
            matchedSplitRange = r
        }

        // CJK lenticular-bracket artist prefix (e.g. `【Ado】うっせぇわ` -> Artist "Ado", Song "うっせぇわ").
        if matchedSplitRange == nil,
           let lenticRegex = try? NSRegularExpression(pattern: #"^【([^】]{1,40})】\s*(.+)$"#),
           let m = lenticRegex.firstMatch(in: withoutNoise, range: NSRange(location: 0, length: (withoutNoise as NSString).length)),
           let r1 = Range(m.range(at: 1), in: withoutNoise),
           let r2 = Range(m.range(at: 2), in: withoutNoise) {
            let lArtRaw = String(withoutNoise[r1]).trimmingCharacters(in: .whitespacesAndNewlines)
            let lSong = String(withoutNoise[r2]).trimmingCharacters(in: .whitespacesAndNewlines)
            let lowLArt = lArtRaw.lowercased()
            let isNoiseTag = lowLArt.contains("official") || lowLArt.contains("lyric") || lowLArt.contains("mv")
                || lowLArt.contains("sub") || lowLArt.contains("audio") || lowLArt.contains("full")
                || lowLArt.contains("歌詞") || lowLArt.contains("和訳")
            if !isNoiseTag, !lArtRaw.isEmpty, !lSong.isEmpty {
                let cArt = canonicalizeSingle(lArtRaw)
                return ParsedTrackHints(
                    songTitle: lSong,
                    artistHint: cArt,
                    allArtists: mergeUniqueArtists([cArt], featuredFromBrackets),
                    albumHint: wholeAlbum,
                    isExplicitSingle: wholeExplicitSingle,
                    alternatePair: nil
                )
            }
        }

        // CJK corner-bracket split when no dash separator exists (e.g. `YOASOBI「アイドル」` or `米津玄師『Lemon』`).
        if matchedSplitRange == nil,
           let cjkRegex = try? NSRegularExpression(pattern: #"^([^\「\『]{2,40})[\「\『]([^\」\』]{1,80})[\」\』]"#),
           let m = cjkRegex.firstMatch(in: withoutNoise, range: NSRange(location: 0, length: (withoutNoise as NSString).length)),
           let r1 = Range(m.range(at: 1), in: withoutNoise),
           let r2 = Range(m.range(at: 2), in: withoutNoise) {
            let cjkArtist = canonicalizeSingle(String(withoutNoise[r1]).trimmingCharacters(in: .whitespacesAndNewlines))
            let cjkSong = String(withoutNoise[r2]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !cjkArtist.isEmpty && !cjkSong.isEmpty {
                return ParsedTrackHints(
                    songTitle: cjkSong,
                    artistHint: cjkArtist,
                    allArtists: mergeUniqueArtists([cjkArtist], featuredFromBrackets),
                    albumHint: nil,
                    isExplicitSingle: false,
                    alternatePair: nil
                )
            }
        }

        // K-Pop / quoted MV title format without dash (e.g. `NewJeans (뉴진스) 'Super Shy' Official MV`).
        if matchedSplitRange == nil,
           let quoteRegex = try? NSRegularExpression(pattern: #"^([^'\u2018\u2019"\u201C\u201D\(\[]{2,45}?)(?:\s*[\(\[][^\)\]]{1,30}[\)\]])?\s*['\u2018"\u201C]([^'\u2019"\u201D]{1,80})['\u2019"\u201D]"#),
           let m = quoteRegex.firstMatch(in: withoutNoise, range: NSRange(location: 0, length: (withoutNoise as NSString).length)),
           let r1 = Range(m.range(at: 1), in: withoutNoise),
           let r2 = Range(m.range(at: 2), in: withoutNoise) {
            var qArtist = String(withoutNoise[r1]).trimmingCharacters(in: .whitespacesAndNewlines)
            let qTokens = qArtist.split(separator: " ").map(String.init)
            if qTokens.count == 2,
               let second = qTokens.last,
               second.unicodeScalars.contains(where: { (0xAC00...0xD7AF).contains($0.value) || (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) }) {
                qArtist = qTokens[0]
            }
            let cArtist = canonicalizeSingle(qArtist)
            let qSong = String(withoutNoise[r2]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !cArtist.isEmpty && !qSong.isEmpty {
                return ParsedTrackHints(
                    songTitle: qSong,
                    artistHint: cArtist,
                    allArtists: mergeUniqueArtists([cArtist], featuredFromBrackets),
                    albumHint: wholeAlbum,
                    isExplicitSingle: wholeExplicitSingle,
                    alternatePair: nil
                )
            }
        }

        if let range = matchedSplitRange {
            let leftRaw = stripLeadingTrackNumber(String(withoutNoise[..<range.lowerBound]))
            var rightRaw = String(withoutNoise[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            var trailingPipeAlbum: String?
            if let pipeRange = rightRaw.range(of: " | ", options: .backwards) {
                let afterPipe = String(rightRaw[pipeRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                let beforePipe = String(rightRaw[..<pipeRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let lowAfter = afterPipe.lowercased()
                if !beforePipe.isEmpty, !afterPipe.isEmpty, afterPipe.count <= 60,
                   !lowAfter.contains("official"), !lowAfter.contains("lyric"), !lowAfter.contains("video") {
                    trailingPipeAlbum = afterPipe
                    rightRaw = beforePipe
                }
            }
            if !leftRaw.isEmpty && !rightRaw.isEmpty {
                let (left, leftAlbum, leftSingle, _) = extractBracketedProjectTag(from: leftRaw)
                let (right, rightAlbum, rightSingle, _) = extractBracketedProjectTag(from: rightRaw)
                let resolvedAlbum = trailingPipeAlbum ?? rightAlbum ?? leftAlbum ?? wholeAlbum
                let explicitSingle = leftSingle || rightSingle || wholeExplicitSingle

                let leftIsChannel = looksLikeUploaderChannel(left, customIgnoredChannels: ignoredChannels) ||
                    (cleanedArtistTag.map { normalizeLookupKey($0) == normalizeLookupKey(left) } ?? false)
                let rightIsChannel = looksLikeUploaderChannel(right, customIgnoredChannels: ignoredChannels) ||
                    (cleanedArtistTag.map { normalizeLookupKey($0) == normalizeLookupKey(right) } ?? false)

                if leftIsChannel && !rightIsChannel {
                    let tagArtists = (!tagIsChannel ? cleanedArtistTag.map { splitAndCanonicalize($0) } : nil) ?? []
                    return ParsedTrackHints(
                        songTitle: right,
                        artistHint: tagArtists.first,
                        allArtists: mergeUniqueArtists(tagArtists, featuredFromBrackets),
                        albumHint: resolvedAlbum,
                        isExplicitSingle: explicitSingle,
                        alternatePair: nil
                    )
                }
                if rightIsChannel && !leftIsChannel {
                    let tagArtists = (!tagIsChannel ? cleanedArtistTag.map { splitAndCanonicalize($0) } : nil) ?? []
                    return ParsedTrackHints(
                        songTitle: left,
                        artistHint: tagArtists.first,
                        allArtists: mergeUniqueArtists(tagArtists, featuredFromBrackets),
                        albumHint: resolvedAlbum,
                        isExplicitSingle: explicitSingle,
                        alternatePair: nil
                    )
                }

                let leftArtists = splitAndCanonicalize(left)
                let rightArtists = splitAndCanonicalize(right)
                let leftKnown = !left.isEmpty && (lookup(left) != nil || leftArtists.contains { lookup($0) != nil })
                let rightKnown = !right.isEmpty && (lookup(right) != nil || rightArtists.contains { lookup($0) != nil })

                if rightKnown && !leftKnown {
                    let all = mergeUniqueArtists(rightArtists, featuredFromBrackets)
                    return ParsedTrackHints(
                        songTitle: left,
                        artistHint: all.first ?? right,
                        allArtists: all,
                        albumHint: resolvedAlbum,
                        isExplicitSingle: explicitSingle,
                        alternatePair: (song: right, artist: left)
                    )
                }
                if leftKnown && !rightKnown {
                    let all = mergeUniqueArtists(leftArtists, featuredFromBrackets)
                    return ParsedTrackHints(
                        songTitle: right,
                        artistHint: all.first ?? left,
                        allArtists: all,
                        albumHint: resolvedAlbum,
                        isExplicitSingle: explicitSingle,
                        alternatePair: (song: left, artist: right)
                    )
                }

                if let cleanedArtistTag, !tagIsChannel,
                   normalizeLookupKey(cleanedArtistTag) == normalizeLookupKey(left) {
                    let tagArtists = splitAndCanonicalize(cleanedArtistTag)
                    let all = mergeUniqueArtists(tagArtists, featuredFromBrackets)
                    return ParsedTrackHints(
                        songTitle: right,
                        artistHint: all.first ?? canonicalizeSingle(left),
                        allArtists: all,
                        albumHint: resolvedAlbum,
                        isExplicitSingle: explicitSingle,
                        alternatePair: nil
                    )
                }

                // When neither side matched the offline catalog cleanly (indie/SoundCloud/YouTube `"Song - Artist"`),
                // keep left as Song Title and right as Artist (preserves unique song names when one artist has many tracks!)
                // while storing the reversed pair in `alternatePair` for dual-orientation online verification.
                let resolvedArtist: String
                let resolvedSong: String
                let alt: (song: String, artist: String)?
                if let cleanedArtistTag, !tagIsChannel,
                   normalizeLookupKey(cleanedArtistTag) == normalizeLookupKey(right) {
                    resolvedSong = left
                    resolvedArtist = rightArtists.first ?? canonicalizeSingle(cleanedArtistTag)
                    alt = nil
                } else {
                    resolvedSong = left
                    resolvedArtist = right.contains("&") || right.contains(",")
                        ? right
                        : (rightArtists.first ?? canonicalizeSingle(right))
                    alt = (rightArtists.count <= 1 && featuredFromBrackets.isEmpty) ? (song: right, artist: left) : nil
                }
                let all = mergeUniqueArtists(rightArtists, featuredFromBrackets)
                return ParsedTrackHints(
                    songTitle: resolvedSong,
                    artistHint: resolvedArtist,
                    allArtists: all,
                    albumHint: resolvedAlbum,
                    isExplicitSingle: explicitSingle,
                    alternatePair: alt
                )
            }
        }

        let tagArtists = (!tagIsChannel ? cleanedArtistTag.map { splitAndCanonicalize($0) } : nil) ?? []
        let cleanTitle = stripLeadingTrackNumber(wholeStripped.isEmpty ? trimmed : wholeStripped)
        if tagArtists.isEmpty, let wholeParenArtist, !wholeParenArtist.isEmpty {
            let pArtists = splitAndCanonicalize(wholeParenArtist)
            let knownParen = lookup(wholeParenArtist) != nil || pArtists.contains { lookup($0) != nil }
            let primaryParen = pArtists.first ?? canonicalizeSingle(wholeParenArtist)
            let allParen = mergeUniqueArtists(pArtists, featuredFromBrackets)
            return ParsedTrackHints(
                songTitle: cleanTitle.isEmpty ? trimmed : cleanTitle,
                artistHint: knownParen ? primaryParen : nil,
                allArtists: knownParen ? allParen : featuredFromBrackets,
                albumHint: knownParen ? wholeAlbum : wholeParenArtist,
                isExplicitSingle: wholeExplicitSingle,
                alternatePair: (song: cleanTitle.isEmpty ? trimmed : cleanTitle, artist: primaryParen)
            )
        }
        let all = mergeUniqueArtists(tagArtists, featuredFromBrackets)
        return ParsedTrackHints(
            songTitle: cleanTitle.isEmpty ? trimmed : cleanTitle,
            artistHint: all.first ?? (tagIsChannel ? nil : cleanedArtistTag),
            allArtists: all,
            albumHint: wholeAlbum,
            isExplicitSingle: wholeExplicitSingle,
            alternatePair: nil
        )
    }

    /// Separates trailing bracketed project/album tags like `(Bully)`, `(Single)`, or `(Soulja Boy)` while preserving version markers.
    private static func extractBracketedProjectTag(from raw: String) -> (cleaned: String, albumHint: String?, isExplicitSingle: Bool, bracketedArtistCandidate: String?) {
        var working = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var detectedAlbum: String?
        var isSingle = false
        var artistCandidate: String?

        let pattern = #"(?<=\s)[\(\[]([^\)\]]{2,48})[\)\]]\s*$"#
        let versionKeywords: [String] = [
            "remix", "live", "acoustic", "instrumental", "karaoke", "cover",
            "slowed", "reverb", "sped", "nightcore", "demo", "unplugged", "8d",
            "version", "edit", "mix", "part", "pt.", "intro", "outro", "interlude",
            "skit", "explicit", "clean", "master", "leak", "v1", "v2", "v3", "v4", "v5",
            "produced by"
        ]
        let noiseOrQualityKeywords: [String] = [
            "official", "music video", "official video", "official audio", "visualizer",
            "lyric video", "lyrics", "cdq", "hq", "hd", "4k", "1080p", "720p", "snippet", "leaked"
        ]
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            while let match = regex.firstMatch(in: working, range: NSRange(location: 0, length: (working as NSString).length)),
                  match.numberOfRanges > 1 {
                let ns = working as NSString
                let inner = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                let lower = inner.lowercased()
                let before = ns.substring(with: NSRange(location: 0, length: match.range.location))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !before.isEmpty else { break }

                if lower == "single" || lower == "unreleased single" {
                    isSingle = true
                    working = before
                    continue
                }
                if noiseOrQualityKeywords.contains(where: { lower == $0 || lower.contains($0) }) ||
                    lower.hasPrefix("prod.") || lower.hasPrefix("prod ") {
                    working = before
                    continue
                }
                let looksLikeVersion = versionKeywords.contains { kw in
                    lower == kw || lower.contains(" \(kw)") || lower.hasPrefix("\(kw) ") || lower.hasSuffix(" \(kw)")
                } || inner.allSatisfy({ $0.isNumber || $0 == "." })
                if looksLikeVersion {
                    break
                }
                if lookup(inner) != nil || artistCandidate == nil && !inner.contains(" ") && !lower.contains("album") && !lower.contains("ep") && !lower.contains("playlist") {
                    artistCandidate = inner
                    working = before
                    continue
                }
                if detectedAlbum == nil {
                    detectedAlbum = inner
                }
                working = before
            }
        }
        return (working, detectedAlbum, isSingle, artistCandidate)
    }

    static func cleanSongTitleForSearch(
        rawTitle: String,
        rawArtistTag: String? = nil,
        ignoredChannels: Set<String> = []
    ) -> (songOnly: String, artistHint: String?) {
        let parsed = parseTrackHints(
            rawTitle: rawTitle,
            rawArtistTag: rawArtistTag,
            fileName: nil,
            ignoredChannels: ignoredChannels
        )
        return (parsed.songTitle, parsed.artistHint)
    }

    // MARK: - Smart Artist Recognition

    static func extractArtists(
        rawArtistTag: String?,
        rawTitle: String?,
        fileName: String? = nil,
        customAliases: [String: String] = [:],
        ignoredChannels: Set<String> = [],
        isArtistVerified: Bool = false
    ) -> ArtistExtractionResult {
        let cleanedTag = rawArtistTag.flatMap { cleanChannelOrTagNoise($0) }
        let tagBlocked = cleanedTag.map {
            isJunkArtistString($0) || looksLikeUploaderChannel($0, customIgnoredChannels: ignoredChannels)
        } ?? true

        if let cleanedTag, !isJunkArtistString(cleanedTag), isArtistVerified {
            let split = splitAndCanonicalize(cleanedTag, customAliases: customAliases)
            if let first = split.first, !isJunkArtistString(first) {
                let resolvedGenre = split.compactMap { lookup($0)?.genre }.first
                return ArtistExtractionResult(
                    primaryArtist: first,
                    allArtists: split,
                    genre: resolvedGenre,
                    matchedFromCatalog: true
                )
            }
        }

        let tagArtists: [String] = {
            guard let cleanedTag, !tagBlocked else { return [] }
            return splitAndCanonicalize(cleanedTag, customAliases: customAliases)
                .filter { !isJunkArtistString($0) }
        }()
        let tagMatchedCatalog = tagArtists.contains { lookup($0) != nil }

        if tagMatchedCatalog, let first = tagArtists.first {
            let resolvedGenre = tagArtists.compactMap { lookup($0)?.genre }.first
            return ArtistExtractionResult(
                primaryArtist: first,
                allArtists: tagArtists,
                genre: resolvedGenre,
                matchedFromCatalog: true
            )
        }

        // Parse title & filename: can override uncatalogued / channel artist tags when title names a real artist!
        let candidateSources = [rawTitle, fileName.map { stripFileExtension($0) }]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for source in candidateSources {
            let (withoutNoise, featuredFromBrackets) = extractFeaturesAndStripNoise(from: source)

            for separator in [" - ", " — ", " – ", " | "] {
                if let range = withoutNoise.range(of: separator) {
                    let leftClean = stripLeadingTrackNumber(String(withoutNoise[..<range.lowerBound]))
                    let rightClean = String(withoutNoise[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)

                    let leftIsBlocked = looksLikeUploaderChannel(leftClean, customIgnoredChannels: ignoredChannels)
                    let rightIsBlocked = looksLikeUploaderChannel(rightClean, customIgnoredChannels: ignoredChannels)

                    let leftArtists = leftIsBlocked ? [] : splitAndCanonicalize(leftClean, customAliases: customAliases)
                    let rightArtists = rightIsBlocked ? [] : splitAndCanonicalize(rightClean, customAliases: customAliases)

                    let leftKnown = !leftArtists.isEmpty && leftArtists.contains { lookup($0) != nil }
                    let rightKnown = !rightArtists.isEmpty && rightArtists.contains { lookup($0) != nil }

                    if rightKnown && !leftKnown {
                        let combined = mergeUniqueArtists(rightArtists, featuredFromBrackets, customAliases: customAliases)
                        if let primary = combined.first {
                            return ArtistExtractionResult(
                                primaryArtist: primary,
                                allArtists: combined,
                                genre: combined.compactMap { lookup($0)?.genre }.first,
                                matchedFromCatalog: true
                            )
                        }
                    }

                    if leftKnown {
                        let combined = mergeUniqueArtists(leftArtists, featuredFromBrackets, customAliases: customAliases)
                        if let primary = combined.first, !isJunkArtistString(primary) {
                            return ArtistExtractionResult(
                                primaryArtist: primary,
                                allArtists: combined,
                                genre: combined.compactMap { lookup($0)?.genre }.first,
                                matchedFromCatalog: true
                            )
                        }
                    }

                    // If tag itself was missing or looks like a channel, allow clean "Artist - Title" left side
                    if tagBlocked && !leftIsBlocked && !rightIsBlocked &&
                        !leftClean.isEmpty && leftClean.count <= 48 && !isGenericTrackPrefix(leftClean) {
                        let baseArtists = leftArtists.isEmpty ? [leftClean] : leftArtists
                        let combined = mergeUniqueArtists(baseArtists, featuredFromBrackets, customAliases: customAliases)
                        if let primary = combined.first,
                           !isJunkArtistString(primary),
                           !looksLikeUploaderChannel(primary, customIgnoredChannels: ignoredChannels) {
                            return ArtistExtractionResult(
                                primaryArtist: primary,
                                allArtists: combined,
                                genre: combined.compactMap { lookup($0)?.genre }.first,
                                matchedFromCatalog: combined.contains { lookup($0) != nil }
                            )
                        }
                    }
                }
            }

            let directScanMatches = scanUnseparatedTitleForKnownArtists(withoutNoise)
            if !directScanMatches.isEmpty || !featuredFromBrackets.isEmpty {
                let combined = mergeUniqueArtists(directScanMatches, featuredFromBrackets, customAliases: customAliases)
                if let primary = combined.first, !isJunkArtistString(primary) {
                    return ArtistExtractionResult(
                        primaryArtist: primary,
                        allArtists: combined,
                        genre: combined.compactMap { lookup($0)?.genre }.first,
                        matchedFromCatalog: true
                    )
                }
            }
        }

        // Fall back to user-provided tag only if it didn't match channel heuristics/blocklist
        if let firstTag = tagArtists.first {
            return ArtistExtractionResult(
                primaryArtist: firstTag,
                allArtists: tagArtists,
                genre: nil,
                matchedFromCatalog: false
            )
        }

        return ArtistExtractionResult(
            primaryArtist: "Unknown Artist",
            allArtists: ["Unknown Artist"],
            genre: nil,
            matchedFromCatalog: false
        )
    }

    static func canonicalizeSingle(_ raw: String, customAliases: [String: String] = [:]) -> String {
        let trimmed = cleanChannelOrTagNoise(raw) ?? raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let norm = normalizeLookupKey(trimmed)
        if let custom = customAliases[norm], !custom.isEmpty {
            return lookup(custom)?.canonicalName ?? custom
        }
        if let catalogHit = lookup(trimmed) {
            return catalogHit.canonicalName
        }
        return trimmed
    }

    // MARK: - Compilation Detection & Genre Inference

    struct CompilationDetection: Sendable {
        let genre: String        // e.g. "Hip-Hop", "R&B", "Pop", or "Music"
        let albumLabel: String   // e.g. "Hip-Hop Compilation" or "Music Compilation"
        let cleanTitle: String
        let artistLabel: String  // e.g. "Kanye West" for single-artist comp, else "Various Artists"
    }

    static func normalizeGenreLabel(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        let lower = trimmed.lowercased()
        if lower.contains("hip-hop") || lower.contains("hip hop") || lower == "rap" || lower.contains("trap") || lower.contains("drill") {
            return "Hip-Hop"
        }
        if lower.contains("r&b") || lower.contains("rnb") || lower.contains("neo-soul") || lower == "soul" {
            return "R&B"
        }
        if lower.contains("lo-fi") || lower.contains("lofi") || lower.contains("chillhop") {
            return "Lo-Fi"
        }
        if lower.contains("k-pop") || lower.contains("kpop") {
            return "K-Pop"
        }
        if lower.contains("afrobeat") || lower.contains("amapiano") || lower.contains("afropop") {
            return "Afrobeats"
        }
        if lower.contains("country") || lower.contains("americana") {
            return "Country"
        }
        if lower.contains("electronic") || lower.contains("edm") || lower.contains("dance") || lower.contains("house") || lower.contains("techno") || lower.contains("dubstep") || lower.contains("trance") {
            return "Electronic"
        }
        if lower.contains("rock") || lower.contains("alternative") || lower.contains("metal") || lower.contains("punk") || lower.contains("grunge") {
            return "Rock"
        }
        if lower.contains("latin") || lower.contains("reggaeton") || lower.contains("urbano") || lower.contains("corrido") || lower.contains("bachata") {
            return "Latin"
        }
        if lower.contains("jazz") {
            return "Jazz"
        }
        if lower.contains("reggae") || lower.contains("dancehall") {
            return "Reggae"
        }
        if lower.contains("gospel") || lower.contains("christian") || lower.contains("worship") {
            return "Gospel"
        }
        if lower.contains("classical") || lower.contains("soundtrack") {
            return "Classical"
        }
        if lower.contains("pop") {
            return "Pop"
        }
        if let first = trimmed.split(separator: "/").first {
            let cleaned = String(first).trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { return cleaned }
        }
        return trimmed
    }

    static func inferGenreFromText(_ text: String) -> String? {
        let lower = " " + text.lowercased() + " "
        let rules: [(pattern: String, label: String)] = [
            (#"\b(hip[- ]?hop|rap|trap|drill|boom[- ]?bap|phonk|cypher)\b"#, "Hip-Hop"),
            (#"\b(r&b|rnb|neo[- ]?soul|slow jams)\b"#, "R&B"),
            (#"\b(lo[- ]?fi|lofi|chillhop)\b"#, "Lo-Fi"),
            (#"\b(k[- ]?pop|kpop)\b"#, "K-Pop"),
            (#"\b(city\s+pop|j[- ]?pop|jpop|japanese|anime)\b"#, "J-Pop"),
            (#"\b(soundtrack|minecraft|c418|ost|bgm)\b"#, "Soundtrack"),
            (#"\b(afrobeats?|afropop|amapiano)\b"#, "Afrobeats"),
            (#"\b(edm|house|techno|dubstep|trance|dnb|drum\s*&?\s*bass|electronic|synthwave)\b"#, "Electronic"),
            (#"\b(rock|metal|punk|grunge|indie\s+rock|alt\s+rock)\b"#, "Rock"),
            (#"\b(country|americana|bluegrass)\b"#, "Country"),
            (#"\b(latin|reggaeton|corridos|bachata|salsa|cumbia)\b"#, "Latin"),
            (#"\b(jazz|bebop|swing)\b"#, "Jazz"),
            (#"\b(reggae|dancehall)\b"#, "Reggae"),
            (#"\b(gospel|worship|christian)\b"#, "Gospel"),
            (#"\b(classical|orchestral|symphony)\b"#, "Classical"),
            (#"\b(pop|synthpop)\b"#, "Pop")
        ]
        for (pattern, label) in rules {
            if lower.range(of: pattern, options: .regularExpression) != nil {
                return label
            }
        }
        return nil
    }

    static func detectCompilation(
        rawTitle: String,
        rawArtistTag: String? = nil,
        fileName: String? = nil,
        embeddedAlbum: String? = nil,
        durationSeconds: Double? = nil,
        youtubeSongs: [(title: String, artist: String, genre: String?)] = [],
        allowLongDurationFallback: Bool = false
    ) -> CompilationDetection? {
        let combined = [rawTitle, fileName ?? "", embeddedAlbum ?? ""].joined(separator: " ")
        let lower = combined.lowercased()

        let singleSongMixGuard = lower.range(
            of: #"\b(remix|club\s+mix|extended\s+mix|radio\s+mix|acoustic\s+mix|clean\s+mix|instrumental\s+mix|vocal\s+mix|dub\s+mix|vip\s+mix|slowed|reverb|sped\s+up)\b"#,
            options: .regularExpression
        ) != nil

        let explicitComp = lower.range(
            of: #"\b(compilation|comp|megamix|medley|mashup|mixtape|non[- ]?stop|full\s+album|full\s+ep|special\s+collection|collection|soundtrack\s+playlist|playlist|all\s+songs|best\s+of|greatest\s+hits|top\s+\d+|dj\s+set|live\s+set|jukebox|\d+\s*(?:hr|hrs|hour|hours|min|mins|minute|minutes)\s*(?:of\s+)?(?:mix|music|songs|hits|beats)?)\b"#,
            options: .regularExpression
        ) != nil

        let genreOrEraMix = !singleSongMixGuard && lower.range(
            of: #"\b(?:hip[- ]?hop|rap|trap|r&b|rnb|pop|rock|country|jazz|lofi|lo[- ]?fi|chill|study|workout|gym|summer|party|80s|90s|2000s|2010s|2020s|hits|throwback|unreleased|leaks?|songs|beats)\s+mix\b"#,
            options: .regularExpression
        ) != nil

        let distinctYTSongs = Set(youtubeSongs.map { normalizeLookupKey($0.title) }.filter { !$0.isEmpty })
        let multiSongYT = !singleSongMixGuard && (
            distinctYTSongs.count >= 4 || (distinctYTSongs.count >= 3 && (durationSeconds ?? 0) >= 480)
        )
        let genericMixWithLongDuration = !singleSongMixGuard && (durationSeconds ?? 0) >= 540
            && lower.range(of: #"\bmix\b"#, options: .regularExpression) != nil
        let longUnknownFallback = allowLongDurationFallback && (durationSeconds ?? 0) >= 1500 && !singleSongMixGuard

        guard explicitComp || genreOrEraMix || multiSongYT || genericMixWithLongDuration || longUnknownFallback else {
            return nil
        }

        // Infer dominant genre cleanly across text tags, catalog artists, and YouTube track cards.
        var genreCounts: [String: Int] = [:]
        func addGenreVote(_ raw: String?, weight: Int) {
            guard let norm = normalizeGenreLabel(raw), !norm.isEmpty else { return }
            genreCounts[norm, default: 0] += weight
        }

        addGenreVote(inferGenreFromText(combined), weight: 4)
        for item in youtubeSongs {
            addGenreVote(item.genre ?? genre(forArtist: item.artist), weight: 2)
        }

        // Split tight dashes too (`Minecraft Soundtrack Playlist- C418`, `Vultures 2 (Full Album)- Ye & Ty Dolla $ign`).
        let parsedHints = parseTrackHints(rawTitle: rawTitle, rawArtistTag: rawArtistTag, fileName: fileName)
        let extractedArtists = extractArtists(
            rawArtistTag: rawArtistTag ?? parsedHints.artistHint,
            rawTitle: rawTitle,
            fileName: fileName
        )
        for artistName in extractedArtists.allArtists where artistName != "Unknown Artist" {
            addGenreVote(genre(forArtist: artistName), weight: 3)
        }
        addGenreVote(extractedArtists.genre, weight: 3)

        let chosenGenre = genreCounts.max(by: { $0.value < $1.value })?.key ?? "Music"
        let albumLabel = "\(chosenGenre) Compilation"

        let ytDistinctArtists = Set(youtubeSongs.map { canonicalizeSingle($0.artist) }.filter { !$0.isEmpty })
        let resolvedArtistLabel: String = {
            if ytDistinctArtists.count == 1, let sole = ytDistinctArtists.first {
                return sole
            }
            if ytDistinctArtists.count >= 2 {
                return ytDistinctArtists.count == 2
                    ? ytDistinctArtists.sorted().joined(separator: " & ")
                    : "Various Artists"
            }
            if let hintArtist = parsedHints.artistHint, !hintArtist.isEmpty,
               !looksLikeUploaderChannel(hintArtist), !isJunkArtistString(hintArtist) {
                return canonicalizeSingle(hintArtist)
            }
            if extractedArtists.matchedFromCatalog && extractedArtists.allArtists.count == 1 {
                return extractedArtists.primaryArtist
            }
            if extractedArtists.allArtists.count == 2 {
                return extractedArtists.allArtists.joined(separator: " & ")
            }
            if extractedArtists.allArtists.count >= 3 {
                return "Various Artists"
            }
            if let tag = rawArtistTag?.trimmingCharacters(in: .whitespacesAndNewlines),
               !tag.isEmpty,
               !looksLikeUploaderChannel(tag) {
                return canonicalizeSingle(tag)
            }
            return "Various Artists"
        }()

        let cleanTitle = rawTitle
            .replacingOccurrences(of: #"\.(?:mp3|m4a|wav|flac|aac|ogg|opus|mp4|mov|mkv|webm)$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return CompilationDetection(
            genre: chosenGenre,
            albumLabel: albumLabel,
            cleanTitle: cleanTitle.isEmpty ? rawTitle : cleanTitle,
            artistLabel: resolvedArtistLabel
        )
    }

    // MARK: - Parsing Internals

    private static func cleanChannelOrTagNoise(_ raw: String) -> String? {
        var text = raw
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let exactSuffixes = [
            " - Topic", "- Topic", "-Topic",
            " Official Music", " Official Channel", " Official Audio",
            " Music Official", " Official", " Records"
        ]
        for suffix in exactSuffixes {
            if text.lowercased().hasSuffix(suffix.lowercased()) && text.count > suffix.count {
                text = String(text.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if text.lowercased().hasSuffix("vevo") && text.count > 4 {
            let candidate = String(text.dropLast(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty {
                text = candidate
            }
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isJunkArtistString(_ raw: String) -> Bool {
        let low = normalizeLookupKey(raw)
        if low.isEmpty { return true }
        let junkSet: Set<String> = [
            "unknown", "unknown artist", "various", "various artists",
            "music player video", "musejrm video", "artist", "none", "n a", "na",
            "youtube", "youtube com", "m youtube com", "youtu be",
            "music youtube com", "spotify", "spotify com", "open spotify com",
            "soundcloud", "soundcloud com", "apple com", "music apple com",
            "googlevideo com", "track", "audio", "video", "download"
        ]
        if junkSet.contains(low) { return true }
        if low.hasSuffix(" com") || low.hasSuffix(" net") || low.hasSuffix(" org") {
            return true
        }
        return false
    }

    private static func stripFileExtension(_ fileName: String) -> String {
        (fileName as NSString).deletingPathExtension
    }

    private static func stripLeadingTrackNumber(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let regex = try? NSRegularExpression(pattern: #"^(?:\d{1,3}[\.\)\-\s]+)"#) else {
            return trimmed
        }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        let replaced = regex.stringByReplacingMatches(in: trimmed, range: range, withTemplate: "")
        let clean = replaced.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? trimmed : clean
    }

    private static func isGenericTrackPrefix(_ s: String) -> Bool {
        let low = normalizeLookupKey(s)
        return low.hasPrefix("track ") || low.hasPrefix("audio ") || low.hasPrefix("video ")
    }

    private static func extractFeaturesAndStripNoise(from raw: String) -> (cleaned: String, featured: [String]) {
        var text = raw.replacingOccurrences(of: "_", with: " ")
        var featured: [String] = []

        // Extract "(feat. Artist)" / "[ft. Artist]" / "(with Artist)"
        if let featRegex = try? NSRegularExpression(
            pattern: #"[\(\[]\s*(?:feat\.?|ft\.?|featuring|with|prod\.?\s*by)\s+([^\)\]]+)[\)\]]"#,
            options: [.caseInsensitive]
        ) {
            let nsText = text as NSString
            let matches = featRegex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            for match in matches where match.numberOfRanges > 1 {
                let rawGuests = nsText.substring(with: match.range(at: 1))
                featured.append(contentsOf: splitAndCanonicalize(rawGuests))
            }
            text = featRegex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: nsText.length), withTemplate: " ")
        }

        // Strip bracketed/CJK/multilingual release noise FIRST so trailing `feat. Artist` isn't blocked by `[Official Audio]`.
        let noisePattern = #"(?:[\(\[]\s*(?:official(?:\s+(?:music|lyric|audio|hd|4k))?\s*(?:video|audio|visualizer|mv|m/v)?|video\s+oficial|audio\s+oficial|clip\s+officiel|videoclip|letra|paroles|lyrics?|lyric video|audio|video|hd|4k|hq|explicit|clean|remaster(?:ed)?(?:\s*\d{4})?|live|acoustic|sped up|slowed(?:\s*\+\s*reverb)?|topic)\s*[\)\]]|【[^】]*(?:lyric|official|mv|sub|audio|full|hd|4k|和訳|歌詞)[^】]*】|\s+(?:official\s+(?:music\s+)?video|official\s+(?:audio|mv)|video\s+oficial|clip\s+officiel|m/v|mv)\s*$)"#
        if let noiseRegex = try? NSRegularExpression(pattern: noisePattern, options: [.caseInsensitive]) {
            text = noiseRegex.stringByReplacingMatches(
                in: text,
                range: NSRange(location: 0, length: (text as NSString).length),
                withTemplate: " "
            ).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Strip trailing "feat. Artist" or tight "feat.Artist" when unbracketed
        if let inlineFeatRegex = try? NSRegularExpression(
            pattern: #"\s+(?:feat|ft|featuring)(?:\.?\s+|\.)([^-\|\(\)\[\]]+)$"#,
            options: [.caseInsensitive]
        ) {
            let nsText = text as NSString
            let matches = inlineFeatRegex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            for match in matches where match.numberOfRanges > 1 {
                let rawGuests = nsText.substring(with: match.range(at: 1))
                featured.append(contentsOf: splitAndCanonicalize(rawGuests))
            }
            text = inlineFeatRegex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: nsText.length), withTemplate: "")
        }

        while text.contains("  ") {
            text = text.replacingOccurrences(of: "  ", with: " ")
        }

        return (text.trimmingCharacters(in: .whitespacesAndNewlines), featured)
    }

    static func splitAndCanonicalize(_ raw: String, customAliases: [String: String] = [:]) -> [String] {
        var working = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !working.isEmpty else { return [] }

        // If the whole string itself matches a known artist or custom alias, return directly!
        let wholeNorm = normalizeLookupKey(working)
        if let custom = customAliases[wholeNorm], !custom.isEmpty {
            return [canonicalizeSingle(custom, customAliases: customAliases)]
        }
        if let exact = lookup(working) {
            return [exact.canonicalName]
        }

        // Temporarily shield protected punctuated names (e.g. "Tyler, The Creator", "Earth, Wind & Fire", "AC/DC")
        var restoredTokens: [String: String] = [:]
        for (idx, protected) in store.punctuatedProtectedNames.enumerated() {
            let token = "__PROTECTED_ARTIST_\(idx)__"
            if working.range(of: protected, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                restoredTokens[token] = lookup(protected)?.canonicalName ?? protected
                working = working.replacingOccurrences(
                    of: protected,
                    with: token,
                    options: [.caseInsensitive, .diacriticInsensitive]
                )
            }
        }

        // Normalize feature keywords & collaborator delimiters before splitting
        var delimiterNormalized = working
        if let featSep = try? NSRegularExpression(
            pattern: #"\s+(?:feat\.?|ft\.?|featuring|with|vs\.?|x)\s+"#,
            options: [.caseInsensitive]
        ) {
            delimiterNormalized = featSep.stringByReplacingMatches(
                in: delimiterNormalized,
                range: NSRange(location: 0, length: (delimiterNormalized as NSString).length),
                withTemplate: " ||| "
            )
        }
        for sep in [", ", ",", " & ", " / ", "; "] {
            delimiterNormalized = delimiterNormalized.replacingOccurrences(of: sep, with: " ||| ")
        }

        var output: [String] = []
        var seen = Set<String>()
        for part in delimiterNormalized.components(separatedBy: " ||| ") {
            var restored = part.trimmingCharacters(in: .whitespacesAndNewlines)
            for (token, original) in restoredTokens {
                restored = restored.replacingOccurrences(of: token, with: original)
            }
            guard !restored.isEmpty else { continue }
            let canonical = canonicalizeSingle(restored, customAliases: customAliases)
            guard !isJunkArtistString(canonical) else { continue }
            let dedupKey = normalizeLookupKey(canonical)
            if seen.insert(dedupKey).inserted {
                output.append(canonical)
            }
        }
        return output
    }

    private static func mergeUniqueArtists(
        _ primaryList: [String],
        _ secondaryList: [String],
        customAliases: [String: String] = [:]
    ) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for item in primaryList + secondaryList {
            let canon = canonicalizeSingle(item, customAliases: customAliases)
            guard !isJunkArtistString(canon) else { continue }
            let k = normalizeLookupKey(canon)
            if seen.insert(k).inserted {
                result.append(canon)
            }
        }
        return result
    }

    private static func scanUnseparatedTitleForKnownArtists(_ text: String) -> [String] {
        let padded = " \(normalizeLookupKey(text)) "
        guard padded.count > 2 else { return [] }
        var found: [String] = []
        var seen = Set<String>()
        // Store.unseparatedSearchTerms is sorted longest-first so "Kendrick Lamar" beats shorter partial terms
        for term in store.unseparatedSearchTerms {
            if padded.contains(" \(term.normalizedKey) ") {
                let key = normalizeLookupKey(term.canonicalName)
                if seen.insert(key).inserted {
                    found.append(term.canonicalName)
                }
                if found.count >= 3 { break }
            }
        }
        return found
    }

    static func normalizeLookupKey(_ raw: String) -> String {
        let folded = raw
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))

        var scalars = String.UnicodeScalarView()
        var lastWasSpace = true
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "$" {
                scalars.append(scalar)
                lastWasSpace = false
            } else if !lastWasSpace {
                scalars.append(" ")
                lastWasSpace = true
            }
        }
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Indexed Store

    private struct SearchTerm {
        let normalizedKey: String
        let canonicalName: String
    }

    private struct CatalogStore {
        let entries: [ArtistCatalogEntry]
        let byNormalizedKey: [String: ArtistCatalogEntry]
        let punctuatedProtectedNames: [String]
        let unseparatedSearchTerms: [SearchTerm]

        init(raw: String) {
            var parsedEntries: [ArtistCatalogEntry] = []
            var seenCanonicalKeys = Set<String>()
            var lookupMap: [String: ArtistCatalogEntry] = [:]
            var protectedNames: [String] = []
            var scanTerms: [SearchTerm] = []

            for line in raw.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                let cols = trimmed.components(separatedBy: "|")
                guard cols.count >= 2 else { continue }

                let name = cols[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let genre = cols[1].trimmingCharacters(in: .whitespacesAndNewlines)
                let flags = cols.count > 2 ? cols[2].uppercased() : ""
                let aliasesRaw = cols.count > 3 ? cols[3] : ""
                let aliases = aliasesRaw
                    .components(separatedBy: ";")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }

                let requiresSeparated = flags.contains("S")
                let canonicalKey = ArtistDatabase.normalizeLookupKey(name)
                guard !canonicalKey.isEmpty, seenCanonicalKeys.insert(canonicalKey).inserted else {
                    continue
                }

                let entry = ArtistCatalogEntry(
                    canonicalName: name,
                    genre: genre,
                    aliases: aliases,
                    requiresSeparatedContext: requiresSeparated
                )
                parsedEntries.append(entry)

                if lookupMap[canonicalKey] == nil {
                    lookupMap[canonicalKey] = entry
                }
                for alias in aliases {
                    let aliasKey = ArtistDatabase.normalizeLookupKey(alias)
                    if !aliasKey.isEmpty, lookupMap[aliasKey] == nil {
                        lookupMap[aliasKey] = entry
                    }
                }

                if name.contains(",") || name.contains("&") || name.contains("+") || name.contains("/") {
                    protectedNames.append(name)
                }

                if !requiresSeparated && canonicalKey.count >= 4 {
                    scanTerms.append(SearchTerm(normalizedKey: canonicalKey, canonicalName: name))
                }
            }

            protectedNames.sort { $0.count > $1.count }
            scanTerms.sort { $0.normalizedKey.count > $1.normalizedKey.count }

            self.entries = parsedEntries
            self.byNormalizedKey = lookupMap
            self.punctuatedProtectedNames = protectedNames
            self.unseparatedSearchTerms = scanTerms
        }
    }

    // Curated offline catalog of 540+ major global recording artists across Pop, Hip-Hop, R&B,
    // Rock, Electronic, Latin, K-Pop/J-Pop, Afrobeats, Country, and Film/Classical.
    // Format: CanonicalName|Genre|Flags(S = match only with tag/separator context)|alias1;alias2
    private static let rawCatalogData = """
Taylor Swift|Pop||tswift;taylor alison swift
The Weeknd|R&B & Soul||weeknd;abel tesfaye;the weekend
Drake|Hip-Hop & Rap||drizzy;aubrey graham;champagnepapi
Kendrick Lamar|Hip-Hop & Rap||kdot;k-dot;kung fu kenny
Kanye West|Hip-Hop & Rap||ye;yeezy
Billie Eilish|Pop||billie
Sabrina Carpenter|Pop||
Ariana Grande|Pop||ari;ariana
Chappell Roan|Pop||
Olivia Rodrigo|Pop||
Charli xcx|Pop||charli xcx
Dua Lipa|Pop||
Lady Gaga|Pop||gaga;stefani germanotta
Beyonce|Pop||beyoncé;queen bey
Rihanna|R&B & Soul||riri
SZA|R&B & Soul||solána rowe
Frank Ocean|R&B & Soul||christopher breaux
Tyler, The Creator|Hip-Hop & Rap||tyler the creator;tyler okonma
Travis Scott|Hip-Hop & Rap||la flame;cactus jack
Playboi Carti|Hip-Hop & Rap||carti;king vamp
Ken Carson|Hip-Hop & Rap||teen x
Destroy Lonely|Hip-Hop & Rap||
Don Toliver|Hip-Hop & Rap||
Metro Boomin|Hip-Hop & Rap||
Future|Hip-Hop & Rap|S|pluto;future hendrix
21 Savage|Hip-Hop & Rap||21
Lil Uzi Vert|Hip-Hop & Rap||uzi;symere woods
Young Thug|Hip-Hop & Rap||thugger;jeffery
Gunna|Hip-Hop & Rap||
J. Cole|Hip-Hop & Rap||j cole;jermaine cole
Eminem|Hip-Hop & Rap||slim shady;marshall mathers
Lil Wayne|Hip-Hop & Rap||lil' wayne;weezy;tunechi
Nicki Minaj|Hip-Hop & Rap||onikas;nicki
Cardi B|Hip-Hop & Rap||
Megan Thee Stallion|Hip-Hop & Rap||
Doja Cat|Pop||doja
Post Malone|Pop||posty
Juice WRLD|Hip-Hop & Rap||jarad higgins
XXXTENTACION|Hip-Hop & Rap||xxxtentacion;jahseh onfroy
Lil Peep|Hip-Hop & Rap||gustav ahr
Mac Miller|Hip-Hop & Rap||malcolm mccormick;larry fisherman
A$AP Rocky|Hip-Hop & Rap||asap rocky;lord flacko
Kid Cudi|Hip-Hop & Rap||scott mescudi
Childish Gambino|Hip-Hop & Rap||donald glover
2Pac|Hip-Hop & Rap||tupac;tupac shakur;makaveli
The Notorious B.I.G.|Hip-Hop & Rap||biggie;biggie smalls;notorious big
Nas|Hip-Hop & Rap|S|nasir jones
JAY-Z|Hip-Hop & Rap||jay z;hov;shawn carter
Snoop Dogg|Hip-Hop & Rap||snoop
Dr. Dre|Hip-Hop & Rap||dr dre
Ice Cube|Hip-Hop & Rap||
50 Cent|Hip-Hop & Rap||fifty cent;curtis jackson
N.W.A|Hip-Hop & Rap||nwa
OutKast|Hip-Hop & Rap||andre 3000;big boi
MF DOOM|Hip-Hop & Rap||mf doom;viktor vaughn;madvillain
Denzel Curry|Hip-Hop & Rap||zeltron
JID|Hip-Hop & Rap|S|j.i.d
Joey Bada$$|Hip-Hop & Rap||joey badass
Freddie Gibbs|Hip-Hop & Rap||
Pusha T|Hip-Hop & Rap||king push
Chief Keef|Hip-Hop & Rap||sosa
Kodak Black|Hip-Hop & Rap||
NBA YoungBoy|Hip-Hop & Rap||youngboy never broke again
Lil Baby|Hip-Hop & Rap||
Roddy Ricch|Hip-Hop & Rap||
DaBaby|Hip-Hop & Rap||
Jack Harlow|Hip-Hop & Rap||
Central Cee|Hip-Hop & Rap||cench
Stormzy|Hip-Hop & Rap||
Skepta|Hip-Hop & Rap||
Dave|Hip-Hop & Rap|S|santan dave
Little Simz|Hip-Hop & Rap||
$uicideboy$|Hip-Hop & Rap||suicideboys
Yeat|Hip-Hop & Rap|S|
Nettspend|Hip-Hop & Rap||
OsamaSon|Hip-Hop & Rap||
Che|Hip-Hop & Rap|S|
Pop Smoke|Hip-Hop & Rap||
King Von|Hip-Hop & Rap||
Polo G|Hip-Hop & Rap||
Lil Durk|Hip-Hop & Rap||
A Boogie wit da Hoodie|Hip-Hop & Rap||a boogie
Trippie Redd|Hip-Hop & Rap||
Ski Mask the Slump God|Hip-Hop & Rap||
Baby Keem|Hip-Hop & Rap||
Vince Staples|Hip-Hop & Rap||
Earl Sweatshirt|Hip-Hop & Rap||
Danny Brown|Hip-Hop & Rap||
JPEGMAFIA|Hip-Hop & Rap||jpegmafia;peggy
Run The Jewels|Hip-Hop & Rap||rtj
Logic|Hip-Hop & Rap|S|bobby tarantino
NF|Hip-Hop & Rap|S|
Wiz Khalifa|Hip-Hop & Rap||
Mac DeMarco|Rock & Alternative||
Steve Lacy|R&B & Soul||
Daniel Caesar|R&B & Soul||
Brent Faiyaz|R&B & Soul||sonder
Summer Walker|R&B & Soul||
Bryson Tiller|R&B & Soul||
PARTYNEXTDOOR|R&B & Soul||partynextdoor;pnd
6LACK|R&B & Soul||6lack
Kehlani|R&B & Soul||
H.E.R.|R&B & Soul|S|her
Tems|R&B & Soul|S|
Victoria Monet|R&B & Soul||victoria monét
Giveon|R&B & Soul||
Khalid|R&B & Soul|S|
Chris Brown|R&B & Soul||breezy
Usher|R&B & Soul|S|
Ne-Yo|R&B & Soul|S|neyo
Trey Songz|R&B & Soul||
Alicia Keys|R&B & Soul||
John Legend|R&B & Soul||
Bruno Mars|Pop||silk sonic
Anderson .Paak|R&B & Soul||anderson paak;nxworries
Miguel|R&B & Soul|S|
Jhene Aiko|R&B & Soul||jhené aiko
Solange|R&B & Soul||
Mary J. Blige|R&B & Soul||
Mariah Carey|Pop||mariah
Whitney Houston|Pop||
Michael Jackson|Pop||mj;king of pop
Janet Jackson|Pop||
Prince|Pop|S|
Stevie Wonder|R&B & Soul||
Marvin Gaye|R&B & Soul||
Aretha Franklin|R&B & Soul||
Otis Redding|R&B & Soul||
Sam Cooke|R&B & Soul||
Lauryn Hill|R&B & Soul||ms. lauryn hill
Erykah Badu|R&B & Soul||
D'Angelo|R&B & Soul||dangelo
Amy Winehouse|R&B & Soul||
Adele|Pop||
Sam Smith|Pop||
Ed Sheeran|Pop||
Justin Bieber|Pop||bieber
Harry Styles|Pop||
ZAYN|Pop|S|zayn malik
Niall Horan|Pop||
Louis Tomlinson|Pop||
Liam Payne|Pop||
One Direction|Pop||1d
Shawn Mendes|Pop||
Charlie Puth|Pop||
Camila Cabello|Pop||
Selena Gomez|Pop||
Miley Cyrus|Pop||
Demi Lovato|Pop||
Katy Perry|Pop||
P!nk|Pop|S|pink
Rihanna|R&B & Soul||
Britney Spears|Pop||
Christina Aguilera|Pop||xtina
Madonna|Pop|S|
Justin Timberlake|Pop||jt
Tate McRae|Pop||
Gracie Abrams|Pop||
Benson Boone|Pop||
Teddy Swims|Pop||
Hozier|Rock & Alternative||
Lana Del Rey|Pop||lana
Lorde|Pop||
Halsey|Pop||
Melanie Martinez|Pop||
Troye Sivan|Pop||
Conan Gray|Pop||
beabadoobee|Rock & Alternative||
clairo|Rock & Alternative||
Mitski|Rock & Alternative||
Phoebe Bridgers|Rock & Alternative||boygenius
FKA twigs|Electronic & Dance||
Caroline Polachek|Pop||
Carly Rae Jepsen|Pop||
Marina|Pop|S|marina and the diamonds
Sia|Pop|S|
Ava Max|Pop||
Bebe Rexha|Pop||
Zara Larsson|Pop||
Tyla|Afrobeats||
Kylie Minogue|Pop||
Ellie Goulding|Pop||
Kesha|Pop||ke$ha
Avril Lavigne|Pop||
Gwen Stefani|Pop||no doubt
Fergie|Pop||black eyed peas
The Black Eyed Peas|Pop||black eyed peas
Maroon 5|Pop||
Imagine Dragons|Pop||
OneRepublic|Pop||
AJR|Pop|S|
Twenty One Pilots|Rock & Alternative||tøp;21 pilots
Panic! At The Disco|Rock & Alternative||panic at the disco
Fall Out Boy|Rock & Alternative||fob
My Chemical Romance|Rock & Alternative||mcr
Paramore|Rock & Alternative||hayley williams
blink-182|Rock & Alternative||blink 182
Green Day|Rock & Alternative||
Sum 41|Rock & Alternative||
The Offspring|Rock & Alternative||
Weezer|Rock & Alternative||
Nirvana|Rock & Alternative||kurt cobain
Pearl Jam|Rock & Alternative||
Soundgarden|Rock & Alternative||
Alice In Chains|Rock & Alternative||
Foo Fighters|Rock & Alternative||dave grohl
Red Hot Chili Peppers|Rock & Alternative||rhcp
Linkin Park|Rock & Alternative||chester bennington
System Of A Down|Rock & Alternative||soad
Deftones|Rock & Alternative||
Korn|Rock & Alternative||
Slipknot|Rock & Alternative||
Metallica|Rock & Alternative||
Megadeth|Rock & Alternative||
Slayer|Rock & Alternative|S|
Anthrax|Rock & Alternative|S|
Iron Maiden|Rock & Alternative||
Black Sabbath|Rock & Alternative||ozzy osbourne
Judas Priest|Rock & Alternative||
Avenged Sevenfold|Rock & Alternative||a7x
Disturbed|Rock & Alternative|S|
Bring Me The Horizon|Rock & Alternative||bmth
Sleep Token|Rock & Alternative||
Bad Omens|Rock & Alternative||
Evanescence|Rock & Alternative||
Three Days Grace|Rock & Alternative||
Breaking Benjamin|Rock & Alternative||
Nickelback|Rock & Alternative||
Creed|Rock & Alternative|S|
Tool|Rock & Alternative|S|
A Perfect Circle|Rock & Alternative||
Nine Inch Nails|Rock & Alternative||nin
Rammstein|Rock & Alternative||
Ghost|Rock & Alternative|S|ghost bc
Queen|Rock & Alternative|S|freddie mercury
The Beatles|Rock & Alternative||beatles
The Rolling Stones|Rock & Alternative||rolling stones
Led Zeppelin|Rock & Alternative||
Pink Floyd|Rock & Alternative||
AC/DC|Rock & Alternative||acdc;ac dc;ac_dc
Guns N' Roses|Rock & Alternative||guns n roses
Aerosmith|Rock & Alternative||
Bon Jovi|Rock & Alternative||
Def Leppard|Rock & Alternative||
Van Halen|Rock & Alternative||
Kiss|Rock & Alternative|S|
Journey|Rock & Alternative|S|
Boston|Rock & Alternative|S|
Chicago|Rock & Alternative|S|
Toto|Rock & Alternative|S|
Fleetwood Mac|Rock & Alternative||stevie nicks
Eagles|Rock & Alternative|S|the eagles
Creedence Clearwater Revival|Rock & Alternative||ccr
The Doors|Rock & Alternative||jim morrison
Jimi Hendrix|Rock & Alternative||
Bob Dylan|Rock & Alternative||
David Bowie|Rock & Alternative||ziggy stardust
Elton John|Pop||
Billy Joel|Pop||
Bruce Springsteen|Rock & Alternative||
Tom Petty|Rock & Alternative||tom petty & the heartbreakers
U2|Rock & Alternative|S|
R.E.M.|Rock & Alternative||rem
Radiohead|Rock & Alternative||thom yorke
Coldplay|Rock & Alternative||
Muse|Rock & Alternative|S|
Oasis|Rock & Alternative|S|
Blur|Rock & Alternative|S|
Pulp|Rock & Alternative|S|
The Smiths|Rock & Alternative||morrissey
The Cure|Rock & Alternative||robert smith
Depeche Mode|Electronic & Dance||
New Order|Rock & Alternative||joy division
Joy Division|Rock & Alternative||
Talking Heads|Rock & Alternative||
Tears For Fears|Pop||
Duran Duran|Pop||
a-ha|Pop|S|aha
Gorillaz|Rock & Alternative||
Arctic Monkeys|Rock & Alternative||alex turner
The Strokes|Rock & Alternative||julian casablancas
The Killers|Rock & Alternative||
Kings of Leon|Rock & Alternative||
Vampire Weekend|Rock & Alternative||
Tame Impala|Rock & Alternative||kevin parker
MGMT|Rock & Alternative||
Foster The People|Rock & Alternative||
Cage The Elephant|Rock & Alternative||
The Neighbourhood|Rock & Alternative||the nbhd
The 1975|Rock & Alternative||
Glass Animals|Rock & Alternative||
alt-J|Rock & Alternative||alt j
Two Door Cinema Club|Rock & Alternative||
Phoenix|Rock & Alternative|S|
M83|Electronic & Dance||
Empire of the Sun|Electronic & Dance||
Florence + The Machine|Rock & Alternative||florence and the machine
Mumford & Sons|Rock & Alternative||
The Lumineers|Rock & Alternative||
Of Monsters and Men|Rock & Alternative||
Cigarettes After Sex|Rock & Alternative||cas
Beach House|Rock & Alternative||
Slowdive|Rock & Alternative||
My Bloody Valentine|Rock & Alternative||mbv
Pavement|Rock & Alternative|S|
Pixies|Rock & Alternative|S|
Sonic Youth|Rock & Alternative||
Smashing Pumpkins|Rock & Alternative||the smashing pumpkins
Rage Against The Machine|Rock & Alternative||ratm
Audioslave|Rock & Alternative||chris cornell
Incubus|Rock & Alternative||
311|Rock & Alternative|S|
Sublime|Rock & Alternative|S|
No Doubt|Rock & Alternative||
Daft Punk|Electronic & Dance||thomas bangalter
Justice|Electronic & Dance|S|
Deadmau5|Electronic & Dance||deadmau5
Calvin Harris|Electronic & Dance||
Avicii|Electronic & Dance||tim bergling
David Guetta|Electronic & Dance||
Tiesto|Electronic & Dance||tiësto
Martin Garrix|Electronic & Dance||
Zedd|Electronic & Dance||
Marshmello|Electronic & Dance||
The Chainsmokers|Electronic & Dance||chainsmokers
Kygo|Electronic & Dance||
Alan Walker|Electronic & Dance||
Skrillex|Electronic & Dance||sonny moore
Diplo|Electronic & Dance||major lazer
Major Lazer|Electronic & Dance||
DJ Snake|Electronic & Dance||
Fred again..|Electronic & Dance||fred again
Disclosure|Electronic & Dance|S|
Kaytranada|Electronic & Dance||
ODESZA|Electronic & Dance||odesza
Flume|Electronic & Dance||
Illenium|Electronic & Dance||
Porter Robinson|Electronic & Dance||virtual self
Madeon|Electronic & Dance||
Kaskade|Electronic & Dance||
Swedish House Mafia|Electronic & Dance||shm
Alesso|Electronic & Dance||
Afrojack|Electronic & Dance||
Hardwell|Electronic & Dance||
Armin van Buuren|Electronic & Dance||
Above & Beyond|Electronic & Dance||
FISHER|Electronic & Dance|S|
John Summit|Electronic & Dance||
Dom Dolla|Electronic & Dance||
Peggy Gou|Electronic & Dance||
Charlotte de Witte|Electronic & Dance||
Aphex Twin|Electronic & Dance||richard d james
Boards of Canada|Electronic & Dance||
Four Tet|Electronic & Dance||
Caribou|Electronic & Dance|S|
Jamie xx|Electronic & Dance||the xx
The xx|Rock & Alternative||
Bonobo|Electronic & Dance|S|
RÜFÜS DU SOL|Electronic & Dance||rufus du sol
Rufus Du Sol|Electronic & Dance||
Glass Beams|Electronic & Dance||
Bad Bunny|Latin & Reggaeton||benito
J Balvin|Latin & Reggaeton||
Daddy Yankee|Latin & Reggaeton||
Karol G|Latin & Reggaeton||la bichota
Shakira|Latin & Reggaeton||
Maluma|Latin & Reggaeton||
Ozuna|Latin & Reggaeton||
Rauw Alejandro|Latin & Reggaeton||
Feid|Latin & Reggaeton||ferxxo
Jhayco|Latin & Reggaeton||jhay cortez
Anuel AA|Latin & Reggaeton||
Rosalia|Latin & Reggaeton||rosalía
Peso Pluma|Latin & Reggaeton||doble p
Fuerza Regida|Latin & Reggaeton||
Grupo Frontera|Latin & Reggaeton||
Natanael Cano|Latin & Reggaeton||
Junior H|Latin & Reggaeton||
Eslabon Armado|Latin & Reggaeton||
Romeo Santos|Latin & Reggaeton||aventura
Enrique Iglesias|Latin & Reggaeton||
Luis Fonsi|Latin & Reggaeton||
Ricky Martin|Latin & Reggaeton||
Marc Anthony|Latin & Reggaeton||
Selena|Latin & Reggaeton|S|selena quintanilla
Becky G|Latin & Reggaeton||
Natti Natasha|Latin & Reggaeton||
Bizarrap|Latin & Reggaeton||bzrp
Quevedo|Latin & Reggaeton|S|
Myke Towers|Latin & Reggaeton||
Mora|Latin & Reggaeton|S|
Eladio Carrion|Latin & Reggaeton||eladio carrión
BTS|K-Pop & J-Pop||bangtan boys;bts official
BLACKPINK|K-Pop & J-Pop||blackpink
NewJeans|K-Pop & J-Pop||new jeans;njz
Stray Kids|K-Pop & J-Pop||skz
TWICE|K-Pop & J-Pop|S|twice
SEVENTEEN|K-Pop & J-Pop|S|svt
aespa|K-Pop & J-Pop||
IVE|K-Pop & J-Pop|S|ive
LE SSERAFIM|K-Pop & J-Pop||le sserafim
ILLIT|K-Pop & J-Pop||
EXO|K-Pop & J-Pop||
NCT 127|K-Pop & J-Pop||nct;nct dream
ENHYPEN|K-Pop & J-Pop||
TOMORROW X TOGETHER|K-Pop & J-Pop||txt
ATEEZ|K-Pop & J-Pop||
KATSEYE|K-Pop & J-Pop||
BABYMONSTER|K-Pop & J-Pop||
BIGBANG|K-Pop & J-Pop||g-dragon
G-DRAGON|K-Pop & J-Pop||g dragon
IU|K-Pop & J-Pop|S|lee jieun
PSY|K-Pop & J-Pop|S|
Jungkook|K-Pop & J-Pop||jung kook
Jimin|K-Pop & J-Pop||
V|K-Pop & J-Pop|S|kim taehyung
ROSE|K-Pop & J-Pop|S|rosé
LISA|K-Pop & J-Pop|S|lalisa
JENNIE|K-Pop & J-Pop|S|jennie kim
JISOO|K-Pop & J-Pop||
YOASOBI|K-Pop & J-Pop||ikura;ayase
Ado|K-Pop & J-Pop|S|
Kenshi Yonezu|K-Pop & J-Pop||hachi
Fujii Kaze|K-Pop & J-Pop||
Eve|K-Pop & J-Pop|S|
Creepy Nuts|K-Pop & J-Pop||
King Gnu|K-Pop & J-Pop||
LiSA|K-Pop & J-Pop|S|
Official HIGE DANdism|K-Pop & J-Pop||higedan
Mrs. GREEN APPLE|K-Pop & J-Pop||
Vaundy|K-Pop & J-Pop||
aimyon|K-Pop & J-Pop||
ONE OK ROCK|K-Pop & J-Pop||
BABYMETAL|K-Pop & J-Pop||
ATARASHII GAKKO!|K-Pop & J-Pop||atarashii gakko
RADWIMPS|K-Pop & J-Pop||
TK from Ling tosite sigure|K-Pop & J-Pop||ling tosite sigure
Nujabes|K-Pop & J-Pop||jun seba
Joe Hisaishi|Soundtrack & Classical||studio ghibli
Burna Boy|Afrobeats||
Wizkid|Afrobeats||
Davido|Afrobeats||
Rema|Afrobeats|S|
Asake|Afrobeats||
Ayra Starr|Afrobeats||
Tyla|Afrobeats||
Ckay|Afrobeats||
Omah Lay|Afrobeats||
Fireboy DML|Afrobeats||
Kizz Daniel|Afrobeats||
Black Sherif|Afrobeats||
Morgan Wallen|Country||
Zach Bryan|Country||
Luke Combs|Country||
Chris Stapleton|Country||
Shaboozey|Country||
Jelly Roll|Country||
Lainey Wilson|Country||
Dolly Parton|Country||
Johnny Cash|Country||
Willie Nelson|Country||
Garth Brooks|Country||
George Strait|Country||
Tim McGraw|Country||
Faith Hill|Country||
Shania Twain|Country||
Carrie Underwood|Country||
Keith Urban|Country||
Blake Shelton|Country||
Kane Brown|Country||
Bailey Zimmerman|Country||
Noah Kahan|Rock & Alternative||
Luke Bryan|Country||
Kacey Musgraves|Country||
Dan + Shay|Country||dan and shay
Florida Georgia Line|Country||
Jason Aldean|Country||
Eric Church|Country||
Hank Williams|Country||
Kool & The Gang|R&B & Soul||
Earth, Wind & Fire|R&B & Soul||earth wind and fire
Simon & Garfunkel|Rock & Alternative||
Hall & Oates|Pop||daryl hall & john oates
Huey Lewis & The News|Rock & Alternative||
Bob Marley & The Wailers|Rock & Alternative||bob marley
ABBA|Pop||abba
Bee Gees|Pop||
Donna Summer|Pop||
Diana Ross|R&B & Soul||the supremes
Whitney Houston|Pop||
Celine Dion|Pop||céline dion
George Michael|Pop||wham!
Wham!|Pop||wham
Cyndi Lauper|Pop||
Cher|Pop|S|
Barbra Streisand|Pop||
Frank Sinatra|Jazz & Standards||sinatra
Dean Martin|Jazz & Standards||
Nat King Cole|Jazz & Standards||
Ella Fitzgerald|Jazz & Standards||
Louis Armstrong|Jazz & Standards||
Miles Davis|Jazz & Standards||
John Coltrane|Jazz & Standards||
Bill Evans|Jazz & Standards||
Nina Simone|Jazz & Standards||
Etta James|R&B & Soul||
Ray Charles|R&B & Soul||
Al Green|R&B & Soul||
James Brown|R&B & Soul||
Curtis Mayfield|R&B & Soul||
Sade|R&B & Soul|S|sade adu
Luther Vandross|R&B & Soul||
Janet Jackson|Pop||
TLC|R&B & Soul|S|
Destiny's Child|R&B & Soul||destinys child
Boyz II Men|R&B & Soul||
Aaliyah|R&B & Soul||
Missy Elliott|Hip-Hop & Rap||
Timbaland|Hip-Hop & Rap||
Pharrell Williams|Hip-Hop & Rap||n.e.r.d;pharrell
N.E.R.D|Hip-Hop & Rap||nerd
Busta Rhymes|Hip-Hop & Rap||
Wu-Tang Clan|Hip-Hop & Rap||
Mobb Deep|Hip-Hop & Rap||
A Tribe Called Quest|Hip-Hop & Rap||q-tip
De La Soul|Hip-Hop & Rap||
Public Enemy|Hip-Hop & Rap||
Beastie Boys|Hip-Hop & Rap||
Cypress Hill|Hip-Hop & Rap||
DMX|Hip-Hop & Rap|S|
Ja Rule|Hip-Hop & Rap||
Nelly|Hip-Hop & Rap|S|
Ludacris|Hip-Hop & Rap||
T.I.|Hip-Hop & Rap|S|ti
Young Jeezy|Hip-Hop & Rap||jeezy
Gucci Mane|Hip-Hop & Rap||
2 Chainz|Hip-Hop & Rap||
Rick Ross|Hip-Hop & Rap||rozay
Meek Mill|Hip-Hop & Rap||
Big Sean|Hip-Hop & Rap||
Tyga|Hip-Hop & Rap|S|
Nicki Minaj|Hip-Hop & Rap||
A$AP Ferg|Hip-Hop & Rap||asap ferg
ScHoolboy Q|Hip-Hop & Rap||schoolboy q
Ab-Soul|Hip-Hop & Rap||
Isaiah Rashad|Hip-Hop & Rap||
Chance the Rapper|Hip-Hop & Rap||
Kehlani|R&B & Soul||
Kali Uchis|R&B & Soul||
Jorja Smith|R&B & Soul||
PinkPantheress|Pop||pink pantheress
Ice Spice|Hip-Hop & Rap||
GloRilla|Hip-Hop & Rap||
Sexyy Red|Hip-Hop & Rap||
Latto|Hip-Hop & Rap||
Flo Milli|Hip-Hop & Rap||
Doechii|Hip-Hop & Rap||
Tory Lanez|R&B & Soul||
The Kid LAROI|Pop||kid laroi
24kGoldn|Hip-Hop & Rap||
iann dior|Hip-Hop & Rap||
Dominic Fike|Rock & Alternative||
Omar Apollo|R&B & Soul||
d4vd|R&B & Soul||
Joji|R&B & Soul|S|filthy frank
Rich Brian|Hip-Hop & Rap||
NIKI|R&B & Soul|S|
Jackson Wang|K-Pop & J-Pop||
Shawn Desman|Pop||
Hans Zimmer|Soundtrack & Classical||
John Williams|Soundtrack & Classical||
Ludwig Goransson|Soundtrack & Classical||ludwig göransson
Ramin Djawadi|Soundtrack & Classical||
Howard Shore|Soundtrack & Classical||
Ennio Morricone|Soundtrack & Classical||
Alexandre Desplat|Soundtrack & Classical||
Trent Reznor & Atticus Ross|Soundtrack & Classical||
Yoko Shimomura|Soundtrack & Classical||
Nobuo Uematsu|Soundtrack & Classical||
Koji Kondo|Soundtrack & Classical||
Hiroyuki Sawano|Soundtrack & Classical||sawano hiroyuki
Yuki Hayashi|Soundtrack & Classical||
Ludwig van Beethoven|Soundtrack & Classical||beethoven
Wolfgang Amadeus Mozart|Soundtrack & Classical||mozart
Johann Sebastian Bach|Soundtrack & Classical||bach
Frederic Chopin|Soundtrack & Classical||chopin
Claude Debussy|Soundtrack & Classical||debussy
Pyotr Ilyich Tchaikovsky|Soundtrack & Classical||tchaikovsky
Antonio Vivaldi|Soundtrack & Classical||vivaldi
Max Richter|Soundtrack & Classical||
Ludovico Einaudi|Soundtrack & Classical||
Olafur Arnalds|Soundtrack & Classical||ólafur arnalds
Yiruma|Soundtrack & Classical||
Macklemore|Hip-Hop & Rap||ryan lewis
Pitbull|Pop||mr worldwide
Flo Rida|Pop||
Jason Derulo|Pop||
Akon|R&B & Soul||
T-Pain|R&B & Soul||tpain
Sean Paul|Latin & Reggaeton||
Shaggy|Latin & Reggaeton|S|
Sia|Pop|S|
Coldplay|Rock & Alternative||
Metallica|Rock & Alternative||
Sleepy Hallow|Hip-Hop & Rap||
Sheff G|Hip-Hop & Rap||
Lil Tjay|Hip-Hop & Rap||
A Boogie|Hip-Hop & Rap||
Fivio Foreign|Hip-Hop & Rap||
Ice-T|Hip-Hop & Rap||
Run-D.M.C.|Hip-Hop & Rap||run dmc
Grandmaster Flash|Hip-Hop & Rap||
Eric B. & Rakim|Hip-Hop & Rap||rakim
Big L|Hip-Hop & Rap||
Big Pun|Hip-Hop & Rap||
Mos Def|Hip-Hop & Rap||yasiin bey
Talib Kweli|Hip-Hop & Rap||
Common|Hip-Hop & Rap|S|
The Roots|Hip-Hop & Rap||questlove;black thought
Lupe Fiasco|Hip-Hop & Rap||
Kid Ink|Hip-Hop & Rap||
G-Eazy|Hip-Hop & Rap||geazy
Ty Dolla $ign|R&B & Soul||ty dolla sign
Swae Lee|Hip-Hop & Rap||rae sremmurd
Rae Sremmurd|Hip-Hop & Rap||
Migos|Hip-Hop & Rap||quavo;offset;takeoff
Quavo|Hip-Hop & Rap||
Offset|Hip-Hop & Rap|S|
Takeoff|Hip-Hop & Rap|S|
Lil Yachty|Hip-Hop & Rap||
Kodak Black|Hip-Hop & Rap||
NLE Choppa|Hip-Hop & Rap||
Key Glock|Hip-Hop & Rap||
Young Dolph|Hip-Hop & Rap||
Moneybagg Yo|Hip-Hop & Rap||
42 Dugg|Hip-Hop & Rap||
EST Gee|Hip-Hop & Rap||
Lucki|Hip-Hop & Rap|S|
Veeze|Hip-Hop & Rap||
Babyface Ray|Hip-Hop & Rap||
Smino|Hip-Hop & Rap||
Saba|Hip-Hop & Rap|S|
Noname|Hip-Hop & Rap||
Kelela|R&B & Soul||
Foushee|R&B & Soul||fousheé
Ravyn Lenae|R&B & Soul||
Lucky Daye|R&B & Soul||
Leon Bridges|R&B & Soul||
Khruangbin|Rock & Alternative||
Mac Miller|Hip-Hop & Rap||
Tame Impala|Rock & Alternative||
Kacey Musgraves|Country||
Benson Boone|Pop||
Teddy Swims|Pop||
Hozier|Rock & Alternative||
Djo|Rock & Alternative|S|joe keery
sombr|Rock & Alternative||
Alex Warren|Pop||
Myles Smith|Pop||
Lola Young|Pop||
Addison Rae|Pop||
Jennie|K-Pop & J-Pop|S|
Rosé|K-Pop & J-Pop|S|
Freddie Dredd|Hip-Hop & Rap||
Ghostemane|Hip-Hop & Rap||
Bones|Hip-Hop & Rap|S|teamsesh
HyunA|K-Pop & J-Pop||hyuna
iKON|K-Pop & J-Pop||
Mika Nakashima|K-Pop & J-Pop||中島美嘉;中島 美嘉
KAIWARE HUMMER|K-Pop & J-Pop||カイワレハンマー
Yasuha|K-Pop & J-Pop||泰葉
Yurie Kokubu|K-Pop & J-Pop||国分友里恵
Pearl Brothers|K-Pop & J-Pop||パール兄弟
ROUND TABLE|K-Pop & J-Pop|S|roundtable
FLOW|K-Pop & J-Pop|S|
Lacrim|Hip-Hop & Rap||
Soulja Boy|Hip-Hop & Rap||soulja boy tell em
DANGERDOOM|Hip-Hop & Rap||dangerdoom
Kankan|Hip-Hop & Rap||
Imogen Heap|Pop||
C418|Soundtrack & Classical||
# Expanded Big, Underground, Indie & Global Catalog
Lazer Dim 700|Hip-Hop & Rap||lazerdim700
1oneam|Hip-Hop & Rap|S|
Joeyy|Hip-Hop & Rap|S|
Molly Santana|Hip-Hop & Rap||
Fakemink|Hip-Hop & Rap||
EsDeeKid|Hip-Hop & Rap||esdeekid
Smokedope2016|Hip-Hop & Rap||smokedope
Glokk40Spaz|Hip-Hop & Rap||
Dom Corleo|Hip-Hop & Rap||
Rich Amiri|Hip-Hop & Rap||
Tana|Hip-Hop & Rap|S|babysantana
Hardrock|Hip-Hop & Rap|S|
Sematary|Hip-Hop & Rap||haunted mound
Bladee|Hip-Hop & Rap||drain gang
Ecco2k|Hip-Hop & Rap||
Thaiboy Digital|Hip-Hop & Rap||
Yung Lean|Hip-Hop & Rap||jonatan leandoer
Xaviersobased|Hip-Hop & Rap||xavier so based
phreshboyswag|Hip-Hop & Rap||
2hollis|Electronic & Hyperpop||
glaive|Electronic & Hyperpop|S|
ericdoa|Electronic & Hyperpop||eric doa
jane remover|Electronic & Hyperpop||
underscores|Electronic & Hyperpop|S|
brakence|Electronic & Hyperpop||
100 gecs|Electronic & Hyperpop||laura les;dylan brady
SOPHIE|Electronic & Hyperpop|S|
A. G. Cook|Electronic & Hyperpop||ag cook
Oklou|Electronic & Hyperpop||
Nine Vicious|Hip-Hop & Rap||
Yhapojj|Hip-Hop & Rap||
Iayze|Hip-Hop & Rap||jace
Summrs|Hip-Hop & Rap|S|
Autumn!|Hip-Hop & Rap|S|twinuzis
Izaya Tiji|Hip-Hop & Rap||
SoFaygo|Hip-Hop & Rap||faygo
Homixide Gang|Hip-Hop & Rap||
bktherula|Hip-Hop & Rap||
TiaCorine|Hip-Hop & Rap||
Cochise|Hip-Hop & Rap|S|
BabyTron|Hip-Hop & Rap||shittyboyz
Rio Da Yung OG|Hip-Hop & Rap||
RMC Mike|Hip-Hop & Rap||
Skilla Baby|Hip-Hop & Rap||
BossMan Dlow|Hip-Hop & Rap||
BigXthaPlug|Hip-Hop & Rap||bigx
That Mexican OT|Hip-Hop & Rap||mexican ot
Luh Tyler|Hip-Hop & Rap||
Anycia|Hip-Hop & Rap|S|
Karrahbooo|Hip-Hop & Rap||
Tierra Whack|Hip-Hop & Rap||
Samara Cyn|Hip-Hop & Rap||
MIKE|Hip-Hop & Rap|S|
billy woods|Hip-Hop & Rap||armand hammer
Mach-Hommy|Hip-Hop & Rap||
Westside Gunn|Hip-Hop & Rap||griselda
Conway the Machine|Hip-Hop & Rap||
Benny the Butcher|Hip-Hop & Rap||
Boldy James|Hip-Hop & Rap||
Roc Marciano|Hip-Hop & Rap||
Larry June|Hip-Hop & Rap||good job larry
Payroll Giovanni|Hip-Hop & Rap||
Curren$y|Hip-Hop & Rap||currensy;spitta
Action Bronson|Hip-Hop & Rap||
The Alchemist|Hip-Hop & Rap||alchemist
Madlib|Hip-Hop & Rap||quasimoto;lord quas
J Dilla|Hip-Hop & Rap||jay dee
KnXWLEDGE|Hip-Hop & Rap||knx
EarthGang|Hip-Hop & Rap||
Kenny Mason|Hip-Hop & Rap||
Redveil|Hip-Hop & Rap||
J Hus|Hip-Hop & Rap||
Headie One|Hip-Hop & Rap||
Knucks|Hip-Hop & Rap||
Nemzzz|Hip-Hop & Rap||
Pozer|Hip-Hop & Rap|S|
Faye Webster|Rock & Alternative||
Men I Trust|Rock & Alternative||
TV Girl|Rock & Alternative||
Alex G|Rock & Alternative||sandy alex g
Rex Orange County|Rock & Alternative||
Boygenius|Rock & Alternative||phoebe bridgers;julien baker;lucy dacus
Laufey|Jazz & Acoustic||
wave to earth|Rock & Alternative||wavetoearth
Malcolm Todd|Pop||
Role Model|Pop|S|
Sonder|R&B & Soul|S|
4batz|R&B & Soul||
Mariah the Scientist|R&B & Soul||
FLO|R&B & Soul|S|
Coco Jones|R&B & Soul||
Leon Thomas|R&B & Soul||
Destin Conrad|R&B & Soul||
Tinashe|R&B & Soul||
Victoria Monét|R&B & Soul||victoria monet
Snoh Aalegra|R&B & Soul||
Cleo Sol|R&B & Soul||
SiR|R&B & Soul|S|
Blood Orange|R&B & Soul||dev hynes
Sampha|R&B & Soul||
RAYE|Pop|S|
Gigi Perez|Pop||
Reneé Rapp|Pop||renee rapp
The Marías|Rock & Alternative||the marias
Alvvays|Rock & Alternative||
Magdalena Bay|Electronic & Hyperpop||
Title Fight|Rock & Alternative||
Whirr|Rock & Alternative|S|
Wisp|Rock & Alternative|S|
Julie|Rock & Alternative|S|
Fontaines D.C.|Rock & Alternative||fontaines dc
IDLES|Rock & Alternative|S|
Turnstile|Rock & Alternative|S|
Wallows|Rock & Alternative||
Overmono|Electronic & Hyperpop||
Bicep|Electronic & Hyperpop|S|
Amelie Lens|Electronic & Hyperpop||
Anyma|Electronic & Hyperpop|S|
Knock2|Electronic & Hyperpop||
ISOxo|Electronic & Hyperpop||isoxo
RL Grime|Electronic & Hyperpop||
Nia Archives|Electronic & Hyperpop||
Machine Girl|Electronic & Hyperpop||
Kordhell|Electronic & Hyperpop||
DVRST|Electronic & Hyperpop||
interworld|Electronic & Hyperpop|S|
MC Orsen|Electronic & Hyperpop||
Uncle Waffles|Afrobeats||
Olamide|Afrobeats||
Gabito Ballesteros|Latin & Reggaeton||
Tito Double P|Latin & Reggaeton||
Neton Vega|Latin & Reggaeton||
Oscar Maydon|Latin & Reggaeton||
Xavi|Latin & Reggaeton|S|
Cris Mj|Latin & Reggaeton||
FloyyMenor|Latin & Reggaeton||floyymenor
Young Miko|Latin & Reggaeton||
Eladio Carrión|Latin & Reggaeton||eladio carrion
ROSALÍA|Latin & Reggaeton||rosalia
Tokischa|Latin & Reggaeton||
Ichiko Aoba|Rock & Alternative||青葉市子
Lamp|Rock & Alternative|S|
Tatsuro Yamashita|K-Pop & J-Pop||山下達郎
Mariya Takeuchi|K-Pop & J-Pop||竹内まりや
Anri|K-Pop & J-Pop|S|杏里
Miki Matsubara|K-Pop & J-Pop||松原みき
Masayoshi Takanaka|Rock & Alternative||高中正義
Natori|K-Pop & J-Pop||なとり
imase|K-Pop & J-Pop|S|
XG|K-Pop & J-Pop|S|
KISS OF LIFE|K-Pop & J-Pop||
RIIZE|K-Pop & J-Pop||
BOYNEXTDOOR|K-Pop & J-Pop||
ITZY|K-Pop & J-Pop||
(G)I-DLE|K-Pop & J-Pop||gidle
NMIXX|K-Pop & J-Pop||
BIBI|K-Pop & J-Pop|S|
DEAN|R&B & Soul|S|
DPR IAN|K-Pop & J-Pop||dpr live
keshi|R&B & Soul||
Tyler Childers|Country||
Sturgill Simpson|Country||
Megan Moroney|Country||
Ella Langley|Country||
Riley Green|Country||
Sierra Ferrell|Country||
Billy Strings|Country||
Wyatt Flores|Country||
Treaty Oak Revival|Country||
cheRomani|Hip-Hop & Rap||
Protect|Hip-Hop & Rap|S|
Duwap Kaine|Hip-Hop & Rap||
Black Kray|Hip-Hop & Rap||sickboyrari
Spaceghostpurrp|Hip-Hop & Rap||sgp
Lil Shine|Hip-Hop & Rap||
Desire|Hip-Hop & Rap|S|
Jace!|Hip-Hop & Rap|S|
TDF|Hip-Hop & Rap|S|
Boolymon|Hip-Hop & Rap||
Jaydes|Hip-Hop & Rap||
Wifiskeleton|Hip-Hop & Rap||
Untiljapan|Hip-Hop & Rap||
Southsidesilhouette|Hip-Hop & Rap||
Ohsxnta|Hip-Hop & Rap||
Fluhkunxhkos|Hip-Hop & Rap||
Yung Bans|Hip-Hop & Rap||
Thouxanbanfauni|Hip-Hop & Rap||fauni
Unotheactivist|Hip-Hop & Rap||uno the activist
Madeintyo|Hip-Hop & Rap||
Maxo Kream|Hip-Hop & Rap||
Key!|Hip-Hop & Rap|S|
Mick Jenkins|Hip-Hop & Rap||
Jay Rock|Hip-Hop & Rap||
Reason|Hip-Hop & Rap|S|
Lancey Foux|Hip-Hop & Rap||
Fimi Guerrero|Hip-Hop & Rap||fimiguerrero
Len|Hip-Hop & Rap|S|
Yt|Hip-Hop & Rap|S|
Kyle Richh|Hip-Hop & Rap||41
Jenn Carter|Hip-Hop & Rap||
Tata|Hip-Hop & Rap|S|
DThang|Hip-Hop & Rap||dthang gz
Kay Flock|Hip-Hop & Rap||
Sha Ek|Hip-Hop & Rap||
Sugarhill Ddot|Hip-Hop & Rap||
Mabu|Hip-Hop & Rap|S|lil mabu
Dd Osama|Hip-Hop & Rap||
Notti Osama|Hip-Hop & Rap||
41|Hip-Hop & Rap|S|
Cash Cobain|Hip-Hop & Rap||slizzy
Chow Lee|Hip-Hop & Rap||
Bay Swag|Hip-Hop & Rap||
Vonte*|Hip-Hop & Rap|S|
Vonoff1700|Hip-Hop & Rap||
Chuckyy|Hip-Hop & Rap||
Screwly G|Hip-Hop & Rap||
Q50|Hip-Hop & Rap|S|
Lil Jeff|Hip-Hop & Rap||
Bloodhound Q50|Hip-Hop & Rap||
G Herbo|Hip-Hop & Rap||lil herb
Peejy|Hip-Hop & Rap||
Icewear Vezzo|Hip-Hop & Rap||
Krispylife Kidd|Hip-Hop & Rap||
YN Jay|Hip-Hop & Rap||
Louie Ray|Hip-Hop & Rap||
Enrgy Beats|Hip-Hop & Rap||
Ohgeesy|Hip-Hop & Rap||shoreline mafia
Fenix Flexin|Hip-Hop & Rap||
Blxst|R&B & Soul||
Bino Rideaux|Hip-Hop & Rap||
Kalan.FrFr|Hip-Hop & Rap||kalan frfr
Buddha Lovas|Hip-Hop & Rap||
YG|Hip-Hop & Rap|S|
Dom Kennedy|Hip-Hop & Rap||
Nipsey Hussle|Hip-Hop & Rap||
Mozzy|Hip-Hop & Rap||
EBK Jaaybo|Hip-Hop & Rap||
Remble|Hip-Hop & Rap|S|
Bluebucksclan|Hip-Hop & Rap||
Dxrt3all|Hip-Hop & Rap||
Mazzy Star|Rock & Alternative||hope sandoval
Cocteau Twins|Rock & Alternative||
Jeff Buckley|Rock & Alternative||
Elliott Smith|Rock & Alternative||
Fiona Apple|Rock & Alternative||
Björk|Electronic & Hyperpop||björk
Portishead|Electronic & Hyperpop||
Massive Attack|Electronic & Hyperpop||
Amaarae|R&B & Soul||
Sudan Archives|R&B & Soul||
Yves Tumor|Rock & Alternative||
King Krule|Rock & Alternative||
Panchiko|Rock & Alternative||
Duster|Rock & Alternative|S|
American Football|Rock & Alternative||
Sunny Day Real Estate|Rock & Alternative||
Lush|Rock & Alternative|S|
Ride|Rock & Alternative|S|
Julien Baker|Rock & Alternative||
Lucy Dacus|Rock & Alternative||
Adrianne Lenker|Rock & Alternative||big thief
Big Thief|Rock & Alternative||
Japanese Breakfast|Rock & Alternative||michelle zauner
Soccer Mommy|Rock & Alternative||
Snail Mail|Rock & Alternative||
Mk.gee|Rock & Alternative||mkgee
Dijon|R&B & Soul|S|
Jai Paul|Electronic & Hyperpop||
Dean Blunt|Electronic & Hyperpop||babyfather
Bar Italia|Rock & Alternative||
Channel Tres|Electronic & Hyperpop||
Sam Gellaitry|Electronic & Hyperpop||
Montell Fish|R&B & Soul||
Sewerslvt|Electronic & Hyperpop||cynthoni
Femtanyl|Electronic & Hyperpop||
Snow Strippers|Electronic & Hyperpop||
Damon R|Electronic & Hyperpop||
Brothel|Electronic & Hyperpop||
Sidewalks And Skeletons|Electronic & Hyperpop||
Pastel Ghost|Electronic & Hyperpop||
Crystal Castles|Electronic & Hyperpop||
Salem|Electronic & Hyperpop|S|
White Ring|Electronic & Hyperpop||
Kamasi Washington|Jazz & Acoustic||
Robert Glasper|Jazz & Acoustic||
Thundercat|Jazz & Acoustic||stephen bruner
Flying Lotus|Electronic & Hyperpop||flylo;captain murphy
BADBADNOTGOOD|Jazz & Acoustic||bbng
Yussef Dayes|Jazz & Acoustic||
DOMi & JD BECK|Jazz & Acoustic||domi and jd beck
Tom Misch|R&B & Soul||
FKJ|Electronic & Hyperpop|S|french kiwi juice
Hiatus Kaiyote|R&B & Soul||
Free Nationals|R&B & Soul||
Masego|R&B & Soul||
Raveena|R&B & Soul||
Sabrina Claudio|R&B & Soul||
Alina Baraz|R&B & Soul||
"""
}
