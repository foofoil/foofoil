// 只读代码预览的页面宿主脚本。只执行应用自带代码；源码仅作为数据经 textContent 或 Worker 消息进入页面。
(() => {
    'use strict';

    const root = document.documentElement;
    const codeElement = document.getElementById('code');
    const messageHandler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.foofoilCode;
    const highlightTimeout = 500;
    const workerStartTimeout = 3000;
    const lineBreakPattern = /\r\n|\r|\n/g;

    let workerSource = null;
    let revision = 0;
    let source = '';
    let rowRanges = [];
    let activeWorker = null;
    let activeWorkerURL = null;
    let activeTimer = null;
    let deferredApply = null;
    let hoveredRow = null;

    function post(payload) {
        if (messageHandler) {
            messageHandler.postMessage(payload);
        }
    }

    function escapeHTML(text) {
        return text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    }

    // 源码按 \r\n、\r、\n 切分为逻辑行；行号与复制都依据这里的 UTF-16 偏移。
    function computeRowRanges(text) {
        const ranges = [];
        let start = 0;
        lineBreakPattern.lastIndex = 0;
        let match;
        while ((match = lineBreakPattern.exec(text)) !== null) {
            ranges.push({ start, end: match.index });
            start = match.index + match[0].length;
        }
        ranges.push({ start, end: text.length });
        return ranges;
    }

    // 把 highlight.js 的 HTML（或转义后的纯文本）按逻辑行拆开，跨行的 span 在每行重新开闭。
    function splitIntoRows(html) {
        const rows = [];
        const openTags = [];
        let buffer = '';
        const tokenPattern = /<[^>]+>|[^<]+/g;
        let token;
        while ((token = tokenPattern.exec(html)) !== null) {
            const piece = token[0];
            if (piece.charAt(0) === '<') {
                if (piece.charAt(1) === '/') {
                    openTags.pop();
                } else {
                    openTags.push(piece);
                }
                buffer += piece;
                continue;
            }
            const segments = piece.split(/\r\n|\r|\n/);
            segments.forEach((segment, index) => {
                if (index > 0) {
                    rows.push(buffer + '</span>'.repeat(openTags.length));
                    buffer = openTags.join('');
                }
                buffer += segment;
            });
        }
        rows.push(buffer + '</span>'.repeat(openTags.length));
        return rows;
    }

    // 行与行之间没有额外文本；只有 .c 的 textContent 参与一致性校验。
    function renderRows(html, text) {
        const rows = splitIntoRows(html);
        const ranges = computeRowRanges(text);
        if (rows.length !== ranges.length) {
            return false;
        }
        const fragments = rows.map((row, index) => {
            const range = ranges[index];
            return `<div class="l" data-s="${range.start}" data-e="${range.end}"><span class="n">${index + 1}</span><span class="c">${row}</span></div>`;
        });
        codeElement.innerHTML = fragments.join('');
        hoveredRow = null;
        rowRanges = ranges;
        root.style.setProperty('--digits', String(ranges.length).length);
        return verifyRows(text);
    }

    // 渲染结果必须与输入源码逐行一致（textContent 相同），否则视为失败并回退原生视图。
    function verifyRows(text) {
        const rows = codeElement.children;
        if (rows.length !== rowRanges.length) {
            return false;
        }
        for (let index = 0; index < rows.length; index += 1) {
            const content = rows[index].children[1];
            const range = rowRanges[index];
            if (!content || content.textContent !== text.slice(range.start, range.end)) {
                return false;
            }
        }
        return true;
    }

    function cancelWorker() {
        if (activeTimer !== null) {
            clearTimeout(activeTimer);
            activeTimer = null;
        }
        if (activeWorker) {
            activeWorker.terminate();
            activeWorker = null;
        }
        if (activeWorkerURL) {
            URL.revokeObjectURL(activeWorkerURL);
            activeWorkerURL = null;
        }
    }

    function applyWhenSelectionClears(action) {
        const selection = document.getSelection();
        if (selection && !selection.isCollapsed && codeElement.contains(selection.anchorNode)) {
            deferredApply = action;
            return;
        }
        action();
    }

    document.addEventListener('selectionchange', () => {
        if (!deferredApply) {
            return;
        }
        const selection = document.getSelection();
        if (selection && !selection.isCollapsed && codeElement.contains(selection.anchorNode)) {
            return;
        }
        const action = deferredApply;
        deferredApply = null;
        action();
    });

    function highlightInWorker(currentRevision, language, text) {
        cancelWorker();
        if (!workerSource) {
            post({ type: 'failed', revision: currentRevision, reason: 'missingWorker' });
            return;
        }
        const fail = (reason) => {
            if (currentRevision !== revision) return;
            cancelWorker();
            post({ type: 'failed', revision: currentRevision, reason });
        };
        let worker;
        try {
            activeWorkerURL = URL.createObjectURL(new Blob([workerSource], { type: 'text/javascript' }));
            worker = new Worker(activeWorkerURL);
        } catch (error) {
            fail('workerCreation');
            return;
        }
        activeWorker = worker;
        // 启动阶段（解析语法脚本）单独计时；开始计算后再切换为 highlightTimeout。
        activeTimer = setTimeout(() => fail('startTimeout'), workerStartTimeout);
        worker.onerror = () => fail('workerError');
        worker.onmessage = (event) => {
            const data = event.data || {};
            if (data.ready) {
                if (currentRevision !== revision) return;
                clearTimeout(activeTimer);
                activeTimer = setTimeout(() => fail('timeout'), highlightTimeout);
                worker.postMessage({ id: currentRevision, language, source: text });
                return;
            }
            if (currentRevision !== revision || data.id !== currentRevision) return;
            if (typeof data.html !== 'string') {
                fail('highlightError');
                return;
            }
            const html = data.html;
            cancelWorker();
            applyWhenSelectionClears(() => {
                if (currentRevision !== revision) return;
                if (renderRows(html, text)) {
                    post({ type: 'highlighted', revision: currentRevision });
                } else {
                    post({ type: 'failed', revision: currentRevision, reason: 'verifyFailed' });
                }
            });
        };
    }

    // 样式与内容分开：仅样式变化时保留阅读位置（以首个可见行及其偏移为锚点）。
    function captureAnchor() {
        const top = window.scrollY;
        const rows = codeElement.children;
        let low = 0;
        let high = rows.length - 1;
        if (high < 0) return null;
        while (low < high) {
            const middle = (low + high + 1) >> 1;
            if (rows[middle].offsetTop <= top) {
                low = middle;
            } else {
                high = middle - 1;
            }
        }
        const row = rows[low];
        return { row, viewportTop: row.getBoundingClientRect().top };
    }

    function restoreAnchor(anchor) {
        if (!anchor || !anchor.row.isConnected) return;
        const delta = anchor.row.getBoundingClientRect().top - anchor.viewportTop;
        if (delta !== 0) {
            window.scrollBy(0, delta);
        }
    }

    function applyStyle(style) {
        const anchor = captureAnchor();
        root.style.setProperty('--font-family', style.fontFamily);
        root.style.setProperty('--font-size', `${style.fontSize}px`);
        root.style.setProperty('--line-height', style.lineHeight === null ? 'normal' : String(style.lineHeight));
        root.style.setProperty('--paragraph-spacing', `${style.paragraphSpacing}px`);
        if (style.textColor) {
            root.style.setProperty('--text', style.textColor);
        } else {
            root.style.removeProperty('--text');
        }
        root.dataset.theme = style.isDark ? 'dark' : 'light';
        root.classList.toggle('no-ln', !style.showLineNumbers);
        restoreAnchor(anchor);
    }

    window.foofoilCode = {
        setWorkerSource(text) {
            workerSource = text;
        },

        setStyle(style) {
            applyStyle(style);
        },

        setContent(payload) {
            revision = payload.revision;
            source = payload.source;
            deferredApply = null;
            cancelWorker();
            applyStyle(payload.style);
            const plainHTML = escapeHTML(source);
            applyWhenSelectionClears(() => {
                if (payload.revision !== revision) return;
                if (!renderRows(plainHTML, source)) {
                    post({ type: 'failed', revision: payload.revision, reason: 'verifyFailed' });
                    return;
                }
                window.scrollTo(0, 0);
                post({ type: 'plain', revision: payload.revision });
                if (payload.language) {
                    highlightInWorker(payload.revision, payload.language, source);
                }
            });
        },

        dispose() {
            revision += 1;
            deferredApply = null;
            cancelWorker();
            source = '';
            rowRanges = [];
            hoveredRow = null;
            codeElement.textContent = '';
        },
    };

    // 复制只输出源码片段：行号、行容器与伪元素均不参与。
    function sourceOffset(node, offset) {
        const range = document.createRange();
        range.selectNodeContents(codeElement);
        const position = range.comparePoint(node, offset);
        if (position < 0) return 0;
        if (position > 0) return source.length;
        if (node === codeElement) {
            const child = codeElement.children[offset];
            return child ? Number(child.dataset.s) : source.length;
        }
        const element = node.nodeType === Node.ELEMENT_NODE ? node : node.parentNode;
        const row = element && element.closest ? element.closest('.l') : null;
        if (!row) return 0;
        const content = row.children[1];
        let local;
        if (content.contains(node)) {
            const contentRange = document.createRange();
            contentRange.selectNodeContents(content);
            contentRange.setEnd(node, offset);
            local = contentRange.toString().length;
        } else {
            local = content.compareDocumentPosition(node) & Node.DOCUMENT_POSITION_PRECEDING ? 0 : content.textContent.length;
        }
        return Math.min(Number(row.dataset.s) + local, Number(row.dataset.e));
    }

    document.addEventListener('copy', (event) => {
        const selection = document.getSelection();
        if (!event.clipboardData || !selection || selection.isCollapsed || selection.rangeCount === 0 || !source) return;
        const range = selection.getRangeAt(0);
        const start = sourceOffset(range.startContainer, range.startOffset);
        const end = sourceOffset(range.endContainer, range.endOffset);
        if (end <= start) return;
        event.clipboardData.setData('text/plain', source.slice(start, end));
        event.preventDefault();
    });

    // 鼠标所在的逻辑行整行高亮：只切换一个 class，不改动 DOM 结构，选择与复制不受影响。
    function setHoveredRow(row) {
        if (row === hoveredRow) {
            return;
        }
        if (hoveredRow) {
            hoveredRow.classList.remove('is-hovered');
        }
        hoveredRow = row;
        if (hoveredRow) {
            hoveredRow.classList.add('is-hovered');
        }
    }

    codeElement.addEventListener('mousemove', (event) => {
        const row = event.target instanceof Element ? event.target.closest('.l') : null;
        setHoveredRow(row && codeElement.contains(row) ? row : null);
    });
    codeElement.addEventListener('mouseleave', () => setHoveredRow(null));
    root.addEventListener('mouseleave', () => setHoveredRow(null));

    post({ type: 'ready' });
})();
