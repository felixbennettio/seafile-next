import XCTest

@MainActor final class LoginTests: XCTestCase {
    func testServerAddressIsAnEmptyEditableFullWidthField() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-signed-out", "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        app.buttons["Add account"].firstMatch.click()
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
        app.buttons["Add account"].firstMatch.click()
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
        XCTAssertTrue(app.staticTexts["My documents"].waitForExistence(timeout: 15))
    }
}
