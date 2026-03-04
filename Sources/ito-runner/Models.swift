import Foundation

public enum MangaStatus: Int32, Codable, Sendable {
    case Unknown = 0
    case Ongoing = 1
    case Completed = 2
    case Cancelled = 3
    case Hiatus = 4
}

public enum ContentRating: Int32, Codable, Sendable {
    case Safe = 0
    case Suggestive = 1  // Ecchi
    case Nsfw = 2  // Pornographic
}

public struct Manga: Codable, Sendable {
    public var key: String
    public var title: String
    public var authors: [String]?
    public var artist: String?
    public var description: String?
    public var tags: [String]?
    public var cover: String?
    public var url: String?
    public var status: MangaStatus
    public var contentRating: ContentRating
    public var nsfw: Int32
    public var viewer: Int32
    public var chapters: [Chapter]?

    public init(
        key: String, title: String, authors: [String]? = nil, artist: String? = nil,
        description: String? = nil, tags: [String]? = nil, cover: String? = nil, url: String? = nil,
        status: MangaStatus = .Unknown, contentRating: ContentRating = .Safe, nsfw: Int32 = 0,
        viewer: Int32 = 0, chapters: [Chapter]? = nil
    ) {
        self.key = key
        self.title = title
        self.authors = authors
        self.artist = artist
        self.description = description
        self.tags = tags
        self.cover = cover
        self.url = url
        self.status = status
        self.contentRating = contentRating
        self.nsfw = nsfw
        self.viewer = viewer
        self.chapters = chapters
    }
}

public struct MangaPageResult: Codable, Sendable {
    public var entries: [Manga]
    public var hasNextPage: Bool

    public init(entries: [Manga], hasNextPage: Bool) {
        self.entries = entries
        self.hasNextPage = hasNextPage
    }
}

public struct Chapter: Codable, Sendable {
    public var key: String
    public var title: String?
    public var volume: Float32?
    public var chapter: Float32?
    public var dateUpdated: Double?  // Option<f64>
    public var scanlator: String?
    public var url: String?
    public var lang: String?

    public init(
        key: String, title: String? = nil, volume: Float32? = nil, chapter: Float32? = nil,
        dateUpdated: Double? = nil, scanlator: String? = nil, url: String? = nil,
        lang: String? = nil
    ) {
        self.key = key
        self.title = title
        self.volume = volume
        self.chapter = chapter
        self.dateUpdated = dateUpdated
        self.scanlator = scanlator
        self.url = url
        self.lang = lang
    }
}

public enum PageContent: Codable, Sendable {
    case url(String)
    case text(String)

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let variant = try container.decode(UInt32.self)
        switch variant {
        case 0: self = .url(try container.decode(String.self))
        case 1: self = .text(try container.decode(String.self))
        default:
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unknown PageContent variant")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        switch self {
        case .url(let s):
            try container.encode(0 as UInt32)
            try container.encode(s)
        case .text(let s):
            try container.encode(1 as UInt32)
            try container.encode(s)
        }
    }
}

public struct Page: Codable, Sendable {
    public var index: Int32
    public var content: PageContent
    public var hasDescription: Bool
    public var description: String?

    public init(
        index: Int32, content: PageContent, hasDescription: Bool = false, description: String? = nil
    ) {
        self.index = index
        self.content = content
        self.hasDescription = hasDescription
        self.description = description
    }
}

public struct Listing: Codable, Sendable {
    public var id: String
    public var name: String
    public var kind: Int32  // Enum ListingKind

    public init(id: String, name: String, kind: Int32) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}

public struct FilterStruct: Codable, Sendable {
    public let type: String
    public let name: String
    public let value: FilterValue
}

public enum FilterValue: Codable, Sendable {
    case boolean(Bool)
    case int(Int64)
    case float(Double)
    case string(String)

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let variant = try container.decode(UInt32.self)
        switch variant {
        case 0: self = .boolean(try container.decode(Bool.self))
        case 1: self = .int(try container.decode(Int64.self))
        case 2: self = .float(try container.decode(Double.self))
        case 3: self = .string(try container.decode(String.self))
        default:
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unknown FilterValue variant")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        switch self {
        case .boolean(let b):
            try container.encode(0 as UInt32)
            try container.encode(b)
        case .int(let i):
            try container.encode(1 as UInt32)
            try container.encode(i)
        case .float(let f):
            try container.encode(2 as UInt32)
            try container.encode(f)
        case .string(let s):
            try container.encode(3 as UInt32)
            try container.encode(s)
        }
    }
}

public struct FilterItem: Codable, Sendable {
    public var type: String
    public var name: String
    public var value: FilterValue

    public init(from decoder: Decoder) throws {
        // Based on Aidoku's implementation, FilterItem is an enum with string variants and struct variants
        // Let's implement it as a String for now, since it can coerce in the test `aidoku::FilterItem::from("Action")`
        // Or if it refers to actual struct instances. For now, matching the FilterStruct format.
        var container = try decoder.unkeyedContainer()
        self.type = try container.decode(String.self)
        self.name = try container.decode(String.self)
        self.value = try container.decode(FilterValue.self)
    }

    public func encode(to encoder: Encoder) throws {
        // Enforce the tuple structure expected by some rust enum variants using UnkeyedContainer
        var container = encoder.unkeyedContainer()
        try container.encode(type)
        try container.encode(name)
        try container.encode(value)
    }
}

public struct Link: Codable, Sendable {
    public var title: String
    public var value: LinkValue?

    public init(title: String, value: LinkValue? = nil) {
        self.title = title
        self.value = value
    }
}

public enum LinkValue: Codable, Sendable {
    case url(String)
    case manga(Manga)
    case listing(Listing)

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let variant = try container.decode(UInt32.self)
        switch variant {
        case 0: self = .url(try container.decode(String.self))
        case 1: self = .manga(try container.decode(Manga.self))
        case 2: self = .listing(try container.decode(Listing.self))
        default:
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unknown LinkValue variant")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        switch self {
        case .url(let s):
            try container.encode(0 as UInt32)
            try container.encode(s)
        case .manga(let m):
            try container.encode(1 as UInt32)
            try container.encode(m)
        case .listing(let l):
            try container.encode(2 as UInt32)
            try container.encode(l)
        }
    }
}

public struct MangaWithChapter: Codable, Sendable {
    public var manga: Manga
    public var chapter: Chapter

    public init(manga: Manga, chapter: Chapter) {
        self.manga = manga
        self.chapter = chapter
    }
}

private struct PostcardOption<T: Codable & Sendable>: Codable, Sendable {
    let value: T?
    init(_ value: T?) { self.value = value }
    func encode(to encoder: Encoder) throws {
        if let value = value {
            var container = encoder.singleValueContainer()
            try container.encode(true)
            try value.encode(to: encoder)
        } else {
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }
}

public enum HomeComponentValue: Codable, Sendable {
    case scroller([Manga], Listing?)
    case mangaList(Bool, Int32?, [Manga], Listing?)
    case mangaChapterList(Int32?, [MangaWithChapter], Listing?)
    case bigScroller([Manga], Float32?)
    case filters([FilterItem])
    case links([Link])

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let variant = try container.decode(UInt32.self)
        switch variant {
        case 0:
            self = .scroller(
                try container.decode([Manga].self), try container.decodeIfPresent(Listing.self))
        case 1:
            self = .mangaList(
                try container.decode(Bool.self), try container.decodeIfPresent(Int32.self),
                try container.decode([Manga].self), try container.decodeIfPresent(Listing.self))
        case 2:
            self = .mangaChapterList(
                try container.decodeIfPresent(Int32.self),
                try container.decode([MangaWithChapter].self),
                try container.decodeIfPresent(Listing.self))
        case 3:
            self = .bigScroller(
                try container.decode([Manga].self), try container.decodeIfPresent(Float32.self))
        case 4: self = .filters(try container.decode([FilterItem].self))
        case 5: self = .links(try container.decode([Link].self))
        default:
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unknown HomeComponentValue variant")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        switch self {
        case .scroller(let entries, let listing):
            try container.encode(0 as UInt32)
            try container.encode(entries)
            try container.encode(PostcardOption(listing))
        case .mangaList(let ranking, let pageSize, let entries, let listing):
            try container.encode(1 as UInt32)
            try container.encode(ranking)
            try container.encode(PostcardOption(pageSize))
            try container.encode(entries)
            try container.encode(PostcardOption(listing))
        case .mangaChapterList(let pageSize, let entries, let listing):
            try container.encode(2 as UInt32)
            try container.encode(PostcardOption(pageSize))
            try container.encode(entries)
            try container.encode(PostcardOption(listing))
        case .bigScroller(let entries, let interval):
            try container.encode(3 as UInt32)
            try container.encode(entries)
            try container.encode(PostcardOption(interval))
        case .filters(let items):
            try container.encode(4 as UInt32)
            try container.encode(items)
        case .links(let links):
            try container.encode(5 as UInt32)
            try container.encode(links)
        }
    }
}

public struct HomeComponent: Codable, Sendable {
    public var title: String?
    public var subtitle: String?
    public var value: HomeComponentValue

    public init(title: String? = nil, subtitle: String? = nil, value: HomeComponentValue) {
        self.title = title
        self.subtitle = subtitle
        self.value = value
    }
}

public struct HomeLayout: Codable, Sendable {
    public var components: [HomeComponent]

    public init(components: [HomeComponent]) {
        self.components = components
    }
}
