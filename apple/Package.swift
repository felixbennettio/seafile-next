// swift-tools-version: 6.0
import PackageDescription
import Foundation

// Allows API tests on machines with Command Line Tools but no SwiftUI build plugins.
let coreOnly = ProcessInfo.processInfo.environment["SEAFILE_CORE_ONLY"] == "1"
let package = Package(
    name: "SeafileNext",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "SeafileCore", targets: ["SeafileCore"])] +
        (coreOnly ? [] : [.executable(name: "seafile-next", targets: ["SeafileApp"])]),
    targets: [.target(name: "SeafileCore"), .testTarget(name: "SeafileCoreTests", dependencies: ["SeafileCore"])] +
        (coreOnly ? [] : [.executableTarget(name: "SeafileApp", dependencies: ["SeafileCore"])])
)
