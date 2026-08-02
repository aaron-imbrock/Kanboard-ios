import Foundation

enum KanboardError: LocalizedError {
    case invalidServerURL(String)
    case httpStatus(Int)
    case malformedResponse
    case api(String)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL(let raw):
            return "\"\(raw)\" is not a valid server address."
        case .httpStatus(let code):
            return code == 401
                ? "The server rejected the API token (HTTP 401)."
                : "The server returned HTTP \(code)."
        case .malformedResponse:
            return "The server sent a response this app could not read."
        case .api(let message):
            return message
        }
    }
}

final class KanboardClient {
    let baseURL: String
    let token: String
    private let session: URLSession

    init(baseURL: String, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    /// Builds the JSON-RPC endpoint from a user-typed address. Anything that is not a
    /// usable http(s) URL is reported as an error instead of trapping.
    private func endpoint() throws -> URL {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed + "/jsonrpc.php"),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            throw KanboardError.invalidServerURL(baseURL)
        }
        return url
    }

    @discardableResult
    func rpc(method: String, params: Any) async throws -> Any {
        let url = try endpoint()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let auth = Data("jsonrpc:\(token)".utf8).base64EncodedString()
        request.setValue("Basic \(auth)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": method, "params": params]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw KanboardError.httpStatus(http.statusCode)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw KanboardError.malformedResponse
        }
        if let error = json["error"] as? [String: Any] {
            throw KanboardError.api(error["message"] as? String ?? "Unknown API error")
        }
        guard let result = json["result"] else { throw KanboardError.malformedResponse }
        return result
    }

    /// `getBoard` returns one entry per swimlane, each holding the columns and their tasks.
    /// The raw structure is flattened by `BoardViewModel`.
    func getBoard(projectId: Int) async throws -> [[String: Any]] {
        guard let swimlanes = try await rpc(method: "getBoard", params: ["project_id": projectId]) as? [[String: Any]] else {
            throw KanboardError.malformedResponse
        }
        return swimlanes
    }

    func moveTask(projectId: Int, taskId: Int, columnId: Int, swimlaneId: Int?, position: Int = 1) async throws {
        var params: [String: Any] = [
            "project_id": projectId,
            "task_id": taskId,
            "column_id": columnId,
            "position": position
        ]
        if let swimlaneId { params["swimlane_id"] = swimlaneId }
        try await rpc(method: "moveTaskPosition", params: params)
    }

    func createTask(projectId: Int, title: String, columnId: Int) async throws {
        try await rpc(method: "createTask", params: ["project_id": projectId, "title": title, "column_id": columnId])
    }

    func closeTask(taskId: Int) async throws {
        try await rpc(method: "closeTask", params: ["task_id": taskId])
    }
}
