import XCTest

final class RealtimeVoiceAgentUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCallAssistantFlowOnSimulator() throws {
        let app = XCUIApplication()
        app.launchArguments += ["UITEST_CALLKIT_SIMULATION"]
        app.launch()

        let callButton = app.buttons["call-assistant-button"]
        XCTAssertTrue(callButton.waitForExistence(timeout: 5))

        let statusLabel = app.staticTexts["connection-state-label"]
        XCTAssertTrue(statusLabel.waitForExistence(timeout: 2))
        XCTAssertTrue(callButton.isEnabled)
        attachScreenshot(named: "01-idle-home", app: app)

        callButton.tap()

        let connectedLabel = app.staticTexts.matching(identifier: "connection-state-label").matching(NSPredicate(format: "label == %@", "Connected")).firstMatch
        XCTAssertTrue(connectedLabel.waitForExistence(timeout: 5))

        let transcriptList = app.otherElements["transcript-list"]
        XCTAssertTrue(transcriptList.waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Call connected. This is the simulator CallKit test path."].waitForExistence(timeout: 2))
        attachScreenshot(named: "02-connected-transcript", app: app)

        app.tabBars.buttons["Log"].tap()
        XCTAssertTrue(app.staticTexts["Local Tools"].waitForExistence(timeout: 2))
        attachScreenshot(named: "03-log-tab", app: app)

        app.tabBars.buttons["Transcript"].tap()

        let hangUpButton = app.buttons["hang-up-button"]
        XCTAssertTrue(hangUpButton.isEnabled)
        hangUpButton.tap()

        let disconnectedLabel = app.staticTexts.matching(identifier: "connection-state-label").matching(NSPredicate(format: "label == %@", "Disconnected")).firstMatch
        XCTAssertTrue(disconnectedLabel.waitForExistence(timeout: 5))
        attachScreenshot(named: "04-disconnected", app: app)
    }

    private func attachScreenshot(named name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
