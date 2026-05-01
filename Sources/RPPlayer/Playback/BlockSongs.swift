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
}
