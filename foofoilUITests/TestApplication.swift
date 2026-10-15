import XCTest

/// 参数只覆盖测试进程的偏好，不改写用户的启动方式或快捷键配置。
@MainActor
func makeTestApplication() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
        "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        "-startupBehavior", "newWindow", "-keyboardShortcutOverrides", ""
    ]
    return app
}
