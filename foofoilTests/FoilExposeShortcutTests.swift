//
//  FoilExposeShortcutTests.swift
//  foofoil
//
//  Created by tolg on 2026/9/14.
//

import AppKit
import Testing
@testable import foofoil

struct FoilExposeShortcutTests {
    @Test func globalAndFileShortcutGroups() {
        #expect(KeyboardShortcutCatalog.sections.prefix(2) == [.global, .file])
        #expect(KeyboardShortcutCatalog.global.map(\.id) == ["window.showAllFoils", "global.openClipboardContent"])
        #expect(KeyboardShortcutCatalog.global.last?.defaultShortcut == nil)
        #expect(!KeyboardShortcutCatalog.window.contains { $0.id == "window.showAllFoils" })
        #expect(KeyboardShortcutCatalog.openClipboardContent.defaultShortcut ==
                KeyboardShortcut(keyEquivalent: "v", modifiers: [.command, .shift]))
        let ids = KeyboardShortcutCatalog.sections.flatMap { $0.definitions.map(\.id) }
        #expect(Set(ids).count == ids.count)
        let camera = try? #require(KeyboardShortcutCatalog.definition(withID: "file.openCamera"))
        #expect(camera?.titleKey == "Open Camera")
        #expect(camera?.defaultShortcut == nil)
        #expect(KeyboardShortcutCatalog.file.contains { $0.id == "file.openCamera" })
    }

    @Test func shortcutsAreGroupedByPurpose() {
        #expect(KeyboardShortcutCatalog.sections == [.global, .file, .go, .view, .image, .web, .playback, .window, .history])
        #expect(KeyboardShortcutCatalog.image.map(\.id) == [
            "edit.extractText", "edit.extractImageSubject", "view.selectColor", "view.slideshow",
            "view.fitWindowToImage", "view.fitImageToWindowWidth"
        ])
        #expect(KeyboardShortcutCatalog.web.map(\.id) == [
            "file.openInBrowser", "file.copyURL", "view.reloadPage", "view.captureImage"
        ])
        #expect(KeyboardShortcutCatalog.go.suffix(2).map(\.id) == ["view.toggleNavigator", "view.moveNavigatorSide"])
        #expect(KeyboardShortcutCatalog.definition(withID: "view.toggleFullScreen")?.titleKey == "Shortcut Toggle Full Screen")
        #expect(KeyboardShortcutCatalog.definition(withID: "edit.extractImageSubject")?.noteKey == "Shortcut Scope Detected Image Subject")
    }

    @Test func indicesZeroThroughEightMapToDigits() {
        #expect(FoilExposeShortcut.key(forIndex: 0) == "1")
        #expect(FoilExposeShortcut.key(forIndex: 4) == "5")
        #expect(FoilExposeShortcut.key(forIndex: 8) == "9")
    }

    @Test func indicesNineThroughThirtyFourMapToLetters() {
        #expect(FoilExposeShortcut.key(forIndex: 9) == "A")
        #expect(FoilExposeShortcut.key(forIndex: 10) == "B")
        #expect(FoilExposeShortcut.key(forIndex: 16) == "H")
        #expect(FoilExposeShortcut.key(forIndex: 34) == "Z")
    }

    @Test func indexThirtyFiveAndBeyondHaveNoShortcut() {
        #expect(FoilExposeShortcut.key(forIndex: 35) == nil)
        #expect(FoilExposeShortcut.key(forIndex: 100) == nil)
    }

    @Test func negativeIndicesHaveNoShortcut() {
        #expect(FoilExposeShortcut.key(forIndex: -1) == nil)
        #expect(FoilExposeShortcut.key(forIndex: -9) == nil)
    }

    @Test func allAssignedShortcutsAreUnique() {
        let keys = (0..<35).compactMap { FoilExposeShortcut.key(forIndex: $0) }
        #expect(keys.count == 35)
        #expect(Set(keys).count == 35)
    }
}
