import Foundation

/// Fetches a LiveKit JWT from sonar-server. Plan §10/14.
/// The bundled development server does not enforce app-level auth or a Sonar TTL policy yet.
protocol RoomTokenProviding {
    func fetchToken(roomName: String, participantIdentity: String) async throws -> String
}

/// HTTP implementation that POSTs to `<serverURL>/token`.
struct SonarTokenProvider: RoomTokenProviding {
    let serverURL: String

    func fetchToken(roomName: String, participantIdentity: String) async throws -> String {
        guard let url = URL(string: "\(serverURL)/token") else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "room": roomName,
            "identity": participantIdentity
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let token = json["token"] as? String
        else { throw URLError(.cannotParseResponse) }
        return token
    }
}
