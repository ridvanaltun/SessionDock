import Foundation

/// Maps OpenCode message rows to the normalised `Message` model. Unknown shapes become
/// `ContentPart.unknown` with the raw JSON, so nothing is lost when OpenCode changes its format.
enum OpenCodeMessageMapper {
    static func v2Message(
        id: String,
        sessionId: String,
        ordinal: Int,
        type: String,
        timestamp: Date?,
        data: JSONValue
    ) -> Message {
        var metadata = data.objectValue ?? [:]
        metadata["sourceType"] = .string(type)
        metadata.removeValue(forKey: "content")

        var role: MessageRole = .unknown
        var parts: [ContentPart] = []
        var model: String?

        switch type {
        case "user":
            role = .user
            if let text = data["text"]?.stringValue, !text.isEmpty { parts.append(.text(text)) }
            for file in data["files"]?.arrayValue ?? [] {
                if let path = file.stringValue ?? file["path"]?.stringValue {
                    parts.append(.fileReference(FileReference(path: path, kind: nil)))
                }
            }
            metadata.removeValue(forKey: "text")
            metadata.removeValue(forKey: "files")
        case "assistant":
            role = .assistant
            model = modelName(data["model"])
            parts = (data["content"]?.arrayValue ?? []).flatMap(v2ContentParts)
        case "system", "synthetic":
            role = .system
            parts = [.text(data["text"]?.stringValue ?? "")]
            metadata.removeValue(forKey: "text")
        case "compaction":
            role = .system
            parts = [.text(data["summary"]?.stringValue ?? "")]
            metadata.removeValue(forKey: "summary")
        default:
            role = .system
            parts = [.unknown(kind: type, raw: data)]
        }

        return Message(
            id: id,
            sessionId: sessionId,
            ordinal: ordinal,
            role: role,
            timestamp: timestamp ?? TimestampParser.fromEpochMilliseconds(data["time"]?["created"]?.numberValue),
            model: model,
            contentParts: parts,
            metadata: metadata
        )
    }

    static func legacyMessage(
        id: String,
        sessionId: String,
        ordinal: Int,
        timestamp: Date?,
        data: JSONValue,
        parts: [JSONValue]
    ) -> Message {
        let roleText = data["role"]?.stringValue ?? ""
        let role = MessageRole(rawValue: roleText) ?? .unknown
        let provider = data["providerID"]?.stringValue
        let modelId = data["modelID"]?.stringValue ?? data["model"]?.stringValue
        let model: String? = modelId.map { id in provider.map { "\($0)/\(id)" } ?? id }

        var metadata = data.objectValue ?? [:]
        metadata["storageTable"] = .string("message")
        metadata.removeValue(forKey: "role")

        return Message(
            id: id,
            sessionId: sessionId,
            ordinal: ordinal,
            role: role,
            timestamp: timestamp,
            model: model,
            contentParts: parts.flatMap(legacyParts),
            metadata: metadata
        )
    }

    // MARK: - Parts

    private static func v2ContentParts(_ element: JSONValue) -> [ContentPart] {
        switch element["type"]?.stringValue {
        case "text":
            return [.text(element["text"]?.stringValue ?? "")]
        case "reasoning":
            return [.reasoning(element["text"]?.stringValue ?? element["reasoning"]?.stringValue ?? "")]
        case "tool":
            return toolParts(id: element["id"]?.stringValue, name: element["name"]?.stringValue, state: element["state"] ?? .null)
        default:
            return [.unknown(kind: element["type"]?.stringValue ?? "unknown", raw: element)]
        }
    }

    private static func legacyParts(_ part: JSONValue) -> [ContentPart] {
        switch part["type"]?.stringValue {
        case "text":
            return [.text(part["text"]?.stringValue ?? "")]
        case "reasoning":
            return [.reasoning(part["text"]?.stringValue ?? "")]
        case "file":
            let path = part["filename"]?.stringValue ?? part["url"]?.stringValue ?? ""
            return [.fileReference(FileReference(path: path, kind: part["mime"]?.stringValue))]
        case "tool":
            return toolParts(
                id: part["callID"]?.stringValue ?? part["id"]?.stringValue,
                name: part["tool"]?.stringValue,
                state: part["state"] ?? .null
            )
        default:
            return [.unknown(kind: part["type"]?.stringValue ?? "unknown", raw: part)]
        }
    }

    /// Returns a tool call, and a tool result when the state carries output.
    private static func toolParts(id: String?, name: String?, state: JSONValue) -> [ContentPart] {
        let status = state["status"]?.stringValue
        var parts: [ContentPart] = [.toolCall(ToolCall(
            id: id,
            name: name ?? "tool",
            input: state["input"] ?? .object([:]),
            status: status
        ))]
        let output = outputText(state)
        if output != nil || status == "completed" || status == "error" {
            parts.append(.toolResult(ToolResult(
                callId: id,
                output: output ?? "",
                isError: status == "error",
                raw: state
            )))
        }
        return parts
    }

    private static func outputText(_ state: JSONValue) -> String? {
        if let output = state["output"]?.stringValue { return output }
        guard let blocks = state["content"]?.arrayValue else { return nil }
        let texts = blocks.compactMap { $0["text"]?.stringValue }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    private static func modelName(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        if let text = value.stringValue { return text }
        let id = value["id"]?.stringValue ?? ""
        guard !id.isEmpty else { return nil }
        let provider = value["providerID"]?.stringValue ?? ""
        return provider.isEmpty ? id : "\(provider)/\(id)"
    }
}
