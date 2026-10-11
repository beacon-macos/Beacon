import Foundation
import JavaScriptCore
import SQLite3

/// Runs extension scripts in an isolated JavaScriptCore context.
///
/// A script registers command handlers with `beacon.registerCommand(id, handler)`. A handler returns an
/// array of items that Beacon shows in the launcher. Each run uses a fresh context, so scripts cannot keep
/// state between runs.
nonisolated enum ExtensionRuntime {
    static func runCommand(_ commandID: String, in installedExtension: InstalledExtension) throws -> [ExtensionItem] {
        let source: String
        do {
            source = try String(contentsOf: installedExtension.scriptURL, encoding: .utf8)
        } catch {
            throw ExtensionError.script("Could not read \(installedExtension.manifest.main).")
        }
        return try runCommand(commandID, source: source, sourceURL: installedExtension.scriptURL)
    }

    static func runCommand(_ commandID: String, source: String, sourceURL: URL? = nil) throws -> [ExtensionItem] {
        guard let context = JSContext() else {
            throw ExtensionError.script("Could not create a JavaScript context.")
        }
        var exceptionMessage: String?
        context.exceptionHandler = { _, exception in
            exceptionMessage = exception?.toString() ?? "Unknown error"
        }

        var handlers: [String: JSValue] = [:]
        let registerCommand: @convention(block) (String, JSValue) -> Void = { id, handler in
            handlers[id] = handler
        }
        installAPI(in: context, registerCommand: registerCommand)

        context.evaluateScript(source, withSourceURL: sourceURL)
        if let exceptionMessage { throw ExtensionError.script(exceptionMessage) }

        guard let handler = handlers[commandID], handler.isObject else {
            throw ExtensionError.commandNotFound(commandID)
        }
        let result = handler.call(withArguments: [])
        if let exceptionMessage { throw ExtensionError.script(exceptionMessage) }
        guard let result, !result.isUndefined, !result.isNull else { return [] }

        let json = context.objectForKeyedSubscript("JSON")
        guard let encoded = json?.invokeMethod("stringify", withArguments: [result])?.toString(),
              let data = encoded.data(using: .utf8) else {
            throw ExtensionError.invalidResult("The command result could not be encoded.")
        }
        do {
            return try JSONDecoder().decode([ExtensionItem].self, from: data)
        } catch {
            throw ExtensionError.invalidResult(String(describing: error))
        }
    }

    private static func installAPI(
        in context: JSContext,
        registerCommand: @escaping @convention(block) (String, JSValue) -> Void
    ) {
        let beacon = JSValue(newObjectIn: context)!
        beacon.setObject(registerCommand, forKeyedSubscript: "registerCommand" as NSString)
        beacon.setObject(
            FileManager.default.homeDirectoryForCurrentUser.path,
            forKeyedSubscript: "homeDirectory" as NSString
        )

        let fileExists: @convention(block) (String) -> Bool = { path in
            FileManager.default.fileExists(atPath: expandingTilde(in: path))
        }
        beacon.setObject(fileExists, forKeyedSubscript: "fileExists" as NSString)

        let readFile: @convention(block) (String) -> Any = { path in
            (try? String(contentsOfFile: expandingTilde(in: path), encoding: .utf8)) ?? NSNull()
        }
        beacon.setObject(readFile, forKeyedSubscript: "readFile" as NSString)

        let querySQLite: @convention(block) (String, String) -> Any = { path, sql in
            do {
                return try SQLiteReader.query(path: expandingTilde(in: path), sql: sql)
            } catch {
                if let context = JSContext.current() {
                    context.exception = JSValue(newErrorFromMessage: error.localizedDescription, in: context)
                }
                return NSNull()
            }
        }
        beacon.setObject(querySQLite, forKeyedSubscript: "querySQLite" as NSString)
        context.setObject(beacon, forKeyedSubscript: "beacon" as NSString)

        let log: @convention(block) () -> Void = {
            let message = (JSContext.currentArguments() as? [JSValue] ?? []).map { $0.toString() ?? "" }
            print("[Beacon extension]", message.joined(separator: " "))
        }
        let console = JSValue(newObjectIn: context)!
        for name in ["log", "info", "warn", "error"] {
            console.setObject(log, forKeyedSubscript: name as NSString)
        }
        context.setObject(console, forKeyedSubscript: "console" as NSString)
    }

    static func expandingTilde(in path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return FileManager.default.homeDirectoryForCurrentUser.path + path.dropFirst()
    }
}

/// Reads SQLite databases without ever opening them for writing.
nonisolated enum SQLiteReader {
    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    static func query(path: String, sql: String) throws -> [[String: Any]] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open \(path)."
            sqlite3_close(database)
            throw Failure(errorDescription: message)
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1_000)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Failure(errorDescription: String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        var rows: [[String: Any]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else {
                throw Failure(errorDescription: String(cString: sqlite3_errmsg(database)))
            }
            var row: [String: Any] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, column))
                row[name] = value(of: statement, at: column)
            }
            rows.append(row)
        }
        return rows
    }

    private static func value(of statement: OpaquePointer?, at column: Int32) -> Any {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER:
            return sqlite3_column_int64(statement, column)
        case SQLITE_FLOAT:
            return sqlite3_column_double(statement, column)
        case SQLITE_TEXT:
            return sqlite3_column_text(statement, column).map { String(cString: $0) } ?? NSNull()
        case SQLITE_BLOB:
            guard let bytes = sqlite3_column_blob(statement, column) else { return NSNull() }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
            return String(data: data, encoding: .utf8) ?? NSNull()
        default:
            return NSNull()
        }
    }
}
