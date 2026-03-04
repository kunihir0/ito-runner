import Foundation
import WasmKit

/// WasmBridge acts as the FFI layer connecting WasmKit's `Memory` to native Swift protocols
/// using the Postcard serialization format.
public class WasmBridge {

    private let runner: ItoRunner

    // Dependencies
    public var netModule: NetModule?
    public var htmlModule: HtmlModule?
    public var jsModule: JsModule?
    public var stdModule: StdModule?
    public var defaultsModule: DefaultsModule?

    public init(runner: ItoRunner) {
        self.runner = runner
    }

    /// Reads and decodes a Postcard struct from Wasm memory
    public func readRequest<T: Decodable>(_ type: T.Type, requestPtr: Int32, requestLen: Int32)
        async throws -> T
    {
        let bytes = try await runner.readMemory(offset: Int(requestPtr), length: Int(requestLen))
        return try runner.postcardDecoder.decode(type, from: bytes)
    }

    /// Encodes a Swift struct to Postcard and writes it to Wasm memory.
    /// Returns the packed (pointer << 32 | length) response.
    public func writeResponse<T: Encodable>(_ response: T) async throws -> Int64 {
        let bytes = try runner.postcardEncoder.encode(response)

        // Ask Wasm to allocate memory for us
        let allocResult = try await runner.executeExport("alloc", args: [.i32(UInt32(bytes.count))])
        guard let pointerVal = allocResult.first, case .i32(let pointer) = pointerVal else {
            throw ItoError.wasmTrap("Failed to allocate memory for response")
        }

        // Write the encoded bytes to the allocated pointer
        try await runner.writeMemory(offset: Int(pointer), bytes: Array(bytes))

        // Pack pointer and length into Int64
        let len = Int64(bytes.count)
        let ptr = Int64(pointer)
        return (ptr << 32) | len
    }

    /// Helper to write an empty or error response (e.g., throwing a swift error across the FFI)
    /// We can define an error structure later, for now we let it trap or return 0.

    // MARK: - Imports Registration

    /// Builds the host functions that the WebAssembly plugin can import.
    public func buildImports(store: Store) -> Imports {
        // --- ito:core/net ---
        let netFetch = Function(store: store, parameters: [.i32, .i32], results: [.i64]) {
            [weak self] caller, args in
            guard let self = self else { return [] }
            let requestPtr = args[0].i32
            let requestLen = args[1].i32

            guard let memory = caller.instance?.exports[memory: "memory"] else {
                fatalError("Plugin must export linear memory")
            }

            let requestBytes = memory.withUnsafeMutableBufferPointer(
                offset: UInt(requestPtr), count: Int(requestLen)
            ) { buffer in
                Array(buffer)
            }

            do {
                let request = try self.runner.postcardDecoder.decode(
                    NetRequest.self, from: requestBytes)

                class ResultBox: @unchecked Sendable {
                    var response: NetResponse?
                    var error: Error?
                }

                let box = ResultBox()
                let module = self.netModule
                let sem = DispatchSemaphore(value: 0)

                Task {
                    do {
                        if let module = module {
                            box.response = try await module.fetch(request: request)
                        } else {
                            throw ItoError.hostModuleError(
                                domain: "net", message: "NetModule not provided")
                        }
                    } catch {
                        box.error = error
                    }
                    sem.signal()
                }
                sem.wait()

                if let error = box.error {
                    fatalError("FFI Error in net_fetch: \(error)")  // Will trap the Wasm module
                }

                let response = box.response!
                let responseBytes = try self.runner.postcardEncoder.encode(response)

                guard let alloc = caller.instance?.exports[function: "alloc"] else {
                    fatalError("Plugin must export alloc(size)")
                }

                let allocResult = try alloc([.i32(UInt32(responseBytes.count))])
                let responsePtr = allocResult[0].i32

                memory.withUnsafeMutableBufferPointer(
                    offset: UInt(responsePtr), count: responseBytes.count
                ) { buffer in
                    responseBytes.withUnsafeBytes { src in
                        buffer.copyMemory(from: UnsafeRawBufferPointer(src))
                    }
                }

                let packed =
                    (UInt64(responsePtr) << 32)
                    | UInt64(UInt32(responseBytes.count))
                return [.i64(packed)]

            } catch {
                fatalError("Failed to decode NetRequest or serialize NetResponse: \(error)")
            }
        }

        let htmlParse = Function(store: store, parameters: [.i32, .i32], results: [.i32]) {
            [weak self] caller, args in
            guard let self = self else { return [] }
            let requestPtr = args[0].i32
            let requestLen = args[1].i32

            guard let memory = caller.instance?.exports[memory: "memory"] else {
                fatalError("Plugin must export linear memory")
            }

            let htmlString = memory.withUnsafeMutableBufferPointer(
                offset: UInt(requestPtr), count: Int(requestLen)
            ) { buffer in
                String(decoding: buffer, as: UTF8.self)
            }

            guard let module = self.htmlModule else {
                throw ItoError.hostModuleError(domain: "html", message: "HtmlModule not provided")
            }

            let elementId = try module.parse(html: htmlString)
            return [.i32(elementId)]
        }

        let htmlSelect = Function(store: store, parameters: [.i32, .i32, .i32], results: [.i64]) {
            [weak self] caller, args in
            guard let self = self else { return [] }
            let elementId = args[0].i32
            let requestPtr = args[1].i32
            let requestLen = args[2].i32

            guard let memory = caller.instance?.exports[memory: "memory"],
                let alloc = caller.instance?.exports[function: "alloc"]
            else {
                fatalError("Plugin must export memory and alloc")
            }

            let selectorString = memory.withUnsafeMutableBufferPointer(
                offset: UInt(requestPtr), count: Int(requestLen)
            ) { buffer in
                String(decoding: buffer, as: UTF8.self)
            }

            guard let module = self.htmlModule else {
                throw ItoError.hostModuleError(domain: "html", message: "HtmlModule not provided")
            }

            let resultIds = try module.select(elementId: elementId, selector: selectorString)
            let responseBytes = try self.runner.postcardEncoder.encode(resultIds)

            let allocResult = try alloc([.i32(UInt32(responseBytes.count))])
            let responsePtr = allocResult[0].i32

            memory.withUnsafeMutableBufferPointer(
                offset: UInt(responsePtr), count: responseBytes.count
            ) { buffer in
                responseBytes.withUnsafeBytes { src in
                    buffer.copyMemory(from: UnsafeRawBufferPointer(src))
                }
            }

            let packed = (UInt64(responsePtr) << 32) | UInt64(UInt32(responseBytes.count))
            return [.i64(packed)]
        }

        let htmlText = Function(store: store, parameters: [.i32], results: [.i64]) {
            [weak self] caller, args in
            guard let self = self else { return [] }
            let elementId = args[0].i32

            guard let memory = caller.instance?.exports[memory: "memory"],
                let alloc = caller.instance?.exports[function: "alloc"]
            else {
                fatalError("Plugin must export memory and alloc")
            }

            guard let module = self.htmlModule else {
                throw ItoError.hostModuleError(domain: "html", message: "HtmlModule not provided")
            }

            let text = try module.text(elementId: elementId)
            let responseBytes = try self.runner.postcardEncoder.encode(text)

            let allocResult = try alloc([.i32(UInt32(responseBytes.count))])
            let responsePtr = allocResult[0].i32

            memory.withUnsafeMutableBufferPointer(
                offset: UInt(responsePtr), count: responseBytes.count
            ) { buffer in
                responseBytes.withUnsafeBytes { src in
                    buffer.copyMemory(from: UnsafeRawBufferPointer(src))
                }
            }

            let packed = (UInt64(responsePtr) << 32) | UInt64(UInt32(responseBytes.count))
            return [.i64(packed)]
        }

        let htmlAttr = Function(store: store, parameters: [.i32, .i32, .i32], results: [.i64]) {
            [weak self] caller, args in
            guard let self = self else { return [] }
            let elementId = args[0].i32
            let requestPtr = args[1].i32
            let requestLen = args[2].i32

            guard let memory = caller.instance?.exports[memory: "memory"],
                let alloc = caller.instance?.exports[function: "alloc"]
            else {
                fatalError("Plugin must export memory and alloc")
            }

            let attrName = memory.withUnsafeMutableBufferPointer(
                offset: UInt(requestPtr), count: Int(requestLen)
            ) { buffer in
                String(decoding: buffer, as: UTF8.self)
            }

            guard let module = self.htmlModule else {
                throw ItoError.hostModuleError(domain: "html", message: "HtmlModule not provided")
            }

            let attrVal = try module.attr(elementId: elementId, name: attrName)
            let responseBytes = try self.runner.postcardEncoder.encode(attrVal)

            let allocResult = try alloc([.i32(UInt32(responseBytes.count))])
            let responsePtr = allocResult[0].i32

            memory.withUnsafeMutableBufferPointer(
                offset: UInt(responsePtr), count: responseBytes.count
            ) { buffer in
                responseBytes.withUnsafeBytes { src in
                    buffer.copyMemory(from: UnsafeRawBufferPointer(src))
                }
            }

            let packed = (UInt64(responsePtr) << 32) | UInt64(UInt32(responseBytes.count))
            return [.i64(packed)]
        }

        let htmlFree = Function(store: store, parameters: [.i32], results: []) {
            [weak self] caller, args in
            guard let self = self else { return [] }
            let elementId = args[0].i32

            guard let module = self.htmlModule else {
                throw ItoError.hostModuleError(domain: "html", message: "HtmlModule not provided")
            }

            module.free(elementId: elementId)
            return []
        }

        let imports: Imports = [
            "ito:core/net": ["fetch": netFetch],
            "ito:core/html": [
                "parse": htmlParse,
                "select": htmlSelect,
                "text": htmlText,
                "attr": htmlAttr,
                "free": htmlFree,
            ],
        ]

        return imports
    }
}
