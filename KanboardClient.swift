import Foundation

final class KanboardClient {
    var baseURL: String
    var token: String
    init(baseURL: String, token: String) { self.baseURL = baseURL; self.token = token }

    @discardableResult
    func rpc(method: String, params: Any) async throws -> Any {
        let url = URL(string: baseURL + "/jsonrpc.php")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let auth = "jsonrpc:\(token)".data(using:.utf8)!.base64EncodedString()
        req.setValue("Basic \(auth)", forHTTPHeaderField: "Authorization")
        let body: [String:Any] = ["jsonrpc":"2.0","id":1,"method":method,"params":params]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data,_) = try await URLSession.shared.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as! [String:Any]
        if let err = json["error"] as? [String:Any] { throw NSError(domain: err["message"] as! String, code: 0) }
        return json["result"]!
    }
    func getBoard(projectId: Int) async throws -> [[String:Any]] {
        return try await rpc(method: "getBoard", params: ["project_id": projectId]) as! [[String:Any]]
    }
    func moveTask(projectId: Int, taskId: Int, columnId: Int) async throws {
        _ = try await rpc(method: "moveTaskPosition", params: ["project_id":projectId,"task_id":taskId,"column_id":columnId,"position":1])
    }
    func createTask(projectId: Int, title: String, columnId: Int) async throws {
        _ = try await rpc(method: "createTask", params: ["project_id":projectId,"title":title,"column_id":columnId])
    }
}
