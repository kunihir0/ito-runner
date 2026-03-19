import Foundation
import JavaScriptCore

/// The default implementation of `JsModule` using `JavaScriptCore`.
public final class DefaultJsModule: JsModule, @unchecked Sendable {

    private let lock = NSLock()

    public init() {}

    public func evaluate(script: String) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        // JavaScriptCore contexts should be isolated per plugin if possible,
        // but for now we create a fresh context per evaluation or maintain one.
        // Creating a new context for every eval is safer and avoids memory leaks,
        // but state won't persist between calls.

        guard let context = JSContext() else {
            throw ItoError.hostModuleError(domain: "js", message: "Failed to initialize JSContext")
        }

        // Define a simple console.log for debugging JS within the plugin
        let consoleLog: @convention(block) (String) -> Void = { message in
            print("[JS Log] \(message)")
        }

        let console = context.objectForKeyedSubscript("console")
        if console == nil || console?.isUndefined == true {
            let newConsole = JSValue(newObjectIn: context)
            newConsole?.setObject(consoleLog, forKeyedSubscript: "log" as NSString)
            context.setObject(newConsole, forKeyedSubscript: "console" as NSString)
        } else {
            console?.setObject(consoleLog, forKeyedSubscript: "log" as NSString)
        }

        context.exceptionHandler = { _, exception in
            if let exc = exception {
                print("[JS Exception] \(exc.toString() ?? "Unknown exception")")
            }
        }

        guard let result = context.evaluateScript(script) else {
            throw ItoError.hostModuleError(domain: "js", message: "Evaluation returned nil")
        }

        if result.isUndefined || result.isNull {
            return ""
        }

        return result.toString() ?? ""
    }
}
