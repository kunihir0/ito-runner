import Foundation

// MARK: - Net Module

public protocol NetModule: Sendable {
    func fetch(request: NetRequest) async throws -> NetResponse
}

public struct NetRequest: Codable, Sendable {
    public let url: String
    public let method: String
    @PostcardMapCoded public var headers: [String: String]
    public let body: [UInt8]?

    public init(url: String, method: String, headers: [String: String], body: [UInt8]?) {
        self.url = url
        self.method = method
        self._headers = PostcardMapCoded(wrappedValue: headers)
        self.body = body
    }
}

public struct NetResponse: Codable, Sendable {
    public let status: Int32
    @PostcardMapCoded public var headers: [String: String]
    public let body: [UInt8]

    public init(status: Int32, headers: [String: String], body: [UInt8]) {
        self.status = status
        self._headers = PostcardMapCoded(wrappedValue: headers)
        self.body = body
    }
}

// MARK: - HTML Module

public protocol HtmlModule: Sendable {
    func parse(html: String) throws -> UInt32
    func select(elementId: UInt32, selector: String) throws -> [UInt32]
    func text(elementId: UInt32) throws -> String
    func attr(elementId: UInt32, name: String) throws -> String?
    func free(elementId: UInt32)
}

// MARK: - JS Module

public protocol JsModule: Sendable {
    func evaluate(script: String) async throws -> String
}

// MARK: - Std Module

public protocol StdModule: Sendable {
    func print(message: String)
}

// MARK: - Defaults Module

public protocol DefaultsModule: Sendable {
    func set(key: String, value: String)
    func get(key: String) -> String?
    func remove(key: String)
}
