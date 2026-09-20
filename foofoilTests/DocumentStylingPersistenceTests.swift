//  DocumentStylingPersistenceTests.swift
//  foofoilTests
//
//  Created by tolg on 2026/9/18.
//

import Foundation
import SQLite3
import Testing
@testable import foofoil

/// 文档内容样式（背景色、文字颜色、字体）必须能落到历史库并原样读回；
/// 旧库缺列时由启动迁移补齐，补列后读写照常。
@MainActor
@Suite(.serialized)
struct DocumentStylingPersistenceTests {
    @Test func historyRoundTripsDocumentStyling() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("history.sqlite3")
        let config = WindowConfig(
            id: UUID(),
            text: "正文",
            backgroundColorHex: "#F5EFE0",
            textColorHex: "#123456",
            documentFontName: "Menlo-Regular",
            documentLineSpacing: 1.6,
            documentParagraphSpacing: 0.8
        )

        let database = try HistoryDatabase(databaseURL: databaseURL)
        try database.upsert(config)
        let loaded = try #require(try database.config(id: config.id))
        #expect(loaded.backgroundColorHex == "#F5EFE0")
        #expect(loaded.textColorHex == "#123456")
        #expect(loaded.documentFontName == "Menlo-Regular")
        #expect(loaded.documentLineSpacing == 1.6)
        #expect(loaded.documentParagraphSpacing == 0.8)
    }

    /// 载入历史时样式一起回到箔上。
    @Test func loadingHistoryRestoresDocumentStyling() throws {
        let state = AppState()
        defer { HistoryManager.shared.removeFromHistory(state.toConfig()) }

        let config = WindowConfig(
            id: state.id,
            text: "正文",
            backgroundColorHex: "#F5EFE0",
            textColorHex: "#123456",
            documentFontName: "Menlo-Regular",
            documentLineSpacing: 1.7,
            documentParagraphSpacing: 0.5
        )
        state.loadConfig(config)

        #expect(state.backgroundColorHex == "#F5EFE0")
        #expect(state.textColorHex == "#123456")
        #expect(state.documentFontName == "Menlo-Regular")
        #expect(state.documentLineSpacing == 1.7)
        #expect(state.documentParagraphSpacing == 0.5)
    }

    /// 模拟旧库：去掉两个新列后重开，迁移应补回列并回到默认值，随后仍可正常写入。
    @Test func legacyDatabaseGainsStylingColumns() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("history.sqlite3")
        let config = WindowConfig(
            id: UUID(),
            text: "正文",
            textColorHex: "#123456",
            documentFontName: "Songti SC",
            documentLineSpacing: 2.0
        )

        let database = try HistoryDatabase(databaseURL: databaseURL)
        try database.upsert(config)
        try dropColumn("text_color_hex", from: databaseURL)
        try dropColumn("document_font_name", from: databaseURL)
        try dropColumn("document_line_spacing", from: databaseURL)

        let migrated = try HistoryDatabase(databaseURL: databaseURL)
        let legacy = try #require(try migrated.config(id: config.id))
        #expect(legacy.textColorHex == nil, "补列后应回到默认值")
        #expect(legacy.documentFontName == nil)
        #expect(legacy.documentLineSpacing == nil)

        try migrated.upsert(config)
        let rewritten = try #require(try migrated.config(id: config.id))
        #expect(rewritten.textColorHex == "#123456")
        #expect(rewritten.documentFontName == "Songti SC")
        #expect(rewritten.documentLineSpacing == 2.0)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("foofoil-styling-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func dropColumn(_ name: String, from databaseURL: URL) throws {
        var connection: OpaquePointer?
        #expect(sqlite3_open(databaseURL.path, &connection) == SQLITE_OK)
        defer { sqlite3_close(connection) }
        let result = sqlite3_exec(connection, "ALTER TABLE history_items DROP COLUMN \(name)", nil, nil, nil)
        #expect(result == SQLITE_OK, "无法删除列 \(name)：\(String(cString: sqlite3_errmsg(connection)))")
    }
}
