import Foundation
import WasmKit

/// The main execution engine for ito-runner.
/// It wraps WasmKit to load, instantiate, and execute WebAssembly plugins.
public actor ItoRunner {

    /// The running WasmKit Instance. We hold onto it so we can execute exports later.
    private var instance: Instance?

    /// The memory space shared by the Wasm plugin and swift.
    private var memory: Memory?

    /// The Object Bridge Registry, used to securely store Swift objects and pass their integer IDs to Wasm.
    public let registry: DescriptorRegistry

    /// The custom Postcard Serialization encoder and decoder.
    nonisolated public let postcardEncoder = ItoPostcardEncoder()
    nonisolated public let postcardDecoder = ItoPostcardDecoder()

    /// The FFI Bridge that connects Host Modules to Wasm. Created upon plugin load.
    public var bridge: WasmBridge?

    public var netModule: NetModule?
    public var htmlModule: HtmlModule?
    public var jsModule: JsModule?
    public var stdModule: StdModule?
    public var defaultsModule: DefaultsModule?

    /// Initializes a new runner instance.
    public init() {
        self.registry = DescriptorRegistry()
    }

    public func setNetModule(_ module: NetModule) { self.netModule = module }
    public func setHtmlModule(_ module: HtmlModule) { self.htmlModule = module }
    public func setJsModule(_ module: JsModule) { self.jsModule = module }
    public func setStdModule(_ module: StdModule) { self.stdModule = module }
    public func setDefaultsModule(_ module: DefaultsModule) { self.defaultsModule = module }

    /// Loads a `.wasm` file, sets up the host environment (FFI), and instantiates the plugin.
    ///
    /// - Parameter url: The file URL to the `.wasm` binary.
    /// - Throws: An `ItoError` if loading or instantiation fails.
    public func loadPlugin(from url: URL) throws {
        do {
            let wasmBytes = try Data(contentsOf: url)

            // 1. Initialize a new Wasm Engine & Store
            let engine = Engine()
            let store = Store(engine: engine)

            // 2. Parse the Wasm Module
            let module = try parseWasm(bytes: [UInt8](wasmBytes))

            // 3. Setup Imports
            let bridge = WasmBridge(runner: self)
            bridge.netModule = self.netModule
            bridge.htmlModule = self.htmlModule
            bridge.jsModule = self.jsModule
            bridge.stdModule = self.stdModule
            bridge.defaultsModule = self.defaultsModule
            let imports = bridge.buildImports(store: store)

            // 4. Instantiate the plugin.
            self.instance = try module.instantiate(store: store, imports: imports)
            self.bridge = bridge

            // 5. Store a reference to the Wasm linear memory.
            guard let exportedMemory = self.instance?.exports["memory"],
                case .memory(let mem) = exportedMemory
            else {
                throw ItoError.wasmTrap("Plugin did not export linear 'memory'.")
            }

            self.memory = mem

        } catch let error as ItoError {
            throw error
        } catch {
            throw ItoError.wasmTrap("Failed to load Wasm plugin: \(error.localizedDescription)")
        }
    }

    // MARK: - Memory Utilities

    /// Reads a slice of bytes from the Wasm linear memory.
    /// - Parameters:
    ///   - offset: The starting byte offset in Wasm memory.
    ///   - length: The number of bytes to read.
    /// - Returns: An array of bytes.
    /// - Throws: `ItoError.memoryOutOfBounds` if the requested range is outside memory bounds.
    public func readMemory(offset: Int, length: Int) throws -> [UInt8] {
        guard let memory = memory else {
            throw ItoError.wasmTrap("Memory is not initialized.")
        }

        let memData = memory.data
        guard offset >= 0, length >= 0, offset + length <= memData.count else {
            throw ItoError.memoryOutOfBounds(
                offset: offset, length: length, memorySize: memData.count)
        }

        return Array(memData[offset..<(offset + length)])
    }

    /// Writes a slice of bytes into the Wasm linear memory.
    /// Note: The plugin is responsible for `alloc`ating this memory first and providing a safe offset!
    /// - Parameters:
    ///   - offset: The starting byte offset in Wasm memory.
    ///   - bytes: The data to write.
    /// - Throws: `ItoError.memoryOutOfBounds` if the requested range is outside memory bounds.
    public func writeMemory(offset: Int, bytes: [UInt8]) throws {
        guard let memory = memory else {
            throw ItoError.wasmTrap("Memory is not initialized.")
        }

        let memData = memory.data
        let length = bytes.count

        guard offset >= 0, offset + length <= memData.count else {
            throw ItoError.memoryOutOfBounds(
                offset: offset, length: length, memorySize: memData.count)
        }

        // Write the bytes using GuestMemory API
        memory.withUnsafeMutableBufferPointer(offset: UInt(offset), count: bytes.count) {
            buffer in
            bytes.withUnsafeBytes { sourceBuffer in
                buffer.copyMemory(from: UnsafeRawBufferPointer(sourceBuffer))
            }
        }
    }

    /// Execute a function exported by the Wasm module.
    ///
    /// - Parameters:
    ///   - name: The name of the exported function (e.g., "get_manga_list")
    ///   - args: Wasm primitive arguments (i32, i64, f32, f64)
    /// - Returns: An array of resulting Wasm primitive values
    /// - Throws: `ItoError` on execution failure or missing export
    public func executeExport(_ name: String, args: [Value] = []) throws -> [Value] {
        guard let instance = instance else {
            throw ItoError.wasmTrap("Instance is not initialized.")
        }

        guard let exportedItem = instance.exports[name],
            case .function(let function) = exportedItem
        else {
            throw ItoError.wasmTrap("Function '\(name)' not exported by plugin.")
        }

        do {
            return try function(args)
        } catch {
            throw ItoError.wasmTrap("Execution of '\(name)' failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Core Execution API

    /// Executes `get_home()`
    public func getHome() async throws -> HomeLayout {
        let result = try self.executeExport("get_home")

        guard let resultVal = result.first, case .i64(let packed) = resultVal else {
            throw ItoError.wasmTrap("Expected i64 packed pointer response from Wasm layer")
        }

        let responseLen = Int(packed & 0xFFFF_FFFF)
        let responsePtr = Int(packed >> 32)
        defer {
            deallocBytes(
                ptr: Int32(bitPattern: UInt32(responsePtr)),
                len: Int32(bitPattern: UInt32(responseLen)))
        }

        let responseBytes = try self.readMemory(offset: responsePtr, length: responseLen)
        return try self.postcardDecoder.decode(HomeLayout.self, from: responseBytes)
    }

    private func allocString(_ string: String) throws -> (ptr: Int32, len: Int32) {
        let bytes = Array(string.utf8)
        let ptrInfo = try allocBytes(bytes)
        return ptrInfo
    }

    private func allocBytes(_ bytes: [UInt8]) throws -> (ptr: Int32, len: Int32) {
        if bytes.isEmpty { return (0, 0) }
        let allocResult = try self.executeExport("alloc", args: [.i32(UInt32(bytes.count))])
        guard let pointerVal = allocResult.first, case .i32(let pointer) = pointerVal else {
            throw ItoError.wasmTrap("Failed to allocate memory")
        }
        try self.writeMemory(offset: Int(pointer), bytes: bytes)
        return (Int32(bitPattern: pointer), Int32(bytes.count))
    }

    private func deallocBytes(ptr: Int32, len: Int32) {
        if len == 0 || ptr == 0 { return }
        do {
            _ = try self.executeExport(
                "dealloc", args: [.i32(UInt32(bitPattern: ptr)), .i32(UInt32(bitPattern: len))])
        } catch {
            print("[ItoRunner] Warning: Failed to dealloc memory at \(ptr) (len \(len))")
        }
    }

    /// Executes `get_search_manga_list(query: String, page: Int32, filters: [FilterStruct])`
    public func getSearchMangaList(query: String, page: Int32, filters: [FilterItem]?) async throws
        -> MangaPageResult
    {
        let qInfo = try allocString(query)
        defer { deallocBytes(ptr: qInfo.ptr, len: qInfo.len) }

        let fBytes = try self.postcardEncoder.encode(filters ?? [])
        let fInfo = try allocBytes(fBytes)
        defer { deallocBytes(ptr: fInfo.ptr, len: fInfo.len) }

        let result = try self.executeExport(
            "get_search_manga_list",
            args: [
                .i32(UInt32(bitPattern: qInfo.ptr)), .i32(UInt32(bitPattern: qInfo.len)),
                .i32(UInt32(bitPattern: page)),
                .i32(UInt32(bitPattern: fInfo.ptr)), .i32(UInt32(bitPattern: fInfo.len)),
            ])

        guard let resultVal = result.first, case .i64(let packed) = resultVal else {
            throw ItoError.wasmTrap("Expected i64 packed pointer response from Wasm layer")
        }

        let responseLen = Int(packed & 0xFFFF_FFFF)
        let responsePtr = Int(packed >> 32)
        defer {
            deallocBytes(
                ptr: Int32(bitPattern: UInt32(responsePtr)),
                len: Int32(bitPattern: UInt32(responseLen)))
        }

        let responseBytes = try self.readMemory(offset: responsePtr, length: responseLen)
        return try self.postcardDecoder.decode(MangaPageResult.self, from: responseBytes)
    }

    /// Executes `get_manga_list(listing: Listing, page: Int32)`
    public func getMangaList(listing: Listing, page: Int32) async throws -> MangaPageResult {
        let lBytes = try self.postcardEncoder.encode(listing)
        let lInfo = try allocBytes(lBytes)
        defer { deallocBytes(ptr: lInfo.ptr, len: lInfo.len) }

        let result = try self.executeExport(
            "get_manga_list",
            args: [
                .i32(UInt32(bitPattern: lInfo.ptr)), .i32(UInt32(bitPattern: lInfo.len)),
                .i32(UInt32(bitPattern: page)),
            ])

        guard let resultVal = result.first, case .i64(let packed) = resultVal else {
            throw ItoError.wasmTrap("Expected i64 packed pointer response from Wasm layer")
        }

        let responseLen = Int(packed & 0xFFFF_FFFF)
        let responsePtr = Int(packed >> 32)
        defer {
            deallocBytes(
                ptr: Int32(bitPattern: UInt32(responsePtr)),
                len: Int32(bitPattern: UInt32(responseLen)))
        }

        let responseBytes = try self.readMemory(offset: responsePtr, length: responseLen)
        return try self.postcardDecoder.decode(MangaPageResult.self, from: responseBytes)
    }

    /// Executes `get_manga_update(manga: Manga, needs_details: Bool, needs_chapters: Bool)`
    public func getMangaUpdate(manga: Manga, needsDetails: Bool = true, needsChapters: Bool = true)
        async throws -> Manga
    {
        let mBytes = try self.postcardEncoder.encode(manga)
        let hexString = mBytes.map { String(format: "%02x", $0) }.joined()
        print("[DEBUG] getMangaUpdate Swift Manga Payload (len \(mBytes.count)): \(hexString)")

        let mInfo = try allocBytes(mBytes)
        defer { deallocBytes(ptr: mInfo.ptr, len: mInfo.len) }

        let result = try self.executeExport(
            "get_manga_update",
            args: [
                .i32(UInt32(bitPattern: mInfo.ptr)), .i32(UInt32(bitPattern: mInfo.len)),
                .i32(needsDetails ? 1 : 0), .i32(needsChapters ? 1 : 0),
            ])

        guard let resultVal = result.first, case .i64(let packed) = resultVal else {
            throw ItoError.wasmTrap("Expected i64 packed pointer response from Wasm layer")
        }

        let responseLen = Int(packed & 0xFFFF_FFFF)
        let responsePtr = Int(packed >> 32)
        defer {
            deallocBytes(
                ptr: Int32(bitPattern: UInt32(responsePtr)),
                len: Int32(bitPattern: UInt32(responseLen)))
        }

        let responseBytes = try self.readMemory(offset: responsePtr, length: responseLen)
        return try self.postcardDecoder.decode(Manga.self, from: responseBytes)
    }

    /// Executes `get_page_list(manga: Manga, chapter: Chapter)`
    public func getPageList(manga: Manga, chapter: Chapter) async throws -> [Page] {
        let mBytes = try self.postcardEncoder.encode(manga)
        let mInfo = try allocBytes(mBytes)
        defer { deallocBytes(ptr: mInfo.ptr, len: mInfo.len) }

        let cBytes = try self.postcardEncoder.encode(chapter)
        let cInfo = try allocBytes(cBytes)
        defer { deallocBytes(ptr: cInfo.ptr, len: cInfo.len) }

        let result = try self.executeExport(
            "get_page_list",
            args: [
                .i32(UInt32(bitPattern: mInfo.ptr)), .i32(UInt32(bitPattern: mInfo.len)),
                .i32(UInt32(bitPattern: cInfo.ptr)), .i32(UInt32(bitPattern: cInfo.len)),
            ])

        guard let resultVal = result.first, case .i64(let packed) = resultVal else {
            throw ItoError.wasmTrap("Expected i64 packed pointer response from Wasm layer")
        }

        let responseLen = Int(packed & 0xFFFF_FFFF)
        let responsePtr = Int(packed >> 32)
        defer {
            deallocBytes(
                ptr: Int32(bitPattern: UInt32(responsePtr)),
                len: Int32(bitPattern: UInt32(responseLen)))
        }

        let responseBytes = try self.readMemory(offset: responsePtr, length: responseLen)
        return try self.postcardDecoder.decode([Page].self, from: responseBytes)
    }
}
