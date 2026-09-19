import XCTest
@testable import Flotilla

final class HomeWidgetPackerTests: XCTestCase {
    private typealias Item = HomeWidgetPacker.Item<String>

    func testSingleColumnItemsStackVertically() {
        let items = [Item(id: "a", columnSpan: 1, rowSpan: 1), Item(id: "b", columnSpan: 1, rowSpan: 1)]
        let rects = HomeWidgetPacker.pack(items, columns: 1)
        XCTAssertEqual(rects["a"], HomeWidgetRect(column: 0, row: 0, columnSpan: 1, rowSpan: 1))
        XCTAssertEqual(rects["b"], HomeWidgetRect(column: 0, row: 1, columnSpan: 1, rowSpan: 1))
    }

    func testItemsFillARowBeforeWrapping() {
        let items = (0..<4).map { Item(id: "\($0)", columnSpan: 1, rowSpan: 1) }
        let rects = HomeWidgetPacker.pack(items, columns: 3)
        XCTAssertEqual(rects["0"]?.column, 0); XCTAssertEqual(rects["0"]?.row, 0)
        XCTAssertEqual(rects["1"]?.column, 1); XCTAssertEqual(rects["1"]?.row, 0)
        XCTAssertEqual(rects["2"]?.column, 2); XCTAssertEqual(rects["2"]?.row, 0)
        XCTAssertEqual(rects["3"]?.column, 0); XCTAssertEqual(rects["3"]?.row, 1)
    }

    /// A large (2x2) widget leaves a hole beside it that a later small widget
    /// should fill — dense packing, not strict placement order.
    func testDenseFillsHolesLeftByALargeWidget() {
        let items = [
            Item(id: "large", columnSpan: 2, rowSpan: 2),
            Item(id: "small1", columnSpan: 1, rowSpan: 1),
            Item(id: "small2", columnSpan: 1, rowSpan: 1),
        ]
        let rects = HomeWidgetPacker.pack(items, columns: 3)
        XCTAssertEqual(rects["large"], HomeWidgetRect(column: 0, row: 0, columnSpan: 2, rowSpan: 2))
        // The 3rd column, row 0 is free next to the large widget — dense
        // packing should claim it before wrapping to a new row.
        XCTAssertEqual(rects["small1"], HomeWidgetRect(column: 2, row: 0, columnSpan: 1, rowSpan: 1))
        XCTAssertEqual(rects["small2"], HomeWidgetRect(column: 2, row: 1, columnSpan: 1, rowSpan: 1))
    }

    func testWideItemAlreadyResolvedToColumnsFillsTheRow() {
        let items = [
            Item(id: "wide", columnSpan: 4, rowSpan: 1),
            Item(id: "next", columnSpan: 1, rowSpan: 1),
        ]
        let rects = HomeWidgetPacker.pack(items, columns: 4)
        XCTAssertEqual(rects["wide"], HomeWidgetRect(column: 0, row: 0, columnSpan: 4, rowSpan: 1))
        XCTAssertEqual(rects["next"], HomeWidgetRect(column: 0, row: 1, columnSpan: 1, rowSpan: 1))
    }

    func testWideAtEveryColumnCountSpansTheFullRow() {
        for columns in HomeWidgetGridLayout.minColumns...HomeWidgetGridLayout.maxColumns {
            let items = [Item(id: "wide", columnSpan: columns, rowSpan: 1)]
            let rects = HomeWidgetPacker.pack(items, columns: columns)
            XCTAssertEqual(rects["wide"]?.columnSpan, columns, "columns=\(columns)")
        }
    }

    /// A widget wider than the available columns is clamped rather than
    /// overflowing — e.g. a `large` (2-wide) widget on a 2-column grid still
    /// fits after `HomeWidgetGridLayout` resolves `wide`, but nothing should
    /// ever be asked to place wider than the grid itself.
    func testColumnSpanWiderThanGridIsClamped() {
        let items = [Item(id: "big", columnSpan: 5, rowSpan: 1)]
        let rects = HomeWidgetPacker.pack(items, columns: 2)
        XCTAssertEqual(rects["big"]?.columnSpan, 2)
    }

    func testEmptyItemsProduceEmptyResult() {
        XCTAssertTrue(HomeWidgetPacker.pack([Item](), columns: 4).isEmpty)
    }

    func testZeroColumnsProducesEmptyResult() {
        let items = [Item(id: "a", columnSpan: 1, rowSpan: 1)]
        XCTAssertTrue(HomeWidgetPacker.pack(items, columns: 0).isEmpty)
    }

    func testLargeWidgetOnTwoColumnGridUsesTheWholeWidth() {
        let items = [Item(id: "large", columnSpan: 2, rowSpan: 2)]
        let rects = HomeWidgetPacker.pack(items, columns: 2)
        XCTAssertEqual(rects["large"], HomeWidgetRect(column: 0, row: 0, columnSpan: 2, rowSpan: 2))
    }

    // MARK: - Insertion index

    func testInsertionIndexBeforeFirstFrame() {
        let frames = [CGRect(x: 0, y: 0, width: 170, height: 170)]
        let index = HomeWidgetPacker.insertionIndex(for: CGPoint(x: -10, y: -10), orderedFrames: frames)
        XCTAssertEqual(index, 0)
    }

    func testInsertionIndexPastLastFrame() {
        let frames = [CGRect(x: 0, y: 0, width: 170, height: 170)]
        let index = HomeWidgetPacker.insertionIndex(for: CGPoint(x: 200, y: 400), orderedFrames: frames)
        XCTAssertEqual(index, 1)
    }

    func testInsertionIndexBetweenTwoFramesInTheSameRow() {
        let frames = [
            CGRect(x: 0, y: 0, width: 170, height: 170),
            CGRect(x: 186, y: 0, width: 170, height: 170),
        ]
        // Left of the first frame's midpoint: insert before it.
        XCTAssertEqual(HomeWidgetPacker.insertionIndex(for: CGPoint(x: 40, y: 50), orderedFrames: frames), 0)
        // Right of the second frame's midpoint: insert after it.
        XCTAssertEqual(HomeWidgetPacker.insertionIndex(for: CGPoint(x: 340, y: 50), orderedFrames: frames), 2)
    }

    func testEmptyFramesInsertsAtZero() {
        XCTAssertEqual(HomeWidgetPacker.insertionIndex(for: CGPoint(x: 10, y: 10), orderedFrames: []), 0)
    }
}
