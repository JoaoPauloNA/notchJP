import Foundation
import Darwin

struct LGTVDevice: Codable, Identifiable, Sendable {
    let id: String
    let host: String
    let name: String
    let model: String
    let descriptionURL: URL
}

enum LGTVDiscovery {
    nonisolated static let service = "urn:lge-com:service:webos-second-screen:1"
    nonisolated static func location(in response: String) -> URL? {
        var fields: [String: String] = [:]
        for line in response.components(separatedBy: .newlines) {
            let parts = line.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            if parts.count == 2 { fields[parts[0].lowercased()] = parts[1] }
        }
        guard fields["st"] == service, let value = fields["location"], let url = URL(string: value),
              url.scheme == "http", url.user == nil, url.password == nil,
              let host = url.host, (try? LGTVProtocol.address(host)) != nil else { return nil }
        return url
    }
    static func decode(_ data: Data, from url: URL) throws -> LGTVDevice {
        guard data.count < 131072, let host = url.host, (try? LGTVProtocol.address(host)) != nil else {
            throw LGTVError(message: "Descrição da TV inválida.")
        }
        let delegate = DeviceDescriptionParser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.services.contains(service),
              let id = delegate.fields["UDN"], id.hasPrefix("uuid:"),
              let manufacturer = delegate.fields["manufacturer"], manufacturer.lowercased().contains("lg"),
              let model = delegate.fields["modelNumber"], !model.isEmpty else {
            throw LGTVError(message: "O dispositivo não foi identificado como uma TV LG compatível.")
        }
        return LGTVDevice(id: id, host: host, name: delegate.fields["friendlyName"] ?? "TV LG", model: model, descriptionURL: url)
    }
    static func describe(_ url: URL) async throws -> LGTVDevice {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 6
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, response.url?.host == url.host else {
            throw LGTVError(message: "A TV não respondeu à identificação na rede.")
        }
        return try decode(data, from: url)
    }
    static func find() async throws -> [LGTVDevice] {
        let worker = Task.detached(priority: .userInitiated) { try searchLocations() }
        let locations = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        return await withTaskGroup(of: LGTVDevice?.self) { group in
            for url in locations { group.addTask { try? await describe(url) } }
            var devices: [String: LGTVDevice] = [:]
            for await device in group { if let device { devices[device.id] = device } }
            return devices.values.sorted { $0.name < $1.name }
        }
    }
    private nonisolated static func searchLocations() throws -> [URL] {
        let socket = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socket >= 0 else { throw LGTVError(message: "Não foi possível iniciar a busca na rede local.") }
        defer { Darwin.close(socket) }
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = UInt16(1900).bigEndian
        inet_pton(AF_INET, "239.255.255.250", &destination.sin_addr)
        let request = Data("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: \(service)\r\n\r\n".utf8)
        func send() throws {
            let result = withUnsafePointer(to: &destination) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    request.withUnsafeBytes { buffer in Darwin.sendto(socket, buffer.baseAddress, buffer.count, 0, address, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
            }
            guard result >= 0 else { throw LGTVError(message: "A busca na rede foi bloqueada. Confira a permissão de Rede Local do aplicativo no macOS.") }
        }
        try send()
        let start = Date()
        var repeated = false
        var urls = Set<URL>()
        while Date().timeIntervalSince(start) < 3.2 {
            if Task.isCancelled { throw CancellationError() }
            if !repeated && Date().timeIntervalSince(start) > 0.8 { try send(); repeated = true }
            var descriptor = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 200) > 0 else { continue }
            var buffer = [UInt8](repeating: 0, count: 16384)
            let count = buffer.withUnsafeMutableBytes { Darwin.recv(socket, $0.baseAddress, $0.count, 0) }
            if count > 0, let url = location(in: String(decoding: buffer.prefix(count), as: UTF8.self)) { urls.insert(url) }
        }
        return Array(urls)
    }
}

private final class DeviceDescriptionParser: NSObject, XMLParserDelegate {
    var fields: [String: String] = [:]
    var services: [String] = []
    private var text = ""
    private let wanted = Set(["UDN", "manufacturer", "modelNumber", "friendlyName", "serviceType"])
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) { text = "" }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "serviceType" { services.append(value) }
        else if wanted.contains(name), fields[name] == nil { fields[name] = value }
        text = ""
    }
}
