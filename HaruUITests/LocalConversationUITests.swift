import XCTest

final class LocalConversationUITests: XCTestCase {
    func testOfflineSetupUsesTheNormalChatScreen() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-haru.local.selected", "YES", "-haru.local.model", "umbral", "-haru.local.handoff", "YES"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Conversation settings"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["Download Umbral · 3.52 GB"].exists)
        XCTAssertFalse(app.buttons["Ask server"].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["conversation.settings"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["Say something"].exists || app.textViews["Say something"].exists)
        XCTAssertFalse(app.buttons["On iPhone"].exists)
        XCTAssertFalse(app.buttons["Speak to Haru on this iPhone"].isEnabled)
        app.buttons["conversation.settings"].tap()
        XCTAssertTrue(app.buttons["Download Umbral · 3.52 GB"].waitForExistence(timeout: 10))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Umbral settings on the existing Haru chat"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
