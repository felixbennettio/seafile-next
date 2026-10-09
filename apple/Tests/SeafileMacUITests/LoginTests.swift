import XCTest

@MainActor final class LoginTests: XCTestCase {
    func testChineseLoginKeepsEditableFieldsAndTranslatedControls() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-signed-out", "-ApplePersistenceIgnoreState", "YES", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let addAccount = app.buttons["account.add"]
        XCTAssertTrue(addAccount.waitForExistence(timeout: 10)); XCTAssertEqual(addAccount.label, "添加账号"); addAccount.click()
        let server = app.textFields["login.server"]
        XCTAssertTrue(server.waitForExistence(timeout: 10)); XCTAssertEqual(server.value as? String, "")
        server.click(); server.typeText("https://fixture.invalid/seafile/")
        XCTAssertEqual(server.value as? String, "https://fixture.invalid/seafile/")
        XCTAssertEqual(app.buttons["login.sso"].label, "使用 SSO 登录")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Chinese login retains left aligned editable server field"; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    func testLegacyServerSignInCanBeCancelledBeforeUsingPasswordLogin() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-signed-out", "--ui-test-legacy-sso", "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["account.add"].waitForExistence(timeout: 10)); app.buttons["account.add"].click()
        let server = app.textFields["login.server"]
        XCTAssertTrue(server.waitForExistence(timeout: 10)); server.click(); server.typeText("https://fixture.invalid/seafile/")
        app.buttons["login.sso"].click()
        let cancel = app.buttons["login.legacyCancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10)); cancel.click()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 10))
        app.textFields["login.email"].click(); app.textFields["login.email"].typeText("first@fixture.invalid")
        app.secureTextFields["login.password"].click(); app.secureTextFields["login.password"].typeText("fixture-password")
        XCTAssertTrue(app.buttons["login.passwordSignIn"].isEnabled)
        app.buttons["login.passwordSignIn"].click()
        XCTAssertTrue(app.descendants(matching: .any)["library.first-repo"].firstMatch.waitForExistence(timeout: 15))
    }

    func testServerAddressIsAnEmptyEditableFullWidthField() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-signed-out", "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        let addAccount = app.buttons["account.add"]
        XCTAssertTrue(addAccount.waitForExistence(timeout: 10))
        addAccount.click()
        let server = app.textFields["login.server"]
        XCTAssertTrue(server.waitForExistence(timeout: 10))
        XCTAssertEqual(server.value as? String, "")
        XCTAssertFalse(app.links["https://cloud.example.com/seafile/"].exists)
        XCTAssertGreaterThan(server.frame.width, 300)
        server.click()
        server.typeText("https://fixture.invalid/seafile/")
        XCTAssertEqual(server.value as? String, "https://fixture.invalid/seafile/")
        XCTAssertTrue(app.buttons["login.sso"].isEnabled)
        XCTAssertFalse(app.buttons["login.passwordSignIn"].isEnabled)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Editable server address with visible input boundary"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testAllAccountFieldsCanBeEditedAndPasswordLoginOpensLibraries() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-signed-out", "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        let addAccount = app.buttons["account.add"]
        XCTAssertTrue(addAccount.waitForExistence(timeout: 10))
        addAccount.click()
        let server = app.textFields["login.server"]
        XCTAssertTrue(server.waitForExistence(timeout: 10))
        server.click(); server.typeText("https://fixture.invalid/seafile/")
        let email = app.textFields["login.email"]
        email.click(); email.typeText("first@fixture.invalid")
        let password = app.secureTextFields["login.password"]
        password.click(); password.typeText("fixture-password")
        let otp = app.textFields["login.otp"]
        otp.click(); otp.typeText("123456")
        XCTAssertEqual(otp.value as? String, "123456")
        app.buttons["login.passwordSignIn"].click()
        XCTAssertTrue(app.descendants(matching: .any)["library.first-repo"].firstMatch.waitForExistence(timeout: 15))
    }
}

@MainActor final class DesktopFeatureTests: XCTestCase {
    func testNewFileUsesTheServersUniqueNameAndKeepsTheOriginal() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-test-signed-in", "-ApplePersistenceIgnoreState", "YES"]; app.launch()
        let library = app.descendants(matching: .any)["library.first-repo"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 15)); library.click()
        let create = app.buttons["directory.newFile"]
        XCTAssertTrue(create.waitForExistence(timeout: 10)); create.click()
        let name = app.textFields["namePrompt.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.click(); name.typeText("welcome.txt")
        app.buttons["namePrompt.save"].click()
        XCTAssertTrue(app.descendants(matching: .any)["file./welcome(1).txt"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["file./welcome.txt"].firstMatch.exists)
        XCTAssertEqual(app.staticTexts["directory.createdFile"].value as? String, "Created welcome(1).txt")
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Native Mac new-file action preserves existing files"
        screenshot.lifetime = .keepAlways; add(screenshot)
    }
    func testCloudDownloadSurvivesLeavingTheDirectory() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-signed-in", "--ui-test-slow-transfer", "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        let library = app.descendants(matching: .any)["library.first-repo"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 15)); library.click()
        let file = app.descendants(matching: .any)["file./welcome.txt"].firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 10))
        let windowCount = app.windows.count
        file.rightClick()
        app.menuItems["Preview"].click()
        XCTAssertTrue(app.staticTexts["Downloading preview…"].waitForExistence(timeout: 5))
        app.descendants(matching: .any)["transfers.sidebar"].firstMatch.click()
        let complete = app.buttons["transfers.fixtureComplete"]
        XCTAssertTrue(complete.waitForExistence(timeout: 5)); complete.click()
        XCTAssertTrue(app.staticTexts["Completed"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.windows.count, windowCount, "Leaving the directory must not open a late preview panel")
        XCTAssertTrue(app.staticTexts["welcome.txt"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Cloud download survives leaving directory"
        screenshot.lifetime = .keepAlways; add(screenshot)
    }

    func testNativeSettingsHaveDockAndProxyControls() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-signed-in", "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        let settings = app.buttons["settings.open"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.click()
        let hideDock = app.switches["settings.hideDock"]
        XCTAssertTrue(hideDock.waitForExistence(timeout: 10))
        XCTAssertTrue(app.switches["settings.autoStart"].exists)
        // Native forms scroll; proxy selection remains available below Sync.
        let proxy = app.popUpButtons["settings.proxy"]
        XCTAssertTrue(proxy.exists)
        proxy.click()
        app.menuItems["HTTP proxy"].click()
        let host = app.textFields["settings.proxyHost"]
        XCTAssertTrue(host.waitForExistence(timeout: 5))
        host.click(); host.typeText("127.0.0.1")
        XCTAssertGreaterThan(host.frame.width, 250)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Native Mac proxy controls"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testLibrariesHaveNativeCreateAndFileOperationMenus() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-signed-in", "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        let library = app.descendants(matching: .any)["library.first-repo"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["New library"].exists)
        library.click()
        let file = app.descendants(matching: .any)["file./welcome.txt"].firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 10))
        file.rightClick()
        XCTAssertTrue(app.menuItems["Open in default app"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuItems["Copy to…"].exists)
        XCTAssertTrue(app.menuItems["Move to…"].exists)
        XCTAssertTrue(app.menuItems["Lock file"].exists)
        XCTAssertTrue(app.menuItems["Download / Save as"].exists)
    }
}
