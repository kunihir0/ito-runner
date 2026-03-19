import Foundation

/// A thread-safe registry that bridges the gap between WebAssembly's integer IDs and native Swift objects.
/// Wasm plugins cannot natively hold complex Swift types (like URLRequest, SwiftSoup.Document, etc.), so they
/// request the host to allocate these objects. The host stores them here and gives the Wasm plugin an integer descriptor.
public actor DescriptorRegistry {

    private var storage: [UInt32: Any] = [:]

    /// We start at 1 to avoid a 0/null error in the Wasm memory space.
    private var nextID: UInt32 = 1

    public init() {}

    /// Stores the provided object in the registry and returns its unique descriptor ID.
    ///
    /// - Parameter object: The native Swift object to store.
    /// - Returns: The generated generic descriptor ID.
    public func store(_ object: Any) -> UInt32 {
        var id = nextID
        
        // Hardening: Search for a free ID if the current one is taken
        while storage[id] != nil {
            nextID &+= 1
            if nextID == 0 { nextID = 1 }
            id = nextID
        }
        
        storage[id] = object
        nextID &+= 1 // Safely wrap around if we ever reach UInt32.max

        // Prevent handing out 0 on wrap-around
        if nextID == 0 {
            nextID = 1
        }

        return id
    }

    /// Retrieves a specific stored object by its generic descriptor ID and attempts to cast it to `T`.
    ///
    /// - Parameter id: The generic descriptor ID given by Wasm.
    /// - Returns: The strongly typed requested object.
    /// - Throws: `ItoError.invalidDescriptor` if the ID doesn't exist or is the wrong type.
    public func get<T>(_ id: UInt32) throws -> T {
        guard let object = storage[id] else {
            throw ItoError.invalidDescriptor(id: id)
        }

        guard let typedObject = object as? T else {
            throw ItoError.invalidDescriptor(id: id) // Or maybe a typeMismatch error?
        }

        return typedObject
    }

    /// Removes the object associated with the descriptor ID from the registry.
    ///
    /// - Parameter id: The generic descriptor ID.
    public func remove(_ id: UInt32) {
        storage.removeValue(forKey: id)
    }

    /// Clears all objects from the registry, freeing memory.
    /// Useful for when a plugin execution context completes.
    public func clear() {
        storage.removeAll()
        nextID = 1
    }
}
