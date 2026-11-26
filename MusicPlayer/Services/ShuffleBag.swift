import Foundation

/// "Shuffle without repeats."
///
/// The old shuffle picked `queue.randomElement()` every time a song ended (only excluding the song
/// that was playing), so the same few songs could come back again and again while others never played.
///
/// A shuffle bag deals every song in the current playlist/library exactly once, in random order.
/// Only after every song has played does it reshuffle for a new cycle, and the new cycle never starts
/// with the songs that just played. Turning shuffle off/on (or tapping Shuffle Play) restarts it.
struct ShuffleBag {
    /// Songs still to play this cycle, in order.
    private(set) var remaining: [String] = []
    /// Songs already played this cycle, oldest first (the current song is last).
    private(set) var history: [String] = []
    private(set) var contextKey: String?
    /// The song that ended the previous cycle. It is also dealt into the new cycle (just not near the
    /// front), so while it keeps playing it must not be counted as "played" in the new cycle.
    private var carriedOverPath: String?

    /// Up to this many of the most recently played songs are kept out of the start of a new cycle
    /// (capped at a third of the playlist so small playlists still shuffle).
    var recentGuard = 10

    mutating func reset() {
        remaining = []
        history = []
        contextKey = nil
        carriedOverPath = nil
    }

    /// Brings the bag in line with the queue: new songs get dealt in at random positions, deleted
    /// songs drop out, and the current song counts as played.
    mutating func sync(queue: [String], current: String?, contextKey key: String) {
        if key != contextKey {
            reset()
            contextKey = key
        }
        let valid = Set(queue)
        remaining.removeAll { !valid.contains($0) }
        history.removeAll { !valid.contains($0) }

        if let current, valid.contains(current), current != carriedOverPath {
            carriedOverPath = nil
            remaining.removeAll { $0 == current }
            if history.last != current {
                history.removeAll { $0 == current }
                history.append(current)
            }
        }

        var known = Set(remaining)
        known.formUnion(history)
        var seen = Set<String>()
        let newcomers = queue.filter { !known.contains($0) && seen.insert($0).inserted }
        for path in newcomers.shuffled() {
            let index = remaining.isEmpty ? 0 : Int.random(in: 0...remaining.count)
            remaining.insert(path, at: index)
        }
    }

    /// The next song to play. `consume: false` only peeks (used to prepare a crossfade).
    mutating func next(queue: [String], current: String?, contextKey key: String, consume: Bool) -> String? {
        sync(queue: queue, current: current, contextKey: key)

        if remaining.isEmpty {
            // Every song has played once: start a new cycle.
            startNewCycle(queue: queue, current: current)
        }
        guard let nextPath = remaining.first else { return nil }
        if consume {
            remaining.removeFirst()
        }
        return nextPath
    }

    /// Goes back to the song played before the current one in this cycle, putting the current song
    /// back at the front of the upcoming list so it isn't lost.
    mutating func previous(queue: [String], current: String?, contextKey key: String) -> String? {
        sync(queue: queue, current: current, contextKey: key)
        guard history.count >= 2 else { return nil }
        let currentPath = history.removeLast()
        let previousPath = history.removeLast()
        remaining.insert(currentPath, at: 0)
        return previousPath
    }

    /// Read-only preview of what's coming up (for "Continue Playing" lists). Does not mutate.
    func upcomingPreview(queue: [String], current: String?, contextKey key: String) -> [String] {
        guard key == contextKey else {
            return queue.filter { $0 != current }
        }
        let valid = Set(queue)
        var known = Set(remaining)
        known.formUnion(history)
        let upcoming = remaining.filter { valid.contains($0) && $0 != current }
        let newcomers = queue.filter { !known.contains($0) && $0 != current }
        return upcoming + newcomers
    }

    private mutating func startNewCycle(queue: [String], current: String?) {
        var seen = Set<String>()
        var fresh = queue.filter { seen.insert($0).inserted }.shuffled()
        guard fresh.count > 1 || (fresh.count == 1 && fresh[0] != current) else {
            remaining = []
            return
        }

        // Keep the song that's playing now and the few before it out of the first slots of the new
        // cycle, so the reshuffle never sounds like a repeat.
        let guardCount = max(1, min(recentGuard, fresh.count / 3))
        var recent = Set(history.suffix(guardCount + 1))
        if let current { recent.insert(current) }
        if fresh.count > guardCount {
            for i in 0..<guardCount where recent.contains(fresh[i]) {
                if let swapIndex = (guardCount..<fresh.count).shuffled().first(where: { !recent.contains(fresh[$0]) }) {
                    fresh.swapAt(i, swapIndex)
                } else if let swapIndex = (guardCount..<fresh.count).shuffled().first(where: { fresh[$0] != current }),
                          fresh[i] == current {
                    fresh.swapAt(i, swapIndex)
                }
            }
        }
        if fresh.first == current, fresh.count > 1 {
            fresh.swapAt(0, fresh.count - 1)
        }

        remaining = fresh
        history = []
        carriedOverPath = current
    }
}
