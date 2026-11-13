import XCTest
@testable import notchi

@MainActor
final class ResidentialTVControlTests: XCTestCase {
    func testResidentialDeviceTabsHaveDistinctLabelsAndIcons() {
        XCTAssertEqual(ResidentialDevice.allCases, [.favorites, .air, .tv, .scenes])
        XCTAssertEqual(ResidentialDevice.air.symbol, "air.conditioner.horizontal")
        XCTAssertEqual(ResidentialDevice.tv.symbol, "tv")
        XCTAssertEqual(ResidentialDevice.tv.title, "TV")
    }

    func testTVAddressRejectsPublicAndInvalidHosts() {
        XCTAssertEqual(try LGTVProtocol.address(" 192.168.15.2 "), "192.168.15.2")
        XCTAssertThrowsError(try LGTVProtocol.address("8.8.8.8"))
        XCTAssertThrowsError(try LGTVProtocol.address("192.168.1.999"))
        XCTAssertThrowsError(try LGTVProtocol.address("https://example.com"))
    }

    func testPairingKeyIsOnlyReusedForMatchingDevice() {
        let saved = LGTVPairing(host: "192.168.1.2", key: "test-key")
        let same = LGTVProtocol.registration(host: saved.host, saved: saved)["payload"] as? [String: Any]
        let other = LGTVProtocol.registration(host: "192.168.1.3", saved: saved)["payload"] as? [String: Any]
        XCTAssertEqual(same?["client-key"] as? String, "test-key")
        XCTAssertNil(other?["client-key"])
    }

    func testInvalidTVVolumeIsNotAcceptedAsReportedState() throws {
        let (volume, muted) = try LGTVProtocol.volume(from: ["volumeStatus": ["volume": 35, "muted": true]])
        XCTAssertEqual(volume, 35)
        XCTAssertTrue(muted)
        XCTAssertThrowsError(try LGTVProtocol.volume(from: ["volume": 101, "muted": false]))
        XCTAssertThrowsError(try LGTVProtocol.volume(from: ["volume": 30]))
    }

    func testNavigationSocketMustBelongToSelectedTV() throws {
        XCTAssertEqual(try LGTVProtocol.pointerURL("ws://192.168.1.2:3000/input", host: "192.168.1.2").host, "192.168.1.2")
        XCTAssertThrowsError(try LGTVProtocol.pointerURL("ws://192.168.1.3:3000/input", host: "192.168.1.2"))
    }

    func testWakePacketContainsHeaderAndSixteenCopiesOfMAC() throws {
        let packet = try LGTVWakeOnLAN.magicPacket(mac: "a0:b1:c2:d3:e4:f5")
        XCTAssertEqual(packet.count, 102)
        XCTAssertEqual(Array(packet.prefix(6)), Array(repeating: 255, count: 6))
        for offset in stride(from: 6, to: 102, by: 6) {
            XCTAssertEqual(Array(packet[offset..<(offset + 6)]), [0xa0, 0xb1, 0xc2, 0xd3, 0xe4, 0xf5])
        }
        XCTAssertEqual(try LGTVWakeOnLAN.magicPacket(mac: "a0-b1-c2-d3-e4-f5"), packet)
    }

    func testInvalidWakeAddressesAreRejected() {
        for mac in ["", "aa:bb:cc", "zz:bb:cc:dd:ee:ff", "00:00:00:00:00:00", "ff:ff:ff:ff:ff:ff"] {
            XCTAssertThrowsError(try LGTVWakeOnLAN.magicPacket(mac: mac))
        }
    }

    func testBroadcastUsesActualSubnetMask() throws {
        XCTAssertEqual(try LGTVWakeOnLAN.broadcastAddress(host: "192.168.15.2", netmask: "255.255.255.0"), "192.168.15.255")
        XCTAssertEqual(try LGTVWakeOnLAN.broadcastAddress(host: "10.20.4.8", netmask: "255.255.0.0"), "10.20.255.255")
        XCTAssertThrowsError(try LGTVWakeOnLAN.broadcastAddress(host: "invalid", netmask: "255.255.255.0"))
    }

    func testLegacyPairingDecodesWithoutWakeAddress() throws {
        let data = Data(#"{"host":"192.168.1.2","key":"test"}"#.utf8)
        let pairing = try JSONDecoder().decode(LGTVPairing.self, from: data)
        XCTAssertNil(pairing.wakeMAC)
        XCTAssertEqual(pairing.key, "test")
    }

    func testTVNameFollowsDeviceIdentityAndLeavesPairingUntouched() throws {
        let suite = "notchjp-tv-name-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = LGTVPairingStore(directory: directory)
        let device = LGTVDevice(id: "uuid:living-room", host: "192.168.1.2", name: "LG original", model: "webOS",
                                descriptionURL: URL(string: "http://192.168.1.2:1540/")!)
        try store.save(LGTVPairing(host: device.host, key: "test", device: device, wakeMAC: "aa:bb:cc:dd:ee:ff"))
        let tv = LGTVController(store: store, deviceNames: ResidentialDeviceNames(defaults: defaults))
        tv.rename(to: " TV da sala ")
        XCTAssertEqual(tv.displayName, "TV da sala")
        XCTAssertEqual(try store.load()?.key, "test")
        XCTAssertEqual(try store.load()?.device?.name, "LG original")
        XCTAssertEqual(try store.load()?.wakeMAC, "aa:bb:cc:dd:ee:ff")

        let moved = LGTVDevice(id: device.id, host: "192.168.1.3", name: device.name, model: device.model,
                               descriptionURL: URL(string: "http://192.168.1.3:1540/")!)
        try store.save(LGTVPairing(host: moved.host, key: "test", device: moved))
        let reopened = LGTVController(store: store, deviceNames: ResidentialDeviceNames(defaults: defaults))
        XCTAssertEqual(reopened.displayName, "TV da sala")
        let other = LGTVDevice(id: "uuid:other", host: moved.host, name: "Outra TV", model: "webOS", descriptionURL: moved.descriptionURL)
        XCTAssertEqual(reopened.displayName(for: other), "Outra TV")
        reopened.rename(to: "")
        XCTAssertEqual(reopened.displayName, "LG original")
    }
}
