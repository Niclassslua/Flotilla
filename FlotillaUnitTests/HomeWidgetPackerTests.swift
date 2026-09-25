import XCTest
@testable import Flotilla

final class HomeWidgetPackerTests: XCTestCase {
    private typealias Item = HomeWidgetPacker.Item<String>

    func testPackShapes() {
        // Single column stacks vertically.
        do {
            let items = [Item(id: "a", columnSpan: 1, rowSpan: 1), Item(id: "b", columnSpan: 1, rowSpan: 1)]
            let rects = HomeWidgetPacker.pack(items, columns: 1)
            XCTAssertEqual(rects["a"], HomeWidgetRect(column: 0, row: 0, columnSpan: 1, rowSpan: 1))
            XCTAssertEqual(rects["b"], HomeWidgetRect(column: 0, row: 1, columnSpan: 1, rowSpan: 1))
        }

        // Fill a row before wrapping.
        do {
            let items = (0..<4).map { Item(id: "\($0)", columnSpan: 1, rowSpan: 1) }
            let rects = HomeWidgetPacker.pack(items, columns: 3)
            XCTAssertEqual(rects["0"]?.column, 0); XCTAssertEqual(rects["0"]?.row, 0)
            XCTAssertEqual(rects["1"]?.column, 1); XCTAssertEqual(rects["1"]?.row, 0)
            XCTAssertEqual(rects["2"]?.column, 2); XCTAssertEqual(rects["2"]?.row, 0)
            XCTAssertEqual(rects["3"]?.column, 0); XCTAssertEqual(rects["3"]?.row, 1)
        }

        // Dense packing fills holes beside a large widget.
        do {
            let items = [
                Item(id: "large", columnSpan: 2, rowSpan: 2),
                Item(id: "small1", columnSpan: 1, rowSpan: 1),
                Item(id: "small2", columnSpan: 1, rowSpan: 1),
            ]
            let rects = HomeWidgetPacker.pack(items, columns: 3)
            XCTAssertEqual(rects["large"], HomeWidgetRect(column: 0, row: 0, columnSpan: 2, rowSpan: 2))
            XCTAssertEqual(rects["small1"], HomeWidgetRect(column: 2, row: 0, columnSpan: 1, rowSpan: 1))
            XCTAssertEqual(rects["small2"], HomeWidgetRect(column: 2, row: 1, columnSpan: 1, rowSpan: 1))
        }

        // Wide item fills the row; next wraps.
        do {
            let items = [
                Item(id: "wide", columnSpan: 4, rowSpan: 1),
                Item(id: "next", columnSpan: 1, rowSpan: 1),
            ]
            let rects = HomeWidgetPacker.pack(items, columns: 4)
            XCTAssertEqual(rects["wide"], HomeWidgetRect(column: 0, row: 0, columnSpan: 4, rowSpan: 1))
            XCTAssertEqual(rects["next"], HomeWidgetRect(column: 0, row: 1, columnSpan: 1, rowSpan: 1))
        }

        XCTAssertEqual(
            HomeWidgetPacker.pack([Item(id: "big", columnSpan: 5, rowSpan: 1)], columns: 2)["big"]?.columnSpan,
            2
        )
        XCTAssertTrue(HomeWidgetPacker.pack([Item](), columns: 4).isEmpty)
        XCTAssertTrue(HomeWidgetPacker.pack([Item(id: "x", columnSpan: 1, rowSpan: 1)], columns: 0).isEmpty)
        XCTAssertEqual(
            HomeWidgetPacker.pack([Item(id: "large", columnSpan: 2, rowSpan: 2)], columns: 2)["large"],
            HomeWidgetRect(column: 0, row: 0, columnSpan: 2, rowSpan: 2)
        )
    }

    func testInsertionIndexRelativeToFrames() {
        let single = [CGRect(x: 0, y: 0, width: 170, height: 170)]
        XCTAssertEqual(HomeWidgetPacker.insertionIndex(for: CGPoint(x: -10, y: -10), orderedFrames: single), 0)
        XCTAssertEqual(HomeWidgetPacker.insertionIndex(for: CGPoint(x: 200, y: 400), orderedFrames: single), 1)
        XCTAssertEqual(HomeWidgetPacker.insertionIndex(for: CGPoint(x: 10, y: 10), orderedFrames: []), 0)

        let row = [
            CGRect(x: 0, y: 0, width: 170, height: 170),
            CGRect(x: 186, y: 0, width: 170, height: 170),
        ]
        XCTAssertEqual(HomeWidgetPacker.insertionIndex(for: CGPoint(x: 40, y: 50), orderedFrames: row), 0)
        XCTAssertEqual(HomeWidgetPacker.insertionIndex(for: CGPoint(x: 340, y: 50), orderedFrames: row), 2)
    }
}
