import XCTest

final class XHS_Downloader_iOSUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testTaskImageViewerHasOneCloseButton() throws {
        guard let fixture = ProcessInfo.processInfo.environment["XHS_UI_TEST_MEDIA_IDS"],
              let identifier = fixture.split(separator: ",").first.map(String.init) else {
            throw XCTSkip("Requires seeded simulator Photos identifiers")
        }
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                                "-disable-automatic-clipboard", "-ui-test-task-center"]
        app.launchEnvironment["XHS_UI_TEST_MEDIA_IDS"] = fixture
        app.launch()
        let row = app.descendants(matching: .any)["task-row-00000000-0000-0000-0000-000000000001"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.tap()
        let image = app.buttons["detail-media-\(identifier)"]
        XCTAssertTrue(image.waitForExistence(timeout: 5))
        image.tap()
        let close = app.buttons["viewer-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 8))
        attachScreenshot("task-image-viewer-close-controls")
        let navigationBar = app.navigationBars.firstMatch
        XCTAssertEqual(navigationBar.buttons.count, 1)
        XCTAssertTrue(close.isHittable)
        let canvas = app.scrollViews["viewer-zoom-canvas"]
        XCTAssertTrue(canvas.exists)
        app.buttons["viewer-zoom"].tap()
        XCTAssertEqual(canvas.value as? String, "250%")
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        XCTAssertTrue(image.waitForExistence(timeout: 3))
    }

    @MainActor
    func testAllSixNotesRemainVisibleAcrossRowsAndTabChanges() throws {
        executionTimeAllowance = 240
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                                "-disable-automatic-clipboard", "-ui-test-text-notes", "-ui-test-six-notes"]
        app.launch()
        app.tabBars.buttons["Notes"].tap()
        XCTAssertTrue(app.scrollViews["library-note-feed"].waitForExistence(timeout: 8))
        attachScreenshot("six-notes-first-row")
        for index in 1...6 {
            let card = app.buttons["library-item-note:text-fixture-\(index)"]
            if index % 2 == 1, index > 1 { app.scrollViews["library-note-feed"].swipeUp(velocity: .slow) }
            XCTAssertTrue(card.waitForExistence(timeout: 3), "Missing note \(index)")
            card.tap()
            XCTAssertTrue(app.buttons["note-close"].waitForExistence(timeout: 3))
            XCTAssertEqual(app.staticTexts["note-title"].label, "Text fixture \(index)")
            app.buttons["note-close"].tap()
        }
        attachScreenshot("six-notes-last-row")
        app.tabBars.buttons["Downloads"].tap()
        app.tabBars.buttons["Notes"].tap()
        app.buttons["library-select"].tap()
        app.buttons["library-enter-selection"].tap()
        app.buttons["library-select-all"].tap()
        XCTAssertEqual(app.staticTexts["library-selection-count"].label, "6 notes selected")
    }

    @MainActor
    func testTextOnlyNotesSupportBatchCopyShareAndDeletion() throws {
        executionTimeAllowance = 240
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                                "-disable-automatic-clipboard", "-ui-test-text-notes"]
        app.launch()
        app.tabBars.buttons["Notes"].tap()
        let first = app.buttons["library-item-note:text-fixture-1"]
        let second = app.buttons["library-item-note:text-fixture-2"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        first.tap()
        XCTAssertTrue(app.buttons["note-close"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["note-caption"].label.contains("纯文字笔记"))
        app.buttons["note-close"].tap()
        app.buttons["feed-search"].tap()
        let search = app.textFields["feed-search-field"]
        search.tap()
        search.typeText("Text fixture\n")
        app.buttons["library-select"].tap()
        app.buttons["library-enter-selection"].tap()
        app.buttons["library-select-all"].tap()
        XCTAssertEqual(app.staticTexts["library-selection-count"].label, "2 notes selected")
        XCTAssertTrue(app.buttons["library-share"].isEnabled)
        app.buttons["library-selection-more"].tap()
        let copy = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Copy' AND label CONTAINS '2'")).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 3))
        copy.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 3))
        app.alerts.buttons["OK"].tap()
        app.buttons["library-share"].tap()
        let closeShare = app.buttons["header.closeButton"]
        XCTAssertTrue(closeShare.waitForExistence(timeout: 8))
        XCTAssertTrue(app.otherElements["LP.CaptionBar.TopCaption"].label.contains("2"))
        attachScreenshot("text-notes-share-documents")
        closeShare.tap()
        app.buttons["library-delete"].tap()
        let keepMedia = app.buttons["Delete notes, keep media"]
        XCTAssertTrue(keepMedia.waitForExistence(timeout: 3))
        // iOS presents this as a popover; dismissing outside is its cancel action.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        XCTAssertTrue(keepMedia.waitForNonExistence(timeout: 3))
        XCTAssertTrue(first.exists && second.exists)
        XCTAssertEqual(app.staticTexts["library-selection-count"].label, "2 notes selected")
        attachScreenshot("text-notes-selected-after-cancel")
        app.buttons["library-delete"].tap()
        app.buttons["Delete notes, keep media"].tap()
        XCTAssertTrue(first.waitForNonExistence(timeout: 5))
        XCTAssertFalse(second.exists)
        XCTAssertEqual(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.count, 0)
        attachScreenshot("text-notes-deleted")
    }

    @MainActor
    func testHapticsSettingControlsPreviewAvailability() throws {
        executionTimeAllowance = 240
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                                "-disable-automatic-clipboard", "-ui-test-task-center"]
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        let interactionRow = app.buttons["settings-row-interaction"]
        for _ in 0..<6 {
            if interactionRow.exists && interactionRow.isHittable { break }
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(interactionRow.waitForExistence(timeout: 5))
        interactionRow.tap()
        let toggle = app.switches["settings-haptics-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        for _ in 0..<6 {
            if toggle.isHittable { break }
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(toggle.isHittable)
        let setSwitch: (Bool) -> Void = { expected in
            let desired = expected ? "1" : "0"
            let matched = NSPredicate(format: "value == %@", desired)
            for attempt in 0..<4 {
                if (toggle.value as? String) == desired { return }
                let inner = toggle.switches.firstMatch
                let target = inner.exists ? inner : toggle
                let centerX: CGFloat = inner.exists ? 0.5 : (toggle.frame.width > 100 ? 0.92 : 0.5)
                if attempt == 2 {
                    let fromX: CGFloat = inner.exists ? (expected ? 0.2 : 0.8) : 0.92
                    let toX: CGFloat = inner.exists ? (expected ? 0.85 : 0.15) : (expected ? 0.97 : 0.82)
                    target.coordinate(withNormalizedOffset: CGVector(dx: fromX, dy: 0.5))
                        .press(forDuration: 0.05, thenDragTo: target.coordinate(withNormalizedOffset: CGVector(dx: toX, dy: 0.5)))
                } else {
                    target.coordinate(withNormalizedOffset: CGVector(dx: centerX, dy: 0.5)).tap()
                }
                let expectation = XCTNSPredicateExpectation(predicate: matched, object: toggle)
                if XCTWaiter.wait(for: [expectation], timeout: 4) == .completed { return }
            }
        }
        let wasEnabled = toggle.value as? String == "1"
        defer {
            setSwitch(wasEnabled)
        }
        if !wasEnabled { setSwitch(true) }
        let preview = app.buttons["settings-haptics-preview"]
        XCTAssertTrue(preview.isEnabled)
        preview.tap()
        let selectionButton = app.buttons["Selection · subtle tick"]
        XCTAssertTrue(selectionButton.waitForExistence(timeout: 3))
        selectionButton.tap()
        XCTAssertTrue(selectionButton.waitForNonExistence(timeout: 5))
        let switchTarget = toggle.switches.firstMatch.exists ? toggle.switches.firstMatch : toggle
        XCTAssertTrue(switchTarget.waitForExistence(timeout: 3))
        setSwitch(false)
        XCTAssertEqual(toggle.value as? String, "0")
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == false"), object: preview)], timeout: 8),
            .completed
        )
        attachScreenshot("settings-haptics-disabled")
        setSwitch(true)
        XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: preview)], timeout: 8),
            .completed
        )
        attachScreenshot("settings-haptics-enabled")
    }

    @MainActor
    func testNoteRightSwipeReturnsFromEveryVerticalRegion() throws {
        executionTimeAllowance = 120
        guard let fixture = ProcessInfo.processInfo.environment["XHS_UI_TEST_MEDIA_IDS"],
              let id = fixture.split(separator: ",").first.map(String.init) else {
            throw XCTSkip("Requires seeded simulator Photos identifiers")
        }
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                                "-disable-automatic-clipboard", "-ui-test-note-feed", "-ui-test-long-note-body"]
        app.launchEnvironment["XHS_UI_TEST_MEDIA_IDS"] = fixture
        app.launch()
        app.tabBars.buttons["Notes"].tap()
        let card = app.buttons["library-item-\(id)"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        let window = app.windows.firstMatch
        for (region, y) in [("header", 0.10), ("media", 0.40), ("body", 0.65), ("bottom", 0.93)] {
            card.tap()
            XCTAssertTrue(app.buttons["note-close"].waitForExistence(timeout: 5))
            if region == "media" {
                app.scrollViews["note-media-canvas-\(id)"].swipeLeft()
                XCTAssertTrue(app.staticTexts["2/2"].waitForExistence(timeout: 5))
                // Right-swiping inside the media carousel on page 2 flips back
                // to page 1 instead of dismissing the note.
                window.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: y))
                    .press(forDuration: 0.05,
                           thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: y)),
                           withVelocity: .slow, thenHoldForDuration: 0.1)
                XCTAssertTrue(app.staticTexts["1/2"].waitForExistence(timeout: 5))
                XCTAssertTrue(app.buttons["note-close"].exists)
            }
            if region == "body" {
                app.scrollViews["note-reader-scroll"].swipeUp(velocity: .slow)
                let title = app.staticTexts["note-title"]
                let readingY = title.frame.minY
                window.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: y))
                    .press(forDuration: 0.05,
                           thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.30, dy: y)),
                           withVelocity: .slow, thenHoldForDuration: 0.3)
                XCTAssertTrue(app.buttons["note-close"].exists)
                XCTAssertEqual(title.frame.minY, readingY, accuracy: 1)
                attachScreenshot("global-return-body-cancelled")
            }
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: y))
                .press(forDuration: 0.05,
                       thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.86, dy: y)),
                       withVelocity: .slow, thenHoldForDuration: 0.15)
            XCTAssertTrue(app.buttons["note-close"].waitForNonExistence(timeout: 5), region)
            XCTAssertTrue(card.isHittable, region)
            attachScreenshot("global-return-\(region)")
        }
        // On photo #2, dragging from the left screen edge returns directly to
        // library-note-feed without stopping on photo #1.
        card.tap()
        XCTAssertTrue(app.buttons["note-close"].waitForExistence(timeout: 5))
        app.scrollViews["note-media-canvas-\(id)"].swipeLeft()
        XCTAssertTrue(app.staticTexts["2/2"].waitForExistence(timeout: 5))
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.40))
            .press(forDuration: 0.05,
                   thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.86, dy: 0.40)),
                   withVelocity: .slow, thenHoldForDuration: 0.15)
        XCTAssertTrue(app.buttons["note-close"].waitForNonExistence(timeout: 5), "left-edge-from-page-2")
        XCTAssertTrue(app.scrollViews["library-note-feed"].waitForExistence(timeout: 5), "left-edge-from-page-2")
        XCTAssertTrue(card.isHittable, "left-edge-from-page-2")
        attachScreenshot("global-return-left-edge-page2")
    }

    @MainActor
    func testLaunchShowsTaskCenter() throws {
        executionTimeAllowance = 240
        let app = XCUIApplication()
        // A Photos prompt from an earlier interrupted run can outlive its app.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for title in ["Don't Allow", "不允许", "不允許"] where springboard.alerts.buttons[title].exists {
            springboard.alerts.buttons[title].tap()
        }
        app.resetAuthorizationStatus(for: .photos)
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-disable-automatic-clipboard"]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["task-center-list"].waitForExistence(timeout: 8))
        XCTAssertEqual(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.count, 0)
        XCTAssertFalse(app.switches["dashboard-clipboard-toggle"].exists)
        XCTAssertFalse(app.switches["Download clipboard links automatically"].exists)
        let primaryButton = app.buttons["primary-paste-button"]
        XCTAssertTrue(primaryButton.waitForExistence(timeout: 3))
        let moreButton = app.buttons["more-actions-button"]
        XCTAssertTrue(moreButton.exists)

        let window = app.windows.firstMatch
        XCTAssertGreaterThan(primaryButton.frame.midY, window.frame.height * 0.72)
        XCTAssertEqual(primaryButton.frame.height, moreButton.frame.height, accuracy: 1)
        XCTAssertEqual(moreButton.frame.width, moreButton.frame.height, accuracy: 1)
        app.tabBars.buttons["Notes"].tap()
        XCTAssertTrue(app.buttons["feed-discover"].waitForExistence(timeout: 3))
        XCTAssertEqual(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.count, 0)
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.switches["Download clipboard links automatically"].waitForExistence(timeout: 3))
        app.tabBars.buttons["Downloads"].tap()
        XCTAssertTrue(primaryButton.waitForExistence(timeout: 3))
    }

    @MainActor
    func testTaskDeletionAndResponsiveBottomBar() throws {
        executionTimeAllowance = 240
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
            "-disable-automatic-clipboard", "-ui-test-task-center"
        ]
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        app.launch()

        let list = app.descendants(matching: .any)["task-center-list"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 8))
        let firstRow = app.descendants(matching: .any)["task-row-00000000-0000-0000-0000-000000000001"].firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 3))
        attachScreenshot("task-center-portrait")
        revealDeletion(firstRow)
        let delete = app.buttons["task-delete-00000000-0000-0000-0000-000000000001"]
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        delete.tap()
        let alert = app.alerts["删除此任务？"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        XCTAssertTrue(alert.buttons["仅删除历史"].exists)
        XCTAssertTrue(alert.buttons["同时删除已保存照片"].exists)
        XCTAssertTrue(alert.buttons["取消"].exists)
        let window = app.windows.firstMatch
        XCTAssertGreaterThan(alert.frame.minY, window.frame.height * 0.2)
        XCTAssertLessThan(alert.frame.maxY, window.frame.height * 0.85)
        attachScreenshot("task-delete-alert")
        alert.buttons["取消"].tap()
        XCTAssertTrue(firstRow.exists)
        revealDeletion(firstRow)
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        delete.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        alert.buttons["仅删除历史"].tap()
        XCTAssertTrue(firstRow.waitForNonExistence(timeout: 3))
        XCTAssertEqual(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.count, 0)

        let lastRow = app.descendants(matching: .any)["task-row-00000000-0000-0000-0000-000000000012"].firstMatch
        for _ in 0..<12 {
            if lastRow.exists, lastRow.frame.maxY < app.buttons["primary-paste-button"].frame.minY { break }
            list.swipeUp()
        }
        XCTAssertTrue(lastRow.isHittable)
        XCTAssertLessThanOrEqual(lastRow.frame.maxY, app.buttons["primary-paste-button"].frame.minY)
        assertBottomActions(app)
        attachScreenshot("task-center-last-row")

        XCUIDevice.shared.orientation = .landscapeLeft
        assertBottomActions(app)
        attachScreenshot("task-center-landscape")
    }

    @MainActor
    func testTaskCenterWithAccessibilityText() throws {
        executionTimeAllowance = 240
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
            "-disable-automatic-clipboard", "-ui-test-task-center",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ]
        app.launch()
        XCTAssertTrue(app.buttons["primary-paste-button"].waitForExistence(timeout: 8))
        assertBottomActions(app)
        XCTAssertGreaterThan(app.buttons["primary-paste-button"].frame.height, 56)
        attachScreenshot("task-center-accessibility-text")
    }

    @MainActor
    func testContinuousMediaPreviewFromBothEntrances() throws {
        // The runner supplies identifiers of media seeded in this test simulator.
        guard let fixture = ProcessInfo.processInfo.environment["XHS_UI_TEST_MEDIA_IDS"],
              let id = fixture.split(separator: ",").first.map(String.init) else {
            throw XCTSkip("Requires seeded simulator Photos identifiers")
        }
        let app = XCUIApplication()
        // Terminate the old Photos observer before resetting simulator consent;
        // otherwise its prompt can outlive the app and race this launch.
        app.terminate()
        app.resetAuthorizationStatus(for: .photos)
        addUIInterruptionMonitor(withDescription: "Photos access for preview fixtures") { alert in
            for title in ["Allow Full Access", "允许完全访问", "Allow Access to All Photos", "允许访问所有照片"] {
                if alert.buttons[title].exists { alert.buttons[title].tap(); return true }
            }
            return false
        }
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                                "-disable-automatic-clipboard", "-ui-test-task-center"]
        app.launchEnvironment["XHS_UI_TEST_MEDIA_IDS"] = fixture
        app.launch()
        app.tabBars.buttons["Notes"].tap()
        let permission = app.buttons["Allow Photos access"]
        XCTAssertTrue(permission.waitForExistence(timeout: 5))
        permission.tap()
        let prompt = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if prompt.waitForExistence(timeout: 3) {
            for title in ["Allow Full Access", "允许完全访问", "Allow Access to All Photos", "允许访问所有照片"]
                where prompt.buttons[title].exists {
                prompt.buttons[title].tap()
                break
            }
        }
        XCTAssertTrue(app.buttons["library-item-\(id)"].waitForExistence(timeout: 15))
        app.tabBars.buttons["Downloads"].tap()
        let firstRow = app.descendants(matching: .any)["task-row-00000000-0000-0000-0000-000000000001"].firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 8))
        firstRow.tap()
        let detailMedia = app.buttons["detail-media-\(id)"]
        XCTAssertTrue(detailMedia.waitForExistence(timeout: 5))
        for _ in 0..<2 {
            detailMedia.tap()
            assertPreviewAndClose(app)
            XCTAssertTrue(detailMedia.waitForExistence(timeout: 3))
        }
        app.navigationBars.buttons.firstMatch.tap()
        app.tabBars.buttons["Notes"].tap()
        let libraryMedia = app.buttons["library-item-\(id)"]
        XCTAssertTrue(libraryMedia.waitForExistence(timeout: 5))
        libraryMedia.tap()
        XCTAssertTrue(app.buttons["note-close"].waitForExistence(timeout: 5))
        app.scrollViews["note-media-canvas-\(id)"].tap()
        assertPreviewAndClose(app)
        app.buttons["note-close"].tap()
        XCTAssertTrue(libraryMedia.waitForExistence(timeout: 3))
        libraryMedia.tap()
        XCTAssertTrue(app.buttons["note-close"].waitForExistence(timeout: 5))
        app.buttons["note-expand-media"].tap()
        XCTAssertTrue(app.buttons["viewer-close"].waitForExistence(timeout: 5))
        let canvas = app.scrollViews["viewer-zoom-canvas"]
        let ids = fixture.split(separator: ",").map(String.init)
        if ids.count > 1 {
            canvas.swipeLeft()
            XCTAssertTrue(app.staticTexts["viewer-page-count"].waitForExistence(timeout: 3) && app.staticTexts["viewer-page-count"].label == "2 / \(ids.count)")
        }
        canvas.swipeDown(velocity: .slow)
        XCTAssertFalse(app.buttons["viewer-close"].exists)
        if ids.count > 1 {
            XCTAssertTrue(app.scrollViews["note-media-canvas-\(ids[1])"].isHittable)
        }
        app.buttons["note-close"].tap()
        XCTAssertTrue(libraryMedia.waitForExistence(timeout: 5))
    }

    @MainActor
    func testNoteExpandedPageReturnsToSelectedImage() throws {
        executionTimeAllowance = 120
        guard let fixture = ProcessInfo.processInfo.environment["XHS_UI_TEST_MEDIA_IDS"] else {
            throw XCTSkip("Requires seeded simulator Photos identifiers")
        }
        let ids = fixture.split(separator: ",").map(String.init)
        guard ids.count > 1 else { throw XCTSkip("Requires two Photos fixtures") }
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                                "-disable-automatic-clipboard", "-ui-test-task-center"]
        app.launchEnvironment["XHS_UI_TEST_MEDIA_IDS"] = fixture
        app.launch()
        app.tabBars.buttons["Notes"].tap()
        let card = app.buttons["library-item-\(ids[0])"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        XCTAssertTrue(app.buttons["note-expand-media"].waitForExistence(timeout: 5))
        app.buttons["note-expand-media"].tap()
        let canvas = app.scrollViews["viewer-zoom-canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        canvas.pinch(withScale: 1.5, velocity: 1)
        XCTAssertNotEqual(canvas.value as? String, "100%")
        app.buttons["viewer-zoom"].tap()
        XCTAssertEqual(canvas.value as? String, "100%")
        // Shrinking below fit size must settle on the same visible photo,
        // without changing pages or disabling a subsequent drag.
        for _ in 0..<2 {
            canvas.pinch(withScale: 0.45, velocity: -1)
            XCTAssertEqual(canvas.value as? String, "100%")
            XCTAssertTrue(app.buttons["viewer-close"].isHittable)
        }
        attachScreenshot("media-preview-minimum-zoom-settled")
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)))
        let pageCount = app.staticTexts["viewer-page-count"]
        XCTAssertTrue(pageCount.waitForExistence(timeout: 3))
        let secondPage = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "2 / \(ids.count)"), object: pageCount)
        XCTAssertEqual(XCTWaiter.wait(for: [secondPage], timeout: 3), .completed)
        canvas.swipeDown(velocity: .slow)
        XCTAssertTrue(app.buttons["viewer-close"].waitForNonExistence(timeout: 5))
        let second = app.scrollViews["note-media-canvas-\(ids[1])"]
        XCTAssertTrue(second.isHittable)
        second.tap()
        XCTAssertTrue(app.staticTexts["viewer-page-count"].waitForExistence(timeout: 5) && app.staticTexts["viewer-page-count"].label == "2 / \(ids.count)")
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.57)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(app.buttons["viewer-close"].isHittable)
        XCTAssertEqual(canvas.value as? String, "100%")
        attachScreenshot("media-preview-cancelled-dismissal")
        // The image follows horizontal travel as well as downward travel; a
        // short diagonal gesture returns to its starting position each time.
        for direction in [0.68, 0.32] {
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: direction, dy: 0.62)),
                       withVelocity: .slow, thenHoldForDuration: 0.3)
            XCTAssertTrue(app.buttons["viewer-close"].isHittable)
            XCTAssertEqual(canvas.value as? String, "100%")
            XCTAssertEqual(pageCount.label, "2 / \(ids.count)")
        }
        assertPreviewAndClose(app)
        XCTAssertTrue(second.isHittable)
        second.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            .press(forDuration: 0.05, thenDragTo: second.coordinate(withNormalizedOffset: CGVector(dx: 0.58, dy: 0.49)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(app.buttons["note-close"].isHittable)
        attachScreenshot("note-card-cancelled-dismissal")
        second.swipeDown(velocity: .slow)
        XCTAssertTrue(app.buttons["note-close"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(card.waitForExistence(timeout: 5))
    }

    @MainActor
    func testNoteLeftEdgeReturnAndCancellation() throws {
        guard let fixture = ProcessInfo.processInfo.environment["XHS_UI_TEST_MEDIA_IDS"],
              let id = fixture.split(separator: ",").first.map(String.init) else {
            throw XCTSkip("Requires seeded simulator Photos identifiers")
        }
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                                "-disable-automatic-clipboard", "-ui-test-note-feed", "-ui-test-long-note-body"]
        app.launchEnvironment["XHS_UI_TEST_MEDIA_IDS"] = fixture
        app.launch()
        app.tabBars.buttons["Notes"].tap()
        let card = app.buttons["library-item-\(id)"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        XCTAssertTrue(app.buttons["note-close"].waitForExistence(timeout: 5))
        let window = app.windows.firstMatch
        let image = app.scrollViews["note-media-canvas-\(id)"]
        let title = app.staticTexts["note-title"]
        let titleY = title.frame.minY
        let imageY = image.frame.minY
        // Returning owns the whole drag: the body and media pager stay still.
        image.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            .press(forDuration: 0.05, thenDragTo: image.coordinate(withNormalizedOffset: CGVector(dx: 0.54, dy: 0.5)),
                   withVelocity: .slow, thenHoldForDuration: 0.4)
        XCTAssertTrue(app.buttons["note-close"].isHittable)
        XCTAssertEqual(title.frame.minY, titleY, accuracy: 1)
        XCTAssertEqual(image.frame.minY, imageY, accuracy: 1)
        XCTAssertTrue(app.staticTexts["1/2"].exists)
        attachScreenshot("note-pull-cancelled-without-content-scroll")
        let edge = window.coordinate(withNormalizedOffset: CGVector(dx: 0.004, dy: 0.5))
        // A short edge drag returns to the same reader, including its title.
        edge.press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.19, dy: 0.52)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(app.buttons["note-close"].isHittable)
        XCTAssertTrue(app.staticTexts["note-title"].isHittable)
        XCTAssertEqual(title.frame.minY, titleY, accuracy: 1)
        attachScreenshot("note-edge-cancelled")
        // Cancellation restores normal reading, and the edge still wins
        // without changing that reading position on the next short drag.
        app.scrollViews["note-reader-scroll"].swipeUp(velocity: .slow)
        let scrolledTitleY = title.frame.minY
        XCTAssertLessThan(scrolledTitleY, titleY - 10)
        edge.press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.19, dy: 0.52)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(app.buttons["note-close"].exists)
        XCTAssertEqual(title.frame.minY, scrolledTitleY, accuracy: 1)
        // XCTest can report isHittable=false for this reparented SwiftUI
        // control even while it accepts touches. Exercise the actual action.
        let closeFrame = app.buttons["note-close"].frame
        XCTAssertTrue(window.frame.contains(closeFrame))
        window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: closeFrame.midX, dy: closeFrame.midY)).tap()
        XCTAssertTrue(app.buttons["note-close"].waitForNonExistence(timeout: 5))
        card.tap()
        XCTAssertTrue(app.buttons["note-close"].waitForExistence(timeout: 5))
        app.scrollViews["note-reader-scroll"].swipeUp(velocity: .slow)
        edge.press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.52)),
                   withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertTrue(app.buttons["note-close"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(card.isHittable)
        attachScreenshot("note-edge-returned-card")
        card.tap()
        XCTAssertTrue(app.buttons["note-expand-media"].waitForExistence(timeout: 5))
        app.buttons["note-expand-media"].tap()
        XCTAssertTrue(app.buttons["viewer-close"].waitForExistence(timeout: 5))
        edge.press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.52)),
                   withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertTrue(app.buttons["viewer-close"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["note-close"].isHittable)
        app.buttons["note-close"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
    }

    @MainActor
    func testNoteCoverHandoffWithQuickFlick() throws {
        guard let fixture = ProcessInfo.processInfo.environment["XHS_UI_TEST_MEDIA_IDS"] else {
            throw XCTSkip("Requires seeded simulator Photos identifiers")
        }
        let ids = fixture.split(separator: ",").map(String.init)
        guard ids.count > 1 else { throw XCTSkip("Requires two Photos fixtures") }
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                                "-disable-automatic-clipboard", "-ui-test-task-center"]
        app.launchEnvironment["XHS_UI_TEST_MEDIA_IDS"] = fixture
        app.launch()
        app.tabBars.buttons["Notes"].tap()
        let card = app.buttons["library-item-\(ids[0])"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        let first = app.scrollViews["note-media-canvas-\(ids[0])"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: first.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)))
        XCTAssertTrue(app.staticTexts["2/2"].waitForExistence(timeout: 10))
        attachScreenshot("note-second-image-before-cover-handoff")
        app.scrollViews["note-media-canvas-\(ids[1])"].swipeDown(velocity: .fast)
        XCTAssertTrue(app.buttons["note-close"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        attachScreenshot("note-cover-after-quick-flick")
    }

    @MainActor
    func testNoteFeedReaderBookmarksAndSearch() throws {
        guard let fixture = ProcessInfo.processInfo.environment["XHS_UI_TEST_MEDIA_IDS"],
              let id = fixture.split(separator: ",").first.map(String.init) else {
            throw XCTSkip("Requires seeded simulator Photos identifiers")
        }
        let app = XCUIApplication()
        addUIInterruptionMonitor(withDescription: "Photos access for note feed") { alert in
            for title in ["允许完全访问", "Allow Full Access", "允许访问所有照片"] {
                if alert.buttons[title].exists { alert.buttons[title].tap(); return true }
            }
            return false
        }
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
                                "-disable-automatic-clipboard", "-ui-test-note-feed"]
        app.launchEnvironment["XHS_UI_TEST_MEDIA_IDS"] = fixture
        app.launch()
        app.tabBars.buttons["笔记"].tap()
        let permission = app.buttons["允许访问照片"]
        if permission.exists {
            permission.tap()
            let prompt = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
            if prompt.waitForExistence(timeout: 3) {
                for title in ["允许完全访问", "Allow Full Access"] where prompt.buttons[title].exists { prompt.buttons[title].tap(); break }
            }
        }
        XCTAssertTrue(app.buttons["feed-discover"].waitForExistence(timeout: 5))
        let first = app.buttons["library-item-\(id)"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        attachScreenshot("note-feed-air-portrait")
        first.tap()
        XCTAssertTrue(app.buttons["note-close"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["note-title"].exists)
        XCTAssertTrue(app.buttons["note-source"].exists)
        let author = app.buttons["note-author-profile"]
        XCTAssertTrue(author.isEnabled && author.isHittable)
        XCTAssertEqual(author.value as? String, "https://www.xiaohongshu.com/user/profile/author-fixture-1")
        attachScreenshot("note-reader-air-media")
        let body = app.staticTexts["note-caption"]
        let scroll = app.scrollViews["note-reader-scroll"]
        scroll.swipeUp()
        XCTAssertTrue(body.waitForExistence(timeout: 3))
        XCTAssertTrue(body.label.contains("光线刚刚好"))
        XCTAssertFalse(body.label.contains("[话题]"))
        attachScreenshot("note-reader-air-caption")
        let favorite = app.buttons["note-like"]
        if favorite.label == "取消收藏" { favorite.tap() }
        favorite.tap()
        XCTAssertEqual(favorite.label, "取消收藏")
        app.buttons["note-copy-caption"].tap()
        XCTAssertTrue(app.buttons["note-copy-caption"].label.contains("已复制"))
        app.buttons["note-close"].tap()
        app.buttons["feed-bookmarks"].tap()
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        attachScreenshot("note-feed-bookmarked")
        app.buttons["feed-discover"].tap()
        app.buttons["feed-search"].tap()
        let field = app.textFields["feed-search-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap(); field.typeText("不存在的笔记标题"); field.typeText("\n")
        XCTAssertTrue(app.staticTexts["没有找到相关笔记"].waitForExistence(timeout: 3))
        app.buttons["清除搜索"].tap()
        XCTAssertTrue(first.waitForExistence(timeout: 3))
        app.buttons["feed-search"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.buttons["feed-discover"].isHittable)
        attachScreenshot("note-feed-air-landscape")
    }

    @MainActor
    func testRedesignedTabsAndLiquidGlassControls() throws {
        executionTimeAllowance = 360
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
            "-disable-automatic-clipboard", "-ui-test-text-notes", "-ui-test-six-notes"
        ]
        app.launch()

        // 1. Downloads filter chips, task detail, and manual input
        XCTAssertTrue(app.descendants(matching: .any)["task-center-list"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.switches["dashboard-clipboard-toggle"].exists)
        attachScreenshot("redesign-downloads-populated")
        app.buttons["task-filter-waiting"].tap()
        attachScreenshot("redesign-downloads-filtered-empty")
        app.buttons["task-filter-all"].tap()
        let firstTask = app.descendants(matching: .any)["task-row-00000000-0000-0000-0000-000000000001"].firstMatch
        XCTAssertTrue(firstTask.waitForExistence(timeout: 3))
        firstTask.tap()
        XCTAssertTrue(app.buttons["文案"].waitForExistence(timeout: 3))
        app.buttons["文案"].tap()
        attachScreenshot("redesign-task-detail-caption")
        app.buttons["资源"].tap()
        attachScreenshot("redesign-task-detail-resources")
        app.navigationBars.buttons.firstMatch.tap()

        app.buttons["more-actions-button"].tap()
        XCTAssertTrue(app.buttons["手动输入"].waitForExistence(timeout: 3))
        app.buttons["手动输入"].tap()
        XCTAssertTrue(app.textViews["manual-input-field"].waitForExistence(timeout: 3))
        attachScreenshot("redesign-manual-input")
        app.buttons["取消"].tap()

        // 2. Notes feed with Liquid Glass header, search, and selection bar
        app.tabBars.buttons["笔记"].tap()
        XCTAssertTrue(app.scrollViews["library-note-feed"].waitForExistence(timeout: 8))
        attachScreenshot("redesign-notes-feed")
        app.buttons["feed-search"].tap()
        XCTAssertTrue(app.textFields["feed-search-field"].waitForExistence(timeout: 3))
        attachScreenshot("redesign-notes-search")
        app.buttons["feed-search"].tap()
        app.buttons["library-select"].tap()
        app.buttons["library-enter-selection"].tap()
        app.buttons["library-select-all"].tap()
        attachScreenshot("redesign-notes-selecting")
        app.buttons["library-select-done"].tap()

        // 3. Settings overview and subpages
        app.tabBars.buttons["设置"].tap()
        XCTAssertTrue(app.buttons["settings-row-media"].waitForExistence(timeout: 5))
        attachScreenshot("redesign-settings-overview")
        app.buttons["settings-row-media"].tap()
        XCTAssertTrue(app.switches["settings-content-images"].waitForExistence(timeout: 3))
        attachScreenshot("redesign-settings-media")
        app.navigationBars.buttons.firstMatch.tap()

        app.buttons["settings-row-archive"].tap()
        XCTAssertTrue(app.switches["自定义命名模板"].waitForExistence(timeout: 3))
        attachScreenshot("redesign-settings-archive")
        app.navigationBars.buttons.firstMatch.tap()

        app.buttons["settings-row-interaction"].tap()
        XCTAssertTrue(app.switches["settings-haptics-toggle"].waitForExistence(timeout: 3))
        attachScreenshot("redesign-settings-interaction")
        app.navigationBars.buttons.firstMatch.tap()

        app.buttons["settings-row-storage"].tap()
        XCTAssertTrue(app.buttons["导出记录"].waitForExistence(timeout: 3))
        attachScreenshot("redesign-settings-storage")
        app.navigationBars.buttons.firstMatch.tap()

        app.buttons["settings-row-about"].tap()
        XCTAssertTrue(app.buttons["检查更新"].waitForExistence(timeout: 3))
        attachScreenshot("redesign-settings-about")
        app.navigationBars.buttons.firstMatch.tap()
    }

    @MainActor
    func testNoteHeroReturnBehindTranslucentHeader() throws {
        executionTimeAllowance = 120
        guard let fixture = ProcessInfo.processInfo.environment["XHS_UI_TEST_MEDIA_IDS"],
              let id = fixture.split(separator: ",").first.map(String.init) else {
            throw XCTSkip("Requires seeded simulator Photos identifiers")
        }
        let app = XCUIApplication()
        addUIInterruptionMonitor(withDescription: "Photos access for note feed") { alert in
            for title in ["允许完全访问", "Allow Full Access", "允许访问所有照片"] {
                if alert.buttons[title].exists { alert.buttons[title].tap(); return true }
            }
            return false
        }
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
                                "-disable-automatic-clipboard", "-ui-test-note-feed"]
        app.launchEnvironment["XHS_UI_TEST_MEDIA_IDS"] = fixture
        app.launch()
        app.tabBars.buttons["笔记"].tap()
        let feed = app.scrollViews["library-note-feed"]
        XCTAssertTrue(feed.waitForExistence(timeout: 8))
        let first = app.buttons["library-item-\(id)"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 8))

        // Scroll slightly so top cards slide behind the translucent feedHeader.
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62))
            .press(forDuration: 0.05,
                   thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.44)),
                   withVelocity: .slow, thenHoldForDuration: 0.1)
        attachScreenshot("hero-scrolled-under-header-before")

        // Tap lower exposed portion of the partially-occluded top card (below feedHeader).
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.90)).tap()
        let close = app.buttons["note-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 6))
        attachScreenshot("hero-scrolled-reader-open")

        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 6))
        XCTAssertTrue(app.buttons["feed-discover"].isHittable)
        attachScreenshot("hero-scrolled-under-header-after")
    }

    @MainActor
    private func revealDeletion(_ row: XCUIElement) {
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.2))
            .press(forDuration: 0.1, thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.2)))
    }

    @MainActor
    private func assertPreviewAndClose(_ app: XCUIApplication) {
        let close = app.buttons["viewer-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 8))
        let canvas = app.scrollViews["viewer-zoom-canvas"]
        XCTAssertTrue(canvas.exists)
        XCTAssertEqual(canvas.value as? String, "100%")
        attachScreenshot("media-preview-sharp-first-frame")
        app.buttons["viewer-zoom"].tap()
        XCTAssertEqual(canvas.value as? String, "250%")
        app.buttons["viewer-zoom"].tap()
        XCTAssertEqual(canvas.value as? String, "100%")
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
    }

    @MainActor
    private func assertBottomActions(_ app: XCUIApplication) {
        let primary = app.buttons["primary-paste-button"]
        let more = app.buttons["more-actions-button"]
        XCTAssertTrue(primary.waitForExistence(timeout: 3))
        XCTAssertTrue(primary.isHittable)
        XCTAssertTrue(more.isHittable)
        XCTAssertGreaterThanOrEqual(primary.frame.height, more.frame.height - 1)
        XCTAssertEqual(primary.frame.midY, more.frame.midY, accuracy: 1)
        XCTAssertEqual(more.frame.width, more.frame.height, accuracy: 1)
        XCTAssertLessThanOrEqual(primary.frame.maxX, more.frame.minX)
        XCTAssertGreaterThanOrEqual(primary.frame.minX, app.windows.firstMatch.frame.minX)
        XCTAssertLessThanOrEqual(more.frame.maxX, app.windows.firstMatch.frame.maxX)
        if let tabBar = app.tabBars.allElementsBoundByIndex.first(where: { $0.isHittable }) {
            XCTAssertLessThanOrEqual(primary.frame.maxY, tabBar.frame.minY)
        }
    }

    @MainActor
    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
