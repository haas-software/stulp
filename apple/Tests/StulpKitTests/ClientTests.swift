import Foundation
import Testing
@testable import StulpKit

@Suite("Client")
struct ClientTests {
    @Test func everyRequestCarriesTheBearerToken() async throws {
        let (client, host) = StubProtocol.client { seen in
            switch seen.path {
            case "/api/stulp/health": .json(#"{"ok":true,"stulpVersion":"3.1.0"}"#)
            case "/api/stulp/device-groups": .json(#"[{"id":"g1","name":"Woonkamer","parentId":""}]"#)
            default: .json("true")
            }
        }
        let health = try await client.validate()
        #expect(health.stulpVersion == "3.1.0")
        let groups = try await client.groups()
        #expect(groups.first?.parentId == nil)
        try await client.setFlowEnabled("f1", false)
        let seen = StubProtocol.requests(host)
        #expect(seen.count == 3)
        #expect(seen.allSatisfy { $0.authorization == "Bearer secret-key" })
        #expect(seen.last?.method == "PUT")
        #expect(seen.last?.path == "/api/manager/flow/flow/f1/enabled")
        #expect(seen.last?.json == ["enabled": false])
    }

    @Test func unauthorizedIsItsOwnError() async {
        let (client, _) = StubProtocol.client { _ in .json(#"{"error":"missing or wrong bearer token"}"#, status: 401) }
        await #expect(throws: StulpClientError.unauthorized) { try await client.validate() }
    }

    @Test func serverMessagePrefersTheDescription() async {
        let (client, _) = StubProtocol.client { _ in
            .json(#"{"error":"conflict","error_description":"scene is active"}"#, status: 409)
        }
        await #expect(throws: StulpClientError.server(status: 409, message: "scene is active")) {
            try await client.deleteScene("s1")
        }
    }

    @Test func capabilityGoesAsValue() async throws {
        let (client, host) = StubProtocol.client { _ in .json("null") }
        try await client.setCapability(device: "dev 1", capability: "dim", value: 0.4)
        let put = try #require(StubProtocol.requests(host).first)
        #expect(put.method == "PUT")
        #expect(put.path == "/api/manager/devices/device/dev%201/capability/dim")
        #expect(put.json == ["value": 0.4])
    }

    @Test func devicesComeAsAMap() async throws {
        let (client, _) = StubProtocol.client { _ in .json("{\"a\": \(Fixtures.device)}") }
        let devices = try await client.devices()
        #expect(devices.map(\.name) == ["Testlamp"])
    }

    @Test func appAPIAnswerIsJSON() async throws {
        let (client, host) = StubProtocol.client { _ in .json(#"{"ok":true,"n":2}"#) }
        let value = try await client.appAPI("com.stulp.matter", method: "post", path: "/scan", body: ["window": 4])
        #expect(value["n"] == 2)
        let seen = try #require(StubProtocol.requests(host).first)
        #expect(seen.method == "POST")
        #expect(seen.path == "/api/stulp/apps/com.stulp.matter/api/scan")
        #expect(seen.json == ["window": 4])
    }

    @Test func missingAppSettingIsNull() async throws {
        let (client, _) = StubProtocol.client { _ in .json(#"{"error":"missing"}"#, status: 404) }
        #expect(try await client.appSetting("com.stulp.notify", "apnsKeyId") == .null)
    }

    @Test func driversReadFromAMap() async throws {
        let (client, _) = StubProtocol.client { _ in
            .json(#"""
            {"stulp:app:com.stulp.virtualdevices:switch":{"id":"stulp:app:com.stulp.virtualdevices:switch",
             "ownerUri":"stulp:app:com.stulp.virtualdevices","ownerName":"Virtuele apparaten","name":"Virtuele schakelaar",
             "class":"other","ready":true,"pair":true,"pairViews":[{"id":"name"},{"id":"list_devices","template":"list_devices"}],
             "settings":[],"customPairViews":["name"]}}
            """#)
        }
        let driver = try #require(try await client.drivers().first)
        #expect(driver.appId == "com.stulp.virtualdevices")
        #expect(driver.driverName == "switch")
        #expect(driver.pairViews == ["name", "list_devices"])
        #expect(driver.startsWithCustomView)
    }
}

@Suite("Matter-koppeling")
struct MatterCommissioningTests {
    /// Stulp's side of an iPhone pairing: open, commission, poll until done, list, add, close.
    @Test func commissionsAndCloses() async throws {
        let polls = Counter()
        let (client, host) = StubProtocol.client { seen in
            switch (seen.method, seen.path) {
            case ("POST", "/api/stulp/pair"):
                return .json(#"{"id":"p1","handlers":["commission","commission_state","list_devices"]}"#, status: 201)
            case ("POST", "/api/stulp/pair/p1/emit/commission"):
                return .json(#"{"running":true}"#)
            case ("POST", "/api/stulp/pair/p1/emit/commission_state"):
                return polls.next() < 2 ? .json(#"{"running":true}"#) : .json(#"{"running":false,"found":1}"#)
            case ("POST", "/api/stulp/pair/p1/emit/list_devices"):
                return .json(#"[{"name":"Lamp","data":{"node":"0x12"}}]"#)
            case ("POST", "/api/stulp/apps/com.stulp.matter/drivers/matter/pair/devices"):
                return .json(#"{"id":"d1","name":"Lamp","capabilitiesObj":{}}"#, status: 201)
            default:
                return .json("true")
            }
        }
        let devices = try await MatterCommissioning(client: client, pollInterval: .milliseconds(1))
            .commission(onboardingPayload: " MT:Y.K90AFN00KA0648G00 ")
        #expect(devices == [PendingMatterDevice(id: "d1", name: "Lamp")])
        let seen = StubProtocol.requests(host)
        #expect(seen.first(where: { $0.path.hasSuffix("/emit/commission") })?.json == ["code": "MT:Y.K90AFN00KA0648G00", "address": ""])
        #expect(seen.first(where: { $0.path.hasSuffix("/pair/devices") })?.json == ["name": "Lamp", "data": ["node": "0x12"]])
        #expect(seen.last?.method == "DELETE")
        #expect(seen.last?.path == "/api/stulp/pair/p1")
    }

    @Test func aWarningFailsAndStillCloses() async throws {
        let (client, host) = StubProtocol.client { seen in
            switch seen.path {
            case "/api/stulp/pair":
                .json(#"{"id":"p2","handlers":["commission","commission_state","list_devices"]}"#)
            case "/api/stulp/pair/p2/emit/commission":
                .json(#"{"running":false,"warning":"PASE mislukt"}"#)
            default:
                .json("true")
            }
        }
        await #expect(throws: StulpClientError.commissioningFailed("PASE mislukt")) {
            try await MatterCommissioning(client: client, pollInterval: .milliseconds(1)).commission(onboardingPayload: "MT:X")
        }
        #expect(StubProtocol.requests(host).contains { $0.method == "DELETE" && $0.path == "/api/stulp/pair/p2" })
    }

    @Test func anOldMatterAppIsRefused() async throws {
        let (client, host) = StubProtocol.client { seen in
            seen.path == "/api/stulp/pair" ? .json(#"{"id":"p3","handlers":["list_devices"]}"#) : .json("true")
        }
        await #expect(throws: StulpClientError.incompatibleMatterApp) {
            try await MatterCommissioning(client: client).commission(onboardingPayload: "MT:X")
        }
        #expect(StubProtocol.requests(host).contains { $0.method == "DELETE" && $0.path == "/api/stulp/pair/p3" })
    }

    @Test func anEmptyPayloadNeverReachesStulp() async {
        let (client, host) = StubProtocol.client { _ in .json("true") }
        await #expect(throws: StulpClientError.missingOnboardingPayload) {
            try await MatterCommissioning(client: client).commission(onboardingPayload: "  ")
        }
        #expect(StubProtocol.requests(host).isEmpty)
    }

    @Test func foundIsReadInBothShapes() {
        #expect(CommissionState(["running": false, "found": 2]).found == 2)
        #expect(CommissionState(["running": false, "found": ["found": 3]]).found == 3)
    }
}

/// A thread-safe counter for stub handlers.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.withLock {
            defer { value += 1 }
            return value
        }
    }
}
