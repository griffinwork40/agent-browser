import Foundation

actor ActionLog {
    private var entries: [AgentAction] = []
    private let fileURL: URL
    private let maxEntries = 5_000

    init(dataDirectory: URL) {
        self.fileURL = dataDirectory.appendingPathComponent("agent-actions.json")
        self.entries = Self.load(from: fileURL) ?? []
    }

    func append(_ action: AgentAction) {
        entries.insert(action, at: 0)
        if entries.count > maxEntries { entries.removeLast(entries.count - maxEntries) }
        save()
    }

    func actionsForTab(_ tabID: UUID, limit: Int = 50) -> [AgentAction] {
        Array(entries.filter { $0.tabID == tabID }.prefix(limit))
    }

    func actionsForAgent(_ agentID: String, limit: Int = 50) -> [AgentAction] {
        Array(entries.filter { $0.agentID == agentID }.prefix(limit))
    }

    func recentActions(limit: Int = 50) -> [AgentAction] {
        Array(entries.prefix(limit))
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func load(from url: URL) -> [AgentAction]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([AgentAction].self, from: data)
    }
}
