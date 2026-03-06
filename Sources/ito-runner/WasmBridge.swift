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

    private var pendingNetResponseBytes: [UInt8]? = nil

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

        let allocResult = try await runner.executeExport("alloc", args: [.i32(UInt32(bytes.count))])
        guard let pointerVal = allocResult.first, case .i32(let pointer) = pointerVal else {
            throw ItoError.wasmTrap("Failed to allocate memory for response")
        }

        // Write the encoded bytes to the allocated pointer
        try await runner.writeMemory(offset: Int(pointer), bytes: Array(bytes))

        // Pack pointer and length into Int64
        let packed = (UInt64(pointer) << 32) | UInt64(UInt32(bytes.count))
        return Int64(bitPattern: packed)
    }

    /// Helper to write an empty or error response (e.g., throwing a swift error across the FFI)
    /// We can define an error structure later, for now we let it trap or return 0.

    // MARK: - Imports Registration

    /// Builds the host functions that the WebAssembly plugin can import.
    public func buildImports(store: Store) -> Imports {
        // --- ito:core/net ---
        let netFetch = Function(store: store, parameters: [.i32, .i32], results: [.i32]) {
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

                let response: NetResponse
                if let error = box.error {
                    let errMsg = "FFI Error in net_fetch: \(error.localizedDescription)"
                    response = NetResponse(
                        status: 500,
                        headers: ["Content-Type": "text/plain"],
                        body: Array(errMsg.utf8)
                    )
                } else {
                    response = box.response!
                }
                let responseBytes = try self.runner.postcardEncoder.encode(response)
                self.pendingNetResponseBytes = responseBytes
                return [.i32(UInt32(responseBytes.count))]
            } catch {
                fatalError("Failed to decode NetRequest or serialize NetResponse: \(error)")
            }
        }

        let netFetchRead = Function(store: store, parameters: [.i32], results: []) {
            [weak self] caller, args in
            guard let self = self else { return [] }
            let destPtr = args[0].i32

            guard let bytes = self.pendingNetResponseBytes else {
                fatalError("fetch_read called but no pending response bytes exist")
            }
            guard let memory = caller.instance?.exports[memory: "memory"] else {
                fatalError("Plugin must export linear memory")
            }

            memory.withUnsafeMutableBufferPointer(
                offset: UInt(destPtr), count: bytes.count
            ) { buffer in
                bytes.withUnsafeBytes { src in
                    buffer.copyMemory(from: UnsafeRawBufferPointer(src))
                }
            }

            self.pendingNetResponseBytes = nil
            return []
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
            print("WasmBridge HtmlParse returning: \(elementId)")
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

            print("WasmBridge HtmlSelect(id: \(elementId), selector: '\(selectorString)')")
            let resultIds = try module.select(elementId: elementId, selector: selectorString)
            let resultInt32s = resultIds.map { Int32(bitPattern: $0) }
            let responseBytes = try self.runner.postcardEncoder.encode(resultInt32s)

            let allocResult = try alloc([.i32(UInt32(responseBytes.count))])
            let responsePtr = allocResult[0].i32

            guard let refetchedMemory = caller.instance?.exports[memory: "memory"] else {
                fatalError("Memory lost after alloc")
            }

            refetchedMemory.withUnsafeMutableBufferPointer(
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

            guard let alloc = caller.instance?.exports[function: "alloc"]
            else {
                fatalError("Plugin must export alloc")
            }

            guard let module = self.htmlModule else {
                throw ItoError.hostModuleError(domain: "html", message: "HtmlModule not provided")
            }

            print("WasmBridge HtmlText(id: \(elementId))")
            let text = try module.text(elementId: elementId)
            let responseBytes = try self.runner.postcardEncoder.encode(text)

            let allocResult = try alloc([.i32(UInt32(responseBytes.count))])
            let responsePtr = allocResult[0].i32

            guard let refetchedMemory = caller.instance?.exports[memory: "memory"] else {
                fatalError("Memory lost after alloc")
            }

            refetchedMemory.withUnsafeMutableBufferPointer(
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

            print("WasmBridge HtmlAttr(id: \(elementId), name: '\(attrName)')")
            let attrVal = try module.attr(elementId: elementId, name: attrName)
            var responseBytes: [UInt8] = []
            if let val = attrVal {
                responseBytes.append(1)  // Option::Some
                responseBytes.append(contentsOf: try self.runner.postcardEncoder.encode(val))
            } else {
                responseBytes.append(0)  // Option::None
            }

            let allocResult = try alloc([.i32(UInt32(responseBytes.count))])
            let responsePtr = allocResult[0].i32

            guard let refetchedMemory = caller.instance?.exports[memory: "memory"] else {
                fatalError("Memory lost after alloc")
            }

            refetchedMemory.withUnsafeMutableBufferPointer(
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

            print("WasmBridge HtmlFree(id: \(elementId))")
            module.free(elementId: elementId)
            return []
        }

        let jsEvaluate = Function(store: store, parameters: [.i32, .i32], results: [.i64]) {
            [weak self] caller, args in
            guard let self = self else { return [] }
            let requestPtr = args[0].i32
            let requestLen = args[1].i32

            guard let memory = caller.instance?.exports[memory: "memory"],
                let alloc = caller.instance?.exports[function: "alloc"]
            else {
                fatalError("Plugin must export memory and alloc")
            }

            let scriptString = memory.withUnsafeMutableBufferPointer(
                offset: UInt(requestPtr), count: Int(requestLen)
            ) { buffer in
                String(decoding: buffer, as: UTF8.self)
            }

            guard let module = self.jsModule else {
                throw ItoError.hostModuleError(domain: "js", message: "JsModule not provided")
            }

            let resultString = try module.evaluate(script: scriptString)
            let responseBytes = try self.runner.postcardEncoder.encode(resultString)

            let allocResult = try alloc([.i32(UInt32(responseBytes.count))])
            let responsePtr = allocResult[0].i32

            guard let refetchedMemory = caller.instance?.exports[memory: "memory"] else {
                fatalError("Memory lost after alloc")
            }

            refetchedMemory.withUnsafeMutableBufferPointer(
                offset: UInt(responsePtr), count: responseBytes.count
            ) { buffer in
                responseBytes.withUnsafeBytes { src in
                    buffer.copyMemory(from: UnsafeRawBufferPointer(src))
                }
            }

            let packed = (UInt64(responsePtr) << 32) | UInt64(UInt32(responseBytes.count))
            return [.i64(packed)]
        }

        let stdPrint = Function(store: store, parameters: [.i32, .i32], results: []) {
            [weak self] caller, args in
            guard let self = self else { return [] }
            let requestPtr = args[0].i32
            let requestLen = args[1].i32

            guard let memory = caller.instance?.exports[memory: "memory"] else {
                fatalError("Plugin must export memory")
            }

            let string = memory.withUnsafeMutableBufferPointer(
                offset: UInt(requestPtr), count: Int(requestLen)
            ) { buffer in
                String(decoding: buffer, as: UTF8.self)
            }

            guard let module = self.stdModule else {
                throw ItoError.hostModuleError(domain: "std", message: "StdModule not provided")
            }

            module.print(message: string)
            return []
        }

        let defaultsSet = Function(store: store, parameters: [.i32, .i32, .i32, .i32], results: [])
        {
            [weak self] caller, args in
            guard let self = self else { return [] }
            let keyPtr = args[0].i32
            let keyLen = args[1].i32
            let valPtr = args[2].i32
            let valLen = args[3].i32

            guard let memory = caller.instance?.exports[memory: "memory"] else {
                fatalError("Plugin must export memory")
            }

            let key = memory.withUnsafeMutableBufferPointer(
                offset: UInt(keyPtr), count: Int(keyLen)
            ) { buffer in
                String(decoding: buffer, as: UTF8.self)
            }

            let val = memory.withUnsafeMutableBufferPointer(
                offset: UInt(valPtr), count: Int(valLen)
            ) { buffer in
                String(decoding: buffer, as: UTF8.self)
            }

            guard let module = self.defaultsModule else {
                throw ItoError.hostModuleError(
                    domain: "defaults", message: "DefaultsModule not provided")
            }

            module.set(key: key, value: val)
            return []
        }

        let defaultsGet = Function(store: store, parameters: [.i32, .i32], results: [.i64]) {
            [weak self] caller, args in
            guard let self = self else { return [] }
            let keyPtr = args[0].i32
            let keyLen = args[1].i32

            guard let memory = caller.instance?.exports[memory: "memory"],
                let alloc = caller.instance?.exports[function: "alloc"]
            else {
                fatalError("Plugin must export memory and alloc")
            }

            let key = memory.withUnsafeMutableBufferPointer(
                offset: UInt(keyPtr), count: Int(keyLen)
            ) { buffer in
                String(decoding: buffer, as: UTF8.self)
            }

            guard let module = self.defaultsModule else {
                throw ItoError.hostModuleError(
                    domain: "defaults", message: "DefaultsModule not provided")
            }

            let val = module.get(key: key)
            var responseBytes: [UInt8] = []
            if let v = val {
                responseBytes.append(1)  // Option::Some
                responseBytes.append(contentsOf: try self.runner.postcardEncoder.encode(v))
            } else {
                responseBytes.append(0)  // Option::None
            }

            let allocResult = try alloc([.i32(UInt32(responseBytes.count))])
            let responsePtr = allocResult[0].i32

            guard let refetchedMemory = caller.instance?.exports[memory: "memory"] else {
                fatalError("Memory lost after alloc")
            }

            refetchedMemory.withUnsafeMutableBufferPointer(
                offset: UInt(responsePtr), count: responseBytes.count
            ) { buffer in
                responseBytes.withUnsafeBytes { src in
                    buffer.copyMemory(from: UnsafeRawBufferPointer(src))
                }
            }

            let packed = (UInt64(responsePtr) << 32) | UInt64(UInt32(responseBytes.count))
            return [.i64(packed)]
        }

        let defaultsRemove = Function(store: store, parameters: [.i32, .i32], results: []) {
            [weak self] caller, args in
            guard let self = self else { return [] }
            let keyPtr = args[0].i32
            let keyLen = args[1].i32

            guard let memory = caller.instance?.exports[memory: "memory"] else {
                fatalError("Plugin must export memory")
            }

            let key = memory.withUnsafeMutableBufferPointer(
                offset: UInt(keyPtr), count: Int(keyLen)
            ) { buffer in
                String(decoding: buffer, as: UTF8.self)
            }

            guard let module = self.defaultsModule else {
                throw ItoError.hostModuleError(
                    domain: "defaults", message: "DefaultsModule not provided")
            }

            module.remove(key: key)
            return []
        }

        let imports: Imports = [
            "ito:core/net": [
                "fetch": netFetch,
                "fetch_read": netFetchRead,
            ],
            "ito:core/html": [
                "parse": htmlParse,
                "select": htmlSelect,
                "text": htmlText,
                "attr": htmlAttr,
                "free": htmlFree,
            ],
            "ito:core/js": ["evaluate": jsEvaluate],
            "ito:core/std": ["print": stdPrint],
            "ito:core/defaults": [
                "set": defaultsSet,
                "get": defaultsGet,
                "remove": defaultsRemove,
            ],
        ]

        return imports
    }
}
