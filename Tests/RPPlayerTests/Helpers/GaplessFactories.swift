import Foundation
@testable import RPPlayer

func makeGaplessSong(
    songId: String = "1",
    eventId: Int = 100,
    cue: Int = 0,
    duration: Int = 180_000,
    type: String = "M",
    gaplessUrl: String = "https://example.com/song.flac",
    updateHistory: Bool = true,
    isRateable: Bool = true,
    isPlayableAfterSkip: Bool = true,
    artist: String = "Artist",
    title: String = "Title",
    album: String? = "Album",
    sliceNum: Int = 0,
    userRating: Int = 0,
    rating: Double = 0,
    coverLarge: String? = nil,
    coverMedium: String? = nil,
    year: String? = nil
) -> GaplessSong {
    var json: [String: Any] = [
        "song_id": songId,
        "artist": artist,
        "title": title,
        "duration": duration,
        "cue": cue,
        "event_id": eventId,
        "gapless_url": gaplessUrl,
        "type": type,
        "update_history": updateHistory,
        "is_rateable": isRateable,
        "is_playable_after_skip": isPlayableAfterSkip,
        "is_playable_on_start": true,
        "slice_num": sliceNum,
        "rating": rating,
        "user_rating": userRating,
        "ratings_num": 0,
        "episode_id": 0,
        "sched_time_millis": 0,
        "skip_allowed_millis": 0,
        "slideshow": []
    ]
    if let album { json["album"] = album }
    if let coverLarge { json["cover_large"] = coverLarge }
    if let coverMedium { json["cover_medium"] = coverMedium }
    if let year { json["year"] = year }
    let data = try! JSONSerialization.data(withJSONObject: json)
    return try! JSONDecoder.rpDecoder.decode(GaplessSong.self, from: data)
}

func makeGaplessResponse(
    songs: [GaplessSong], chan: String = "0", bitrateTitle: String = "flac"
) -> GaplessResponse {
    let songsJSON: [[String: Any]] = songs.map { s in
        var dict: [String: Any] = [
            "song_id": s.songId,
            "artist": s.artist,
            "title": s.title,
            "duration": s.duration,
            "cue": s.cue,
            "event_id": s.eventId,
            "gapless_url": s.gaplessUrl,
            "type": s.type,
            "update_history": s.updateHistory,
            "is_rateable": s.isRateable,
            "is_playable_after_skip": s.isPlayableAfterSkip,
            "is_playable_on_start": s.isPlayableOnStart,
            "slice_num": s.sliceNum,
            "rating": s.rating,
            "user_rating": s.userRating,
            "ratings_num": s.ratingsNum,
            "episode_id": s.episodeId,
            "sched_time_millis": s.schedTimeMillis,
            "skip_allowed_millis": s.skipAllowedMillis,
            "slideshow": s.slideshow
        ]
        if let v = s.album { dict["album"] = v }
        if let v = s.coverArt { dict["cover_art"] = v }
        if let v = s.coverLarge { dict["cover_large"] = v }
        if let v = s.coverMedium { dict["cover_medium"] = v }
        if let v = s.coverSmall { dict["cover_small"] = v }
        if let v = s.year { dict["year"] = v }
        return dict
    }
    let json: [String: Any] = [
        "channel": ["chan": chan, "title": "Test", "stream_name": "test", "isER": false],
        "bitrate_title": bitrateTitle,
        "extension": "flac",
        "image_base": "//img.test/",
        "current_event_id": songs.first?.eventId ?? 0,
        "max_gapless_event_id": (songs.first?.eventId ?? 0) + 50,
        "slideshow_path": "slideshow/720/",
        "timeout_millis": 2_700_000,
        "songs": songsJSON
    ]
    let data = try! JSONSerialization.data(withJSONObject: json)
    return try! JSONDecoder.rpDecoder.decode(GaplessResponse.self, from: data)
}
