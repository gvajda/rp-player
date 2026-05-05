import Foundation

enum BlockSongs {
    static func orderedSongs(from block: GetBlock) -> [PlayListSong] {
        block.song
            .compactMap { (key, value) -> (Int, PlayListSong)? in
                guard let idx = Int(key) else { return nil }
                return (idx, value)
            }
            .sorted { $0.0 < $1.0 }
            .map { $0.1 }
    }

    // Returns each song's absolute start offset (seconds) from the audio file's beginning.
    // `song.elapsed` is the authoritative value from the API; the `?? 0` guard covers
    // test stubs that omit it.
    static func startsAtSeconds(songs: [PlayListSong]) -> [Double] {
        songs.map { Double($0.elapsed ?? 0) / 1000.0 }
    }

    // End of the last listed song, as an absolute offset from the file start.
    // Used for prefetch "< 10 s remaining" check against mpv's absolute time-pos.
    static func totalDurationSeconds(songs: [PlayListSong]) -> Double {
        guard let last = songs.last else { return 0 }
        return Double((last.elapsed ?? 0) + last.duration) / 1000.0
    }

    // Largest i where startsAtSeconds[i] <= positionSeconds. Clamps below to 0
    // and above to count - 1; returns 0 for an empty array.
    static func indexOfSong(at positionSeconds: Double, in startsAtSeconds: [Double]) -> Int {
        guard !startsAtSeconds.isEmpty else { return 0 }
        if positionSeconds <= 0 { return 0 }
        var result = 0
        for (i, start) in startsAtSeconds.enumerated() where start <= positionSeconds {
            result = i
        }
        return result
    }

    // True when the bootstrap response is for a block whose audio file has
    // already played past its end (server cursor lagged real-time). Detected
    // by cue == 0 AND every song's elapsed offset being <= 0 with at least
    // one strictly negative — distinguishing stale blocks from fresh promo
    // blocks (single song, elapsed=0).
    static func isStale(songs: [PlayListSong], cue: Int) -> Bool {
        guard !songs.isEmpty, cue == 0 else { return false }
        let elapsedValues = songs.map { $0.elapsed ?? 0 }
        return elapsedValues.allSatisfy { $0 <= 0 } && elapsedValues.contains { $0 < 0 }
    }
}
