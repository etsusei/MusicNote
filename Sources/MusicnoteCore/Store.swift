import Foundation
import SQLite3

/// A persisted entity. Every record lives in one document table keyed by
/// (kind, id), with an owner column for parent lookups.
public protocol Record: Codable, Identifiable, Sendable where ID == UUID {
    static var kind: String { get }
    var ownerId: UUID? { get }
    var sortKey: Double { get }
}

public enum StoreError: Error, LocalizedError {
    case sqlite(String)
    public var errorDescription: String? {
        switch self { case .sqlite(let m): "数据库错误：\(m)" }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Single-writer SQLite store. All access goes through one serial queue.
public final class Store: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "musicnote.store")
    private let onQueueKey = DispatchSpecificKey<Bool>()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(url: URL) throws {
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        queue.setSpecific(key: onQueueKey, value: true)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw StoreError.sqlite("cannot open \(url.path)")
        }
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA synchronous=NORMAL")
        try exec("""
            CREATE TABLE IF NOT EXISTS docs (
              kind TEXT NOT NULL, id TEXT NOT NULL, owner TEXT, sort REAL NOT NULL DEFAULT 0,
              updated REAL NOT NULL, json TEXT NOT NULL, PRIMARY KEY (kind, id))
            """)
        try exec("CREATE INDEX IF NOT EXISTS docs_owner ON docs(kind, owner, sort)")
        try exec("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)")
        try exec("INSERT OR IGNORE INTO meta(key, value) VALUES ('schemaVersion', '1')")
    }

    deinit { sqlite3_close(db) }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw StoreError.sqlite(message)
        }
    }

    private func lastError() -> String { String(cString: sqlite3_errmsg(db)) }

    /// Runs on the store queue; re-entrant, so a read inside a transaction doesn't deadlock
    /// (dispatch_sync onto the queue it is already on traps).
    private func locked<R>(_ body: () throws -> R) rethrows -> R {
        if DispatchQueue.getSpecific(key: onQueueKey) == true { return try body() }
        return try queue.sync(execute: body)
    }

    public func save<T: Record>(_ record: T) throws {
        try locked { try saveLocked(record) }
    }

    private func saveLocked<T: Record>(_ record: T) throws {
        let json = String(decoding: try encoder.encode(record), as: UTF8.self)
        var stmt: OpaquePointer?
        let sql = "INSERT OR REPLACE INTO docs(kind, id, owner, sort, updated, json) VALUES (?,?,?,?,?,?)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw StoreError.sqlite(lastError()) }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, T.kind, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, record.id.uuidString, -1, SQLITE_TRANSIENT)
        if let owner = record.ownerId { sqlite3_bind_text(stmt, 3, owner.uuidString, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 3) }
        sqlite3_bind_double(stmt, 4, record.sortKey)
        sqlite3_bind_double(stmt, 5, Date().timeIntervalSince1970)
        sqlite3_bind_text(stmt, 6, json, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw StoreError.sqlite(lastError()) }
    }

    /// Saves several records atomically.
    public func transaction(_ body: (TransactionWriter) throws -> Void) throws {
        try locked {
            try exec("BEGIN IMMEDIATE")
            do {
                try body(TransactionWriter(store: self))
                try exec("COMMIT")
            } catch {
                try? exec("ROLLBACK")
                throw error
            }
        }
    }

    public struct TransactionWriter {
        fileprivate let store: Store
        public func save<T: Record>(_ record: T) throws { try store.saveLocked(record) }
        public func delete<T: Record>(_ type: T.Type, id: UUID) throws { try store.deleteLocked(type, id: id) }
        /// Every record whose owner is `owner`, whatever its kind.
        public func deleteOwned(by owner: UUID) throws { try store.deleteOwnedLocked(owner) }
    }

    public func fetch<T: Record>(_ type: T.Type, id: UUID) -> T? {
        locked {
            query(T.self, sql: "SELECT json FROM docs WHERE kind=? AND id=?", binds: [T.kind, id.uuidString]).first
        }
    }

    public func all<T: Record>(_ type: T.Type, owner: UUID? = nil) -> [T] {
        locked {
            if let owner {
                return query(T.self, sql: "SELECT json FROM docs WHERE kind=? AND owner=? ORDER BY sort", binds: [T.kind, owner.uuidString])
            }
            return query(T.self, sql: "SELECT json FROM docs WHERE kind=? ORDER BY sort", binds: [T.kind])
        }
    }

    public func delete<T: Record>(_ type: T.Type, id: UUID) throws {
        try locked { try deleteLocked(type, id: id) }
    }

    private func deleteLocked<T: Record>(_ type: T.Type, id: UUID) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM docs WHERE kind=? AND id=?", -1, &stmt, nil) == SQLITE_OK else { throw StoreError.sqlite(lastError()) }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, T.kind, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, id.uuidString, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw StoreError.sqlite(lastError()) }
    }

    private func deleteOwnedLocked(_ owner: UUID) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM docs WHERE owner=?", -1, &stmt, nil) == SQLITE_OK else { throw StoreError.sqlite(lastError()) }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, owner.uuidString, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw StoreError.sqlite(lastError()) }
    }

    private func query<T: Decodable>(_ type: T.Type, sql: String, binds: [String]) -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        for (i, b) in binds.enumerated() { sqlite3_bind_text(stmt, Int32(i + 1), b, -1, SQLITE_TRANSIENT) }
        var out: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let c = sqlite3_column_text(stmt, 0) else { continue }
            let data = Data(String(cString: c).utf8)
            if let value = try? decoder.decode(T.self, from: data) { out.append(value) }
        }
        return out
    }

    /// Consistent snapshot for backups, made with SQLite's online backup API.
    public func backup(to url: URL) throws {
        try locked {
            var dest: OpaquePointer?
            guard sqlite3_open(url.path, &dest) == SQLITE_OK else { throw StoreError.sqlite("cannot open backup target") }
            defer { sqlite3_close(dest) }
            guard let b = sqlite3_backup_init(dest, "main", db, "main") else { throw StoreError.sqlite(lastError()) }
            sqlite3_backup_step(b, -1)
            sqlite3_backup_finish(b)
        }
    }
}
