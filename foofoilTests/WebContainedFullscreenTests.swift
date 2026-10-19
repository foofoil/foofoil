import AppKit
import Testing
import WebKit
@testable import foofoil

@MainActor
@Suite(.serialized)
struct WebContainedFullscreenTests {
    @Test func fillsViewportAndRestoresStylesWithoutMovingVideo() async throws {
        try await withPage {
            webView in
            let result = try await webView.callAsyncJavaScript("""
                const video = document.querySelector('video');
                const host = video.parentElement;
                const original = video.getAttribute('style');
                let changes = 0;
                document.addEventListener('fullscreenchange', () => changes++);
                await video.requestFullscreen();
                const rect = video.getBoundingClientRect();
                const entered = document.fullscreenElement === video && video.parentElement === host
                    && Math.abs(rect.width - innerWidth) < 1 && Math.abs(rect.height - innerHeight) < 1
                    && rect.x === 0 && rect.y === 0;
                await document.exitFullscreen();
                return entered && document.fullscreenElement === null && changes === 2
                    && video.getAttribute('style') === original && host.style.transform === 'translateX(30px)';
                """, arguments: [:], in: nil, contentWorld: .page)
            #expect(result as? Bool == true)
            #expect(webView.fullscreenState == .notInFullscreen)
        }
    }

    @Test func escapeAndRemovedTargetRestorePage() async throws {
        try await withPage { webView in
            let result = try await webView.callAsyncJavaScript("""
                const video = document.querySelector('video');
                await video.webkitRequestFullscreen();
                document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true }));
                const escaped = !document.fullscreenElement;
                await video.requestFullscreen();
                video.remove();
                await new Promise(resolve => setTimeout(resolve, 0));
                return escaped && !document.fullscreenElement && document.documentElement.style.overflow === '';
                """, arguments: [:], in: nil, contentWorld: .page)
            #expect(result as? Bool == true)
        }
    }

    @Test func nativeVideoEntryAndExitButtonStayInsideWindow() async throws {
        try await withPage { webView in
            let result = try await webView.callAsyncJavaScript("""
                const video = document.querySelector('video');
                video.webkitEnterFullscreen();
                const entered = video.webkitDisplayingFullscreen && document.webkitIsFullScreen;
                document.querySelector('button[aria-label]').click();
                return entered && !video.webkitDisplayingFullscreen && !document.webkitIsFullScreen;
                """, arguments: [:], in: nil, contentWorld: .page)
            #expect(result as? Bool == true)
            #expect(webView.fullscreenState == .notInFullscreen)
            #expect(webView.window?.styleMask.contains(.fullScreen) == false)
        }
    }

    @Test func embeddedFrameExpandsAndExitsWithParent() async throws {
        try await withPage { webView in
            let result = try await webView.callAsyncJavaScript("""
                const frame = document.createElement('iframe');
                frame.srcdoc = '<video></video>';
                const loaded = new Promise(resolve => frame.onload = resolve);
                document.body.append(frame);
                await loaded;
                await frame.contentDocument.querySelector('video').requestFullscreen();
                for (let i = 0; i < 50 && document.fullscreenElement !== frame; i++)
                    await new Promise(resolve => setTimeout(resolve, 10));
                const entered = document.fullscreenElement === frame;
                await document.exitFullscreen();
                for (let i = 0; i < 50 && frame.contentDocument.fullscreenElement; i++)
                    await new Promise(resolve => setTimeout(resolve, 10));
                return entered && !frame.contentDocument.fullscreenElement;
                """, arguments: [:], in: nil, contentWorld: .page)
            #expect(result as? Bool == true)
        }
    }

    @Test func crossOriginFrameAndNavigationRestoreParent() async throws {
        try await withPage { webView in
            let result = try await webView.callAsyncJavaScript("""
                const frame = document.createElement('iframe');
                frame.sandbox = 'allow-scripts';
                frame.srcdoc = '<body><script>setTimeout(() => document.body.requestFullscreen(), 0)</script>';
                document.body.append(frame);
                for (let i = 0; i < 100 && document.fullscreenElement !== frame; i++)
                    await new Promise(resolve => setTimeout(resolve, 10));
                const entered = document.fullscreenElement === frame;
                const loaded = new Promise(resolve => frame.onload = resolve);
                frame.srcdoc = '<body>navigated</body>';
                await loaded;
                for (let i = 0; i < 100 && document.fullscreenElement; i++)
                    await new Promise(resolve => setTimeout(resolve, 10));
                return entered && !document.fullscreenElement && document.documentElement.style.overflow === '';
                """, arguments: [:], in: nil, contentWorld: .page)
            #expect(result as? Bool == true)
        }
    }

    private func withPage(_ check: (WKWebView) async throws -> Void) async throws {
        let configuration = WKWebViewConfiguration()
        WebContainedFullscreen.install(on: configuration)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let window = NSWindow(contentRect: webView.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = webView
        defer { window.orderOut(nil) }
        let waiter = NavigationWaiter()
        webView.navigationDelegate = waiter
        webView.loadHTMLString("""
            <html><body><div style="transform:translateX(30px);overflow:hidden;width:100px">
            <video style="width: 80px; height: 60px; object-fit: cover;"></video>
            </div></body></html>
            """, baseURL: nil)
        await waiter.waitForFinish()
        try await check(webView)
    }
}
