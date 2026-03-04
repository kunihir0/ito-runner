import Foundation
import Testing
@testable import ito_runner

@Suite("Postcard Dictionary Tests")
struct PostcardDictionaryTests {
    
    struct StringMap: Codable, Equatable {
        @PostcardMapCoded var values: [String: String]
    }
    
    @Test("Decode Dictionary")
    func testDictionary() throws {
        let encoder = ItoPostcardEncoder()
        let decoder = ItoPostcardDecoder()
        
        // Map with 1 entry: "A" -> "B"
        // Postcard Map Encoding:
        // Varint(count) = 1
        // Key: "A" -> 1 (len), 'A'
        // Value: "B" -> 1 (len), 'B'
        // Total: [1, 1, 65, 1, 66]
        
        let map = StringMap(values: ["A": "B"])
        let encoded = try encoder.encode(map)
        print("Encoded: \(encoded)")
        
        let decoded = try decoder.decode(StringMap.self, from: encoded)
        #expect(decoded == map)
    }
}
