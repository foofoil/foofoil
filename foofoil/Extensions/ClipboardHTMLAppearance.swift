import Foundation

/// 剪贴板片段缺少原网页的外观上下文：补齐默认文字配色，仅修正与实际底色撞色的中性文字。
/// 不改缓存原文；每次切换外观先撤销上次修正，避免浅色和暗色来回切换丢失源样式。
enum ClipboardHTMLAppearance {
    static func script(isDark: Bool, textHex: String) -> String {
        let foreground = textHex.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil
            ? textHex : (isDark ? "#E6E6E6" : "#1F2328")
        return """
        (() => {
            const root = document.documentElement;
            if (!root || !document.body) return;
            const scheme = '\(isDark ? "dark" : "light")';
            const fallbackBackground = \(isDark ? "[28,29,31,1]" : "[248,249,250,1]");
            const fallbackText = '\(foreground)';
            const elements = [document.body, ...document.body.querySelectorAll('*')];
            for (const element of elements) {
                const saved = element.__foofoilClipboardColors;
                if (!saved) continue;
                for (const [property, original] of Object.entries(saved)) {
                    if (original.value) element.style.setProperty(property, original.value, original.priority);
                    else element.style.removeProperty(property);
                }
                delete element.__foofoilClipboardColors;
            }
            // WebKit 默认仅声明浅色；片段未携带 color-scheme 时，CanvasText 否则一直是黑色。
            root.style.setProperty('color-scheme', scheme, 'important');
            function rgba(value) {
                const match = value.match(/^rgba?\\(([^)]+)\\)$/);
                if (!match) return null;
                const values = match[1].split(/[,\\s/]+/).filter(Boolean).map(Number);
                if (values.length === 3) values.push(1);
                return values.length === 4 && values.every(Number.isFinite) ? values : null;
            }
            function luminance(color) {
                const c = color.slice(0, 3).map(value => {
                    value /= 255;
                    return value <= 0.04045 ? value / 12.92 : Math.pow((value + 0.055) / 1.055, 2.4);
                });
                return c[0] * 0.2126 + c[1] * 0.7152 + c[2] * 0.0722;
            }
            function background(element) {
                const layers = [];
                for (let current = element; current; current = current.parentElement) {
                    const color = rgba(getComputedStyle(current).backgroundColor);
                    if (color && color[3] > 0) layers.push(color);
                    if (color && color[3] === 1) break;
                }
                return layers.reverse().reduce((under, over) =>
                    over.slice(0, 3).map((value, i) => value * over[3] + under[i] * (1 - over[3])).concat(1), fallbackBackground);
            }
            function setColor(element, property, value) {
                const saved = element.__foofoilClipboardColors || (element.__foofoilClipboardColors = {});
                saved[property] = {value: element.style.getPropertyValue(property), priority: element.style.getPropertyPriority(property)};
                element.style.setProperty(property, value, 'important');
            }
            for (const element of elements) {
                if (['SCRIPT', 'STYLE', 'NOSCRIPT'].includes(element.tagName)) continue;
                if (![...element.childNodes].some(node => node.nodeType === Node.TEXT_NODE && node.textContent.trim())) continue;
                const style = getComputedStyle(element);
                if (style.visibility !== 'visible' || style.display === 'none') continue;
                // text-fill-color 可独立覆盖 color，必须以实际绘制的字色判断。
                const ink = rgba(style.webkitTextFillColor || style.color);
                if (!ink || ink[3] === 0 || Math.max(...ink.slice(0, 3)) - Math.min(...ink.slice(0, 3)) > 24) continue;
                const paper = background(element);
                const visibleInk = ink.slice(0, 3).map((value, i) => value * ink[3] + paper[i] * (1 - ink[3]));
                const a = luminance(visibleInk), b = luminance(paper);
                if ((Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05) >= 4.5) continue;
                // 带独立底色的代码块/引文按自己的底色选字色，不跟整张箔一起反转。
                const color = b < 0.18 ? (scheme === 'dark' ? fallbackText : '#E6E6E6')
                    : (scheme === 'light' ? fallbackText : '#1F2328');
                setColor(element, 'color', color);
                setColor(element, '-webkit-text-fill-color', color);
            }
        })();
        """
    }
}
