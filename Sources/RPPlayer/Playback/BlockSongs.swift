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

    static func startsAtSeconds(songs: [PlayListSong]) -> [Double] {
        var starts: [Double] = []
        starts.reserveCapacity(songs.count)
        var running: Double = 0
        for song in songs {
            starts.append(running)
            running += Double(song.duration) / 1000.0
        }
        return starts
    }

    static func totalDurationSeconds(songs: [PlayListSong]) -> Double {
        songs.reduce(0.0) { $0 + Double($1.duration) / 1000.0 }
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
