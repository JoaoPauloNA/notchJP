import Foundation
import Darwin

enum LGTVWakeOnLAN {
    static func magicPacket(mac: String) throws -> Data {
        let parts = mac.replacingOccurrences(of: "-", with: ":").split(separator: ":", omittingEmptySubsequences: false)
        let bytes = parts.compactMap { part -> UInt8? in
            guard (1...2).contains(part.count) else { return nil }
            return UInt8(part, radix: 16)
        }
        guard bytes.count == 6, parts.count == 6, bytes.contains(where: { $0 != 0 }),
              bytes[0] & 1 == 0 else {
            throw LGTVError(message: "Informe um endereço MAC válido da TV, como AA:BB:CC:DD:EE:02.")
        }
        return Data(Array(repeating: UInt8(0xff), count: 6) + Array(repeating: bytes, count: 16).flatMap { $0 })
    }

    static func cachedMAC(host: String) -> String? {
        guard (try? LGTVProtocol.address(host)) != nil else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        process.arguments = ["-n", host]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let fields = text.split(whereSeparator: \.isWhitespace)
        guard let at = fields.firstIndex(of: "at"), at + 1 < fields.count else { return nil }
        let mac = String(fields[at + 1])
        return (try? magicPacket(mac: mac)) == nil ? nil : mac
    }

    static func broadcastAddress(host: String, netmask: String) throws -> String {
        func number(_ address: String) throws -> UInt32 {
            let parts = address.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 4 else { throw LGTVError(message: "Endereço de rede inválido.") }
            return try parts.reduce(UInt32(0)) { value, part in
                guard let byte = UInt8(part) else { throw LGTVError(message: "Endereço de rede inválido.") }
                return (value << 8) | UInt32(byte)
            }
        }
        let value = try number(host) | ~number(netmask)
        return [24, 16, 8, 0].map { String((value >> $0) & 255) }.joined(separator: ".")
    }

    private static func localBroadcast(host: String) throws -> String {
        var target = in_addr()
        guard inet_pton(AF_INET, host, &target) == 1 else { throw LGTVError(message: "Endereço da TV inválido.") }
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { throw LGTVError(message: "Não foi possível consultar a rede local.") }
        defer { freeifaddrs(interfaces) }
        var cursor = interfaces
        while let entry = cursor {
            let item = entry.pointee
            cursor = item.ifa_next
            guard let address = item.ifa_addr, address.pointee.sa_family == AF_INET,
                  let mask = item.ifa_netmask,
                  item.ifa_flags & UInt32(IFF_UP | IFF_BROADCAST) == UInt32(IFF_UP | IFF_BROADCAST) else { continue }
            let local = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            let netmask = UnsafeRawPointer(mask).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            guard target.s_addr & netmask.s_addr == local.s_addr & netmask.s_addr else { continue }
            return try broadcastAddress(host: host, netmask: String(cString: inet_ntoa(netmask)))
        }
        throw LGTVError(message: "Conecte o Mac à mesma rede local da TV para ligá-la.")
    }

    static func send(mac: String, host: String) throws {
        _ = try LGTVProtocol.address(host)
        let packet = try magicPacket(mac: mac)
        let broadcast = try localBroadcast(host: host)
        let socket = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socket >= 0 else { throw LGTVError(message: "Não foi possível iniciar o comando para ligar a TV.") }
        defer { Darwin.close(socket) }
        var enabled: Int32 = 1
        guard setsockopt(socket, SOL_SOCKET, SO_BROADCAST, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0 else {
            throw LGTVError(message: "Não foi possível enviar o comando na rede local.")
        }
        for _ in 0..<3 {
            for port: UInt16 in [9, 7] {
                var destination = sockaddr_in()
                destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                destination.sin_family = sa_family_t(AF_INET)
                destination.sin_port = port.bigEndian
                inet_pton(AF_INET, broadcast, &destination.sin_addr)
                let count = withUnsafePointer(to: &destination) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                        packet.withUnsafeBytes { bytes in
                            Darwin.sendto(socket, bytes.baseAddress, bytes.count, 0, address, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
                guard count == packet.count else {
                    throw LGTVError(message: "O comando para ligar foi bloqueado. Confira a permissão de Rede Local do notch.")
                }
            }
        }
    }
}
