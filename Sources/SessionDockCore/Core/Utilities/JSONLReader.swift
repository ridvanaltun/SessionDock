import Foundation

/// One newline-terminated line from a JSONL file, with its byte range.
public struct JSONLLine: Sendable {
    public let bytes: Data
    public let startOffset: UInt64
    /// Offset immediately after the terminating newline.
    public let endOffset: UInt64
}

public enum JSONLReader {
    /// Streams complete lines from `offset`. A trailing fragment without a newline is
    /// not delivered and not consumed, so a file that is still being written is never
    /// parsed half-way. Returns the offset just after the last delivered line.
    ///
    /// Each chunk and each line runs inside its own autorelease pool. Foundation returns
    /// autoreleased objects from `FileHandle.read`; on background threads those would
    /// otherwise accumulate for the whole scan of a multi-gigabyte transcript store.
    ///
    /// - Parameter body: return `false` to stop early.
    @discardableResult
    public static func forEachCompleteLine(
        in url: URL,
        from offset: UInt64,
        chunkSize: Int = 1 << 20,
        _ body: (JSONLLine) throws -> Bool
    ) throws -> UInt64 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)

        var consumed = offset
        var buffer: [UInt8] = []
        var bufferStart = offset
        var lineStart = 0
        var scanned = 0
        var keepGoing = true

        while keepGoing {
            let chunk = try autoreleasepool { try handle.read(upToCount: chunkSize) }
            guard let chunk, !chunk.isEmpty else { break }
            buffer.append(contentsOf: chunk)

            try autoreleasepool {
                while let newline = buffer[scanned...].firstIndex(of: 0x0A) {
                    let line = JSONLLine(
                        bytes: Data(buffer[lineStart..<newline]),
                        startOffset: bufferStart + UInt64(lineStart),
                        endOffset: bufferStart + UInt64(newline + 1)
                    )
                    lineStart = newline + 1
                    scanned = lineStart
                    consumed = line.endOffset
                    if try !body(line) {
                        keepGoing = false
                        return
                    }
                }
            }
            scanned = buffer.count

            if lineStart > 0 {
                buffer.removeFirst(lineStart)
                bufferStart += UInt64(lineStart)
                scanned -= lineStart
                lineStart = 0
            }
        }
        return consumed
    }
}
