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
    /// Optional because RP "promo" blocks (DJ talk, type "P") omit album.
    public let album: String?
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
    /// RP block type: "M" = music, "P" = promo. Null for favorites bootstrap.
    public let type: String?
    /// Per-block slice index. String for music ("5"), JSON null for favorites; sent verbatim back as `slice_num` on the next `api/gapless`.
    public let sliceNum: String?

    public init(
        songId: String, artist: String, title: String, album: String?,
        duration: Int, event: String?, schedTime: String?, chan: String?,
        year: String?, asin: String?, rating: String?, userRating: String?,
        cover: String?, elapsed: Int?, slideshow: String?,
        type: String?, sliceNum: String?
    ) {
        self.songId = songId
        self.artist = artist
        self.title = title
        self.album = album
        self.duration = duration
        self.event = event
        self.schedTime = schedTime
        self.chan = chan
        self.year = year
        self.asin = asin
        self.rating = rating
        self.userRating = userRating
        self.cover = cover
        self.elapsed = elapsed
        self.slideshow = slideshow
        self.type = type
        self.sliceNum = sliceNum
    }
}

public extension PlayListSong {
    init(from song: GaplessSong) {
        self.init(
            songId: song.songId,
            artist: song.artist,
            title: song.title,
            album: song.album,
            duration: song.duration,
            event: String(song.eventId),
            schedTime: nil,
            chan: nil,
            year: song.year,
            asin: nil,
            rating: song.rating > 0 ? String(song.rating) : nil,
            userRating: song.userRating > 0 ? String(song.userRating) : nil,
            cover: song.coverLarge ?? song.coverMedium,
            elapsed: nil,
            slideshow: nil,
            type: song.type,
            sliceNum: String(song.sliceNum)
        )
    }

    init(from info: SongInfo) {
        self.init(
            songId: String(info.songId),
            artist: info.artist,
            title: info.title,
            album: info.album,
            duration: (info.length.flatMap(Int.init) ?? 0) * 1000,
            event: nil,
            schedTime: nil,
            chan: nil,
            year: nil,
            asin: info.asin,
            rating: info.avgRating.map { String($0) },
            userRating: info.userRating.map { String($0) },
            cover: info.largeCover ?? info.medCover,
            elapsed: nil,
            slideshow: info.slideshow,
            type: nil,
            sliceNum: nil
        )
    }
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

    public init(
        songId: Int, artist: String, title: String, album: String?, asin: String?,
        avgRating: Double?, numRatings: String?, userRating: Int?,
        webLink: String?, wikiLink: String?, lyricsAvail: String?, lyrics: String?,
        medCover: String?, largeCover: String?,
        releaseDate: String?, length: String?, plays30: Int?, slideshow: String?
    ) {
        self.songId = songId
        self.artist = artist
        self.title = title
        self.album = album
        self.asin = asin
        self.avgRating = avgRating
        self.numRatings = numRatings
        self.userRating = userRating
        self.webLink = webLink
        self.wikiLink = wikiLink
        self.lyricsAvail = lyricsAvail
        self.lyrics = lyrics
        self.medCover = medCover
        self.largeCover = largeCover
        self.releaseDate = releaseDate
        self.length = length
        self.plays30 = plays30
        self.slideshow = slideshow
    }

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

/// Decoded form of `api/auth-state`. Live response also returns `htsso`
/// (nested SSO object), `last_login`, `last_refresh`, `newsletter_r2050`,
/// and `support_meter_percent`. These are intentionally omitted in PR 2.
/// Add as needed in PR 3 when KeychainCookieProvider needs the SSO hash.
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

public struct GaplessSong: Decodable, Sendable, Equatable {
    public let songId: String
    public let artist: String
    public let title: String
    public let album: String?
    public let year: String?
    public let duration: Int
    public let cue: Int
    public let coverArt: String?
    public let coverLarge: String?
    public let coverMedium: String?
    public let coverSmall: String?
    public let eventId: Int
    public let gaplessUrl: String
    public let slideshow: [String]
    public let type: String
    public let schedTimeMillis: Int64
    public let userRating: Int
    public let rating: Double
    public let ratingsNum: Int
    public let episodeId: Int
    public let sliceNum: Int
    public let isRateable: Bool
    public let isPlayableAfterSkip: Bool
    public let isPlayableOnStart: Bool
    public let updateHistory: Bool
    public let skipAllowedMillis: Int64

    // camelCase raw values: convertFromSnakeCase applies to CodingKey raw strings in a custom init(from:).
    private enum CodingKeys: String, CodingKey {
        case songId, artist, title, album, year, duration, cue
        case coverArt, coverLarge, coverMedium, coverSmall
        case eventId, gaplessUrl, slideshow, type
        case schedTimeMillis, userRating, rating, ratingsNum
        case episodeId, sliceNum, isRateable, isPlayableAfterSkip, isPlayableOnStart
        case updateHistory, skipAllowedMillis
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // song_id may be Int or String per legacy AllowReadingFromString contract.
        if let i = try? c.decode(Int.self, forKey: .songId) {
            songId = String(i)
        } else {
            songId = try c.decode(String.self, forKey: .songId)
        }
        artist = try c.decode(String.self, forKey: .artist)
        title = try c.decode(String.self, forKey: .title)
        album = try c.decodeIfPresent(String.self, forKey: .album).flatMap { $0.isEmpty ? nil : $0 }
        year = try c.decodeIfPresent(String.self, forKey: .year)
        duration = try c.decode(Int.self, forKey: .duration)
        cue = try c.decodeIfPresent(Int.self, forKey: .cue) ?? 0
        coverArt = try c.decodeIfPresent(String.self, forKey: .coverArt)
        coverLarge = try c.decodeIfPresent(String.self, forKey: .coverLarge)
        coverMedium = try c.decodeIfPresent(String.self, forKey: .coverMedium)
        coverSmall = try c.decodeIfPresent(String.self, forKey: .coverSmall)
        eventId = try c.decode(Int.self, forKey: .eventId)
        gaplessUrl = try c.decode(String.self, forKey: .gaplessUrl)
        slideshow = try c.decodeIfPresent([String].self, forKey: .slideshow) ?? []
        type = try c.decode(String.self, forKey: .type)
        schedTimeMillis = try c.decodeIfPresent(Int64.self, forKey: .schedTimeMillis) ?? 0
        userRating = try c.decodeIfPresent(Int.self, forKey: .userRating) ?? 0
        rating = try c.decodeIfPresent(Double.self, forKey: .rating) ?? 0
        ratingsNum = try c.decodeIfPresent(Int.self, forKey: .ratingsNum) ?? 0
        episodeId = try c.decodeIfPresent(Int.self, forKey: .episodeId) ?? 0
        sliceNum = try c.decodeIfPresent(Int.self, forKey: .sliceNum) ?? 0
        isRateable = try c.decodeIfPresent(Bool.self, forKey: .isRateable) ?? false
        isPlayableAfterSkip = try c.decodeIfPresent(Bool.self, forKey: .isPlayableAfterSkip) ?? true
        isPlayableOnStart = try c.decodeIfPresent(Bool.self, forKey: .isPlayableOnStart) ?? true
        updateHistory = try c.decodeIfPresent(Bool.self, forKey: .updateHistory) ?? false
        skipAllowedMillis = try c.decodeIfPresent(Int64.self, forKey: .skipAllowedMillis) ?? 0
    }
}

public struct GaplessResponse: Decodable, Sendable, Equatable {
    public let channel: Channel
    public let bitrateTitle: String?
    public let ext: String?
    public let imageBase: String
    public let currentEventId: Int
    public let maxGaplessEventId: Int
    public let slideshowPath: String
    public let timeoutMillis: Int
    public let songs: [GaplessSong]

    // camelCase raw values match convertFromSnakeCase output; `extension` is reserved so `ext` gets an explicit raw value.
    private enum CodingKeys: String, CodingKey {
        case channel
        case bitrateTitle
        case ext = "extension"
        case imageBase
        case currentEventId, maxGaplessEventId, slideshowPath, timeoutMillis, songs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        channel = try c.decode(Channel.self, forKey: .channel)
        bitrateTitle = try c.decodeIfPresent(String.self, forKey: .bitrateTitle)
        ext = try c.decodeIfPresent(String.self, forKey: .ext)
        imageBase = try c.decode(String.self, forKey: .imageBase)
        currentEventId = try c.decode(Int.self, forKey: .currentEventId)
        maxGaplessEventId = try c.decode(Int.self, forKey: .maxGaplessEventId)
        slideshowPath = try c.decode(String.self, forKey: .slideshowPath)
        timeoutMillis = try c.decodeIfPresent(Int.self, forKey: .timeoutMillis) ?? 0
        songs = try c.decode([GaplessSong].self, forKey: .songs)
    }
}
