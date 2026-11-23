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
        "alexrainbirdmusic", "chilledcow", "lofi girl", "unique vibes", "royal bass", "cloud vibes"
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

    static func cleanSongTitleForSearch(
        rawTitle: String,
        rawArtistTag: String? = nil,
        ignoredChannels: Set<String> = []
    ) -> (songOnly: String, artistHint: String?) {
        let trimmed = stripFileExtension(rawTitle).trimmingCharacters(in: .whitespacesAndNewlines)
        let (withoutNoise, _) = extractFeaturesAndStripNoise(from: trimmed)
        let cleanedArtistTag = rawArtistTag.flatMap { cleanChannelOrTagNoise($0) }
        let tagIsChannel = cleanedArtistTag.map {
            isJunkArtistString($0) || looksLikeUploaderChannel($0, customIgnoredChannels: ignoredChannels)
        } ?? false

        for separator in [" - ", " — ", " – ", " | "] {
            if let range = withoutNoise.range(of: separator) {
                let left = stripLeadingTrackNumber(String(withoutNoise[..<range.lowerBound]))
                let right = String(withoutNoise[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !left.isEmpty && !right.isEmpty {
                    let leftIsChannel = looksLikeUploaderChannel(left, customIgnoredChannels: ignoredChannels) ||
                        (cleanedArtistTag.map { normalizeLookupKey($0) == normalizeLookupKey(left) } ?? false)
                    let rightIsChannel = looksLikeUploaderChannel(right, customIgnoredChannels: ignoredChannels) ||
                        (cleanedArtistTag.map { normalizeLookupKey($0) == normalizeLookupKey(right) } ?? false)

                    if leftIsChannel && !rightIsChannel {
                        return (right, nil)
                    }
                    if rightIsChannel && !leftIsChannel {
                        return (left, nil)
                    }

                    let leftKnown = lookup(left) != nil || splitAndCanonicalize(left).contains { lookup($0) != nil }
                    let rightKnown = lookup(right) != nil || splitAndCanonicalize(right).contains { lookup($0) != nil }

                    if rightKnown && !leftKnown {
                        return (left, splitAndCanonicalize(right).first)
                    }
                    if leftKnown && !rightKnown {
                        return (right, splitAndCanonicalize(left).first)
                    }

                    // Standard YouTube music upload pattern: "Artist - Song Title"
                    if let cleanedArtistTag, !tagIsChannel,
                       normalizeLookupKey(cleanedArtistTag) == normalizeLookupKey(left) {
                        return (right, left)
                    }
                    return (right, tagIsChannel ? nil : cleanedArtistTag)
                }
            }
        }

        return (
            stripLeadingTrackNumber(withoutNoise.isEmpty ? trimmed : withoutNoise),
            tagIsChannel ? nil : cleanedArtistTag
        )
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

        // Strip trailing "feat. Artist" when unbracketed
        if let inlineFeatRegex = try? NSRegularExpression(
            pattern: #"\s+(?:feat\.?|ft\.?|featuring)\s+([^-\|\(\)\[\]]+)$"#,
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

        // Remove bracketed/parenthetical noise tags cleanly
        let noisePattern = #"[\(\[]\s*(?:official(?:\s+(?:music|lyric|audio|hd|4k))?\s*(?:video|audio|visualizer|mv|m/v)?|lyrics?|lyric video|audio|video|hd|4k|hq|explicit|clean|remaster(?:ed)?(?:\s*\d{4})?|live|acoustic|sped up|slowed(?:\s*\+\s*reverb)?|topic)\s*[\)\]]"#
        if let noiseRegex = try? NSRegularExpression(pattern: noisePattern, options: [.caseInsensitive]) {
            text = noiseRegex.stringByReplacingMatches(
                in: text,
                range: NSRange(location: 0, length: (text as NSString).length),
                withTemplate: " "
            )
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
        customAliases: [String: String]
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
AC/DC|Rock & Alternative||acdc
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
"""
}
