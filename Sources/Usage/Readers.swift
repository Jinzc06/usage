import Foundation

struct UsagePaths: Sendable {
    var cursorState: URL
    var codexDirectory: URL
    var zcodeDatabase: URL
    var kimiSessions: URL

    static func live() -> UsagePaths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return UsagePaths(
            cursorState: home.appending(path: "Library/Application Support/Cursor/User/globalStorage/state.vscdb"),
            codexDirectory: home.appending(path: ".codex"),
            zcodeDatabase: home.appending(path: ".zcode/cli/db/db.sqlite"),
            kimiSessions: home.appending(path: ".kimi-code/sessions")
        )
    }
}

enum SourceResult: Sendable {
    case success([RawRecord])
    case failure(String)
}

enum Readers {
    static func loadAll(paths: UsagePaths, start: Date, end: Date) async -> [String: SourceResult] {
        async let cursor = CursorReader.load(database: paths.cursorState, start: start, end: end)
        async let codex = CodexReader.load(directory: paths.codexDirectory, start: start, end: end)
        async let zcode = ZCodeReader.load(database: paths.zcodeDatabase, start: start)
        async let kimi = KimiReader.load(sessions: paths.kimiSessions, start: start, end: end)
        let (cursorResult, codexResult, zcodeResult, kimiResult) = await (cursor, codex, zcode, kimi)
        return [
            "Cursor": cursorResult,
            "Codex": codexResult,
            "ZCode": zcodeResult,
            "Kimi": kimiResult,
        ]
    }
}

enum CursorReader {
    static func load(database: URL, start: Date, end: Date) async -> SourceResult {
        let path = database.path
        let startMs = Int(start.timeIntervalSince1970 * 1000)
        let endMs = Int(end.timeIntervalSince1970 * 1000)
        return await Task.detached {
            guard FileManager.default.fileExists(atPath: path) else {
                return .failure("未找到")
            }
            do {
                let cookie = try sessionCookie(database: path)
                return try await fetch(cookie: cookie, startMs: startMs, endMs: endMs)
            } catch let error as CursorError {
                return .failure(error.message)
            } catch {
                return .failure("读取失败")
            }
        }.value
    }

    static func parse(_ data: Data) -> [RawRecord] {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rows = root["aggregations"] as? [[String: Any]]
        else { return [] }
        return rows.map { row in
            let model = (row["modelIntent"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = TokenBreakdown.accounting(
                input: jsonInt(row["inputTokens"]),
                output: jsonInt(row["outputTokens"]),
                cacheRead: jsonInt(row["cacheReadTokens"]),
                cacheWrite: jsonInt(row["cacheWriteTokens"])
            )
            return RawRecord(
                model: (model?.isEmpty == false ? model! : "unknown"),
                parts: parts,
                exactCostUSD: jsonCents(row["totalCents"]).map { $0 / Decimal(100) }
            )
        }
    }

    private static func fetch(cookie: String, startMs: Int, endMs: Int) async throws -> SourceResult {
        let body: [String: Any] = ["teamId": -1, "startDate": startMs, "endDate": endMs]
        let payload = try JSONSerialization.data(withJSONObject: body)
        var request = URLRequest(url: URL(string: "https://cursor.com/api/dashboard/get-aggregated-usage-events")!)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        request.setValue("https://cursor.com/dashboard?tab=usage", forHTTPHeaderField: "Referer")
        request.setValue("WorkosCursorSessionToken=\(cookie)", forHTTPHeaderField: "Cookie")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            let encoded = cookie.replacingOccurrences(of: "::", with: "%3A%3A")
            if encoded != cookie {
                request.setValue("WorkosCursorSessionToken=\(encoded)", forHTTPHeaderField: "Cookie")
                let (retryData, retryResponse) = try await URLSession.shared.data(for: request)
                let retryStatus = (retryResponse as? HTTPURLResponse)?.statusCode ?? 0
                if retryStatus == 401 || retryStatus == 403 { return .failure("请重新登录") }
                guard (200..<300).contains(retryStatus) else { return .failure("读取失败") }
                return .success(stamp(parse(retryData), at: Date(timeIntervalSince1970: Double(startMs) / 1000)))
            }
            return .failure("请重新登录")
        }
        guard (200..<300).contains(status) else { return .failure("读取失败") }
        return .success(stamp(parse(data), at: Date(timeIntervalSince1970: Double(startMs) / 1000)))
    }

    private static func stamp(_ records: [RawRecord], at date: Date) -> [RawRecord] {
        records.map { record in
            var copy = record
            copy.at = date
            return copy
        }
    }

    private static func sessionCookie(database path: String) throws -> String {
        let database = try SQLiteDB.openReadonly(path)
        defer { database.close() }
        let rows = try database.query("SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1")
        guard let token = rows.first?.first?.text, !token.isEmpty else {
            throw CursorError("登录态无效")
        }
        if token.contains("::") { return token }
        guard let subject = jwtSubject(token) else { throw CursorError("登录态无效") }
        let user = subject.range(of: "user_").map { String(subject[$0.lowerBound...]) } ?? subject
        return "\(user)::\(token)"
    }
}

private struct CursorError: Error {
    var message: String
    init(_ message: String) { self.message = message }
}

enum CodexReader {
    static func load(directory: URL, start: Date, end: Date) async -> SourceResult {
        await Task.detached {
            loadSync(directory: directory, start: start, end: end)
        }.value
    }

    static func loadSync(directory: URL, start: Date, end: Date) -> SourceResult {
        let databasePath = newestStateDatabase(in: directory)
        guard let databasePath else { return .failure("未找到") }
        do {
            let database = try SQLiteDB.openReadonly(databasePath)
            defer { database.close() }
            let startMs = Int64(start.timeIntervalSince1970 * 1000)
            let rows = try database.query(
                "SELECT rollout_path, model FROM threads WHERE updated_at_ms >= ?",
                bind: [.int(startMs)]
            )
            var records: [RawRecord] = []
            for row in rows {
                let path = row[0].text
                guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { continue }
                records.append(contentsOf: recordsInRollout(path: path, fallbackModel: row[1].text, start: start, end: end))
            }
            return .success(records)
        } catch {
            return .failure("读取失败")
        }
    }

    static func recordsInRollout(path: String, fallbackModel: String, start: Date, end: Date) -> [RawRecord] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        var models: [String: String] = [:]
        var pending: [(turn: String, at: Date, parts: TokenBreakdown)] = []
        var buffer = Data()
        while true {
            let chunk = handle.readData(ofLength: 64 * 1024)
            if !chunk.isEmpty { buffer.append(chunk) }
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                consume(line, models: &models, pending: &pending)
            }
            if chunk.isEmpty {
                if !buffer.isEmpty { consume(buffer, models: &models, pending: &pending) }
                break
            }
        }
        let fallback = fallbackModel.isEmpty ? "unknown" : fallbackModel
        return pending.compactMap { item in
            guard item.at >= start, item.at <= end else { return nil }
            let model = models[item.turn].flatMap { $0.isEmpty ? nil : $0 } ?? fallback
            return RawRecord(model: model, parts: item.parts, exactCostUSD: nil, at: item.at)
        }
    }

    private static func consume(
        _ line: some Sequence<UInt8>,
        models: inout [String: String],
        pending: inout [(turn: String, at: Date, parts: TokenBreakdown)]
    ) {
        let data = Data(line)
        guard !data.isEmpty else { return }
        let text = String(decoding: data, as: UTF8.self)
        let isUsage = text.contains("\"token_usage_record\"")
        let isContext = text.contains("\"turn_context\"")
        guard isUsage || isContext else { return }
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = object["type"] as? String,
            let payload = object["payload"] as? [String: Any]
        else { return }
        let turn = payload["turn_id"] as? String ?? ""
        if type == "turn_context", let model = payload["model"] as? String {
            models[turn] = model
            return
        }
        guard type == "token_usage_record", let usage = payload["usage"] as? [String: Any] else { return }
        let parts = TokenBreakdown.accounting(
            input: jsonInt(usage["input_tokens"]),
            output: jsonInt(usage["output_tokens"]),
            cacheRead: jsonInt(usage["cached_input_tokens"]),
            cacheWrite: jsonInt(usage["cache_write_input_tokens"]),
            reportedTotal: optionalInt(usage["total_tokens"])
        )
        let stamp = (object["timestamp"] as? String).flatMap(parseTimestamp) ?? .distantPast
        pending.append((turn, stamp, parts))
    }

    private static func newestStateDatabase(in directory: URL) -> String? {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let matches = contents.compactMap { name -> (Int, String)? in
            guard name.hasPrefix("state_"), name.hasSuffix(".sqlite") else { return nil }
            let number = name.dropFirst("state_".count).dropLast(".sqlite".count)
            guard let value = Int(number) else { return nil }
            return (value, directory.appending(path: name).path)
        }
        return matches.max(by: { $0.0 < $1.0 })?.1
    }
}

enum ZCodeReader {
    static func load(database: URL, start: Date) async -> SourceResult {
        let path = database.path
        let startMs = Int64(start.timeIntervalSince1970 * 1000)
        return await Task.detached {
            guard FileManager.default.fileExists(atPath: path) else { return .failure("未找到") }
            do {
                let database = try SQLiteDB.openReadonly(path)
                defer { database.close() }
                let rows = try database.query(
                    """
                    SELECT model_id, input_tokens, output_tokens, cache_read_input_tokens,
                           cache_creation_input_tokens, computed_total_tokens, started_at
                    FROM model_usage
                    WHERE started_at >= ?
                    """,
                    bind: [.int(startMs)]
                )
                let records = rows.map { row -> RawRecord in
                    let stamp = row[6].int
                    let millis = stamp > 1_000_000_000_000 ? stamp : stamp * 1000
                    return RawRecord(
                        model: row[0].text.isEmpty ? "unknown" : row[0].text,
                        parts: TokenBreakdown.accounting(
                            input: row[1].int,
                            output: row[2].int,
                            cacheRead: row[3].int,
                            cacheWrite: row[4].int,
                            reportedTotal: row[5].int
                        ),
                        exactCostUSD: nil,
                        at: Date(timeIntervalSince1970: Double(millis) / 1000)
                    )
                }
                return .success(records)
            } catch {
                return .failure("读取失败")
            }
        }.value
    }
}

enum KimiReader {
    static func load(sessions: URL, start: Date, end: Date) async -> SourceResult {
        await Task.detached {
            loadSync(sessions: sessions, start: start, end: end)
        }.value
    }

    static func loadSync(sessions: URL, start: Date, end: Date) -> SourceResult {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sessions.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure("未找到")
        }
        guard let enumerator = FileManager.default.enumerator(at: sessions, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return .failure("读取失败")
        }
        var records: [RawRecord] = []
        for case let file as URL in enumerator {
            guard file.pathExtension == "jsonl" else { continue }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            guard modified >= start else { continue }
            records.append(contentsOf: recordsIn(file: file, start: start, end: end))
        }
        return .success(records)
    }

    static func recordsIn(file: URL, start: Date, end: Date) -> [RawRecord] {
        guard let handle = FileHandle(forReadingAtPath: file.path) else { return [] }
        defer { try? handle.close() }
        var records: [RawRecord] = []
        var buffer = Data()
        let startMs = start.timeIntervalSince1970 * 1000
        let endMs = end.timeIntervalSince1970 * 1000
        func consume(_ line: Data) {
            guard !line.isEmpty else { return }
            let text = String(decoding: line, as: UTF8.self)
            guard text.contains("usage.record") else { return }
            guard
                let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                object["type"] as? String == "usage.record"
            else { return }
            let time = (object["time"] as? NSNumber)?.doubleValue ?? 0
            guard time >= startMs, time <= endMs else { return }
            let usage = object["usage"] as? [String: Any] ?? [:]
            let model = (object["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
            let parts = TokenBreakdown.accounting(
                input: jsonInt(usage["inputOther"]),
                output: jsonInt(usage["output"]),
                cacheRead: jsonInt(usage["inputCacheRead"]),
                cacheWrite: jsonInt(usage["inputCacheCreation"])
            )
            records.append(RawRecord(
                model: model,
                parts: parts,
                exactCostUSD: nil,
                at: Date(timeIntervalSince1970: time / 1000)
            ))
        }
        while true {
            let chunk = handle.readData(ofLength: 64 * 1024)
            if !chunk.isEmpty { buffer.append(chunk) }
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                consume(line)
            }
            if chunk.isEmpty {
                if !buffer.isEmpty { consume(buffer) }
                break
            }
        }
        return records
    }
}

func jsonInt(_ value: Any?) -> Int {
    optionalInt(value) ?? 0
}

func optionalInt(_ value: Any?) -> Int? {
    switch value {
    case let number as NSNumber:
        return number.intValue
    case let text as String:
        return Int(text)
    default:
        return nil
    }
}

func jsonCents(_ value: Any?) -> Decimal? {
    switch value {
    case let number as NSNumber:
        return Decimal(string: number.stringValue)
    case let text as String:
        return Decimal(string: text)
    default:
        return nil
    }
}

private func jwtSubject(_ jwt: String) -> String? {
    let parts = jwt.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    var body = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    body += String(repeating: "=", count: (4 - body.count % 4) % 4)
    guard
        let data = Data(base64Encoded: body),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let subject = object["sub"] as? String,
        !subject.isEmpty
    else { return nil }
    return subject
}

private func parseTimestamp(_ text: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: text) { return date }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: text)
}

