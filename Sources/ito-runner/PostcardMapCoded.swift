import Foundation

/// A property wrapper that correctly decodes/encodes Postcard Maps (Dictionaries).
/// Postcard encodes Maps as `Count` (entries) followed by `Key, Value` pairs.
/// Swift's `Dictionary` encoding expects `KeyedDecodingContainer` for String/Int keys, which fails for sequential Postcard streams.
/// This wrapper forces the use of `UnkeyedDecodingContainer` and handles the Postcard Map structure explicitly.
@propertyWrapper
public struct PostcardMapCoded<Key: Hashable & Codable, Value: Codable>: Codable,
    PostcardMapDecodable
{
    public var wrappedValue: [Key: Value]

    public init(wrappedValue: [Key: Value]) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: Decoder) throws {
        // Because we conform to PostcardMapDecodable, _PostcardDecoder sets the isMap flag.
        // This causes _PostcardUnkeyedDecodingContainer to multiply the varint count by 2.

        var container = try decoder.unkeyedContainer()

        // container.count is now (Entries * 2).
        let totalItems = container.count ?? 0
        let entries = totalItems / 2

        var dict = [Key: Value](minimumCapacity: entries)

        // We iterate 'entries' times, decoding 2 items per loop.
        // Or we iterate 'totalItems' times?
        // UnkeyedContainer tracks index per decode().
        // So we just decode Key then Value.

        // Wait, if we use `for _ in 0..<entries`, we call decode() twice.
        // That advances index by 2.
        // This is correct.

        for _ in 0..<entries {
            let key = try container.decode(Key.self)
            let value = try container.decode(Value.self)
            dict[key] = value
        }

        self.wrappedValue = dict
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(UInt64(wrappedValue.count))
        for (key, value) in wrappedValue {
            try container.encode(key)
            try container.encode(value)
        }
    }
}

extension PostcardMapCoded: Equatable where Value: Equatable {}

extension PostcardMapCoded: @unchecked Sendable where Key: Sendable, Value: Sendable {}

@propertyWrapper
public struct PostcardOptionalMapCoded<Key: Hashable & Codable, Value: Codable>: Codable,
    PostcardMapDecodable
{
    public var wrappedValue: [Key: Value]?

    public init(wrappedValue: [Key: Value]?) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: Decoder) throws {
        let singleContainer = try decoder.singleValueContainer()
        // If it's an Option::None in Postcard, it consumes the '0' byte
        if singleContainer.decodeNil() {
            self.wrappedValue = nil
        } else {
            // It was Option::Some, the '1' byte was consumed. Now read the map.
            var container = try decoder.unkeyedContainer()
            let totalItems = container.count ?? 0
            let entries = totalItems / 2
            var dict = [Key: Value](minimumCapacity: entries)

            for _ in 0..<entries {
                let key = try container.decode(Key.self)
                let value = try container.decode(Value.self)
                dict[key] = value
            }

            self.wrappedValue = dict
        }
    }

    public func encode(to encoder: Encoder) throws {
        var singleContainer = encoder.singleValueContainer()
        if let dict = wrappedValue {
            try singleContainer.encode(true) // 1 for Option::Some
            
            var container = encoder.unkeyedContainer()
            try container.encode(UInt64(dict.count))
            for (key, value) in dict {
                try container.encode(key)
                try container.encode(value)
            }
        } else {
            try singleContainer.encodeNil() // 0 for Option::None
        }
    }
}

extension PostcardOptionalMapCoded: Equatable where Value: Equatable {}

extension PostcardOptionalMapCoded: @unchecked Sendable where Key: Sendable, Value: Sendable {}
