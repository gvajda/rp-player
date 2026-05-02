import Foundation

public actor SongRegistry {
    private struct Entry {
        let songId: String
        let song: PlayListSong
    }

    private var entries: [Entry] = []
    private let capacity: Int

    public init(capacity: Int = 100) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public func record(_ song: PlayListSong) {
        entries.removeAll { $0.songId == song.songId }
        entries.append(Entry(songId: song.songId, song: song))
        while entries.count > capacity {
            entries.removeFirst()
        }
    }

    public func lookup(songId: String) -> PlayListSong? {
        entries.first(where: { $0.songId == songId })?.song
    }
}
