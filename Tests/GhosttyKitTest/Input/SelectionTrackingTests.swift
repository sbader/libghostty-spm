import Dispatch
import Foundation
import GhosttyKit
@testable import GhosttyTerminal
import Testing

#if os(macOS)
@MainActor
struct SelectionTrackingTests {
    @Test func resettingTheScreenInvalidatesTrackedSelection() async throws {
        let harness = await GhosttySurfaceHarness.make(hostAuthoritativeResize: true)
        defer { harness.tearDown() }
        let surface = try #require(harness.surface)
        harness.receive("\u{1B}[2J\u{1B}[Htoken")
        try #require(surface.selectCells(0 ... 4))
        harness.receive("\u{1B}ctoken")
        #expect(surface.selectedCells() == nil)
        #expect(!surface.hasSelection())
        surface.clearTrackedSelection()
    }

    @Test func trackedSelectionFollowsColumnReflowWithoutSelectingRepeatedText() async throws {
        let harness = await GhosttySurfaceHarness.make(hostAuthoritativeResize: true)
        defer { harness.tearDown() }
        let surface = try #require(harness.surface)
        let initialResize = await withCheckedContinuation { continuation in
            harness.session.resizeForSelectionTest(columns: 20, rows: 8, widthPixels: 200, heightPixels: 160) {
                continuation.resume(returning: $0)
            }
        }
        try #require(initialResize)
        harness.receive("\u{1B}[2J\u{1B}[Hheader\r\n" + String(repeating: "a", count: 17) + "rotation tail\r\nrotation duplicated")
        try #require(surface.selectCells(37 ... 44))
        #expect(surface.readCells(37 ... 44, columns: 20)?.text == "rotation")
        #expect(!surface.hasSelection())

        for columns in [UInt16(12), 40, 20] {
            let resized = await withCheckedContinuation { continuation in
                harness.session.resizeForSelectionTest(
                    columns: columns, rows: 8, widthPixels: UInt32(columns) * 10, heightPixels: 160
                ) { continuation.resume(returning: $0) }
            }
            try #require(resized)
            let range = try #require(surface.selectedCells())
            #expect(surface.readCells(range, columns: Int(columns))?.text == "rotation")
            if columns == 12 { #expect(range != 37 ... 44) }
            #expect(!surface.hasSelection())
        }
        surface.clearTrackedSelection()
        #expect(surface.selectedCells() == nil)
        #expect(!surface.hasSelection())
        #expect(harness.outboundBytes.isEmpty)
    }

    @Test func trackedUnicodeSelectionSurvivesReflowAndHistoryScroll() async throws {
        let harness = await GhosttySurfaceHarness.make(hostAuthoritativeResize: true)
        defer { harness.tearDown() }
        let surface = try #require(harness.surface)
        let initialResize = await withCheckedContinuation { continuation in
            harness.session.resizeForSelectionTest(columns: 20, rows: 8, widthPixels: 200, heightPixels: 160) {
                continuation.resume(returning: $0)
            }
        }
        try #require(initialResize)
        harness.receive("\u{1B}[2J\u{1B}[Hheader\r\nprefix 你好😀e\u{301} tail")
        try #require(surface.selectCells(27 ... 33))
        for columns in [UInt16(12), 40, 20] {
            let resized = await withCheckedContinuation { continuation in
                harness.session.resizeForSelectionTest(
                    columns: columns, rows: 8, widthPixels: UInt32(columns) * 10, heightPixels: 160
                ) { continuation.resume(returning: $0) }
            }
            try #require(resized)
            let range = try #require(surface.selectedCells())
            #expect(surface.readCells(range, columns: Int(columns))?.text == "你好😀e\u{301}")
        }
        harness.receive(String(repeating: "\r\nmore history", count: 30))
        let range = try #require(surface.selectedCells())
        #expect(surface.readCells(range, columns: 20)?.text == "你好😀e\u{301}")
        #expect(surface.scrollToRow(UInt(range.lowerBound / 20)))
        #expect(surface.selectedCells() == range)
        #expect(!surface.hasSelection())
        #expect(harness.outboundBytes.isEmpty)
    }
}
#endif

#if os(macOS)
@MainActor
private extension InMemoryTerminalSession {
    func resizeForSelectionTest(
        columns: UInt16, rows: UInt16, widthPixels: UInt32, heightPixels: UInt32,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        enqueueSurfaceOperation { surface in
            let result = ghostty_surface_apply_host_resize(surface, columns, rows, widthPixels, heightPixels)
            DispatchQueue.main.async { completion(result) }
        }
    }
}
#endif
