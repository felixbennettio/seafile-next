#if os(macOS)
import Foundation
import Testing
@testable import SeafileCore

@Test(.enabled(if: ProcessInfo.processInfo.environment["SEAFILE_TEST_DAEMON"] != nil))
func nativeRPCControlsThePackagedSyncEngine() async throws {
    let executable = try #require(ProcessInfo.processInfo.environment["SEAFILE_TEST_DAEMON"])
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sn-" + UUID().uuidString.prefix(8))
    for name in ["config/logs", "data", "worktrees"] {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = ["-c", root.appendingPathComponent("config").path, "-d", root.appendingPathComponent("data").path,
        "-w", root.appendingPathComponent("worktrees").path, "-l", root.appendingPathComponent("engine.log").path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer { if process.isRunning { process.terminate(); process.waitUntilExit() }; try? FileManager.default.removeItem(at: root) }
    let rpc = DaemonRPC(socketPath: root.appendingPathComponent("data/seafile.sock").path)
    var ready = false
    for _ in 0..<100 {
        if (try? await rpc.call("seafile_get_config", [.string("use_proxy")])) != nil { ready = true; break }
        try await Task.sleep(for: .milliseconds(100))
    }
    try #require(ready, "Packaged sync engine did not become ready")
    _ = try await rpc.call("seafile_set_config", [.string("client_name"), .string("Native regression test")])
    #expect(try await rpc.call("seafile_get_config", [.string("client_name")]) == .string("Native regression test"))
    _ = try await rpc.call("seafile_set_upload_rate_limit", [.integer(128 * 1024)])
    #expect(try await rpc.call("seafile_get_config_int", [.string("upload_limit")]) == .integer(128 * 1024))
    _ = try await rpc.call("seafile_set_download_rate_limit", [.integer(256 * 1024)])
    #expect(try await rpc.call("seafile_get_config_int", [.string("download_limit")]) == .integer(256 * 1024))
    _ = try await rpc.call("seafile_disable_auto_sync")
    #expect(try await rpc.call("seafile_is_auto_sync_enabled") == .integer(0))
    _ = try await rpc.call("seafile_enable_auto_sync")
    #expect(try await rpc.call("seafile_is_auto_sync_enabled") == .integer(1))
    for (name, arguments) in [("seafile_get_repo_list", [JSONValue.integer(0), .integer(-1)]),
                             ("seafile_get_clone_tasks", []), ("seafile_get_file_sync_errors", [.integer(0), .integer(-1)])] {
        let response = try await rpc.call(name, arguments)
        #expect(response == .null || response == .array([]))
    }
    #expect(try await rpc.call("seafile_get_sync_notification") == .null)
}
#endif
