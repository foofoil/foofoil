import Foundation
import WebKit

/// 网页全屏只扩大 DOM 元素，不触发 WebKit 的独立全屏窗口；所有 frame 都在页面脚本之前安装。
enum WebContainedFullscreen {
    static func install(on configuration: WKWebViewConfiguration) {
        configuration.preferences.isElementFullscreenEnabled = false
        configuration.userContentController.addUserScript(WKUserScript(
            source: script,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
    }

    static var script: String {
        let label = String(data: try! JSONEncoder().encode(NSLocalizedString("Exit Full Screen", comment: "")), encoding: .utf8)!
        return #"""
        (() => {
            if (window.__foofoilFullscreenInstalled) return;
            window.__foofoilFullscreenInstalled = true;
            const channel = 'foofoil-contained-fullscreen';
            let active = null, child = null, saved = [], button = null, observer = null;
            const patch = (node, values) => {
                for (const [name, value] of Object.entries(values)) {
                    saved.push([node, name, node.style.getPropertyValue(name), node.style.getPropertyPriority(name)]);
                    node.style.setProperty(name, value, 'important');
                }
            };
            const notifyParent = (action) => {
                if (window !== parent) parent.postMessage({ channel, action }, '*');
            };
            const changed = (target) => {
                target.dispatchEvent(new Event('fullscreenchange', { bubbles: true }));
                target.dispatchEvent(new Event('webkitfullscreenchange', { bubbles: true }));
                if (target instanceof HTMLVideoElement) target.dispatchEvent(new Event('webkitpresentationmodechanged'));
            };
            const leave = (propagate = true) => {
                if (!active) return;
                const previous = active;
                active = null;
                observer?.disconnect();
                observer = null;
                button?.remove();
                button = null;
                if (child) child.postMessage({ channel, action: 'exit' }, '*');
                child = null;
                for (const [node, name, value, priority] of saved.reverse()) {
                    if (value) node.style.setProperty(name, value, priority);
                    else node.style.removeProperty(name);
                }
                saved = [];
                changed(previous.isConnected ? previous : document);
                if (propagate) notifyParent('leave');
            };
            const enter = (target, source = null) => {
                if (!(target instanceof Element) || !target.isConnected)
                    return Promise.reject(new TypeError('Fullscreen target is not connected'));
                if (active === target) return Promise.resolve();
                leave(false);
                active = target;
                child = source;
                // 不移动节点，避免 iframe 重新加载或播放器丢失状态。解除祖先对 fixed 元素的裁剪和定位限制。
                for (let node = target.parentElement; node; node = node.parentElement) {
                    patch(node, { transform: 'none', translate: 'none', rotate: 'none', scale: 'none',
                        filter: 'none', 'backdrop-filter': 'none', perspective: 'none', contain: 'none',
                        'content-visibility': 'visible', 'will-change': 'auto', overflow: 'visible',
                        'clip-path': 'none', clip: 'auto', isolation: 'auto', 'z-index': 'auto', opacity: '1' });
                }
                patch(document.documentElement, { overflow: 'hidden' });
                patch(target, { position: 'fixed', inset: '0', width: '100vw', height: '100vh',
                    'min-width': '0', 'min-height': '0', 'max-width': 'none', 'max-height': 'none',
                    margin: '0', 'box-sizing': 'border-box', 'z-index': '2147483646',
                    transform: 'none', translate: 'none', rotate: 'none', scale: 'none',
                    'aspect-ratio': 'auto', background: 'black' });
                if (target instanceof HTMLVideoElement) patch(target, { 'object-fit': 'contain' });
                if (window === parent) {
                    button = document.createElement('button');
                    button.textContent = '↙';
                    button.title = \#(label);
                    button.setAttribute('aria-label', \#(label));
                    button.style.cssText = 'all:initial!important;position:fixed!important;right:12px!important;top:12px!important;z-index:2147483647!important;background:#222c!important;color:white!important;border-radius:6px!important;padding:8px 12px!important;font:20px sans-serif!important;cursor:pointer!important;';
                    button.addEventListener('click', () => leave());
                    document.documentElement.append(button);
                }
                observer = new MutationObserver(() => { if (active && !active.isConnected) leave(); });
                observer.observe(document, { childList: true, subtree: true });
                changed(target);
                notifyParent('enter');
                return Promise.resolve();
            };
            const define = (prototype, name, descriptor) => Object.defineProperty(prototype, name, { configurable: true, ...descriptor });
            for (const name of ['requestFullscreen', 'webkitRequestFullscreen', 'webkitRequestFullScreen'])
                define(Element.prototype, name, { value: function() { return enter(this); }, writable: true });
            for (const name of ['exitFullscreen', 'webkitExitFullscreen', 'webkitCancelFullScreen'])
                define(Document.prototype, name, { value: function() { leave(); return Promise.resolve(); }, writable: true });
            for (const name of ['fullscreenElement', 'webkitFullscreenElement', 'webkitCurrentFullScreenElement'])
                define(Document.prototype, name, { get: () => active });
            for (const name of ['fullscreenEnabled', 'webkitFullscreenEnabled'])
                define(Document.prototype, name, { get: () => true });
            define(Document.prototype, 'webkitIsFullScreen', { get: () => !!active });
            for (const name of ['webkitEnterFullscreen', 'webkitEnterFullScreen'])
                define(HTMLVideoElement.prototype, name, { value: function() { enter(this); }, writable: true });
            for (const name of ['webkitExitFullscreen', 'webkitExitFullScreen'])
                define(HTMLVideoElement.prototype, name, { value: function() { leave(); }, writable: true });
            define(HTMLVideoElement.prototype, 'webkitDisplayingFullscreen', { get: function() { return active === this; } });
            define(HTMLVideoElement.prototype, 'webkitSupportsFullscreen', { get: () => true });
            const modeDescriptor = Object.getOwnPropertyDescriptor(HTMLVideoElement.prototype, 'webkitPresentationMode');
            if (modeDescriptor?.get) define(HTMLVideoElement.prototype, 'webkitPresentationMode', { get: function() {
                return active === this ? 'fullscreen' : modeDescriptor.get.call(this);
            } });
            const presentation = HTMLVideoElement.prototype.webkitSetPresentationMode;
            if (presentation) {
                define(HTMLVideoElement.prototype, 'webkitSetPresentationMode', { value: function(mode) {
                    if (mode === 'fullscreen') { enter(this); return; }
                    if (active === this) leave();
                    return presentation.call(this, mode);
                }, writable: true });
            }
            document.addEventListener('keydown', (event) => {
                if (event.key === 'Escape' && active) {
                    event.preventDefault(); event.stopImmediatePropagation(); leave();
                }
            }, true);
            // 跨域 iframe 通过逐层消息扩展；只接受直接子 frame 或父 frame 的消息。
            window.addEventListener('message', (event) => {
                if (event.data?.channel !== channel) return;
                if (window !== parent && event.source === parent && event.data.action === 'exit') { leave(false); return; }
                if (event.data.action === 'leave' && event.source === child) { leave(); return; }
                if (event.data.action !== 'enter') return;
                const frame = [...document.querySelectorAll('iframe, frame')].find(frame => frame.contentWindow === event.source);
                if (frame) enter(frame, event.source);
            });
            window.addEventListener('pagehide', () => leave());
            // frame 内导航可能不触发 pagehide 消息，父页面以 load 事件兜底恢复。
            document.addEventListener('load', (event) => {
                if (active && event.target === active && child) leave();
            }, true);
        })();
        """#
    }
}
