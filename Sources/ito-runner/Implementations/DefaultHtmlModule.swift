import Foundation
import SwiftSoup

/// The default implementation of `HtmlModule` using `SwiftSoup`.
/// Note: SwiftSoup parses HTML into elements. Since the FFI needs integer handler IDs,
/// we store elements in a dictionary and pass the keys to WebAssembly.
public final class DefaultHtmlModule: HtmlModule, @unchecked Sendable {

    // 0 is reserved.
    private var nextElementId: UInt32 = 1
    private var elements: [UInt32: Element] = [:]
    private let lock = NSLock()

    public init() {}

    public func parse(html: String) throws -> UInt32 {
        let doc = try SwiftSoup.parse(html)

        lock.lock()
        defer { lock.unlock() }

        let elementId = nextElementId
        elements[elementId] = doc
        nextElementId += 1
        return elementId
    }

    public func select(elementId: UInt32, selector: String) throws -> [UInt32] {
        lock.lock()
        guard let element = elements[elementId] else {
            lock.unlock()
            throw ItoError.hostModuleError(
                domain: "html", message: "Invalid element ID: \(elementId)")
        }
        lock.unlock()

        let selectedElements = try element.select(selector)
        var resultIds: [UInt32] = []

        lock.lock()
        defer { lock.unlock() }

        for el in selectedElements {
            let id = nextElementId
            elements[id] = el
            nextElementId += 1
            resultIds.append(id)
        }

        return resultIds
    }

    public func text(elementId: UInt32) throws -> String {
        lock.lock()
        guard let element = elements[elementId] else {
            lock.unlock()
            throw ItoError.hostModuleError(
                domain: "html", message: "Invalid element ID: \(elementId)")
        }
        lock.unlock()
        return try element.text()
    }

    public func attr(elementId: UInt32, name: String) throws -> String? {
        lock.lock()
        guard let element = elements[elementId] else {
            lock.unlock()
            throw ItoError.hostModuleError(
                domain: "html", message: "Invalid element ID: \(elementId)")
        }
        lock.unlock()

        let value = try element.attr(name)
        return value.isEmpty ? nil : value
    }

    public func free(elementId: UInt32) {
        lock.lock()
        defer { lock.unlock() }
        elements.removeValue(forKey: elementId)
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        elements.removeAll()
        nextElementId = 1
    }
}
