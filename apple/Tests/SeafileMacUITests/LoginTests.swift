import XCTest

@MainActor final class LoginTests: XCTestCase {
    func testWikiSidebarLoadsOriginalCatalogAndPublishesOnlyAfterConfirmation() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-test-signed-in"]; app.launch()
        let sidebar = app.descendants(matching: .any)["wiki.sidebar"].firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 15)); sidebar.click()
        XCTAssertTrue(app.descendants(matching: .any)["wiki.open.wiki:00000000-0000-4000-8000-000000000001"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["wiki.open.wiki:00000000-0000-4000-8000-000000000002"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["wiki.open.legacy:8"].exists)
        let actions = app.descendants(matching: .any)["wiki.actions.wiki:00000000-0000-4000-8000-000000000001"].firstMatch
        XCTAssertTrue(actions.waitForExistence(timeout: 5)); actions.click()
        app.menuItems["Publish wiki"].click()
        let suffix = app.textFields["wiki.suffix"]
        XCTAssertTrue(suffix.waitForExistence(timeout: 5)); suffix.click(); suffix.typeText("mac-handbook")
        XCTAssertTrue(app.staticTexts["Publishing makes this wiki available to anyone with its address. Use 5–30 letters, numbers or hyphens."].exists)
        app.buttons["wiki.confirmPublish"].click()
        let wiki = app.descendants(matching: .any)["wiki.open.wiki:00000000-0000-4000-8000-000000000001"].firstMatch
        expectation(for: NSPredicate(format: "value == 'Published'"), evaluatedWith: wiki)
        waitForExpectations(timeout: 10)
    }
    func testWikiCommentsKeepUnconfirmedInputAndDoNotRepeatAnAcceptedPost() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-test-signed-in", "--ui-test-comment-response-lost"]; app.launch()
        let sidebar = app.descendants(matching: .any)["wiki.sidebar"].firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 15)); sidebar.click()
        let pages = app.descendants(matching: .any)["wiki.pages.00000000-0000-4000-8000-000000000001"].firstMatch
        XCTAssertTrue(pages.waitForExistence(timeout: 10)); pages.click()
        let comments = app.descendants(matching: .any)["comments.open.Ab12"].firstMatch
        XCTAssertTrue(comments.waitForExistence(timeout: 10)); comments.click()
        let input = app.textViews["comments.text"]
        XCTAssertTrue(input.waitForExistence(timeout: 10)); input.click(); input.typeText("Preserved after lost response")
        app.buttons["comments.send"].click()
        XCTAssertTrue(app.staticTexts["comments.error"].waitForExistence(timeout: 10))
        XCTAssertEqual(input.value as? String, "Preserved after lost response")
        XCTAssertEqual(app.staticTexts.matching(identifier: "Preserved after lost response").count, 1)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Comment input survives an uncertain submission"; attachment.lifetime = .keepAlways; add(attachment)
    }
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
