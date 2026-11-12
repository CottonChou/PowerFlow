import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 只存 60s 低频点的历史库。
///
/// 2s 与 10s 数据留在内存里，落库的只有长窗口需要的那一层，
/// 一天 1440 行，代价可以忽略。
public final class SQLiteStore: @unchecked Sendable {

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.powerflow.store")

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent("PowerFlow", isDirectory: true)
            .appendingPathComponent("history.sqlite")
    }

    public init?(url: URL = SQLiteStore.defaultURL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { return nil }
        guard createSchema() else {
            sqlite3_close(db)
            db = nil
            return nil
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    private func createSchema() -> Bool {
        let sql = """
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS samples (
            ts REAL PRIMARY KEY,
            on_ac INTEGER NOT NULL,
            charging INTEGER NOT NULL,
            percent INTEGER,
            minutes INTEGER,
            p_input REAL, p_system REAL, p_battery REAL,
            p_display REAL, p_ports REAL,
            apps TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_samples_ts ON samples(ts);
        """
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    public func insert(_ sample: PowerSample) {
        queue.sync { [db] in
            guard let db else { return }
            let sql = """
            INSERT OR REPLACE INTO samples
            (ts,on_ac,charging,percent,minutes,p_input,p_system,p_battery,p_display,p_ports,apps)
            VALUES (?,?,?,?,?,?,?,?,?,?,?);
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_double(statement, 1, sample.ts.timeIntervalSince1970)
            sqlite3_bind_int(statement, 2, sample.onAC ? 1 : 0)
            sqlite3_bind_int(statement, 3, sample.charging ? 1 : 0)
            bindOptionalInt(statement, 4, sample.batteryPercent)
            bindOptionalInt(statement, 5, sample.batteryMinutes)
            bindOptionalDouble(statement, 6, sample.pInput)
            bindOptionalDouble(statement, 7, sample.pSystem)
            bindOptionalDouble(statement, 8, sample.pBattery)
            bindOptionalDouble(statement, 9, sample.pDisplay)
            bindOptionalDouble(statement, 10, sample.pPorts)

            if let data = try? JSONEncoder().encode(sample.apps),
               let text = String(data: data, encoding: .utf8) {
                sqlite3_bind_text(statement, 11, text, -1, sqliteTransient)
            } else {
                sqlite3_bind_text(statement, 11, "[]", -1, sqliteTransient)
            }
            sqlite3_step(statement)
        }
    }

    public func load(since: Date) -> [PowerSample] {
        queue.sync {
            guard let db else { return [] }
            let sql = """
            SELECT ts,on_ac,charging,percent,minutes,p_input,p_system,p_battery,p_display,p_ports,apps
            FROM samples WHERE ts >= ? ORDER BY ts ASC;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, since.timeIntervalSince1970)

            var result: [PowerSample] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let apps: [AppUsage]
                if let cString = sqlite3_column_text(statement, 10) {
                    let json = String(cString: cString)
                    apps = (try? JSONDecoder().decode([AppUsage].self, from: Data(json.utf8))) ?? []
                } else {
                    apps = []
                }
                result.append(PowerSample(
                    ts: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                    onAC: sqlite3_column_int(statement, 1) != 0,
                    charging: sqlite3_column_int(statement, 2) != 0,
                    batteryPercent: columnInt(statement, 3),
                    batteryMinutes: columnInt(statement, 4),
                    pInput: columnDouble(statement, 5),
                    pSystem: columnDouble(statement, 6),
                    pBattery: columnDouble(statement, 7),
                    pDisplay: columnDouble(statement, 8),
                    pPorts: columnDouble(statement, 9),
                    apps: apps
                ))
            }
            return result
        }
    }

    public func deleteAll() {
        queue.sync {
            guard let db else { return }
            sqlite3_exec(db, "DELETE FROM samples;", nil, nil, nil)
        }
    }

    private func bindOptionalInt(_ statement: OpaquePointer?, _ index: Int32, _ value: Int?) {
        if let value { sqlite3_bind_int(statement, index, Int32(value)) }
        else { sqlite3_bind_null(statement, index) }
    }

    private func bindOptionalDouble(_ statement: OpaquePointer?, _ index: Int32, _ value: Double?) {
        if let value { sqlite3_bind_double(statement, index, value) }
        else { sqlite3_bind_null(statement, index) }
    }

    private func columnInt(_ statement: OpaquePointer?, _ index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int(statement, index))
    }

    private func columnDouble(_ statement: OpaquePointer?, _ index: Int32) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, index)
    }
}
