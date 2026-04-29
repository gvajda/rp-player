import Foundation

public struct Channel: Codable, Sendable, Equatable {
    public let chan: String
    public let title: String
    public let streamName: String?
    public let bannerUrl: String?
    public let slug: String?
    public let image: String?
}

public struct PlayListSong: Codable, Sendable, Equatable {
    public let songId: String
    public let artist: String
    public let title: String
    public let album: String
    /// Duration in milliseconds. The legacy C# typed this as `string`, but the
    /// live API returns it as an integer (e.g. 158807).
    public let duration: Int
    public let event: String?
    public let schedTime: String?
    public let chan: String?
    public let year: String?
    public let asin: String?
    public let rating: String?
    public let userRating: String?
    public let cover: String?
    public let elapsed: Int?
    public let slideshow: String?
}

public struct GetBlock: Codable, Sendable, Equatable {
    public let url: String
    /// The live API returns `chan` as a String (e.g. "0"), not an integer.
    /// Deviated from spec (Int) to match fixture shape.
    public let chan: String
    public let bitrate: String?
    public let cue: Int
    public let expiration: Int
    public let length: String?
    public let imageBase: String
    public let song: [String: PlayListSong]
    public let channel: Channel?
    public let event: String?
    /// The live API returns `end_event` as a String (e.g. "2868121"), not an integer.
    /// Deviated from spec (Int?) to match fixture shape.
    public let endEvent: String?
    public let type: String?
    public let ext: String?
    public let filename: [String: String]?
}

public struct SongInfo: Codable, Sendable, Equatable {
    public let songId: Int
    public let artist: String
    public let title: String
    public let album: String?
    public let asin: String?
    public let avgRating: Double?
    public let numRatings: String?
    public let userRating: Int?
    public let webLink: String?
    public let wikiLink: String?
    public let lyricsAvail: String?
    public let lyrics: String?
    public let medCover: String?
    public let largeCover: String?
    public let releaseDate: String?
    public let length: String?
    public let plays30: Int?
    public let slideshow: String?

    private enum CodingKeys: String, CodingKey {
        case songId, artist, title, album, asin, avgRating, numRatings, userRating
        case webLink, wikiLink, lyricsAvail, lyrics, medCover, largeCover
        case releaseDate, length, plays30, slideshow
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // song_id may be Int or String per legacy AllowReadingFromString contract.
        if let i = try? c.decode(Int.self, forKey: .songId) {
            songId = i
        } else if let s = try? c.decode(String.self, forKey: .songId), let i = Int(s) {
            songId = i
        } else {
            throw DecodingError.typeMismatch(
                Int.self,
                .init(codingPath: c.codingPath, debugDescription: "song_id is neither Int nor numeric String")
            )
        }
        artist = try c.decode(String.self, forKey: .artist)
        title = try c.decode(String.self, forKey: .title)
        album = try c.decodeIfPresent(String.self, forKey: .album)
        asin = try c.decodeIfPresent(String.self, forKey: .asin)
        avgRating = try c.decodeIfPresent(Double.self, forKey: .avgRating)
        numRatings = try c.decodeIfPresent(String.self, forKey: .numRatings)
        userRating = try c.decodeIfPresent(Int.self, forKey: .userRating)
        webLink = try c.decodeIfPresent(String.self, forKey: .webLink)
        wikiLink = try c.decodeIfPresent(String.self, forKey: .wikiLink)
        lyricsAvail = try c.decodeIfPresent(String.self, forKey: .lyricsAvail)
        lyrics = try c.decodeIfPresent(String.self, forKey: .lyrics)
        medCover = try c.decodeIfPresent(String.self, forKey: .medCover)
        largeCover = try c.decodeIfPresent(String.self, forKey: .largeCover)
        releaseDate = try c.decodeIfPresent(String.self, forKey: .releaseDate)
        length = try c.decodeIfPresent(String.self, forKey: .length)
        plays30 = try c.decodeIfPresent(Int.self, forKey: .plays30)
        slideshow = try c.decodeIfPresent(String.self, forKey: .slideshow)
    }
}

public struct Rating: Codable, Sendable, Equatable {
    public let status: String?
    public let songId: Int?
    public let userId: String?
    public let userRating: Int?

    private enum CodingKeys: String, CodingKey {
        case status, songId, userId
        case userRating = "rating"
    }
}

public struct Auth: Codable, Sendable, Equatable {
    public let userId: String?
    public let postOk: String?
    public let username: String?
    public let level: String?
    public let countryCode: String?
    public let avatar: String?
    public let privmsgNew: Bool?
    public let status: String?
}
