import Testing
import WasmKit

@testable import ito_runner

@Suite("WasmKit Memory API Tests")
struct EngineMemoryTests {

    @Test("Verify reading and writing to WasmKit Memory")
    func testReadWriteMemory() throws {
        // We will instantiate a minimal Wasm module that exports memory,
        // and then verify if we can read and write to it correctly.

        // (module (memory (export "memory") 1))
        // Compiled to binary representation:
        let wasmBytes: [UInt8] = [
            0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,  // Magic & Version
            0x05, 0x03, 0x01, 0x00, 0x01,  // Memory section: 1 memory, initial 1 page
            0x07, 0x0a, 0x01, 0x06, 0x6d, 0x65, 0x6d, 0x6f, 0x72, 0x79, 0x02, 0x00,  // Export section: "memory"
        ]

        let engine = Engine()
        let store = Store(engine: engine)
        let module = try parseWasm(bytes: wasmBytes)
        let instance = try module.instantiate(store: store)

        // 1. Extract memory from instance
        guard let exportedItem = instance.exports["memory"],
            case .memory(let memory) = exportedItem
        else {
            Issue.record("Plugin did not export memory")
            return
        }

        // 2. Read initial data (should be 0)
        let data = memory.data
        #expect(data.count == 65536)  // 1 page = 64KB
        #expect(data[0] == 0)

        // 3. Exploring the Memory object to find write methods:
        memory.withUnsafeMutableBufferPointer(offset: 0, count: 1) { buffer in
            buffer[0] = 42
        }
        #expect(memory.data[0] == 42)
    }
}
