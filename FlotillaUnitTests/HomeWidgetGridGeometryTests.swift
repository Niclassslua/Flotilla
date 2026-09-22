import XCTest
import SettingsKit
@testable import Flotilla

final class HomeWidgetGridGeometryTests: XCTestCase {
    // MARK: - Cells

    func testCellsAreSquareAndEverySmallWidgetIsTheSameSize() {
        let geometry = HomeWidgetGridGeometry(width: 1_000)
        let ids = (0..<5).map { _ in UUID() }
        let frames = geometry.frames(for: ids.map { ($0, HomeWidgetSize.small) })
        let sizes = Set(ids.compactMap { frames[$0]?.size }.map { "\($0.width)x\($0.height)" })
        XCTAssertEqual(sizes.count, 1, "every small widget must be the same size")
        let size = try! XCTUnwrap(frames[ids[0]]?.size)
        XCTAssertEqual(size.width, size.height, accuracy: 0.001)
    }

    func testRowsAreExactlyCellPlusGapApart() {
        let geometry = HomeWidgetGridGeometry(width: 700)
        let ids = (0..<(geometry.columns * 2)).map { _ in UUID() }
        let frames = geometry.frames(for: ids.map { ($0, HomeWidgetSize.small) })
        let rowTops = Set(frames.values.map(\.minY)).sorted()
        XCTAssertEqual(rowTops, [0, geometry.cell + HomeWidgetGridGeometry.gap])
    }

    func testLargeIsTwoCellsTallIncludingTheGap() {
        let geometry = HomeWidgetGridGeometry(width: 900)
        let id = UUID()
        let frame = try! XCTUnwrap(geometry.frames(for: [(id, HomeWidgetSize.large)])[id])
        XCTAssertEqual(frame.height, geometry.cell * 2 + HomeWidgetGridGeometry.gap, accuracy: 0.001)
    }

    func testColumnCountClampsBetweenTwoAndSix() {
        XCTAssertEqual(HomeWidgetGridGeometry(width: 100).columns, 2)
        XCTAssertEqual(HomeWidgetGridGeometry(width: 5_000).columns, 6)
    }

    func testCellNeverExceedsTheMaximumAndWideGridIsCentered() {
        let geometry = HomeWidgetGridGeometry(width: 5_000)
        XCTAssertEqual(geometry.cell, HomeWidgetGridGeometry.maxColumnWidth)
        XCTAssertGreaterThan(geometry.originX, 0)
    }

    func testWideFillsTheRowAtEveryColumnCount() {
        for width in stride(from: CGFloat(340), through: 1_300, by: 120) {
            let geometry = HomeWidgetGridGeometry(width: width)
            XCTAssertEqual(geometry.columnSpan(for: .wide), geometry.columns, "width \(width)")
        }
    }

    func testContributionsOnWideSpansOneRow() {
        let geometry = HomeWidgetGridGeometry(width: 1_000)
        let id = UUID()
        let frames = geometry.frames(for: [(id, HomeWidgetSize.wide, HomeWidgetKind.contributions)])
        let frame = try! XCTUnwrap(frames[id])
        XCTAssertEqual(frame.height, geometry.cell, accuracy: 0.001)
    }

    func testBusiestHoursDoesNotSupportWide() {
        XCTAssertFalse(HomeWidgetKind.busiestHours.supportedSizes.contains(.wide))
        XCTAssertEqual(HomeWidgetKind.busiestHours.supportedSizes, [.medium])
    }

    func testWeeklyRhythmDoesNotSupportWide() {
        XCTAssertFalse(HomeWidgetKind.weeklyRhythm.supportedSizes.contains(.wide))
        XCTAssertEqual(HomeWidgetKind.weeklyRhythm.supportedSizes, [.medium])
    }

    func testCodebaseGrowthLargeIsFourWideAndOneHigh() {
        XCTAssertTrue(HomeWidgetKind.codebaseGrowth.supportedSizes.contains(.large))
        let geometry = HomeWidgetGridGeometry(width: 1_200)
        XCTAssertGreaterThanOrEqual(geometry.columns, 4)
        let id = UUID()
        let frames = geometry.frames(for: [(id, HomeWidgetSize.large, HomeWidgetKind.codebaseGrowth)])
        let frame = try! XCTUnwrap(frames[id])
        XCTAssertEqual(frame.height, geometry.cell, accuracy: 0.001)
        let expectedWidth = geometry.cell * 4 + HomeWidgetGridGeometry.gap * 3
        XCTAssertEqual(frame.width, expectedWidth, accuracy: 0.001)
    }

    func testSupportedSizesAreOrderedInNaturalAscendingOrder() {
        let naturalOrder = HomeWidgetSize.allCases
        for kind in HomeWidgetKind.allCases {
            let indices = kind.supportedSizes.compactMap { naturalOrder.firstIndex(of: $0) }
            XCTAssertEqual(indices, indices.sorted(), "\(kind.rawValue) supportedSizes must be in natural ascending order")
        }
    }

    // MARK: - Resize snapping

    func testDraggingAMediumHandleDownSnapsToLarge() {
        let geometry = HomeWidgetGridGeometry(width: 1_000)
        let medium = CGSize(width: geometry.cell * 2 + HomeWidgetGridGeometry.gap, height: geometry.cell)
        let dragged = CGSize(width: medium.width, height: medium.height + geometry.cell)
        XCTAssertEqual(geometry.nearestSize(to: dragged, among: [.medium, .small, .large]), .large)
    }

    func testDraggingAWideHandleLeftSnapsToMedium() {
        // Wide and medium have different spans at any real column count —
        // the previous resize compared areas and couldn't tell them apart.
        let geometry = HomeWidgetGridGeometry(width: 1_000)
        let medium = CGSize(width: geometry.cell * 2 + HomeWidgetGridGeometry.gap, height: geometry.cell)
        XCTAssertEqual(geometry.nearestSize(to: medium, among: [.wide, .medium]), .medium)
    }

    func testASmallHandleMovedBarelyStaysSmall() {
        let geometry = HomeWidgetGridGeometry(width: 1_000)
        let almost = CGSize(width: geometry.cell + 20, height: geometry.cell + 20)
        XCTAssertEqual(geometry.nearestSize(to: almost, among: [.small, .medium]), .small)
    }

    // MARK: - Move

    private func layout(_ sizes: [HomeWidgetSize], width: CGFloat = 1_000) -> (ids: [UUID], frames: [UUID: CGRect]) {
        let ids = sizes.map { _ in UUID() }
        let geometry = HomeWidgetGridGeometry(width: width)
        return (ids, geometry.frames(for: Array(zip(ids, sizes)).map { ($0.0, $0.1) }))
    }

    func testDraggingOverAnotherWidgetTakesItsIndex() {
        let (ids, frames) = layout([.small, .small, .small])
        let over = CGPoint(x: frames[ids[2]]!.midX, y: frames[ids[2]]!.midY)
        let decision = HomeWidgetGridGeometry.moveTarget(pointer: over, dragged: ids[0], order: ids, frames: frames, lastSwap: nil)
        XCTAssertEqual(decision.index, 2)
        XCTAssertEqual(decision.lastSwap, ids[2])
    }

    func testDraggingOverItsOwnSlotDoesNothing() {
        let (ids, frames) = layout([.small, .small])
        let own = CGPoint(x: frames[ids[0]]!.midX, y: frames[ids[0]]!.midY)
        let decision = HomeWidgetGridGeometry.moveTarget(pointer: own, dragged: ids[0], order: ids, frames: frames, lastSwap: nil)
        XCTAssertNil(decision.index)
    }

    func testTheLastSwapTargetIsIgnoredUntilThePointerLeavesIt() {
        let (ids, frames) = layout([.small, .small])
        let over = CGPoint(x: frames[ids[1]]!.midX, y: frames[ids[1]]!.midY)
        let decision = HomeWidgetGridGeometry.moveTarget(pointer: over, dragged: ids[0], order: ids, frames: frames, lastSwap: ids[1])
        XCTAssertNil(decision.index, "swapping straight back would oscillate")
        XCTAssertEqual(decision.lastSwap, ids[1])
    }

    func testDraggingBelowEverythingMovesToTheEnd() {
        let (ids, frames) = layout([.small, .small, .small])
        let below = CGPoint(x: 10, y: (frames.values.map(\.maxY).max() ?? 0) + 40)
        let decision = HomeWidgetGridGeometry.moveTarget(pointer: below, dragged: ids[0], order: ids, frames: frames, lastSwap: nil)
        XCTAssertEqual(decision.index, ids.count)
    }
}

@MainActor
final class HomeWidgetEditorTests: XCTestCase {
    private var saved: [HomeWidgetEntry]?
    private var saveCount = 0

    private func makeEditor(_ entries: [HomeWidgetEntry]? = nil) -> HomeWidgetEditor {
        saved = entries
        saveCount = 0
        return HomeWidgetEditor(settings: .init(
            get: { [unowned self] in self.saved },
            set: { [unowned self] in self.saved = $0; self.saveCount += 1 }
        ))
    }

    func testNoSavedLayoutStartsFromTheDefault() {
        let editor = makeEditor(nil)
        XCTAssertEqual(editor.entries.map(\.kind), HomeWidgetKind.defaultLayout.map(\.kind))
    }

    func testResizingOutsideEditModeSavesImmediately() {
        let editor = makeEditor()
        let id = editor.entries[1].id
        editor.setSize(id: id, to: .wide)
        XCTAssertEqual(saved?.first { $0.id == id }?.size, HomeWidgetSize.wide.rawValue)
    }

    func testEditsInsideASessionOnlySaveOnDone() {
        let editor = makeEditor()
        editor.beginEditing(undoManager: nil)
        editor.add(kind: .streak)
        XCTAssertEqual(saveCount, 0)
        editor.commit()
        XCTAssertEqual(saveCount, 1)
        XCTAssertEqual(saved?.last?.kind, HomeWidgetKind.streak.rawValue)
    }

    func testCancelDiscardsTheDraft() {
        let editor = makeEditor()
        let before = editor.entries
        editor.beginEditing(undoManager: nil)
        editor.remove(id: before[0].id)
        editor.cancel()
        XCTAssertEqual(editor.entries, before)
        XCTAssertEqual(saveCount, 0)
    }

    func testMoveReordersAndKeepsEveryWidget() {
        let editor = makeEditor()
        let ids = editor.entries.map(\.id)
        editor.move(id: ids[0], to: 2)
        XCTAssertEqual(Set(editor.entries.map(\.id)), Set(ids))
        XCTAssertEqual(editor.entries.map(\.id), [ids[1], ids[2], ids[0], ids[3], ids[4]])
    }

    func testAddUsesTheRequestedSizeOnlyIfTheWidgetSupportsIt() {
        let editor = makeEditor()
        editor.add(kind: .hotFiles, size: .large)
        XCTAssertEqual(editor.entries.last?.size, HomeWidgetSize.large.rawValue)
        editor.add(kind: .streak, size: .wide)
        XCTAssertEqual(editor.entries.last?.size, HomeWidgetSize.small.rawValue, "streak has no wide layout")
    }

    func testTheLiveResizeProposalOverridesTheSavedSize() {
        let editor = makeEditor()
        let entry = editor.entries[1]
        editor.resize = .init(id: entry.id, startSize: .zero, proposedSize: .wide)
        XCTAssertEqual(editor.liveSize(of: entry), .wide)
        editor.resize = nil
        XCTAssertEqual(editor.liveSize(of: entry), entry.resolvedSize)
    }

    func testUndoRevertsAChangeInsideTheSession() {
        let editor = makeEditor()
        let undo = UndoManager()
        undo.groupsByEvent = false
        let before = editor.entries
        editor.beginEditing(undoManager: undo)
        undo.beginUndoGrouping()
        editor.remove(id: before[0].id)
        undo.endUndoGrouping()
        undo.undo()
        XCTAssertEqual(editor.entries, before)
    }
}
