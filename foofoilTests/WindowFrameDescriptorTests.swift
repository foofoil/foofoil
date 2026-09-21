//  WindowFrameDescriptorTests.swift
//  foofoilTests
//
//  Created by tolg on 2026/9/21.
//

import AppKit
import Testing
@testable import foofoil

@Suite
struct WindowFrameDescriptorTests {
    /// 常态描述符带屏幕框，取前四个数值即可得到窗口框。
    @Test func parsesDescriptorWithScreenFrame() throws {
        let rect = try #require(NSWindow.frameRect(fromDescriptor: "120 340 480 650 0 0 2560 1440 "))
        #expect(rect == NSRect(x: 120, y: 340, width: 480, height: 650))
    }

    /// 只带四个数值的历史写法同样可解析；负坐标表示窗口位于主屏左下方。
    @Test func parsesDescriptorWithoutScreenFrame() throws {
        let rect = try #require(NSWindow.frameRect(fromDescriptor: "-40 -80 512 512"))
        #expect(rect == NSRect(x: -40, y: -80, width: 512, height: 512))
    }

    @Test(arguments: [
        "",
        "480 650",
        "0 0 480",
        "0 0 480 0 ",
        "0 0 0 650 ",
        "0 0 -480 650 ",
        "0 0 480 inf ",
        "0 0 nan 650 ",
        "0 0 480 abc "
    ])
    func rejectsInvalidDescriptors(descriptor: String) {
        #expect(NSWindow.frameRect(fromDescriptor: descriptor) == nil)
    }
}
