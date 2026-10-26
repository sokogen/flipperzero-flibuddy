import Foundation

/// Bambuddy REST client (internal inventory mode). Routes and permissions are
/// those of Bambuddy 1.2.5.2; every request carries `X-API-Key`.
public struct BambuddyClient: Sendable {
    public static let timeout: TimeInterval = 5
    /// Bambuddy `detail` texts are cut to this length, as `error` fields are.
    static let maxMessage = 200

    public let baseURL: URL
    private let apiKey: String
    private let session: URLSession

    /// `baseURL` is the Bambuddy root, e.g. `http://192.168.1.20:8000`; a path
    /// prefix (reverse proxy) is kept.
    public init(baseURL: URL, apiKey: String, session: URLSession? = nil) throws {
        guard let scheme = baseURL.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = baseURL.host, !host.isEmpty
        else { throw BambuddyError.invalidBaseURL(baseURL.absoluteString) }
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session ?? URLSession(configuration: Self.defaultConfiguration)
    }

    private static var defaultConfiguration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        return configuration
    }

    // MARK: Inventory

    /// The spool carrying this tag: the tray UUID when there is one, then the
    /// UID. `nil` when every query answers 404.
    public func findSpool(trayUuid: String?, uid: String) async throws -> Spool? {
        let queries = (trayUuid.map { [URLQueryItem(name: "tray_uuid", value: $0)] } ?? [])
            + [URLQueryItem(name: "tag_uid", value: uid)]
        for query in queries {
            let (data, status) = try await send("GET", "/inventory/spools/by-tag", query: [query])
            if status == 404 { continue }
            try check(status, data, permission: "inventory:read")
            return try decode(Spool.self, data)
        }
        return nil
    }

    public func spool(id: Int) async throws -> Spool {
        let (data, status) = try await send("GET", "/inventory/spools/\(id)")
        if status == 404 { throw BambuddyError.spoolNotFound(id) }
        try check(status, data, permission: "inventory:read")
        return try decode(Spool.self, data)
    }

    /// Active (not archived) spools.
    public func listSpools() async throws -> [Spool] {
        try await get("/inventory/spools", permission: "inventory:read")
    }

    /// Empty-spool catalog.
    public func catalog() async throws -> [CatalogEntry] {
        try await get("/inventory/catalog", permission: "inventory:read")
    }

    /// Bambuddy's colour names. Decoded with the keys as sent: the tables'
    /// keys are data and must not go through the snake-case conversion.
    public func colorMap() async throws -> ColorMap {
        let (data, status) = try await send("GET", "/inventory/colors/map")
        try check(status, data, permission: "inventory:read")
        return try decode(ColorMap.self, data, keys: .useDefaultKeys)
    }

    /// Record a gross scale weight; Bambuddy subtracts the core weight and sets
    /// `weight_used`, `last_scale_weight` and `last_weighed_at`.
    public func updateWeight(spoolId: Int, gross: Int) async throws -> WeightUpdate {
        struct Body: Encodable {
            var spoolId: Int
            var weightGrams: Int
        }
        let (data, status) = try await send(
            "POST", "/spoolbuddy/scale/update-spool-weight", body: Body(spoolId: spoolId, weightGrams: gross)
        )
        if status == 404 { throw BambuddyError.spoolNotFound(spoolId) }
        try check(status, data, permission: "inventory:update")
        return try decode(WeightUpdate.self, data)
    }

    /// Create a new item. Refuses a body without `material` before any request.
    public func createSpool(_ spool: NewSpool) async throws -> Spool {
        guard !spool.material.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BambuddyError.missingMaterial
        }
        let (data, status) = try await send("POST", "/inventory/spools", body: spool)
        try check(status, data, permission: "inventory:update")
        return try decode(Spool.self, data)
    }

    /// Attach a tag to an existing spool; 409 when another active spool has it.
    public func linkTag(spoolId: Int, _ link: TagLink) async throws -> Spool {
        let (data, status) = try await send("PATCH", "/inventory/spools/\(spoolId)/link-tag", body: link)
        switch status {
        case 404: throw BambuddyError.spoolNotFound(spoolId)
        case 409: throw BambuddyError.tagAlreadyLinked(otherSpoolId: Self.conflictHolder(data))
        default: break
        }
        try check(status, data, permission: "inventory:update")
        return try decode(Spool.self, data)
    }

    /// Hard-delete a spool (Bambuddy needs `inventory:update` for it).
    public func deleteSpool(id: Int) async throws {
        let (data, status) = try await send("DELETE", "/inventory/spools/\(id)")
        if status == 404 { throw BambuddyError.spoolNotFound(id) }
        try check(status, data, permission: "inventory:update")
    }

    // MARK: Settings

    /// Whether Bambuddy runs in Spoolman mode, which the host refuses.
    public func spoolmanEnabled() async throws -> Bool {
        try await get("/settings/spoolman", permission: "settings:read", as: SpoolmanSettings.self).spoolmanEnabled
    }

    private struct SpoolmanSettings: Decodable {
        var spoolmanEnabled: Bool

        private enum CodingKeys: String, CodingKey { case spoolmanEnabled }

        // Bambuddy stores settings as strings ("true"/"false"); accept a bool too.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let flag = try? container.decode(Bool.self, forKey: .spoolmanEnabled) {
                spoolmanEnabled = flag
            } else {
                spoolmanEnabled = try container.decode(String.self, forKey: .spoolmanEnabled).lowercased() == "true"
            }
        }
    }

    // MARK: Plumbing

    private func get<T: Decodable>(_ path: String, permission: String, as type: T.Type = T.self) async throws -> T {
        let (data, status) = try await send("GET", path)
        try check(status, data, permission: permission)
        return try decode(type, data)
    }

    private func send(
        _ method: String, _ path: String, query: [URLQueryItem] = [], body: (any Encodable)? = nil
    ) async throws -> (Data, Int) {
        var request = URLRequest(url: url(path, query: query), timeoutInterval: Self.timeout)
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            request.httpBody = try encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as CancellationError {
            throw error
        } catch {
            throw BambuddyError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw BambuddyError.network("not an HTTP response")
        }
        return (data, http.statusCode)
    }

    private func url(_ path: String, query: [URLQueryItem]) -> URL {
        // init validated scheme and host, so the components always form a URL.
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        var prefix = components.path
        while prefix.hasSuffix("/") { prefix.removeLast() }
        components.path = prefix + "/api/v1" + path
        components.queryItems = query.isEmpty ? nil : query
        return components.url!
    }

    private func check(_ status: Int, _ data: Data, permission: String) throws {
        switch status {
        case 200..<300: return
        case 401: throw BambuddyError.unauthorized
        case 403: throw BambuddyError.permissionMissing(permission)
        default: throw BambuddyError.http(status: status, message: Self.detail(data))
        }
    }

    private func decode<T: Decodable>(
        _ type: T.Type, _ data: Data, keys: JSONDecoder.KeyDecodingStrategy = .convertFromSnakeCase
    ) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = keys
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw BambuddyError.decoding("\(T.self): \(error)".prefix(Self.maxMessage).description)
        }
    }

    /// FastAPI's `detail`: a string, a `{code, message, …}` object, or a list of
    /// validation errors `{loc, msg}`. Falls back to the raw body.
    static func detail(_ data: Data) -> String {
        let raw = String(decoding: data, as: UTF8.self)
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let text: String = switch object?["detail"] {
        case let message as String:
            message
        case let detail as [String: Any]:
            (detail["message"] as? String) ?? (detail["code"] as? String) ?? raw
        case let errors as [[String: Any]]:
            errors.map { error in
                let location = (error["loc"] as? [Any])?.map { "\($0)" }.joined(separator: ".")
                let message = error["msg"] as? String ?? "invalid"
                return location.map { "\($0): \(message)" } ?? message
            }.joined(separator: "; ")
        default:
            raw
        }
        return String(text.prefix(maxMessage))
    }

    /// The spool id a `tag_already_linked` 409 names, when Bambuddy sends one.
    static func conflictHolder(_ data: Data) -> Int? {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (object?["detail"] as? [String: Any])?["spool_id"] as? Int
    }
}
