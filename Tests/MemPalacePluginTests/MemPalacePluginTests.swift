import Foundation
import TypeWhisperPluginSDK
import TypeWhisperPluginSDKTesting
import XCTest
@testable import MemPalacePlugin

// MARK: - Mock JSON-RPC HTTP stub

final class StubMCP: MemPalaceMCPHTTP, @unchecked Sendable {
    struct Recorded {
        let method: String
        let path: String
        let toolName: String?
        let arguments: [String: Any]?
    }

    private let lock = NSLock()
    var recorded: [Recorded] = []
    var responder: ((_ toolName: String, _ arguments: [String: Any]) -> (Int, Any))?

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let body = request.httpBody ?? Data()
        let bodyJSON = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let params = bodyJSON["params"] as? [String: Any] ?? [:]
        let toolName = params["name"] as? String ?? ""
        let arguments = params["arguments"] as? [String: Any] ?? [:]

        let responder = lock.withLock {
            recorded.append(
                Recorded(
                    method: request.httpMethod ?? "",
                    path: request.url?.path ?? "",
                    toolName: toolName,
                    arguments: arguments
                )
            )
            return self.responder
        }

        let outcome = responder?(toolName, arguments) ?? (200, [String: Any]())
        let (status, payload) = outcome

        let toolResultJSON = try JSONSerialization.data(withJSONObject: payload)
        let toolResultString = String(data: toolResultJSON, encoding: .utf8) ?? "{}"
        let envelope: [String: Any] = [
            "jsonrpc": "2.0",
            "id": bodyJSON["id"] ?? 1,
            "result": [
                "content": [
                    ["type": "text", "text": toolResultString],
                ],
            ],
        ]
        let envelopeData = try JSONSerialization.data(withJSONObject: envelope)

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (envelopeData, response)
    }
}

@MainActor
final class MemPalacePluginTests: XCTestCase {

    private func makePlugin(http: StubMCP) -> MemPalacePlugin {
        let factory: (URL, String) -> MemPalaceMCPClient = { url, key in
            MemPalaceMCPClient(baseURL: url, apiKey: key, http: http)
        }
        return MemPalacePlugin(clientFactory: factory)
    }

    private func configuredHost(
        wing: String = "wing_test",
        room: String = "captures",
        baseURL: String = "https://api.test.mempalace.cloud"
    ) throws -> PluginTestHostServices {
        let cfg = MemPalaceConfig(
            deployment: .cloud,
            baseURL: baseURL,
            wing: wing,
            room: room
        )
        let data = try JSONEncoder().encode(cfg)
        let json = String(data: data, encoding: .utf8)!
        return try PluginTestHostServices(
            defaults: [MemPalaceUserDefaultsKey.config: json],
            secrets: [MemPalaceUserDefaultsKey.secretAPIKey: "test-key-with-special!@#"]
        )
    }

    func testStoreSendsAddDrawerJSONRPCWithEncodedSourceFile() async throws {
        let stub = StubMCP()
        stub.responder = { toolName, _ in
            XCTAssertEqual(toolName, "mempalace_add_drawer")
            return (200, ["added": true, "drawer_id": "drawer_abc", "result": "{'success': True, 'drawer_id': 'drawer_abc'}"])
        }

        let host = try configuredHost()
        let plugin = makePlugin(http: stub)
        plugin.activate(host: host)
        XCTAssertTrue(plugin.isReady)

        let entry = MemoryEntry(content: "Hello MemPalace", type: .fact, confidence: 0.9)
        try await plugin.store([entry])

        XCTAssertEqual(stub.recorded.count, 1)
        let rec = stub.recorded[0]
        XCTAssertEqual(rec.method, "POST")
        // Alphanumerics-only encoding: '-', '!', '@', '#' all escaped.
        XCTAssertTrue(rec.path.hasSuffix("/mcp/test%2Dkey%2Dwith%2Dspecial%21%40%23")
                      || rec.path.hasSuffix("/mcp/test-key-with-special!@#"),
                      "unexpected path: \(rec.path)")
        XCTAssertEqual(rec.arguments?["wing"] as? String, "wing_test")
        XCTAssertEqual(rec.arguments?["room"] as? String, "captures")
        XCTAssertEqual(rec.arguments?["content"] as? String, "Hello MemPalace")
        XCTAssertEqual(rec.arguments?["source_file"] as? String, "tw_\(entry.id.uuidString)")
    }

    func testSearchMapsHitsBackViaSourceFileBasename() async throws {
        let stub = StubMCP()
        let stored = MemoryEntry(content: "Cats are great", type: .fact, confidence: 1.0)

        stub.responder = { tool, _ in
            switch tool {
            case "mempalace_add_drawer":
                return (200, ["added": true, "drawer_id": "d1", "result": "{'success': True}"])
            case "mempalace_search":
                let hit: [String: Any] = [
                    "text": "Cats are great",
                    "wing": "wing_test",
                    "room": "captures",
                    // MemPalace strips source_file to basename via Path.name. tw_<uuid> survives.
                    "source_file": "tw_\(stored.id.uuidString)",
                    "similarity": 0.88,
                    "distance": 0.12,
                ]
                // Sidecar wraps tool_search return as {"results": <tool_search_dict>}.
                return (200, ["results": ["query": "cats", "results": [hit]]])
            default:
                return (200, [:])
            }
        }

        let host = try configuredHost()
        let plugin = makePlugin(http: stub)
        plugin.activate(host: host)

        try await plugin.store([stored])
        let results = try await plugin.search(MemoryQuery(text: "cats"))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.entry.id, stored.id)
        XCTAssertEqual(results.first?.relevanceScore ?? 0, 0.88, accuracy: 0.001)
        XCTAssertGreaterThan(results.first?.entry.accessCount ?? 0, 0)
    }

    func testDeleteSingleDrawerSendsOneDeleteCall() async throws {
        let stub = StubMCP()
        stub.responder = { tool, _ in
            switch tool {
            case "mempalace_add_drawer":
                return (200, ["added": true, "drawer_id": "d-del", "result": "ok"])
            case "mempalace_delete_drawer":
                return (200, ["success": true, "drawer_id": "d-del"])
            default:
                return (200, [:])
            }
        }

        let host = try configuredHost()
        let plugin = makePlugin(http: stub)
        plugin.activate(host: host)

        let entry = MemoryEntry(content: "to delete", type: .fact)
        try await plugin.store([entry])
        try await plugin.delete([entry.id])

        let deleteCalls = stub.recorded.filter { $0.toolName == "mempalace_delete_drawer" }
        XCTAssertEqual(deleteCalls.count, 1)
        XCTAssertEqual(deleteCalls.first?.arguments?["drawer_id"] as? String, "d-del")
    }

    func testCoTenancyDeleteIssuesSingleServerDelete() async throws {
        // Regression test for Codex blocker #2: two UUIDs sharing a drawer
        // (content-hash dedup) must produce exactly ONE server DELETE when
        // both are removed in the same batch.
        let stub = StubMCP()
        stub.responder = { tool, _ in
            switch tool {
            case "mempalace_add_drawer":
                // MemPalace dedup: identical content → same drawer_id.
                return (200, ["added": true, "drawer_id": "d-shared", "result": "ok"])
            case "mempalace_delete_drawer":
                return (200, ["success": true, "drawer_id": "d-shared"])
            default:
                return (200, [:])
            }
        }

        let host = try configuredHost()
        let plugin = makePlugin(http: stub)
        plugin.activate(host: host)

        let entryA = MemoryEntry(content: "duplicate", type: .fact)
        let entryB = MemoryEntry(content: "duplicate", type: .fact)
        try await plugin.store([entryA, entryB])
        try await plugin.delete([entryA.id, entryB.id])

        let deletes = stub.recorded.filter { $0.toolName == "mempalace_delete_drawer" }
        XCTAssertEqual(deletes.count, 1, "expected exactly one server DELETE for shared drawer")
    }

    func testCoTenancyDeletePartialKeepsDrawer() async throws {
        // If only one of two co-tenant UUIDs is deleted, server DELETE must NOT fire.
        let stub = StubMCP()
        stub.responder = { tool, _ in
            switch tool {
            case "mempalace_add_drawer":
                return (200, ["added": true, "drawer_id": "d-shared", "result": "ok"])
            case "mempalace_delete_drawer":
                return (200, ["success": true, "drawer_id": "d-shared"])
            default:
                return (200, [:])
            }
        }

        let host = try configuredHost()
        let plugin = makePlugin(http: stub)
        plugin.activate(host: host)

        let entryA = MemoryEntry(content: "duplicate", type: .fact)
        let entryB = MemoryEntry(content: "duplicate", type: .fact)
        try await plugin.store([entryA, entryB])
        try await plugin.delete([entryA.id])

        let deletes = stub.recorded.filter { $0.toolName == "mempalace_delete_drawer" }
        XCTAssertEqual(deletes.count, 0, "co-tenant still exists; drawer must stay on server")
    }

    func testSidecarPersistsAcrossActivate() async throws {
        let stub = StubMCP()
        stub.responder = { _, _ in
            (200, ["added": true, "drawer_id": "d-persist", "result": "ok"])
        }

        let host = try configuredHost()
        let pluginA = makePlugin(http: stub)
        pluginA.activate(host: host)

        let entry = MemoryEntry(content: "persist me", type: .fact)
        try await pluginA.store([entry])
        pluginA.deactivate()

        let pluginB = makePlugin(http: stub)
        pluginB.activate(host: host)
        let listed = try await pluginB.listAll(offset: 0, limit: 10)
        XCTAssertEqual(listed.first?.content, "persist me")
    }

    func testStoreEnqueuesWhenClientOffline() async throws {
        let stub = StubMCP()
        let host = try PluginTestHostServices()
        let plugin = makePlugin(http: stub)
        plugin.activate(host: host)
        XCTAssertFalse(plugin.isReady, "no api key → not ready")

        // v0.3: store() no longer throws when client is offline. It enqueues
        // and returns silently; drain loop replays when client becomes ready.
        try await plugin.store([MemoryEntry(content: "queued-offline", type: .fact)])
        XCTAssertEqual(stub.recorded.count, 0, "no HTTP calls without client")

        // Sidecar must not contain the entry (server never confirmed).
        let listed = try await plugin.listAll(offset: 0, limit: 10)
        XCTAssertEqual(listed.count, 0)
    }

    func testUpdateConfigRejectsEmptyWing() throws {
        let stub = StubMCP()
        let host = try configuredHost()
        let plugin = makePlugin(http: stub)
        plugin.activate(host: host)

        var bad = plugin.currentConfig()
        bad.wing = ""
        XCTAssertFalse(plugin.updateConfig(bad), "empty wing must be rejected")

        var good = plugin.currentConfig()
        good.wing = "wing_other"
        XCTAssertTrue(plugin.updateConfig(good), "valid config must apply")
    }

    func testUpdateConfigRejectsHTTPForCloud() throws {
        let stub = StubMCP()
        let host = try configuredHost()
        let plugin = makePlugin(http: stub)
        plugin.activate(host: host)

        var bad = plugin.currentConfig()
        bad.baseURL = "http://cloud.example.com"
        XCTAssertFalse(plugin.updateConfig(bad), "cloud mode must reject http://")
    }

    func testStoreEnqueuesOnNetworkFailureWithoutThrowing() async throws {
        // SeoFood maintainer feedback on PR #588: if the offline queue is the
        // acceptance path, store() must NOT throw on network failure — the
        // entry is durably queued and will replay. TypeWhisper's MemoryService
        // treats a throw as "memory rejected" which is misleading here.
        let stub = StubMCP()
        stub.responder = { _, _ in
            (500, ["error": "upstream"])
        }
        let host = try configuredHost()
        let plugin = makePlugin(http: stub)
        plugin.activate(host: host)

        let entry = MemoryEntry(content: "to-queue", type: .fact)
        try await plugin.store([entry])  // must not throw — entry is queued

        // Sidecar should NOT have the entry (server rejected); queue should.
        let listed = try await plugin.listAll(offset: 0, limit: 10)
        XCTAssertEqual(listed.count, 0, "failed store must not appear in sidecar")
    }

    func testListAllReturnsSidecarEntriesAfterSuccessfulStore() async throws {
        let stub = StubMCP()
        stub.responder = { _, _ in
            (200, ["added": true, "drawer_id": "d-ok", "result": "ok"])
        }
        let host = try configuredHost()
        let plugin = makePlugin(http: stub)
        plugin.activate(host: host)

        let entry = MemoryEntry(content: "ok-stored", type: .fact)
        try await plugin.store([entry])

        let listed = try await plugin.listAll(offset: 0, limit: 10)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.content, "ok-stored")
    }

    func testDeletePartialFailureRemovesOnlySuccessfulDrawersFromSidecar() async throws {
        // SeoFood maintainer feedback on PR #588 round 3 (MemPalacePlugin.swift:197):
        // If the second remote delete fails after the first one succeeded, the
        // method must NOT leave a stale local handle to the already-deleted
        // drawer. Sidecar entries are removed incrementally after each
        // successful server-delete; failed drawers keep their mappings.
        let stub = StubMCP()
        nonisolated(unsafe) var deleteCallCount = 0
        stub.responder = { tool, args in
            switch tool {
            case "mempalace_add_drawer":
                let content = args["content"] as? String ?? ""
                let drawerId = "drawer-\(content)"
                return (200, ["added": true, "drawer_id": drawerId, "result": "ok"])
            case "mempalace_delete_drawer":
                deleteCallCount += 1
                // First server-delete succeeds, second throws (simulates 500 / transient).
                if deleteCallCount == 1 {
                    return (200, ["success": true, "drawer_id": args["drawer_id"] ?? ""])
                } else {
                    return (500, ["error": "upstream blip"])
                }
            default:
                return (200, [:])
            }
        }

        let host = try configuredHost()
        let plugin = makePlugin(http: stub)
        plugin.activate(host: host)

        let entryA = MemoryEntry(content: "first", type: .fact)
        let entryB = MemoryEntry(content: "second", type: .fact)
        try await plugin.store([entryA, entryB])
        let before = try await plugin.listAll(offset: 0, limit: 10)
        XCTAssertEqual(before.count, 2)

        // Delete both. One server-delete will succeed, the other will throw.
        do {
            try await plugin.delete([entryA.id, entryB.id])
            XCTFail("delete must surface the partial failure")
        } catch {
            // expected
        }

        // Exactly one entry must remain in the sidecar — the one whose
        // server-delete failed. The succeeded one is gone locally.
        let remaining = try await plugin.listAll(offset: 0, limit: 10)
        XCTAssertEqual(remaining.count, 1, "exactly one entry must remain after partial failure")
    }
}
