//
//  FoilExposeShortcutTests.swift
//  foofoil
//
//  Created by tolg on 2026/9/14.
//

import Foundation
import Testing
@testable import foofoil

struct FoilExposeShortcutTests {
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
