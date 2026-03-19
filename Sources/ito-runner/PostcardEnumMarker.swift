import Foundation

/// A marker protocol for enums that should be encoded/decoded as Postcard variants (discriminant first).
public protocol PostcardEnumMarker {}

/// A marker protocol for CodingKeys of an enum. This helps the codec know it's dealing with a variant.
public protocol PostcardEnumKeys {}

/// A protocol that enums can conform to for easier Postcard serialization.
public protocol PostcardEnum: Codable, PostcardEnumMarker {
    var postcardDiscriminant: UInt32 { get }
}

extension PostcardEnum where Self: RawRepresentable, RawValue == Int32 {
    public var postcardDiscriminant: UInt32 { UInt32(rawValue) }
}
