// Protocol references and adapted field mappings: see Resources/TCL_THIRD_PARTY_NOTICES.txt.
import Foundation
import CryptoKit
import Security

struct TCLDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let online: Bool
}

struct TCLBackendError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

@MainActor
final class TCLBackend: ACBackend {
    static let shared = TCLBackend()
    var name: String { "TCL Home" }
    private(set) var devices: [TCLDevice] = []
    var selectedDeviceID: String? {
        didSet { if let selectedDeviceID { UserDefaults.standard.set(selectedDeviceID, forKey: "selectedTCLDevice") } }
    }
    private var savedAuth: SavedAuth?
    private var attemptedSessionRestore = false
    private let secureStore: any TCLSecureSessionStore
    private(set) var loginStorageNotice: String?
    private var cloud: CloudSession?
    /// Last reported shadow of every device, so several air conditioners never share one cache.
    private var reportedByDevice: [String: [String: Any]] = [:]
    private var reported: [String: Any] { reportedByDevice[selectedDeviceID ?? ""] ?? [:] }
    private var deviceTypes: [String: String] = [:]
    private var lastDiscovery = Date.distantPast
    private let network: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 25
        c.timeoutIntervalForResource = 45
        return URLSession(configuration: c)
    }()
    private struct SavedLogin: Codable { let email: String; let password: String; let region: String }
    private struct SavedAuth: Codable { let token: String; let userID: String; let country: String }
    private struct CloudSession {
        let token: String
        let userID: String
        let cloudURL: String
        let deviceURL: String
        let region: String
        let country: String
        let saasToken: String
        let mqttHost: String
        let accessKey: String
        let secretKey: String
        let sessionToken: String
        let expires: Date
    }
    init(secureStore: (any TCLSecureSessionStore)? = nil) {
        self.secureStore = secureStore ?? TCLLoginKeychainStore()
        selectedDeviceID = UserDefaults.standard.string(forKey: "selectedTCLDevice")
    }

    func configure(email: String, password: String, region: String) async throws {
        guard !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !password.isEmpty else {
            throw TCLBackendError("Informe o e-mail e a senha da sua conta TCL Home.")
        }
        let candidate = SavedLogin(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password, region: region.uppercased())
        let session = try await authenticate(candidate)
        cloud = session
        try await discoverDevices(session)
    }

    // Shipped TCL Home 7.1.0 LoginRepository + ConstantsURL; see analysis evidence.
    // This request requires a token from the user's completed official verification widget.
    func sendLoginCode(email: String, region: String, validationToken: String) async throws {
        let body = try TCLLoginCodeRequest.body(email: email, validationToken: validationToken)
        let route = try TCLAccountRoute.lookup(region)
        let response = try await request(route.host + "/common/sendVerifyCodeWithNetEase?clientId=" + route.clientId, body: body)
        try TCLLoginCodeRequest.checkResponse(response)
    }

    func configure(email: String, code: String, region: String) async throws {
        let email = try validatedEmail(email)
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, code.count <= 12, code.allSatisfy({ $0.isNumber }) else { throw TCLBackendError("Informe o código numérico enviado pela TCL ao seu e-mail.") }
        let route = try TCLAccountRoute.lookup(region)
        let body: [String: Any] = ["channel": "app", "username": email, "code": code, "sceneType": 2,
            "acceptPush": "0", "protocol": 1, "language": "pt_BR", "countryAbbr": region.uppercased(),
            "osType": 1, "osVersion": "6.0", "equipment": 2, "clientVersion": "7.1.0", "deviceModel": "macOS"]
        let response = try await request(route.host + "/v3/account/quickLogin?clientId=" + route.clientId,
            body: body, headers: TCLAccountSigner.headers(clientID: route.clientId, clientKey: route.clientKey))
        guard number(response["status"]) == 1 else {
            let status = response["status"].map { String(describing: $0) } ?? "desconhecido"
            throw TCLBackendError("A TCL recusou o código (\(status)). Confira se está correto e se a região é a mesma da sua conta.")
        }
        let session = try await acceptLogin(response, country: region.uppercased())
        cloud = session
        try await discoverDevices(session)
    }

    private func validatedEmail(_ email: String) throws -> String {
        let value = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.contains("@"), value.count <= 254, !value.contains(where: { $0.isWhitespace }) else {
            throw TCLBackendError("Informe o e-mail associado à sua conta TCL Home, inclusive se você entra com Google.")
        }
        return value
    }

    func signOut() {
        attemptedSessionRestore = true
        cloud = nil; savedAuth = nil; devices = []; selectedDeviceID = nil; reportedByDevice = [:]
        UserDefaults.standard.removeObject(forKey: "selectedTCLDevice")
        do { try secureStore.clear(); loginStorageNotice = nil } catch { loginStorageNotice = "A sessão foi encerrada neste app; o Chaves não permitiu remover a sessão salva." }
    }

    func authorizeSavedSession() throws {
        guard let data = try secureStore.authorize() else { throw TCLBackendError("Nenhuma sessão salva. Entre com sua conta TCL Home.") }
        savedAuth = try JSONDecoder().decode(SavedAuth.self, from: data)
        attemptedSessionRestore = true
        loginStorageNotice = nil
    }

    private func activeSession() async throws -> CloudSession {
        if let cloud, cloud.expires.timeIntervalSinceNow > 120 { return cloud }
        if savedAuth == nil && !attemptedSessionRestore {
            attemptedSessionRestore = true
            do {
                if let data = try secureStore.load() { savedAuth = try? JSONDecoder().decode(SavedAuth.self, from: data) }
            } catch { loginStorageNotice = "Autorize a sessão salva nos ajustes do ar-condicionado." }
        }
        guard let auth = savedAuth else { throw TCLBackendError("Entre com sua conta TCL Home para conectar o ar.") }
        let renewed = try await connectCloud(auth)
        cloud = renewed
        try await discoverDevices(renewed)
        return renewed
    }

    func readState() async throws -> ACState {
        try await readState(deviceID: selectedDeviceID ?? "")
    }

    /// Every device of the account, refreshed at most every 30 seconds.
    func listDevices() async throws -> [ACDeviceInfo] {
        let session = try await activeSession()
        if devices.isEmpty || Date().timeIntervalSince(lastDiscovery) > 30 { try await discoverDevices(session) }
        return devices.map { ACDeviceInfo(id: $0.id, name: $0.name, online: $0.online) }
    }

    func readState(deviceID: String) async throws -> ACState {
        let session = try await activeSession()
        if devices.isEmpty || Date().timeIntervalSince(lastDiscovery) > 30 { try await discoverDevices(session) }
        let id = deviceID
        guard !id.isEmpty, devices.contains(where: { $0.id == id }) else {
            throw TCLBackendError("Selecione um ar-condicionado na sua conta TCL Home.")
        }
        guard devices.first(where: { $0.id == id })?.online == true else { throw TCLBackendError("O ar está offline na TCL Home. Verifique energia e Wi-Fi.") }
        let shadow = try await awsRequest(session, method: "GET", path: "/things/\(escaped(id))/shadow")
        guard let state = shadow["state"] as? [String: Any], let values = state["reported"] as? [String: Any] else {
            throw TCLBackendError("Este dispositivo não retornou o estado de um ar-condicionado compatível.")
        }
        reportedByDevice[id] = values
        return try TCLShadowDecoder.decode(values, deviceName: devices.first(where: { $0.id == id })?.name ?? "Ar-condicionado")
    }

    // Scoped diagnostic: only numeric AC control properties, no session/device identifiers.
    func diagnosticAirControls() async throws -> [String: Any] {
        _ = try await readState()
        let keys: Set<String> = ["powerSwitch", "workMode", "windSpeed", "verticalSwitch", "horizontalSwitch",
                                 "verticalDirection", "horizontalDirection", "softWind"]
        return reported.filter { keys.contains($0.key) }
    }

    func perform(_ command: ACCommand) async throws -> ACState {
        try await perform(command, deviceID: selectedDeviceID ?? "")
    }

    func perform(_ command: ACCommand, deviceID: String) async throws -> ACState {
        // Read before every write so unsupported properties never get invented.
        let id = deviceID
        guard !id.isEmpty else { throw TCLBackendError("Selecione o ar-condicionado.") }
        let currentState = try await readState(deviceID: id)
        let session = try await activeSession()
        let reported = reportedByDevice[id] ?? [:]
        let deviceType = (deviceTypes[id] ?? "").lowercased()
        guard deviceType == "split ac" || deviceType.hasPrefix("split ac-") || deviceType == "split ac fresh air" else {
            throw TCLBackendError("O controle desta versão é compatível com aparelhos TCL Split AC. Tipo encontrado: \(deviceTypes[id] ?? "desconhecido").")
        }
        var desired: [String: Any] = [:]
        switch command {
        case .power(let value): desired["powerSwitch"] = value ? 1 : 0
        case .temperature(let value):
            guard value.isFinite, (16...32).contains(value) else { throw TCLBackendError("Escolha uma temperatura de 16 a 32 °C.") }
            desired["targetTemperature"] = Int(value.rounded())
        case .eco(let value): desired["ECO"] = value ? 1 : 0
        case .mode(let value):
            desired["workMode"] = [ACMode.auto: 0, .cool: 1, .dry: 2, .fan: 3, .heat: 4][value]
        case .fan(let value):
            desired["windSpeed"] = [ACFan.auto: 0, .low: 2, .medium: 4, .high: 6][value]
        case .sleep(let value): desired["sleep"] = value ? 1 : 0
        case .airflow(let value):
            desired["verticalSwitch"] = (value == .vertical || value == .both) ? 1 : 0
            desired["horizontalSwitch"] = (value == .horizontal || value == .both) ? 1 : 0
        case .verticalDirection, .horizontalDirection, .breeze:
            desired = try TCLAirControlEncoder.desired(command, reported: reported, mode: currentState.mode)
        }
        for key in desired.keys where reported[key] == nil {
            throw TCLBackendError("O ar selecionado não oferece este controle (\(key)).")
        }
        let body = try JSONSerialization.data(withJSONObject: ["state": ["desired": desired], "clientToken": "mac_\(UUID().uuidString)"])
        _ = try await awsRequest(session, method: "POST", path: "/topics/%24aws/things/\(escaped(id))/shadow/update", query: "qos=1", body: body)
        // Only a subsequent reported state is displayed; a cloud acknowledgement is not device confirmation.
        for _ in 0..<8 {
            try await Task.sleep(nanoseconds: 700_000_000)
            let state = try await readState(deviceID: id)
            if desired.allSatisfy({ key, value in number(reportedByDevice[id]?[key]) == number(value) }) { return state }
        }
        throw TCLBackendError("A nuvem recebeu o comando, mas o ar ainda não confirmou. Verifique se ele está online.")
    }

    private func authenticate(_ login: SavedLogin) async throws -> CloudSession {
        let route = try TCLAccountRoute.lookup(login.region)
        let response = try await request(route.host + "/account/login?clientId=" + route.clientId, body: [
            "username": login.email, "password": md5(login.password), "equipment": 2, "osType": 1,
            "clientVersion": "4.8.1", "osVersion": "6.0", "deviceModel": "AndroidAndroid SDK built for x86",
            "captchaRule": 2, "channel": "app"
        ], headers: ["th_platform": "android", "th_version": "4.8.1", "th_appbulid": "830"])
        guard number(response["status"]) == 1 else {
            throw TCLBackendError("Login TCL recusado. Confira e-mail, senha e região. Se a TCL pedir verificação, conclua no aplicativo oficial.")
        }
        return try await acceptLogin(response, country: login.region)
    }

    private func acceptLogin(_ response: [String: Any], country: String) async throws -> CloudSession {
        guard let token = response["token"] as? String, !token.isEmpty,
              let user = response["user"] as? [String: Any], let userID = user["username"] as? String, !userID.isEmpty else {
            throw TCLBackendError("A TCL não retornou uma sessão válida para esta conta.")
        }
        let country = user["countryAbbr"] as? String ?? user["country_abbr"] as? String ?? country
        let auth = SavedAuth(token: token, userID: userID, country: country)
        let session = try await connectCloud(auth)
        savedAuth = auth
        persistSessionIfPossible(try JSONEncoder().encode(auth))
        return session
    }

    private func connectCloud(_ auth: SavedAuth) async throws -> CloudSession {
        let token = auth.token, userID = auth.userID, country = auth.country
        let routing = try await request("https://prod-center.aws.tcljd.com/v3/global/cloud_url_get", body: ["ssoId": userID, "ssoToken": token])
        try check(routing, operation: "Localizar a região TCL")
        let route = routing["data"] as? [String: Any] ?? [:]
        let cloudURL = try required(route, "cloud_url", "cloudUrl").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let region = try required(route, "cloud_region", "cloudRegion")
        let deviceURL = (route["device_url"] as? String ?? route["deviceUrl"] as? String ?? cloudURL).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let refresh = try await request(cloudURL + "/v3/auth/refresh_tokens", body: ["userId": userID, "ssoToken": token, "appId": "wx6e1af3fa84fbe523"])
        try check(refresh, operation: "Conectar à nuvem TCL")
        let tokens = refresh["data"] as? [String: Any] ?? [:]
        let cognito = try required(tokens, "cognitoToken", "cognito_token")
        let identity = tokens["cognitoId"] as? String ?? tokens["cognito_id"] as? String ?? (jwtPayload(cognito)["sub"] as? String ?? "")
        guard !identity.isEmpty else { throw TCLBackendError("A TCL não informou a identidade AWS desta conta.") }
        let credentials = try await request("https://cognito-identity.\(region).amazonaws.com/", body: ["IdentityId": identity, "Logins": ["cognito-identity.amazonaws.com": cognito]], headers: ["Content-Type": "application/x-amz-json-1.1", "X-Amz-Target": "AWSCognitoIdentityService.GetCredentialsForIdentity"])
        let creds = credentials["Credentials"] as? [String: Any] ?? [:]
        let endpoint = try required(tokens, "mqttEndpoint", "mqtt_endpoint")
        guard let host = URL(string: endpoint.contains("://") ? endpoint : "https://" + endpoint)?.host else {
            throw TCLBackendError("A TCL retornou um endereço IoT inválido.")
        }
        return CloudSession(token: token, userID: userID, cloudURL: cloudURL, deviceURL: deviceURL, region: region, country: country,
                            saasToken: try required(tokens, "saasToken", "saas_token"), mqttHost: host,
                            accessKey: try required(creds, "AccessKeyId"), secretKey: try required(creds, "SecretKey"),
                            sessionToken: try required(creds, "SessionToken"), expires: Date(timeIntervalSince1970: number(creds["Expiration"]) ?? 0))
    }

    private func discoverDevices(_ session: CloudSession) async throws {
        let timestamp = String(Int64(Date().timeIntervalSince1970 * 1000))
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let response = try await request(session.deviceURL + "/v3/user/get_things", body: [:], headers: [
            "platform": "android", "appversion": "5.4.1", "thomeversion": "4.8.1", "accesstoken": session.saasToken,
            "timestamp": timestamp, "nonce": nonce, "sign": md5(timestamp + nonce + session.saasToken), "accept-language": "pt-BR"
        ])
        try check(response, operation: "Listar aparelhos")
        lastDiscovery = Date()
        let list = response["data"] as? [[String: Any]] ?? []
        deviceTypes = [:]
        devices = list.compactMap { item in
            guard let id = item["deviceId"] as? String ?? item["device_id"] as? String else { return nil }
            deviceTypes[id] = item["deviceName"] as? String ?? item["device_name"] as? String ?? ""
            let name = item["nickName"] as? String ?? item["nick_name"] as? String ?? item["deviceName"] as? String ?? item["device_name"] as? String ?? id
            return TCLDevice(id: id, name: name, online: number(item["isOnline"] ?? item["is_online"]) == 1)
        }
        if devices.count == 1 { selectedDeviceID = devices.first?.id }
        if let id = selectedDeviceID, !devices.contains(where: { $0.id == id }) { selectedDeviceID = nil }
        guard !devices.isEmpty else { throw TCLBackendError("Nenhum aparelho encontrado. Adicione o ar à sua conta pelo aplicativo TCL Home.") }
    }

    private func awsRequest(_ session: CloudSession, method: String, path: String, query: String = "", body: Data = Data()) async throws -> [String: Any] {
        let signed = try TCLSigV4.request(host: session.mqttHost, region: session.region,
            accessKey: session.accessKey, secretKey: session.secretKey, sessionToken: session.sessionToken,
            method: method, path: path, query: query, body: body)
        return try await send(signed)
    }

    private func request(_ address: String, body: [String: Any], headers: [String: String] = [:]) async throws -> [String: Any] {
        guard let url = URL(string: address), url.scheme == "https" else { throw TCLBackendError("Endereço TCL inválido.") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Android", forHTTPHeaderField: "User-Agent")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }
    private func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await network.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TCLBackendError("Resposta inválida da nuvem.") }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 { cloud = nil }
            throw TCLBackendError("A nuvem recusou a solicitação (HTTP \(http.statusCode)). Entre novamente se a sessão expirou.")
        }
        if data.isEmpty { return [:] }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw TCLBackendError("Resposta inesperada da nuvem TCL.") }
        return json
    }
    private func check(_ response: [String: Any], operation: String) throws {
        if let code = number(response["code"]), code != 0 && code != 200 {
            throw TCLBackendError("\(operation): a TCL retornou o código \(Int(code)).")
        }
    }
    private func required(_ data: [String: Any], _ keys: String...) throws -> String {
        for key in keys { if let value = data[key] as? String, !value.isEmpty { return value } }
        throw TCLBackendError("A resposta TCL não contém o campo \(keys.first ?? "necessário").")
    }
    private func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }
    private func escaped(_ string: String) -> String { string.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? string }
    private func md5(_ string: String) -> String { Data(Insecure.MD5.hash(data: Data(string.utf8))).hex }
    private func jwtPayload(_ jwt: String) -> [String: Any] {
        let parts = jwt.split(separator: ".")
        guard parts.count > 1 else { return [:] }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
    // Persistence is optional; successful cloud authentication remains usable in memory.
    func persistSessionIfPossible(_ data: Data) {
        do { try secureStore.save(data); loginStorageNotice = nil }
        catch { loginStorageNotice = "Login válido só nesta execução; o Chaves não está disponível." }
    }

}

private extension Data { var hex: String { map { String(format: "%02x", $0) }.joined() } }
@MainActor func makeBackend() -> any ACBackend { TCLBackend.shared }

// AWS Signature V4. The canonical URI is encoded again, as in botocore SigV4Auth.
// In particular, the wire topic /topics/%24aws/... signs as /topics/%2524aws/....
enum TCLSigV4 {
    static func request(host: String, region: String, accessKey: String, secretKey: String,
                        sessionToken: String, method: String, path: String, query: String = "",
                        body: Data = Data(), date: Date = Date()) throws -> URLRequest {
        guard let url = URL(string: "https://" + host + path + (query.isEmpty ? "" : "?" + query)) else { throw TCLBackendError("Endereço AWS inválido.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if !body.isEmpty { request.httpBody = body }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let timestamp = formatter.string(from: date)
        let day = String(timestamp.prefix(8))
        let payloadHash = sha256(body)
        let signedHeaders = "host;x-amz-content-sha256;x-amz-date;x-amz-security-token"
        let canonicalHeaders = "host:\(host)\nx-amz-content-sha256:\(payloadHash)\nx-amz-date:\(timestamp)\nx-amz-security-token:\(sessionToken)\n"
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/")
        let canonicalPath = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        let canonicalQuery = query.split(separator: "&").sorted().joined(separator: "&")
        let canonical = "\(method)\n\(canonicalPath)\n\(canonicalQuery)\n\(canonicalHeaders)\n\(signedHeaders)\n\(payloadHash)"
        let scope = "\(day)/\(region)/iotdata/aws4_request"
        let toSign = "AWS4-HMAC-SHA256\n\(timestamp)\n\(scope)\n\(sha256(Data(canonical.utf8)))"
        let dateKey = hmac(Data(("AWS4" + secretKey).utf8), day)
        let regionKey = hmac(dateKey, region)
        let serviceKey = hmac(regionKey, "iotdata")
        let signature = hmac(hmac(serviceKey, "aws4_request"), toSign).hex
        request.setValue(timestamp, forHTTPHeaderField: "X-Amz-Date")
        request.setValue(payloadHash, forHTTPHeaderField: "X-Amz-Content-Sha256")
        request.setValue(sessionToken, forHTTPHeaderField: "X-Amz-Security-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("AWS4-HMAC-SHA256 Credential=\(accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)", forHTTPHeaderField: "Authorization")
        return request
    }
    private static func sha256(_ data: Data) -> String { Data(SHA256.hash(data: data)).hex }
    private static func hmac(_ key: Data, _ string: String) -> Data { Data(HMAC<SHA256>.authenticationCode(for: Data(string.utf8), using: SymmetricKey(data: key))) }
}

enum TCLShadowDecoder {
    static func decode(_ values: [String: Any], deviceName: String) throws -> ACState {
        func number(_ value: Any?) -> Double? {
            if let n = value as? NSNumber { return n.doubleValue }
            if let s = value as? String { return Double(s) }
            return nil
        }
        // Some models report no windSpeed at all; they read as automatic and the fan control stays unavailable.
        let speedValue: Double? = values["windSpeed"] == nil ? 0 : number(values["windSpeed"])
        guard let power = number(values["powerSwitch"]), power == 0 || power == 1,
              let target = number(values["targetTemperature"]), target.isFinite,
              let rawMode = number(values["workMode"]), rawMode.isFinite, (0...4).contains(rawMode), rawMode.rounded() == rawMode,
              let mode = [0: ACMode.auto, 1: .cool, 2: .dry, 3: .fan, 4: .heat][Int(rawMode)],
              let rawSpeed = speedValue, rawSpeed.isFinite, (0...6).contains(rawSpeed), rawSpeed.rounded() == rawSpeed else {
            throw TCLBackendError("O estado recebido não corresponde a um ar TCL Split AC compatível. \(mismatchDetail(values))")
        }
        let speed = Int(rawSpeed)
        let fan: ACFan = speed == 0 ? .auto : speed <= 2 ? .low : speed <= 4 ? .medium : .high
        let vertical = number(values["verticalSwitch"]) == 1
        let horizontal = number(values["horizontalSwitch"]) == 1
        return ACState(power: power == 1, temperature: target,
                       roomTemperature: number(values["currentTemperature"]),
                       eco: number(values["ECO"]) == 1, mode: mode, fan: fan,
                       sleep: (number(values["sleep"]) ?? 0) > 0,
                       airflow: vertical ? (horizontal ? .both : .vertical) : (horizontal ? .horizontal : .off),
                       deviceName: deviceName,
                       verticalDirection: integer(values["verticalDirection"]).flatMap(ACVerticalDirection.init(rawValue:)),
                       horizontalDirection: integer(values["horizontalDirection"]).flatMap(ACHorizontalDirection.init(rawValue:)),
                       breeze: integer(values["softWind"]).flatMap { value in value == 0 ? false : value == 1 ? true : nil })
    }
    /// Names the control fields that are missing or out of range, with their numeric value only.
    private static func mismatchDetail(_ values: [String: Any]) -> String {
        let expected: [(key: String, range: ClosedRange<Double>)] = [
            ("powerSwitch", 0...1), ("targetTemperature", -100...100), ("workMode", 0...4)
        ] + (values["windSpeed"] == nil ? [] : [("windSpeed", 0...6)])
        let problems = expected.compactMap { item -> String? in
            guard let raw = values[item.key] else { return "\(item.key) ausente" }
            guard let number = (raw as? NSNumber)?.doubleValue ?? (raw as? String).flatMap(Double.init) else { return "\(item.key) não numérico" }
            return item.range.contains(number) && number.rounded() == number || item.key == "targetTemperature" && item.range.contains(number)
                ? nil : "\(item.key)=\(number)"
        }
        guard !problems.isEmpty else { return "" }
        let keys = problems.contains { $0.hasSuffix("ausente") } ? " Chaves recebidas: " + values.keys.sorted().prefix(20).joined(separator: ", ") + "." : ""
        return "Campos: " + problems.joined(separator: ", ") + "." + keys
    }

    private static func integer(_ value: Any?) -> Int? {
        let value = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
        guard let value, value.isFinite, value.rounded() == value, (-1000...1000).contains(value) else { return nil }
        return Int(value)
    }
}

// Corroborated field names in the official APK and enum/switch mapping in the
// reference integration. See analysis/air-direction-protocol-static.json.
enum TCLAirControlEncoder {
    static func desired(_ command: ACCommand, reported: [String: Any], mode: ACMode) throws -> [String: Any] {
        var values: [String: Any]
        let hasSwitches = reported["verticalSwitch"] != nil && reported["horizontalSwitch"] != nil
        switch command {
        case .verticalDirection(let direction):
            guard direction != .unspecified else { throw TCLBackendError("Escolha uma posição ou oscilação vertical.") }
            values = ["verticalDirection": direction.rawValue]
            if hasSwitches { values["verticalSwitch"] = direction.isSwing ? 1 : 0 }
        case .horizontalDirection(let direction):
            guard direction != .unspecified else { throw TCLBackendError("Escolha uma posição ou oscilação horizontal.") }
            values = ["horizontalDirection": direction.rawValue]
            if hasSwitches { values["horizontalSwitch"] = direction.isSwing ? 1 : 0 }
        case .breeze(let enabled):
            guard !enabled || mode == .cool else { throw TCLBackendError("A brisa suave está disponível no modo Resfriar.") }
            values = ["softWind": enabled ? 1 : 0]
        default:
            throw TCLBackendError("Comando de direção do vento inválido.")
        }
        for key in values.keys where reported[key] == nil {
            throw TCLBackendError("O aparelho não oferece este ajuste de vento.")
        }
        return values
    }
}

struct TCLAccountRoute: Decodable {
    let host: String
    let clientId: String
    let clientKey: String
    let region: [String]
    static func lookup(_ country: String) throws -> TCLAccountRoute {
        // Production-only host.json user routes extracted from the public official APK.
        let bundled = Bundle.main.url(forResource: "tcl-account-routes", withExtension: "json")
        let sourceResource = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/tcl-account-routes.json")
        let location = bundled ?? sourceResource
        let routes = try JSONDecoder().decode([TCLAccountRoute].self, from: Data(contentsOf: location))
        guard let route = routes.first(where: { $0.region.contains(country.uppercased()) }) else {
            throw TCLBackendError("Região TCL não reconhecida. Use o código de duas letras da sua conta, como BR.")
        }
        return route
    }
}

enum TCLAccountSigner {
    static func headers(clientID: String, clientKey: String, nonce: String = UUID().uuidString,
                        timestamp: String = String(Int64(Date().timeIntervalSince1970 * 1000))) -> [String: String] {
        var headers = ["clientId": clientID, "sdkSignType": "MD5", "tclSdk": "tcl-sdk-java", "none": nonce, "timestamp": timestamp]
        let signed = headers.filter { $0.key != "sdkSignType" }.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }.joined(separator: "&")
        headers["sdkSign"] = Data(Insecure.MD5.hash(data: Data((signed + clientKey).utf8))).hex
        return headers
    }
}

// Pure request validation is shared with offline tests. No token or email is logged.
enum TCLLoginCodeRequest {
    static func body(email: String, validationToken: String) throws -> [String: Any] {
        let token = validationToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw TCLBackendError("Conclua a verificação de segurança para solicitar o código. Nenhum e-mail foi solicitado.")
        }
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.contains("@"), email.count <= 254, !email.contains(where: { $0.isWhitespace }) else {
            throw TCLBackendError("Informe o e-mail associado à sua conta TCL Home.")
        }
        return ["brand": "defaultbrand", "mailType": 5, "type": 2, "validate": token,
                "username": email, "language": "pt_BR", "sceneType": 2]
    }
    static func checkResponse(_ response: [String: Any]) throws {
        let status = response["status"].map { String(describing: $0) } ?? "desconhecido"
        guard status == "1" else {
            let detail = ["message", "msg"].compactMap { response[$0] as? String }.filter { !$0.isEmpty }.joined(separator: " — ")
            let suffix = detail.isEmpty ? "" : ": " + String(detail.prefix(500))
            throw TCLBackendError("A TCL recusou a solicitação do código (status \(status))\(suffix). Nenhum envio foi confirmado.")
        }
    }
}
