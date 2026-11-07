import SessionDockCore
import SwiftUI

@MainActor
@Observable
final class SessionInspectorViewModel {
    static let pageSize = 40

    let sessionId: String
    private(set) var session: SessionSummary?
    private(set) var parent: SessionSummary?
    private(set) var children: [SessionSummary] = []
    private(set) var messages: [Message] = []
    private(set) var nextOffset: Int?
    private(set) var issues: [SourceIssue] = []
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var hasCopyInOpenCode = false

    init(sessionId: String) {
        self.sessionId = sessionId
    }

    func load(_ services: AppServices) async {
        do {
            session = try services.index.session(id: sessionId)
            guard let session else {
                error = "This session is no longer in the index. Refresh to update it."
                return
            }
            parent = try session.parentSessionId.flatMap { try services.index.session(id: $0) }
            children = try services.index.children(of: session.id)
            hasCopyInOpenCode = try copyExists(session, services)
            messages = []
            issues = []
            nextOffset = 0
            error = nil
            await loadNextPage(services)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadNextPage(_ services: AppServices) async {
        guard let session, let offset = nextOffset, !isLoading else { return }
        guard let adapter = services.registry.adapter(for: session.agent) else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await adapter.parser.page(for: session, offset: offset, limit: Self.pageSize)
            messages.append(contentsOf: page.messages)
            issues.append(contentsOf: page.issues)
            nextOffset = page.nextOffset
        } catch {
            self.error = "The transcript could not be read: \(error.localizedDescription)"
            nextOffset = nil
        }
    }

    private func copyExists(_ session: SessionSummary, _ services: AppServices) throws -> Bool {
        guard session.agent == .claudeCode,
              let installation = try services.index.installations().first(where: { $0.agent == .openCode }),
              let path = installation.storePath, installation.status.isAvailable else { return false }
        return try OpenCodeStore(databaseURL: URL(fileURLWithPath: path)).originMap()
            .contains { $0.originId == session.originalId }
    }
}
