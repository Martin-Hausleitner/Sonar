import Combine
import Foundation

/// Requests sonar-server to attach the LiveKit Agents KI-participant to the room.
/// Plan §8 / §10/15. The agent itself runs server-side (gpt-realtime or Gemini
/// 2.5 Flash Live); this class is only the iOS side of the spawn handshake.
@MainActor
final class AgentConnector {
    enum AgentError: Error { case spawnFailed }

    /// Base URL of sonar-server, e.g. "https://sonar.example.com".
    var serverURL: String = ""

    /// Ask the server to join/spawn the AI participant for `roomName`.
    /// No-op when serverURL is empty (dev builds without a running server).
    func ensureAgentInRoom(roomName: String = "sonar-main") async throws {
        guard !serverURL.isEmpty, let url = URL(string: "\(serverURL)/agent/spawn") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["room": roomName])
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw AgentError.spawnFailed }
    }

    /// Forward a transcribed user utterance to the agent via the server's
    /// hint channel. Optional — agent also listens to the audio track directly.
    func sendUserUtterance(_ text: String) async {
        guard !serverURL.isEmpty, let url = URL(string: "\(serverURL)/agent/utterance") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text])
        _ = try? await URLSession.shared.data(for: req)
    }
}
