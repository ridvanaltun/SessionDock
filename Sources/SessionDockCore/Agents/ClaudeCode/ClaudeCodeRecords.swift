import Foundation

/// Interprets Claude Code JSONL records. Claude Code writes one record per content block, so
/// consecutive assistant records that share `message.id` form one logical message. Both the
/// index counters and the inspector use `ClaudeCodeGrouping` so their numbers always agree.
enum ClaudeCodeRecordType {
    static let conversation: Set<String> = ["user", "assistant", "system", "attachment"]
}

/// Running statistics for one transcript. Stored in `SourceScanState.stateJSON`, so it must be
/// Codable and must only hold values that can be recomputed by resuming at `offset`.
struct ClaudeCodeScanState: Codable, Hashable, Sendable {
    var cwd: String?
    var sessionId: String?
    var version: String?
    var gitBranch: String?
    var firstTimestamp: Date?
    var lastTimestamp: Date?
    var customTitle: String?
    var agentName: String?
    var agentType: String?
    var firstUserText: String?
    var model: String?
    var messageGroups: Int = 0
    var toolCalls: Int = 0
    /// User records that carry text, including injected isMeta records.
    var userPromptCount: Int = 0
    var lastGroupKey: String?
    var recordTypeCounts: [String: Int] = [:]
    var malformedLines: Int = 0
    var blankLines: Int = 0
    var malformedSamples: [SourceIssue] = []
    var excerpt: String = ""
    var excerptParts: Int = 0

    static let excerptPartLimit = 12
    static let excerptPartCharacters = 1_000

    mutating func absorb(_ record: JSONValue) {
        let type = record["type"]?.stringValue ?? "unknown"
        recordTypeCounts[type, default: 0] += 1

        if cwd == nil, let value = record["cwd"]?.stringValue, !value.isEmpty { cwd = value }
        if sessionId == nil, let value = record["sessionId"]?.stringValue { sessionId = value }
        if version == nil, let value = record["version"]?.stringValue { version = value }
        if gitBranch == nil, let value = record["gitBranch"]?.stringValue { gitBranch = value }
        if let timestamp = record["timestamp"]?.stringValue.flatMap(TimestampParser.parse) {
            if firstTimestamp == nil { firstTimestamp = timestamp }
            lastTimestamp = timestamp
        }

        switch type {
        case "custom-title":
            if let title = record["customTitle"]?.stringValue, !title.isEmpty { customTitle = title }
        case "agent-name":
            if let name = record["agentName"]?.stringValue, !name.isEmpty { agentName = name }
        default:
            break
        }

        guard ClaudeCodeRecordType.conversation.contains(type) else { return }
        let key = ClaudeCodeRecordMapper.groupKey(for: record)
        if key == nil || key != lastGroupKey {
            messageGroups += 1
        }
        lastGroupKey = key

        if type == "assistant" {
            toolCalls += ClaudeCodeRecordMapper.toolUseCount(record)
            if model == nil, let value = record["message"]?["model"]?.stringValue, value != "<synthetic>" {
                model = value
            }
        }
        if type == "user", ClaudeCodeRecordMapper.hasUserText(record) {
            // Counts isMeta records too, because they are written to OpenCode as user messages.
            userPromptCount += 1
        }
        if type == "user", firstUserText == nil, record["isMeta"]?.boolValue != true {
            firstUserText = ClaudeCodeRecordMapper.plainUserText(record)
        }
        if excerptParts < Self.excerptPartLimit, type == "user" || type == "assistant" {
            for text in ClaudeCodeRecordMapper.textBlocks(record) where excerptParts < Self.excerptPartLimit {
                excerpt += String(text.prefix(Self.excerptPartCharacters)) + "\n"
                excerptParts += 1
            }
        }
    }

    mutating func noteMalformed() { malformedLines += 1 }
    mutating func noteBlank() { blankLines += 1 }

    var resolvedTitle: String? {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        if let agentName, !agentName.isEmpty { return agentName }
        if let firstUserText, !firstUserText.isEmpty { return firstUserText.previewLine(limit: 120) }
        return nil
    }
}

/// Converts a single conversation record to a message fragment.
struct ClaudeCodeFragment: Sendable {
    var groupKey: String?
    var role: MessageRole
    var timestamp: Date?
    var model: String?
    var parts: [ContentPart]
    var metadata: [String: JSONValue]
    var uuid: String?
}

enum ClaudeCodeRecordMapper {
    static func groupKey(for record: JSONValue) -> String? {
        guard record["type"]?.stringValue == "assistant" else { return nil }
        return record["message"]?["id"]?.stringValue ?? record["requestId"]?.stringValue
    }

    static func toolUseCount(_ record: JSONValue) -> Int {
        guard let blocks = record["message"]?["content"]?.arrayValue else { return 0 }
        return blocks.filter { $0["type"]?.stringValue == "tool_use" }.count
    }

    static func hasUserText(_ record: JSONValue) -> Bool {
        guard let content = record["message"]?["content"] else { return false }
        if let text = content.stringValue { return !text.isEmpty }
        return (content.arrayValue ?? []).contains { $0["type"]?.stringValue == "text" }
    }

    static func textBlocks(_ record: JSONValue) -> [String] {
        guard record["isMeta"]?.boolValue != true else { return [] }
        guard let content = record["message"]?["content"] else { return [] }
        if let text = content.stringValue { return [text] }
        return (content.arrayValue ?? []).compactMap { block in
            guard block["type"]?.stringValue == "text" else { return nil }
            return block["text"]?.stringValue
        }
    }

    static func plainUserText(_ record: JSONValue) -> String? {
        guard let content = record["message"]?["content"] else { return nil }
        if let text = content.stringValue { return text }
        guard let blocks = content.arrayValue else { return nil }
        let texts = blocks.compactMap { block -> String? in
            guard block["type"]?.stringValue == "text" else { return nil }
            return block["text"]?.stringValue
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    static func fragment(from record: JSONValue) -> ClaudeCodeFragment? {
        let type = record["type"]?.stringValue ?? ""
        guard ClaudeCodeRecordType.conversation.contains(type) else { return nil }

        var metadata = baseMetadata(record)
        var model: String?
        var parts: [ContentPart] = []
        var role: MessageRole

        switch type {
        case "user":
            role = .user
            if record["isMeta"]?.boolValue == true { metadata["isMeta"] = .bool(true) }
            parts = userParts(record["message"]?["content"])
        case "assistant":
            role = .assistant
            let message = record["message"]
            model = message?["model"]?.stringValue
            if let usage = message?["usage"] { metadata["usage"] = usage }
            if let messageId = message?["id"] { metadata["messageId"] = messageId }
            parts = assistantParts(message?["content"])
        case "system":
            role = .system
            if let subtype = record["subtype"] { metadata["subtype"] = subtype }
            if let text = record["content"]?.stringValue {
                parts = [.text(text)]
            } else if let text = record["message"]?["content"]?.stringValue {
                parts = [.text(text)]
            }
            if parts.isEmpty { parts = [.unknown(kind: "system", raw: record)] }
        case "attachment":
            role = .system
            let attachment = record["attachment"] ?? .null
            let kind = attachment["type"]?.stringValue ?? "unknown"
            parts = [.unknown(kind: "attachment:\(kind)", raw: attachment)]
        default:
            return nil
        }

        return ClaudeCodeFragment(
            groupKey: groupKey(for: record),
            role: role,
            timestamp: record["timestamp"]?.stringValue.flatMap(TimestampParser.parse),
            model: model,
            parts: parts,
            metadata: metadata,
            uuid: record["uuid"]?.stringValue
        )
    }

    /// Keeps every top-level field except the message body, which is represented by `parts`.
    /// Nothing is dropped: the raw record can be shown in the inspector.
    private static func baseMetadata(_ record: JSONValue) -> [String: JSONValue] {
        var metadata: [String: JSONValue] = [:]
        for (key, value) in record.objectValue ?? [:] where key != "message" {
            metadata[key] = value
        }
        return metadata
    }

    private static func userParts(_ content: JSONValue?) -> [ContentPart] {
        guard let content else { return [] }
        if let text = content.stringValue { return [.text(text)] }
        guard let blocks = content.arrayValue else { return [.unknown(kind: "user-content", raw: content)] }
        return blocks.map { block -> ContentPart in
            switch block["type"]?.stringValue {
            case "text":
                return .text(block["text"]?.stringValue ?? "")
            case "tool_result":
                return .toolResult(ToolResult(
                    callId: block["tool_use_id"]?.stringValue,
                    output: flattenToolResult(block["content"]),
                    isError: block["is_error"]?.boolValue ?? false,
                    raw: block
                ))
            case let kind:
                return .unknown(kind: kind ?? "unknown", raw: block)
            }
        }
    }

    private static func assistantParts(_ content: JSONValue?) -> [ContentPart] {
        guard let content else { return [] }
        if let text = content.stringValue { return [.text(text)] }
        guard let blocks = content.arrayValue else { return [.unknown(kind: "assistant-content", raw: content)] }
        return blocks.map { block -> ContentPart in
            switch block["type"]?.stringValue {
            case "text":
                return .text(block["text"]?.stringValue ?? "")
            case "thinking":
                return .reasoning(block["thinking"]?.stringValue ?? "")
            case "tool_use":
                return .toolCall(ToolCall(
                    id: block["id"]?.stringValue,
                    name: block["name"]?.stringValue ?? "unknown",
                    input: block["input"] ?? .object([:])
                ))
            case let kind:
                return .unknown(kind: kind ?? "unknown", raw: block)
            }
        }
    }

    static func flattenToolResult(_ content: JSONValue?) -> String {
        guard let content else { return "" }
        if let text = content.stringValue { return text }
        guard let blocks = content.arrayValue else { return content.compactText }
        return blocks.map { block -> String in
            switch block["type"]?.stringValue {
            case "text": return block["text"]?.stringValue ?? ""
            case "image": return "[image]"
            default: return block.compactText
            }
        }.joined(separator: "\n")
    }
}
