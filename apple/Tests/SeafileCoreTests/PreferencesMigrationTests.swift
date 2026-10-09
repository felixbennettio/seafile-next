import Foundation
import Testing
@testable import SeafileCore

@Test func olderNetworkPreferencesRetainProxyAuthenticationAndDefaultToCertificateValidation() throws {
    let previous = Data(#"{"proxy":"http","host":"proxy.example.org","port":3128,"username":"test-user","password":"test-only-password"}"#.utf8)
    let restored = try JSONDecoder().decode(ClientNetworkSettings.self, from: previous)
    #expect(restored.proxy == .http && restored.host == "proxy.example.org" && restored.port == 3128)
    #expect(restored.username == "test-user" && restored.password == "test-only-password" && restored.verifyCertificates)
    #expect(try JSONDecoder().decode(ClientNetworkSettings.self, from: JSONEncoder().encode(restored)) == restored)
}

#if os(macOS)
@Test func olderDesktopPreferencesDoNotResetDockLanguageAndLimitsWhenOptionsAreAdded() throws {
    let previous = Data(#"{"hideDockIcon":true,"hideMainWindowWhenStarted":true,"notifySync":false,"downloadLimit":512,"uploadLimit":128,"computerName":"My Mac","language":"zh-Hans"}"#.utf8)
    let restored = try JSONDecoder().decode(DesktopPreferences.self, from: previous)
    #expect(restored.hideDockIcon && restored.hideMainWindowWhenStarted && !restored.notifySync)
    #expect(restored.downloadLimit == 512 && restored.uploadLimit == 128)
    #expect(restored.computerName == "My Mac" && restored.language == "zh-Hans")
    #expect(restored.finderIntegration && restored.deleteConfirmThreshold == 500 && !restored.syncWithExistingFolder)
    #expect(restored.daemonStrings["client_name"] == "My Mac" && restored.daemonStrings["notify_sync"] == "off")
    #expect(try JSONDecoder().decode(DesktopPreferences.self, from: JSONEncoder().encode(restored)) == restored)
}
#endif

@Test func preferenceMigrationStillRejectsDamagedTypesInsteadOfInventingProxySettings() throws {
    #expect(throws: Error.self) { try JSONDecoder().decode(ClientNetworkSettings.self, from: Data(#"{"port":"broken","proxy":"http"}"#.utf8)) }
    #if os(macOS)
    #expect(throws: Error.self) { try JSONDecoder().decode(DesktopPreferences.self, from: Data(#"{"hideDockIcon":"broken"}"#.utf8)) }
    #endif
}
