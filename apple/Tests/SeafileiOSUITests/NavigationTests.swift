import XCTest

@MainActor final class NavigationTests: XCTestCase {
    func testWikiCommentsPostReplyResolveAndDeleteThroughOriginalServerAPI() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-test-signed-in"]; app.launch()
        XCTAssertTrue(app.buttons["libraries.browse"].waitForExistence(timeout: 15)); app.buttons["libraries.browse"].tap()
        app.buttons["wiki.browse"].tap()
        let pages = app.descendants(matching: .any)["wiki.pages.00000000-0000-4000-8000-000000000001"].firstMatch
        XCTAssertTrue(pages.waitForExistence(timeout: 10)); pages.tap()
        let comments = app.buttons["comments.open.Ab12"]
        XCTAssertTrue(comments.waitForExistence(timeout: 10)); comments.tap()
        let input = app.textViews["comments.text"]
        XCTAssertTrue(input.waitForExistence(timeout: 10)); input.tap(); input.typeText("Native comment <safe> & text")
        app.buttons["comments.send"].tap()
        XCTAssertTrue(app.staticTexts["Native comment <safe> & text"].waitForExistence(timeout: 10))
        app.buttons["comments.reply.2"].tap(); input.tap(); input.typeText("Native reply")
        app.buttons["comments.send"].tap()
        XCTAssertTrue(app.staticTexts["Native reply"].waitForExistence(timeout: 10))
        app.buttons["comments.resolve.2"].tap()
        XCTAssertTrue(app.staticTexts["Resolved"].waitForExistence(timeout: 10))
        app.buttons["comments.delete.2"].tap()
        let confirmDelete = app.buttons["comments.confirmDelete"]
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 5)); confirmDelete.tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: app.staticTexts["Native comment <safe> & text"]); waitForExpectations(timeout: 10)
        XCTAssertTrue(app.staticTexts["Initial comment"].exists)
        attachScreen(app, name: "Wiki comments preserve other discussions after deleting a thread")
    }
    func testWikiListsOldAndGroupContentAndKeepsManagementChangesAfterRefresh() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-test-signed-in"]; app.launch()
        XCTAssertTrue(app.buttons["libraries.browse"].waitForExistence(timeout: 15)); app.buttons["libraries.browse"].tap()
        app.buttons["wiki.browse"].tap()
        XCTAssertTrue(app.staticTexts["Team wiki"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Group wiki"].exists); XCTAssertTrue(app.staticTexts["Older handbook"].exists)
        let actions = app.buttons["wiki.actions.wiki:00000000-0000-4000-8000-000000000001"]
        actions.tap(); app.buttons["wiki.rename"].tap()
        let field = app.textFields["namePrompt.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap()
        field.press(forDuration: 1.2)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        else { field.tap(withNumberOfTaps: 3, numberOfTouches: 1) }
        field.typeText("Updated handbook")
        app.buttons["namePrompt.save"].tap()
        XCTAssertTrue(app.staticTexts["Updated handbook"].waitForExistence(timeout: 10))
        actions.tap(); app.buttons["wiki.publish"].tap()
        let suffix = app.textFields["wiki.suffix"]
        XCTAssertTrue(suffix.waitForExistence(timeout: 5)); suffix.tap(); suffix.typeText("team-handbook")
        app.buttons["wiki.confirmPublish"].tap()
        let wiki = app.descendants(matching: .any)["wiki.open.wiki:00000000-0000-4000-8000-000000000001"].firstMatch
        expectation(for: NSPredicate(format: "value == 'Published'"), evaluatedWith: wiki)
        waitForExpectations(timeout: 10)
        actions.tap(); app.buttons["wiki.unpublish"].tap(); app.buttons.matching(identifier: "Unpublish").allElementsBoundByIndex.last?.tap()
        XCTAssertTrue(app.staticTexts["Updated handbook"].waitForExistence(timeout: 10))
        actions.tap(); app.buttons["wiki.delete"].tap(); app.buttons.matching(identifier: "Delete").allElementsBoundByIndex.last?.tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: app.staticTexts["Updated handbook"])
        waitForExpectations(timeout: 10)
        XCTAssertTrue(app.staticTexts["Older handbook"].exists)
        attachScreen(app, name: "Native Wiki management preserves legacy and group content")
    }
    func testChineseNewFileLabelsCreateAnEditableFile() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-signed-in", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let library = app.staticTexts["My documents"]
        XCTAssertTrue(library.waitForExistence(timeout: 15)); library.tap()
        app.buttons["directory.actions"].tap()
        let create = app.buttons["directory.newFile"]
        XCTAssertEqual(create.label, "新建文件"); create.tap()
        XCTAssertTrue(app.navigationBars["新建文件"].waitForExistence(timeout: 5))
        let name = app.textFields["namePrompt.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("chinese-ui.txt")
        let save = app.buttons["namePrompt.save"]
        XCTAssertEqual(save.label, "保存"); save.tap()
        XCTAssertTrue(app.buttons["file./chinese-ui.txt"].waitForExistence(timeout: 10))
        attachScreen(app, name: "Chinese new-file controls create the chosen file")
    }

    func testNewFileUsesTheServersUniqueNameAndKeepsTheOriginal() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-test-signed-in"]; app.launch()
        XCTAssertTrue(app.staticTexts["My documents"].waitForExistence(timeout: 15)); app.staticTexts["My documents"].tap()
        XCTAssertTrue(app.buttons["file./welcome.txt"].waitForExistence(timeout: 10))
        app.buttons["directory.actions"].tap(); app.buttons["directory.newFile"].tap()
        let name = app.textFields["namePrompt.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("welcome.txt")
        app.buttons["namePrompt.save"].tap()
        XCTAssertTrue(app.buttons["file./welcome(1).txt"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["file./welcome.txt"].exists)
        XCTAssertEqual(app.staticTexts["directory.createdFile"].label, "Created welcome(1).txt")
        attachScreen(app, name: "New file keeps an existing file and displays the server's unique name")
    }
    func testHEICBackupCanUseJPEGWithoutRepeatingOrChangingExistingBackups() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-test-signed-in", "--ui-test-jpeg-backup"]; app.launch()
        XCTAssertTrue(app.staticTexts["My documents"].waitForExistence(timeout: 15))
        app.buttons["settings.open"].tap()
        let account = app.buttons["backup.account.first@fixture.invalid"]
        if !account.isHittable { app.swipeUp() }
        XCTAssertTrue(account.waitForExistence(timeout: 5)); account.tap()
        app.buttons["backup.destination"].tap()
        let choose = app.buttons["backup.choose"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5)); choose.tap()
        app.switches["backup.liveVideo"].switches.firstMatch.tap()
        app.switches["backup.jpeg"].switches.firstMatch.tap()
        app.switches["backup.enabled"].switches.firstMatch.tap()
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Photo backup is up to date"].waitForExistence(timeout: 30))
        XCTAssertEqual(app.staticTexts["backup.completed"].label, "1 resources backed up")
        app.buttons["backup.run"].tap()
        XCTAssertTrue(app.staticTexts["Photo backup is up to date"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["backup.completed"].label, "1 resources backed up")
        if !app.switches["backup.jpeg"].isHittable { app.swipeDown() }
        app.switches["backup.jpeg"].switches.firstMatch.tap()
        app.buttons["Save options"].tap()
        if !app.staticTexts["backup.completed"].isHittable { app.swipeUp() }
        let two = NSPredicate(format: "label == %@", "2 resources backed up")
        expectation(for: two, evaluatedWith: app.staticTexts["backup.completed"])
        waitForExpectations(timeout: 30)
        app.buttons["backup.run"].tap()
        XCTAssertTrue(app.staticTexts["Photo backup is up to date"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["backup.completed"].label, "2 resources backed up")
        attachScreen(app, name: "HEIC backup converts to JPEG without duplicate uploads")
        app.navigationBars["Photo backup"].buttons["Done"].tap()
        app.navigationBars["Settings"].buttons["Done"].tap()
        app.staticTexts["My documents"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'file./IMG_0001_' AND identifier ENDSWITH '.jpg'")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'file./IMG_0001_' AND identifier ENDSWITH '.heic'")).firstMatch.exists)
    }
    func testImageGalleryStartsAtTheSelectedPhotoAndCanNavigateWithoutUnstarring() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-test-signed-in", "--ui-test-media"]; app.launch()
        let library = app.staticTexts["My documents"]
        XCTAssertTrue(library.waitForExistence(timeout: 15)); library.tap()
        let second = app.buttons["file./photo-two.png"]
        XCTAssertTrue(second.waitForExistence(timeout: 10)); second.tap()
        XCTAssertTrue(app.images["media.photo"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["media.position"].label, "2 of 2")
        XCTAssertFalse(app.buttons["media.next"].isEnabled)
        app.buttons["media.previous"].tap()
        XCTAssertTrue(app.navigationBars["photo-one.png"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.images["media.photo"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["media.position"].label, "1 of 2")
        app.buttons["media.actions"].tap(); app.buttons["File information"].tap()
        XCTAssertTrue(app.staticTexts["Dimensions, 16 × 16"].waitForExistence(timeout: 5))
        app.navigationBars["File information"].buttons["Done"].tap()
        app.buttons["media.actions"].tap(); app.buttons["Star"].tap()
        attachScreen(app, name: "Native image gallery with adjacent photo navigation")
        app.buttons["media.done"].tap()
        app.tabBars.buttons["Starred"].tap()
        XCTAssertTrue(app.buttons["starred./photo-one.png"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["starred./welcome.txt"].exists)
    }

    func testLegacyServerSignInCanBeCancelledBeforeUsingPasswordLogin() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-test-signed-out", "--ui-test-legacy-sso"]; app.launch()
        let addAccount = app.buttons["Add account"].firstMatch
        XCTAssertTrue(addAccount.waitForExistence(timeout: 10)); addAccount.tap()
        let server = app.textFields["login.server"]
        XCTAssertTrue(server.waitForExistence(timeout: 10)); server.tap(); server.typeText("https://fixture.invalid/seafile/")
        app.buttons["login.sso"].tap()
        let cancel = app.buttons["login.legacyCancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10)); cancel.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 10))
        app.textFields["login.email"].tap(); app.textFields["login.email"].typeText("first@fixture.invalid")
        app.secureTextFields["login.password"].tap(); app.secureTextFields["login.password"].typeText("fixture-password")
        XCTAssertTrue(app.buttons["login.passwordSignIn"].isEnabled)
        app.buttons["login.passwordSignIn"].tap()
        XCTAssertTrue(app.staticTexts["My documents"].waitForExistence(timeout: 15))
    }

    func testPhotoKitExportsAnActualSimulatorPhotoAndDoesNotBackItUpAgain() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-test-signed-in", "--ui-test-real-photos"]; app.launch()
        XCTAssertTrue(app.staticTexts["My documents"].waitForExistence(timeout: 15))
        app.buttons["settings.open"].tap()
        let account = app.buttons["backup.account.first@fixture.invalid"]
        if !account.isHittable { app.swipeUp() }
        XCTAssertTrue(account.waitForExistence(timeout: 5)); account.tap()
        // Xcode may run tests in a cloned simulator whose privacy database is
        // different from the one seeded by simctl. Exercise the real request.
        let access = app.buttons["backup.photoAccess"]
        if access.waitForExistence(timeout: 2) {
            access.tap()
            let permission = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow Full Access"]
            XCTAssertTrue(permission.waitForExistence(timeout: 10)); permission.tap()
        }
        guard app.staticTexts["All photos are accessible"].waitForExistence(timeout: 10) else {
            XCTFail("Photos access was not granted"); return
        }
        app.buttons["backup.destination"].tap()
        let choose = app.buttons["backup.choose"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5)); XCTAssertTrue(choose.isEnabled); choose.tap()
        let enabled = app.switches["backup.enabled"]
        enabled.switches.firstMatch.tap()
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Photo backup is up to date"].waitForExistence(timeout: 30))
        let count = app.staticTexts["backup.completed"]
        let resources = Int(count.label.components(separatedBy: " ").first ?? "0") ?? 0
        XCTAssertGreaterThanOrEqual(resources, 1)
        attachScreen(app, name: "Native PhotoKit exports the simulator's PNG resource")
        app.buttons["backup.run"].tap()
        XCTAssertTrue(app.staticTexts["Photo backup is up to date"].waitForExistence(timeout: 10))
        XCTAssertEqual(count.label, "\(resources) resources backed up")
        XCTAssertFalse(app.staticTexts["backup.error"].exists)
    }

    func testPhotoBackupUploadsPhotoVideoAndLivePairOnce() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-test-signed-in"]; app.launch()
        XCTAssertTrue(app.staticTexts["My documents"].waitForExistence(timeout: 15))
        app.buttons["settings.open"].tap()
        let account = app.buttons["backup.account.first@fixture.invalid"]
        if !account.isHittable { app.swipeUp() }
        XCTAssertTrue(account.waitForExistence(timeout: 5)); account.tap()
        app.buttons["backup.destination"].tap()
        let choose = app.buttons["backup.choose"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5)); XCTAssertTrue(choose.isEnabled); choose.tap()
        let videos = app.switches["backup.videos"]
        videos.switches.firstMatch.tap(); XCTAssertEqual(videos.value as? String, "1")
        let enabled = app.switches["backup.enabled"]
        enabled.switches.firstMatch.tap()
        let count = app.staticTexts["backup.completed"]
        // Form creates offscreen rows lazily. Query existence before asking
        // for a snapshot and scroll until the status section is materialized.
        for _ in 0..<3 {
            if count.exists && count.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Photo backup is up to date"].waitForExistence(timeout: 20))
        XCTAssertEqual(count.label, "3 resources backed up")
        attachScreen(app, name: "Phone backs up a photo, Live Photo pair and video")
        app.buttons["backup.run"].tap()
        XCTAssertTrue(app.staticTexts["Photo backup is up to date"].waitForExistence(timeout: 10))
        XCTAssertEqual(count.label, "3 resources backed up")
        XCTAssertFalse(app.staticTexts["backup.error"].exists)
    }

    func testNativeTextEditingUploadsTheEditAndPreviewLoadsTheNewContents() {
        let app = openProjects()
        let file = app.buttons["file./Projects/notes.txt"]
        file.press(forDuration: 1); app.buttons["Edit text"].tap()
        let editor = app.textViews["editor.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap(); editor.typeText("\nEditor fixture change")
        let save = app.buttons["editor.save"]
        XCTAssertTrue(save.isEnabled); save.tap()
        XCTAssertTrue(save.waitForNonExistence(timeout: 15))
        XCTAssertTrue(file.waitForExistence(timeout: 5)); file.tap()
        let content = app.textViews.matching(NSPredicate(format: "label CONTAINS %@", "Editor fixture change")).firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 10))
        attachScreen(app, name: "Phone text editing round trip")
    }

    func testAppLockCoversFilesAndSettingsUntilAuthenticated() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-signed-in", "--ui-test-app-lock"]
        app.launch()
        XCTAssertTrue(app.staticTexts["security.locked"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["My documents"].exists)
        app.buttons["security.unlock"].tap()
        XCTAssertTrue(app.staticTexts["My documents"].waitForExistence(timeout: 10))
        app.buttons["settings.open"].tap()
        let lock = app.buttons["Lock now"]
        XCTAssertTrue(lock.waitForExistence(timeout: 5)); lock.tap()
        XCTAssertTrue(app.staticTexts["security.locked"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Remove"].exists)
        attachScreen(app, name: "App lock covers the presented account settings")
        app.buttons["security.unlock"].tap()
        XCTAssertTrue(lock.waitForExistence(timeout: 5))
    }

    func testLibraryCreationAndConfirmedDeletionRefreshTheList() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-signed-in"]
        app.launch()
        XCTAssertTrue(app.staticTexts["My documents"].waitForExistence(timeout: 15))
        app.buttons["libraries.browse"].tap(); app.buttons["New library"].tap()
        let name = app.textFields["library.createName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Phone library")
        app.buttons["library.createConfirm"].tap()
        let library = app.staticTexts["Phone library"]
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        attachScreen(app, name: "Phone creates a server library")
        library.press(forDuration: 1); app.buttons["Delete library"].tap()
        XCTAssertTrue(app.staticTexts["This deletes the entire library and every file it contains from the server."].waitForExistence(timeout: 5))
        app.buttons["Delete library"].tap()
        XCTAssertTrue(library.waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["My documents"].exists)
    }

    func testBatchDeleteRemovesBothSelectedFilesWithoutOpeningPreview() {
        let app = openProjects()
        selectBothFiles(app)
        app.buttons["directory.selectedActions"].tap()
        app.buttons["Delete selected items"].tap()
        let confirm = app.buttons["batch.deleteConfirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        XCTAssertTrue(app.staticTexts["Empty folder"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["QLOverlayDoneButtonAccessibilityIdentifier"].exists)
        attachScreen(app, name: "Phone batch deletion refreshes the source folder")
    }

    func testBatchMoveUpdatesBothSourceAndDestination() {
        let app = openProjects()
        selectBothFiles(app)
        app.buttons["directory.selectedActions"].tap()
        app.buttons["Move to…"].tap()
        let perform = app.buttons["destination.perform"]
        XCTAssertTrue(perform.waitForExistence(timeout: 10)); XCTAssertTrue(perform.isEnabled); perform.tap()
        XCTAssertTrue(app.staticTexts["Empty folder"].waitForExistence(timeout: 10))
        app.navigationBars.buttons["My documents"].tap()
        XCTAssertTrue(app.staticTexts["notes.txt"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["todo.txt"].exists)
        attachScreen(app, name: "Phone batch move updates the root destination")
    }

    func testPartialBatchCopyRetriesOnlyTheUnconfirmedItem() {
        let app = openProjects(arguments: ["--ui-test-partial-mutation"])
        selectBothFiles(app)
        app.buttons["directory.selectedActions"].tap()
        app.buttons["Copy to…"].tap()
        let perform = app.buttons["destination.perform"]
        XCTAssertTrue(perform.waitForExistence(timeout: 10)); perform.tap()
        XCTAssertTrue(app.staticTexts["Completed 1 of 2"].waitForExistence(timeout: 10))
        XCTAssertFalse(perform.isEnabled)
        attachScreen(app, name: "A partial copy keeps its first completed item")
        let check = app.switches["destination.checked"]
        XCTAssertTrue(check.waitForExistence(timeout: 5)); check.switches.firstMatch.tap()
        XCTAssertEqual(check.value as? String, "1")
        XCTAssertTrue(perform.isEnabled); perform.tap()
        XCTAssertTrue(app.navigationBars["Projects"].waitForExistence(timeout: 10))
        app.navigationBars.buttons["My documents"].tap()
        XCTAssertTrue(app.staticTexts["notes.txt"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["todo.txt"].exists)
        attachScreen(app, name: "Retry skips the completed copy and finishes the remaining file")
    }

    func testShareLinkIncludesPasswordAndExpiration() {
        let app = openProjects()
        let file = app.buttons["file./Projects/notes.txt"]
        XCTAssertTrue(file.waitForExistence(timeout: 5)); file.press(forDuration: 1)
        app.buttons["Share…"].tap()
        let password = app.secureTextFields["share.password"]
        XCTAssertTrue(password.waitForExistence(timeout: 5)); password.tap(); password.typeText("fixture-link-password")
        let expires = app.switches["share.expires"]
        expires.switches.firstMatch.tap()
        XCTAssertEqual(expires.value as? String, "1")
        app.buttons["Create download link"].tap()
        let result = app.staticTexts["share.result"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertEqual(result.label, "https://fixture.invalid/seafile/d/fixture-share/")
        attachScreen(app, name: "Phone share link with password and expiration")
    }

    private func openProjects(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-signed-in"] + arguments
        app.launch()
        XCTAssertTrue(app.staticTexts["My documents"].waitForExistence(timeout: 15))
        app.staticTexts["My documents"].tap()
        XCTAssertTrue(app.staticTexts["Projects"].waitForExistence(timeout: 10)); app.staticTexts["Projects"].tap()
        XCTAssertTrue(app.staticTexts["notes.txt"].waitForExistence(timeout: 10))
        return app
    }

    private func selectBothFiles(_ app: XCUIApplication) {
        let select = app.buttons["directory.select"]
        XCTAssertTrue(select.waitForExistence(timeout: 5)); select.tap()
        for path in ["/Projects/notes.txt", "/Projects/todo.txt"] {
            let row = app.descendants(matching: .any).matching(identifier: "selection." + path).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        }
        XCTAssertTrue(app.buttons["directory.selectedActions"].waitForExistence(timeout: 5))
    }

    func testCommunityServerSearchOpensAResultOutsideTheCurrentListing() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-signed-in"]
        app.launch()
        XCTAssertTrue(app.staticTexts["My documents"].waitForExistence(timeout: 15))
        app.buttons["libraries.browse"].tap()
        app.buttons["Search server"].tap()
        let input = app.textFields["search.query"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap(); input.typeText("notes")
        let search = app.buttons["search.submit"]
        XCTAssertTrue(search.isEnabled); search.tap()
        let folder = app.buttons["search.result./Projects"]
        XCTAssertTrue(folder.waitForExistence(timeout: 10))
        folder.tap()
        XCTAssertTrue(app.navigationBars["Projects"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["notes.txt"].exists)
        attachScreen(app, name: "Community server search opens matching folder")
    }

    func testActivityOpensCommitDetailsAndItsLibrary() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-signed-in"]
        app.launch()
        XCTAssertTrue(app.staticTexts["My documents"].waitForExistence(timeout: 15))
        app.buttons["libraries.browse"].tap()
        app.buttons["Activity"].tap()
        let event = app.buttons["activity.event.fixture-commit"]
        XCTAssertTrue(event.waitForExistence(timeout: 10)); event.tap()
        XCTAssertTrue(app.navigationBars["Change details"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["/Projects/notes.txt"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["/new-file.txt"].exists)
        attachScreen(app, name: "Native phone activity and commit changes")
        app.buttons["Open library"].tap()
        XCTAssertTrue(app.staticTexts["welcome.txt"].waitForExistence(timeout: 10))
    }

    func testDownloadContinuesAfterLeavingItsDirectory() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-signed-in", "--ui-test-slow-transfer"]
        app.launch()
        XCTAssertTrue(app.staticTexts["My documents"].waitForExistence(timeout: 15))
        app.staticTexts["My documents"].tap()
        let file = app.buttons["file./welcome.txt"]
        XCTAssertTrue(file.waitForExistence(timeout: 10))
        file.tap()
        XCTAssertTrue(app.staticTexts["Downloading preview…"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["Libraries"].tap()
        app.tabBars.buttons["Transfers"].tap()
        let complete = app.buttons["transfers.fixtureComplete"]
        XCTAssertTrue(complete.waitForExistence(timeout: 5)); complete.tap()
        XCTAssertTrue(app.staticTexts["Completed"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["QLOverlayDoneButtonAccessibilityIdentifier"].exists)
        app.buttons["Preview"].tap()
        XCTAssertTrue(app.textViews["Welcome to the preview regression test."].waitForExistence(timeout: 10))
        attachScreen(app, name: "Transfer survives leaving directory")
    }

    func testSignedInPhoneOpensLibrariesAndBrowsesNestedFolders() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-signed-in"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Libraries"].waitForExistence(timeout: 15))
        let library = app.staticTexts["My documents"]
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        attachScreen(app, name: "Files after sign-in")
        library.tap()
        XCTAssertTrue(app.staticTexts["welcome.txt"].waitForExistence(timeout: 10))
        app.staticTexts["Projects"].tap()
        XCTAssertTrue(app.staticTexts["notes.txt"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["Projects"].exists)
        attachScreen(app, name: "Nested folder")
    }

    func testSwitchingAccountReturnsToItsLibraries() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-signed-in"]
        app.launch()
        XCTAssertTrue(app.staticTexts["My documents"].waitForExistence(timeout: 15))
        app.staticTexts["My documents"].tap()
        XCTAssertTrue(app.staticTexts["Projects"].waitForExistence(timeout: 10))
        app.staticTexts["Projects"].tap()
        XCTAssertTrue(app.staticTexts["notes.txt"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Accounts"].tap()
        let account = app.buttons["account.second@fixture.invalid"]
        XCTAssertTrue(account.waitForExistence(timeout: 5))
        account.tap()
        XCTAssertTrue(app.staticTexts["Second library"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["My documents"].exists)
        XCTAssertFalse(app.staticTexts["notes.txt"].exists)
        XCTAssertTrue(app.tabBars.buttons["Files"].isSelected)
    }

    func testSSOOnlyRequiresServerAddress() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-signed-out"]
        app.launch()
        let add = app.buttons["Add account"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        let server = app.textFields["login.server"]
        XCTAssertTrue(server.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["login.sso"].isEnabled)
        server.tap()
        server.typeText("https://cloud.example/seafile/")
        XCTAssertTrue(app.buttons["login.sso"].isEnabled)
        XCTAssertFalse(app.buttons["login.passwordSignIn"].isEnabled)
        app.swipeDown()
        attachScreen(app, name: "Browser SSO sign-in")
    }

    func testPasswordSignInOpensFilesInsteadOfAccountSidebar() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-signed-out"]
        app.launch()
        let add = app.buttons["Add account"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        let server = app.textFields["login.server"]
        XCTAssertTrue(server.waitForExistence(timeout: 5))
        server.tap(); server.typeText("https://fixture.invalid/seafile/")
        let email = app.textFields["login.email"]
        email.tap(); email.typeText("first@fixture.invalid")
        let password = app.secureTextFields["login.password"]
        password.tap(); password.typeText("fixture-password")
        app.buttons["login.passwordSignIn"].tap()
        XCTAssertTrue(app.navigationBars["Libraries"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["My documents"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["Files"].isSelected)
    }

    func testListingFailureIsVisibleInsteadOfEmptyLibraryPlaceholder() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-signed-in", "--ui-test-server-error"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Could not load libraries"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Try again"].exists)
        XCTAssertFalse(app.staticTexts["No libraries"].exists)
    }

    func testPreviewDoesNotUnstarFileAfterReloadingFavorites() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-signed-in"]
        app.launch()
        app.tabBars.buttons["Starred"].tap()
        let file = app.buttons["starred./welcome.txt"]
        XCTAssertTrue(file.waitForExistence(timeout: 15))
        file.tap()
        let close = app.buttons["QLOverlayDoneButtonAccessibilityIdentifier"]
        XCTAssertTrue(close.waitForExistence(timeout: 15))
        XCTAssertTrue(app.textViews["Welcome to the preview regression test."].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Remove from Starred?"].exists)
        close.tap()
        app.buttons["Refresh"].tap()
        XCTAssertTrue(file.waitForExistence(timeout: 10))
        attachScreen(app, name: "Starred file survives preview and server reload")
    }

    func testFolderCanBeStarredAndOpenedFromFavorites() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-signed-in"]
        app.launch()
        XCTAssertTrue(app.staticTexts["My documents"].waitForExistence(timeout: 15))
        app.staticTexts["My documents"].tap()
        let folder = app.staticTexts["Projects"]
        XCTAssertTrue(folder.waitForExistence(timeout: 10))
        folder.press(forDuration: 1)
        app.buttons["Star"].tap()
        app.tabBars.buttons["Starred"].tap()
        let favorite = app.buttons["starred./Projects/"]
        XCTAssertTrue(favorite.waitForExistence(timeout: 10))
        favorite.tap()
        XCTAssertTrue(app.navigationBars["Projects"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["notes.txt"].exists)
        attachScreen(app, name: "Starred folder opens its own contents")
    }

    func testFileRowCenterOpensPreview() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-signed-in"]
        app.launch()
        XCTAssertTrue(app.staticTexts["My documents"].waitForExistence(timeout: 15))
        app.staticTexts["My documents"].tap()
        let file = app.buttons["file./welcome.txt"]
        XCTAssertTrue(file.waitForExistence(timeout: 10))
        file.tap()
        let close = app.buttons["QLOverlayDoneButtonAccessibilityIdentifier"]
        XCTAssertTrue(close.waitForExistence(timeout: 15))
        XCTAssertTrue(app.textViews["Welcome to the preview regression test."].waitForExistence(timeout: 10))
        attachScreen(app, name: "File preview from row center")
        close.tap()
        XCTAssertTrue(file.waitForExistence(timeout: 10))
    }

    private func attachScreen(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
