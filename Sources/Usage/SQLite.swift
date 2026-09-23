import Foundation
import SQLite3

enum SQLiteError: Error, Equatable {
    case open(String)
    case query(String)
}

final class SQLiteDB: @unchecked Sendable {
    private var db: OpaquePointer?

    static func openReadonly(_ path: String) throws -> SQLiteDB {
        if let database = try? SQLiteDB(path: path, flags: SQLITE_OPEN_READONLY) {
            return database
        }
        let copy = try copyAside(path)
        return try SQLiteDB(path: copy, flags: SQLITE_OPEN_READONLY)
    }

    static func create(_ path: String) throws -> SQLiteDB {
        try SQLiteDB(path: path, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
    }

    private init(path: String, flags: Int32) throws {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let handle { sqlite3_close(handle) }
            throw SQLiteError.open(message)
        }
        db = handle
        sqlite3_busy_timeout(handle, 2000)
    }

    func close() {
        if let db {
            sqlite3_close(db)
            self.db = nil
        }
    }

    deinit { close() }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &error)
        if rc != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(error)
            throw SQLiteError.query(message)
        }
    }

    func query(_ sql: String, bind: [SQLiteValue] = []) throws -> [[SQLiteValue]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteError.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in bind.enumerated() {
            try value.bind(statement, index: Int32(index + 1))
        }
        var rows: [[SQLiteValue]] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_ROW {
                let count = sqlite3_column_count(statement)
                var row: [SQLiteValue] = []
                for column in 0..<count {
                    row.append(SQLiteValue.column(statement, index: column))
                }
                rows.append(row)
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw SQLiteError.query(String(cString: sqlite3_errmsg(db)))
            }
        }
        return rows
    }

    private static func copyAside(_ path: String) throws -> String {
        let source = URL(fileURLWithPath: path)
        let directory = FileManager.default.temporaryDirectory.appending(path: "usage-sqlite-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: destination)
        for suffix in ["-wal", "-shm"] {
            let extra = URL(fileURLWithPath: path + suffix)
            guard FileManager.default.fileExists(atPath: extra.path) else { continue }
            try? FileManager.default.copyItem(
                at: extra,
                to: directory.appending(path: source.lastPathComponent + suffix)
            )
        }
        return destination.path
    }
}

enum SQLiteValue: Sendable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)

    var int: Int {
        switch self {
        case .int(let value): Int(value)
        case .double(let value): Int(value)
        case .text(let value): Int(value) ?? 0
        case .null: 0
        }
    }

    var text: String {
        switch self {
        case .text(let value): value
        case .int(let value): String(value)
        case .double(let value): String(value)
        case .null: ""
        }
    }

    fileprivate func bind(_ statement: OpaquePointer, index: Int32) throws {
        let rc: Int32
        switch self {
        case .null:
            rc = sqlite3_bind_null(statement, index)
        case .int(let value):
            rc = sqlite3_bind_int64(statement, index, value)
        case .double(let value):
            rc = sqlite3_bind_double(statement, index, value)
        case .text(let value):
            rc = sqlite3_bind_text(statement, index, value, -1, transient)
        }
        if rc != SQLITE_OK {
            throw SQLiteError.query("bind \(index)")
        }
    }

    fileprivate static func column(_ statement: OpaquePointer, index: Int32) -> SQLiteValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER:
            return .int(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            return .double(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            guard let pointer = sqlite3_column_text(statement, index) else { return .null }
            return .text(String(cString: pointer))
        default:
            return .null
        }
    }
}

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
