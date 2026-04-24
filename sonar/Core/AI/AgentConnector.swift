import Foundation

/// Connects the iOS client to the LiveKit Agents-hosted KI participant. Plan §8 / §10/12.
@MainActor
final class AgentConnector {
    func ensureAgentInRoom() async throws {
        // TODO §10/12: ask sonar-server to spawn / attach the agent worker for this room.
    }

    func sendUserUtterance(_ text: String) async {
        // TODO §10/12: optional text-side channel for "user said this" hints.
    }
}
