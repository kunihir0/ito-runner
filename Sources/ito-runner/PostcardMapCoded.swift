import Foundation

/// A property wrapper that correctly decodes/encodes Postcard Maps (Dictionaries).
/// Postcard encodes Maps as `Count` (entries) followed by `Key, Value` pairs.
/// Swift's `Dictionary` encoding expects `KeyedDecodingContainer` for String/Int keys, which fails for sequential Postcard streams.
/// This wrapper forces the use of `UnkeyedDecodingContainer` and handles the Postcard Map structure explicitly.
@propertyWrapper
public struct PostcardMapCoded<Key: Hashable & Codable, Value: Codable>: Codable, PostcardMapDecodable {
    public var wrappedValue: [Key: Value]

    public init(wrappedValue: [Key: Value]) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: Decoder) throws {
        // PostcardDecoder uses the PostcardMapDecodable conformance to set the map flag.
        var container = try decoder.unkeyedContainer()
        
        guard let totalItems = container.count else {
            throw ItoError.postcardDecodingError("Map missing count header")
        }
        
        let entries = totalItems / 2
        let capacity = min(entries, 1000) 
        var dict = [Key: Value](minimumCapacity: capacity)

        for _ in 0..<entries {
            let key = try container.decode(Key.self)
            let value = try container.decode(Value.self)
            dict[key] = value
        }

        self.wrappedValue = dict
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        // Postcard Map: [count, k1, v1, ...]
        try container.encode(UInt64(wrappedValue.count))
        for (key, value) in wrappedValue {
            try container.encode(key)
            try container.encode(value)
        }
    }
}

extension PostcardMapCoded: Equatable where Value: Equatable {}
extension PostcardMapCoded: Sendable where Key: Sendable, Value: Sendable {}

@propertyWrapper
public struct PostcardOptionalMapCoded<Key: Hashable & Codable, Value: Codable>: Codable, PostcardMapDecodable {
    public var wrappedValue: [Key: Value]?

    public init(wrappedValue: [Key: Value]?) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.wrappedValue = nil
        } else {
            // It was Option::Some (1), now decode the map using the same logic as above
            self.wrappedValue = try PostcardMapCoded<Key, Value>(from: decoder).wrappedValue
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let dict = wrappedValue {
            try container.encode(true) // Option::Some
            try PostcardMapCoded(wrappedValue: dict).encode(to: encoder)
        } else {
            try container.encodeNil() // Option::None
        }
    }
}

extension PostcardOptionalMapCoded: Equatable where Value: Equatable {}
extension PostcardOptionalMapCoded: Sendable where Key: Sendable, Value: Sendable {}
