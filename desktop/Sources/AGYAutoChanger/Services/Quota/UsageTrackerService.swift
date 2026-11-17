import Foundation
import SQLite3

// MARK: - Usage Aggregation Snapshot

public struct ModelUsageSummary: Sendable, Equatable {
    public var turnsByModel: [String: Int]
    public var tokensByModel: [String: Int]
    public var lastUsedByModel: [String: Date]
    public var latestModelDisplayName: String?
    public var latestModelTimestamp: Date?

    public init(
        turnsByModel: [String: Int] = [:],
        tokensByModel: [String: Int] = [:],
        lastUsedByModel: [String: Date] = [:],
        latestModelDisplayName: String? = nil,
        latestModelTimestamp: Date? = nil
    ) {
        self.turnsByModel = turnsByModel
        self.tokensByModel = tokensByModel
        self.lastUsedByModel = lastUsedByModel
        self.latestModelDisplayName = latestModelDisplayName
        self.latestModelTimestamp = latestModelTimestamp
    }
}

// MARK: - Protobuf Wire Reader (adapted from adahime/agy-hud)

private enum ProtoWireField {
    case varint(UInt64)
    case lengthDelimited(Data)
    case fixed64
    case fixed32
}

private enum ProtobufWireScanner {

    static func readVarint(in data: Data, pos: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while pos < data.count {
            let byte = data[pos]
            pos += 1
            result |= UInt64(byte & 0x7F) << shift
            if (byte & 0x80) == 0 {
                return result
            }
            shift += 7
            if shift >= 64 { return nil }
        }
        return nil
    }

    static func parseFields(in data: Data) -> [(fieldNumber: Int, value: ProtoWireField)] {
        var fields: [(Int, ProtoWireField)] = []
        var pos = 0
        let count = data.count
        while pos < count {
            guard let key = readVarint(in: data, pos: &pos) else { break }
            let fieldNumber = Int(key >> 3)
            let wireType = Int(key & 0x07)

            switch wireType {
            case 0:
                guard let val = readVarint(in: data, pos: &pos) else { return fields }
                fields.append((fieldNumber, .varint(val)))
            case 2:
                guard let lenVal = readVarint(in: data, pos: &pos) else { return fields }
                let len = Int(lenVal)
                guard len >= 0, pos + len <= count else { return fields }
                let slice = data.subdata(in: pos..<(pos + len))
                pos += len
                fields.append((fieldNumber, .lengthDelimited(slice)))
            case 1:
                guard pos + 8 <= count else { return fields }
                pos += 8
                fields.append((fieldNumber, .fixed64))
            case 5:
                guard pos + 4 <= count else { return fields }
                pos += 4
                fields.append((fieldNumber, .fixed32))
            default:
                return fields
            }
        }
        return fields
    }

    static func decodeTimestampSeconds(from data: Data) -> TimeInterval? {
        for (fieldNum, value) in parseFields(in: data) {
            if fieldNum == 1, case .varint(let sec) = value, sec > 1_000_000_000 {
                return TimeInterval(sec)
            }
        }
        return nil
    }

    static func decodeStepTimestamp(from stepMetaBlob: Data) -> Date? {
        var preferredSec: TimeInterval?
        for (fieldNum, value) in parseFields(in: stepMetaBlob) where (fieldNum == 1 || fieldNum == 6) {
            if case .lengthDelimited(let tsBlob) = value, let sec = decodeTimestampSeconds(from: tsBlob) {
                if fieldNum == 6 || preferredSec == nil {
                    preferredSec = sec
                }
            }
        }
        return preferredSec.map { Date(timeIntervalSince1970: $0) }
    }

    static func decodeKeyValueEntry(from data: Data) -> (key: String, value: String)? {
        var key: String?
        var value: String?
        for (fieldNum, fieldVal) in parseFields(in: data) {
            guard case .lengthDelimited(let raw) = fieldVal,
                  let text = String(data: raw, encoding: .utf8) else {
                continue
            }
            if fieldNum == 1 {
                key = text
            } else if fieldNum == 2 {
                value = text
            }
        }
        guard let key, let value else { return nil }
        return (key, value)
    }

    static func decodeGenerationRecord(genBlob: Data) -> (
        bucketIDs: [String],
        modelDisplayName: String?,
        tokens: Int,
        referencedStepIndex: Int?,
        directTimestamp: Date?
    )? {
        guard let inner = parseFields(in: genBlob).first(where: {
            if case .lengthDelimited = $0.value, $0.fieldNumber == 1 { return true }
            return false
        }).flatMap({ field -> Data? in
            if case .lengthDelimited(let d) = field.value { return d }
            return nil
        }) else {
            return nil
        }

        var routedModelID: String?
        var displayName: String?
        var usageData: Data?
        var legacyUsageData: Data?
        var referencedStepIndex: Int?
        var directTimestamp: Date?

        for (fieldNum, value) in parseFields(in: inner) {
            guard case .lengthDelimited(let raw) = value else { continue }
            switch fieldNum {
            case 19:
                routedModelID = String(data: raw, encoding: .utf8)
            case 21:
                displayName = String(data: raw, encoding: .utf8)
            case 4:
                usageData = raw
            case 17:
                for (subNum, subVal) in parseFields(in: raw) where subNum == 2 {
                    if case .lengthDelimited(let nested) = subVal {
                        legacyUsageData = nested
                    }
                }
            case 20:
                if let kv = decodeKeyValueEntry(from: raw),
                   kv.key == "last_step_index",
                   let parsedIdx = Int(kv.value) {
                    referencedStepIndex = parsedIdx
                } else if let sec = decodeTimestampSeconds(from: raw) {
                    directTimestamp = Date(timeIntervalSince1970: sec)
                }
            default:
                break
            }
        }

        let mappedBuckets = ModelUsage.canonicalBucketIDs(modelID: routedModelID, displayName: displayName)
        let bucketIDs = mappedBuckets.isEmpty ? ["gemini-5h", "gemini-weekly"] : mappedBuckets
        let cleanDisplay = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelDisplayName = (cleanDisplay?.isEmpty == false) ? cleanDisplay : routedModelID
        let tokens = parseTokenSum(from: usageData ?? legacyUsageData)
        return (bucketIDs, modelDisplayName, tokens, referencedStepIndex, directTimestamp)
    }

    private static func parseTokenSum(from data: Data?) -> Int {
        guard let data else { return 0 }
        var inputTokens = 0
        var outputTokens = 0
        var fallbackOut = 0
        var thinkingTokens = 0
        var visibleTokens = 0

        for (fieldNum, value) in parseFields(in: data) {
            guard case .varint(let rawVal) = value else { continue }
            let count = Int(min(rawVal, UInt64(Int.max)))
            switch fieldNum {
            case 1: fallbackOut = count
            case 2: inputTokens = count
            case 3: outputTokens = count
            case 9: thinkingTokens = count
            case 10: visibleTokens = count
            default: break
            }
        }

        let resolvedOutput = outputTokens > 0 ? outputTokens : (fallbackOut > 0 ? fallbackOut : (thinkingTokens + visibleTokens))
        return max(0, inputTokens + resolvedOutput)
    }
}

// MARK: - Usage Tracker Service

/// Reads Antigravity telemetry strictly read-only from SQLite+WAL conversation DBs (adapted from `agy-hud`)
/// and falls back to `transcript.jsonl`, preserving per-account Dashboard quotas across switches.
public final class UsageTrackerService: Sendable {

    private struct TranscriptStep: Decodable {
        let type: String?
        let created_at: String?
        let content: String?
    }

    public init() {}

    /// Computes turn and token counts per model ID (`argon`, `pro`, `flash`, `claude`) inside the rolling window.
    public func scanUsage(
        brainDir: URL = AppConfig.agyBrainDir,
        conversationsDir: URL = AppConfig.agyConversationsDir,
        rollingWindowHours: Double = AppConfig.defaultRollingWindowHours,
        sinceAccountSwitch: Date? = nil,
        referenceDate: Date = Date()
    ) -> ModelUsageSummary {
        let windowStart = referenceDate.addingTimeInterval(-max(0.01, rollingWindowHours) * 3600.0)
        let effectiveCutoff: Date
        if let sinceAccountSwitch,
           sinceAccountSwitch.timeIntervalSinceReferenceDate > windowStart.timeIntervalSinceReferenceDate {
            effectiveCutoff = sinceAccountSwitch
        } else {
            effectiveCutoff = windowStart
        }

        var summary = ModelUsageSummary()
        let coveredConversationIDs = scanConversationDatabases(
            in: conversationsDir,
            cutoff: effectiveCutoff,
            into: &summary
        )

        scanTranscriptLogs(
            in: brainDir,
            cutoff: effectiveCutoff,
            excludingConversationIDs: coveredConversationIDs,
            into: &summary
        )

        return summary
    }

    /// Replaces local turn counts from a full-window scan while preserving Dashboard quotas and cooldowns.
    public func merge(summary: ModelUsageSummary, into existing: [ModelUsage], tier: AccountTier) -> [ModelUsage] {
        var base = ModelUsage.defaultSet(for: tier)
        for index in base.indices {
            let modelID = base[index].id
            let prior = existing.first(where: { $0.id == modelID })
            let scannedTurns = summary.turnsByModel[modelID] ?? 0
            let scannedTokens = summary.tokensByModel[modelID]
            let scannedLastUsed = summary.lastUsedByModel[modelID]

            base[index].turnsUsed = scannedTurns
            base[index].tokensUsed = scannedTokens ?? prior?.tokensUsed
            base[index].lastUsedAt = scannedLastUsed ?? prior?.lastUsedAt
            base[index].cooldownUntil = prior?.cooldownUntil
            base[index].quotaRemainingFraction = prior?.quotaRemainingFraction
            base[index].quotaResetAt = prior?.quotaResetAt
            base[index].quotaSyncedAt = prior?.quotaSyncedAt
        }
        return base
    }

    /// Incrementally adds newly observed turns & tokens without wiping existing per-account progress on switch.
    public func mergeIncremental(summary: ModelUsageSummary, into existing: [ModelUsage], tier: AccountTier) -> [ModelUsage] {
        var base = ModelUsage.defaultSet(for: tier)
        for index in base.indices {
            let modelID = base[index].id
            let prior = existing.first(where: { $0.id == modelID })
            let deltaTurns = summary.turnsByModel[modelID] ?? 0
            let deltaTokens = summary.tokensByModel[modelID] ?? 0
            let scannedLastUsed = summary.lastUsedByModel[modelID]

            base[index].turnsUsed = (prior?.turnsUsed ?? 0) + deltaTurns
            if deltaTokens > 0 || prior?.tokensUsed != nil {
                base[index].tokensUsed = (prior?.tokensUsed ?? 0) + deltaTokens
            }
            if let scannedLastUsed, let priorDate = prior?.lastUsedAt {
                base[index].lastUsedAt = scannedLastUsed.timeIntervalSinceReferenceDate > priorDate.timeIntervalSinceReferenceDate
                    ? scannedLastUsed
                    : priorDate
            } else {
                base[index].lastUsedAt = scannedLastUsed ?? prior?.lastUsedAt
            }
            base[index].cooldownUntil = prior?.cooldownUntil
            base[index].quotaRemainingFraction = prior?.quotaRemainingFraction
            base[index].quotaResetAt = prior?.quotaResetAt
            base[index].quotaSyncedAt = prior?.quotaSyncedAt
        }
        return base
    }

    // MARK: - SQLite + WAL Protobuf Scanner (agy-hud style)

    private func scanConversationDatabases(
        in conversationsDir: URL,
        cutoff: Date,
        into summary: inout ModelUsageSummary
    ) -> Set<String> {
        let fm = FileManager.default
        guard fm.fileExists(atPath: conversationsDir.path),
              let files = try? fm.contentsOfDirectory(
                at: conversationsDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        var coveredIDs: Set<String> = []
        for fileURL in files where fileURL.pathExtension == "db" {
            let convID = fileURL.deletingPathExtension().lastPathComponent
            let mtime = walAwareModificationDate(for: fileURL)
            if let mtime,
               mtime.timeIntervalSinceReferenceDate < cutoff.timeIntervalSinceReferenceDate {
                continue
            }

            if parseConversationDatabase(at: fileURL, cutoff: cutoff, into: &summary) {
                coveredIDs.insert(convID)
            }
        }
        return coveredIDs
    }

    private func walAwareModificationDate(for dbURL: URL) -> Date? {
        let fm = FileManager.default
        var latest = (try? fm.attributesOfItem(atPath: dbURL.path)[.modificationDate] as? Date)
        let walURL = URL(fileURLWithPath: dbURL.path + "-wal")
        if let walDate = try? fm.attributesOfItem(atPath: walURL.path)[.modificationDate] as? Date {
            if let existing = latest {
                if walDate.timeIntervalSinceReferenceDate > existing.timeIntervalSinceReferenceDate {
                    latest = walDate
                }
            } else {
                latest = walDate
            }
        }
        return latest
    }

    private func parseConversationDatabase(
        at dbURL: URL,
        cutoff: Date,
        into summary: inout ModelUsageSummary
    ) -> Bool {
        var db: OpaquePointer?
        let uriString = "\(dbURL.absoluteString)?mode=ro"
        guard sqlite3_open_v2(uriString, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let db else {
            if let db { sqlite3_close(db) }
            return false
        }
        defer { sqlite3_close(db) }

        sqlite3_busy_timeout(db, 1000)

        var stepTimestamps: [Int: Date] = [:]
        var stepStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT idx, metadata FROM steps WHERE metadata IS NOT NULL;", -1, &stepStmt, nil) == SQLITE_OK,
           let stepStmt {
            defer { sqlite3_finalize(stepStmt) }
            while sqlite3_step(stepStmt) == SQLITE_ROW {
                let stepIdx = Int(sqlite3_column_int64(stepStmt, 0))
                guard let stepBytes = sqlite3_column_blob(stepStmt, 1) else { continue }
                let stepLen = Int(sqlite3_column_bytes(stepStmt, 1))
                guard stepLen > 0 else { continue }
                let stepMetaData = Data(bytes: stepBytes, count: stepLen)
                if let date = ProtobufWireScanner.decodeStepTimestamp(from: stepMetaData) {
                    stepTimestamps[stepIdx] = date
                }
            }
        }

        let genSQL = "SELECT idx, data FROM gen_metadata ORDER BY idx ASC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, genSQL, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return false
        }
        defer { sqlite3_finalize(stmt) }

        var parsedAnyRow = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            let genIdx = Int(sqlite3_column_int64(stmt, 0))
            guard let genBytes = sqlite3_column_blob(stmt, 1) else { continue }
            let genLen = Int(sqlite3_column_bytes(stmt, 1))
            guard genLen > 0 else { continue }
            let genData = Data(bytes: genBytes, count: genLen)

            guard let record = ProtobufWireScanner.decodeGenerationRecord(genBlob: genData) else {
                continue
            }

            parsedAnyRow = true
            let resolvedDate = record.directTimestamp
                ?? record.referencedStepIndex.flatMap { stepTimestamps[$0] }
                ?? stepTimestamps[genIdx]

            guard let stepDate = resolvedDate,
                  stepDate.timeIntervalSinceReferenceDate >= cutoff.timeIntervalSinceReferenceDate else {
                continue
            }

            for bucketID in record.bucketIDs {
                summary.turnsByModel[bucketID, default: 0] += 1
                if record.tokens > 0 {
                    summary.tokensByModel[bucketID, default: 0] += record.tokens
                }
                recordLastUsed(stepDate, for: bucketID, into: &summary)
            }

            if let modelDisplay = record.modelDisplayName {
                if let prevTS = summary.latestModelTimestamp {
                    if stepDate.timeIntervalSinceReferenceDate >= prevTS.timeIntervalSinceReferenceDate {
                        summary.latestModelTimestamp = stepDate
                        summary.latestModelDisplayName = modelDisplay
                    }
                } else {
                    summary.latestModelTimestamp = stepDate
                    summary.latestModelDisplayName = modelDisplay
                }
            }
        }

        return parsedAnyRow
    }

    // MARK: - Transcript JSONL Fallback

    private func scanTranscriptLogs(
        in brainDir: URL,
        cutoff: Date,
        excludingConversationIDs: Set<String>,
        into summary: inout ModelUsageSummary
    ) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: brainDir.path),
              let conversationDirs = try? fm.contentsOfDirectory(
                at: brainDir,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else {
            return
        }

        for dir in conversationDirs {
            let convID = dir.lastPathComponent
            if excludingConversationIDs.contains(convID) {
                continue
            }

            let logURL = dir
                .appendingPathComponent(".system_generated", isDirectory: true)
                .appendingPathComponent("logs", isDirectory: true)
                .appendingPathComponent("transcript.jsonl", isDirectory: false)

            guard fm.fileExists(atPath: logURL.path) else { continue }

            if let attrs = try? fm.attributesOfItem(atPath: logURL.path),
               let modDate = attrs[.modificationDate] as? Date,
               modDate.timeIntervalSinceReferenceDate < cutoff.timeIntervalSinceReferenceDate {
                continue
            }

            parseTranscriptFile(at: logURL, cutoff: cutoff, into: &summary)
        }
    }

    private func parseTranscriptFile(at url: URL, cutoff: Date, into summary: inout ModelUsageSummary) {
        guard let rawContent = try? String(contentsOf: url, encoding: .utf8) else {
            return
        }

        var currentModelID = "gemini-5h"
        let decoder = JSONDecoder()

        for rawLine in rawContent.split(whereSeparator: \.isNewline) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let lineData = trimmed.data(using: .utf8),
                  let step = try? decoder.decode(TranscriptStep.self, from: lineData) else {
                continue
            }

            if let content = step.content, let detected = detectModelChange(in: content) {
                currentModelID = detected
            }

            guard step.type == "PLANNER_RESPONSE",
                  let timestampString = step.created_at,
                  let stepDate = Self.parseISO8601(timestampString),
                  stepDate.timeIntervalSinceReferenceDate >= cutoff.timeIntervalSinceReferenceDate else {
                continue
            }

            let buckets = ModelUsage.canonicalBucketIDs(modelID: currentModelID)
            for bucketID in (buckets.isEmpty ? ["gemini-5h", "gemini-weekly"] : buckets) {
                summary.turnsByModel[bucketID, default: 0] += 1
                recordLastUsed(stepDate, for: bucketID, into: &summary)
            }
        }
    }

    private func recordLastUsed(_ date: Date, for modelID: String, into summary: inout ModelUsageSummary) {
        if let existingDate = summary.lastUsedByModel[modelID] {
            if date.timeIntervalSinceReferenceDate > existingDate.timeIntervalSinceReferenceDate {
                summary.lastUsedByModel[modelID] = date
            }
        } else {
            summary.lastUsedByModel[modelID] = date
        }
    }

    /// Detects `<USER_SETTINGS_CHANGE>` model updates in transcript steps.
    public func detectModelChange(in content: String) -> String? {
        guard content.contains("Model Selection") || content.contains("<USER_SETTINGS_CHANGE>") else {
            return nil
        }

        let lower = content.lowercased()
        if lower.contains("argon") || lower.contains("orchestrator") {
            return "argon-weekly"
        }
        if lower.contains("claude") || lower.contains("sonnet") || lower.contains("opus") || lower.contains("gpt") {
            return "3p-5h"
        }
        if lower.contains("hydrogen") || lower.contains("flash") || lower.contains("pro") || lower.contains("gemini") {
            return "gemini-5h"
        }
        return nil
    }

    public static func parseISO8601(_ raw: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = withFractional.date(from: raw) {
            return parsed
        }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: raw)
    }
}
