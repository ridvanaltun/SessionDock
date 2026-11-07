import Foundation

/// Pages through a Claude Code transcript without loading it into memory.
///
/// Pages are addressed by message index (the same grouping the index uses). Byte checkpoints
/// are cached every `checkpointStride` messages, so reading page N does not require re-reading
/// the whole file from the start. Checkpoints are valid while the file only grows, which is how
/// Claude Code writes transcripts.
public actor ClaudeCodeParser: SessionParser {
    private struct Checkpoint: Hashable, Sendable {
        var messageIndex: Int
        var byteOffset: UInt64
    }

    private struct CheckpointSet {
        var fileSize: Int64
        var points: [Checkpoint]
    }

    private static let checkpointStride = 200
    private static let maxIssuesPerPage = 50

    private var checkpoints: [String: CheckpointSet] = [:]

    public init() {}

    public func page(for session: SessionSummary, offset: Int, limit: Int) async throws -> MessagePage {
        guard let sourcePath = session.sourcePath else {
            return MessagePage(messages: [], nextOffset: nil)
        }
        let url = URL(fileURLWithPath: sourcePath)
        guard let stat = FileFingerprinting.fileStat(of: url) else {
            return MessagePage(messages: [], nextOffset: nil, issues: [
                SourceIssue(kind: "missing-source", detail: "Transcript no longer exists at \(sourcePath).")
            ])
        }

        var known = checkpoints[sourcePath].flatMap { $0.fileSize <= stat.size ? $0.points : nil }
            ?? [Checkpoint(messageIndex: 0, byteOffset: 0)]
        let start = known.last(where: { $0.messageIndex <= offset }) ?? Checkpoint(messageIndex: 0, byteOffset: 0)

        var builder = PageBuilder(
            sessionId: session.id,
            windowStart: offset,
            windowEnd: offset + limit,
            index: start.messageIndex - 1
        )
        try JSONLReader.forEachCompleteLine(in: url, from: start.byteOffset) { line in
            try Task.checkCancellation()
            guard !line.bytes.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) else { return true }
            let record: JSONValue
            do {
                record = try JSONValue.parse(line.bytes)
            } catch {
                builder.noteIssue(
                    SourceIssue(
                        kind: "malformed-jsonl",
                        detail: "Record could not be decoded and is shown as an unparsed line.",
                        byteOffset: line.startOffset,
                        rawPreview: String(decoding: line.bytes.prefix(160), as: UTF8.self)
                    ),
                    limit: Self.maxIssuesPerPage
                )
                return true
            }
            guard let fragment = ClaudeCodeRecordMapper.fragment(from: record) else { return true }
            let startsNewMessage = builder.absorb(fragment, lineOffset: line.startOffset)
            if startsNewMessage, builder.index >= builder.windowEnd {
                return false
            }
            if startsNewMessage, builder.index % Self.checkpointStride == 0, builder.index > 0 {
                let point = Checkpoint(messageIndex: builder.index, byteOffset: line.startOffset)
                if !known.contains(where: { $0.messageIndex == point.messageIndex }) {
                    known.append(point)
                }
            }
            return true
        }

        let previous = checkpoints[sourcePath]?.points ?? []
        let merged = Array(Set(previous + known)).sorted { $0.messageIndex < $1.messageIndex }
        checkpoints[sourcePath] = CheckpointSet(fileSize: stat.size, points: merged)

        return builder.finish()
    }

    /// Accumulates grouped messages for one page while streaming records.
    private struct PageBuilder {
        let sessionId: String
        let windowStart: Int
        let windowEnd: Int
        private(set) var index: Int
        private var open: Pending?
        private var lastKey: String?
        private var messages: [Message] = []
        private var issues: [SourceIssue] = []
        private var reachedEnd = true

        struct Pending {
            var index: Int
            var role: MessageRole
            var timestamp: Date?
            var model: String?
            var parts: [ContentPart]
            var metadata: [String: JSONValue]
            var recordIds: [JSONValue]
        }

        init(sessionId: String, windowStart: Int, windowEnd: Int, index: Int) {
            self.sessionId = sessionId
            self.windowStart = windowStart
            self.windowEnd = windowEnd
            self.index = index
        }

        /// Returns true when the fragment started a new message.
        mutating func absorb(_ fragment: ClaudeCodeFragment, lineOffset: UInt64) -> Bool {
            let continues = fragment.groupKey != nil && fragment.groupKey == lastKey && open != nil
            lastKey = fragment.groupKey
            if continues, var pending = open {
                pending.parts.append(contentsOf: fragment.parts)
                if let uuid = fragment.uuid { pending.recordIds.append(.string(uuid)) }
                if pending.model == nil { pending.model = fragment.model }
                open = pending
                return false
            }

            flushOpen()
            index += 1
            if index >= windowEnd {
                reachedEnd = false
                open = nil
                return true
            }
            var recordIds: [JSONValue] = []
            if let uuid = fragment.uuid { recordIds.append(.string(uuid)) }
            open = Pending(
                index: index,
                role: fragment.role,
                timestamp: fragment.timestamp,
                model: fragment.model,
                parts: fragment.parts,
                metadata: fragment.metadata.merging(["byteOffset": .number(Double(lineOffset))]) { current, _ in current },
                recordIds: recordIds
            )
            return true
        }

        mutating func noteIssue(_ issue: SourceIssue, limit: Int) {
            guard issues.count < limit, index + 1 >= windowStart, index + 1 <= windowEnd else { return }
            issues.append(issue)
        }

        private mutating func flushOpen() {
            guard let pending = open else { return }
            open = nil
            guard pending.index >= windowStart, pending.index < windowEnd else { return }
            var metadata = pending.metadata
            metadata["recordIds"] = .array(pending.recordIds)
            messages.append(Message(
                id: "\(sessionId):\(pending.index)",
                sessionId: sessionId,
                ordinal: pending.index,
                role: pending.role,
                timestamp: pending.timestamp,
                model: pending.model,
                contentParts: pending.parts,
                metadata: metadata
            ))
        }

        mutating func finish() -> MessagePage {
            flushOpen()
            let next: Int? = reachedEnd ? nil : windowEnd
            return MessagePage(messages: messages, nextOffset: next, issues: issues)
        }
    }
}

/// Reads and writes per-session source fingerprints for Claude Code transcripts.
public struct ClaudeCodeStorage: SessionStorage {
    public init() {}

    public func fingerprint(for session: SessionSummary) throws -> FileFingerprint? {
        guard let path = session.sourcePath else { return nil }
        return try FileFingerprinting.fingerprint(of: URL(fileURLWithPath: path))
    }
}
