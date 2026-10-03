import Foundation

/// OAuth device flow for a GitHub App: the user approves in the browser by entering a short
/// code, and the app polls for the token. Needs only the app's public client ID — no client
/// secret is embedded, and no redirect server is required.
struct GitHubDeviceFlow: Sendable {
    static let deviceCodeURL = URL(string: "https://github.com/login/device/code")!
    static let tokenURL = URL(string: "https://github.com/login/oauth/access_token")!

    struct DeviceCode: Sendable, Hashable {
        let deviceCode: String
        let userCode: String
        let verificationURL: URL
        let expiresAt: Date
        let interval: TimeInterval
    }

    enum FlowError: Error, Equatable, Sendable {
        case notConfigured
        case denied
        case expired
        case refreshFailed
        case unexpected(String)
    }

    let clientID: String
    let http: any GitHubHTTP
    let now: @Sendable () -> Date
    var sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }

    func requestCode() async throws -> DeviceCode {
        guard !clientID.isEmpty else { throw FlowError.notConfigured }
        let json = try await post(Self.deviceCodeURL, ["client_id": clientID])
        guard let deviceCode = json["device_code"] as? String,
              let userCode = json["user_code"] as? String,
              let uri = (json["verification_uri"] as? String).flatMap(URL.init(string:)),
              let expiresIn = json["expires_in"] as? Double
        else { throw FlowError.unexpected(json["error"] as? String ?? "malformed device code response") }
        return DeviceCode(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURL: uri,
            expiresAt: now().addingTimeInterval(expiresIn),
            interval: json["interval"] as? Double ?? 5
        )
    }

    /// Polls until the user approves, denies, or the code expires.
    func waitForToken(_ code: DeviceCode) async throws -> GitHubCredential {
        var interval = code.interval
        while now() < code.expiresAt {
            try await sleep(interval)
            let json = try await post(Self.tokenURL, [
                "client_id": clientID,
                "device_code": code.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])
            if let credential = parseCredential(json) { return credential }
            switch json["error"] as? String {
            case "authorization_pending": continue
            case "slow_down": interval = (json["interval"] as? Double) ?? interval + 5
            case "expired_token": throw FlowError.expired
            case "access_denied": throw FlowError.denied
            case let other: throw FlowError.unexpected(other ?? "no token in response")
            }
        }
        throw FlowError.expired
    }

    /// Exchanges a refresh token for a new access token (only for apps with expiring tokens).
    func refresh(_ credential: GitHubCredential) async throws -> GitHubCredential {
        guard let refreshToken = credential.refreshToken else { throw FlowError.refreshFailed }
        let json = try await post(Self.tokenURL, [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ])
        guard let refreshed = parseCredential(json) else { throw FlowError.refreshFailed }
        return refreshed
    }

    private func parseCredential(_ json: [String: Any]) -> GitHubCredential? {
        guard let token = json["access_token"] as? String, !token.isEmpty else { return nil }
        return GitHubCredential(
            accessToken: token,
            refreshToken: json["refresh_token"] as? String,
            expiresAt: (json["expires_in"] as? Double).map { now().addingTimeInterval($0) }
        )
    }

    private func post(_ url: URL, _ form: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Tern", forHTTPHeaderField: "User-Agent")
        var components = URLComponents()
        components.queryItems = form.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await http.send(request)
        guard (200..<300).contains(response.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw FlowError.unexpected("HTTP \(response.statusCode)") }
        return json
    }
}
