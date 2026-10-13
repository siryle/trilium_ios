import Foundation
import XCTest
@testable import TriliumPocket

final class SSEParserTests: XCTestCase {
    func testCRLFAndUnicodeSurviveIndividualByteDelivery() throws {
        let payload = "{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"你好 👋 café\"}}]}"
        let result = try events(Data("data: \(payload)\r\n\r\ndata: [DONE]\r\n\r\n".utf8))
        XCTAssertEqual(result, [payload, "[DONE]"])
    }

    func testMultilineDataIsJoinedOnlyAtBlankEventBoundary() throws {
        var parser = SSEParser()
        for byte in Data("event: message\ndata: {\"choices\":\ndata: []}\n".utf8) {
            XCTAssertNil(try parser.append(byte))
        }
        XCTAssertEqual(try parser.append(10), "{\"choices\":\n[]}")
    }

    func testHeartbeatsCommentsAndUnknownFieldsProduceNoEvents() throws {
        let stream = "\n:\n\n: keepalive\r\n\r\nevent: ignored\nid: 12\nretry: 1000\n\ndata: [DONE]\n\n"
        XCTAssertEqual(try events(Data(stream.utf8)), ["[DONE]"])
    }

    func testDataPrefixAllowsNoSpaceAndRemovesOnlyOneOptionalSpace() throws {
        XCTAssertEqual(try events(Data("data:first\n\ndata:  second\n\n".utf8)), ["first", " second"])
    }

    func testCRSeparatorsDoNotRequireLineFeed() throws {
        XCTAssertEqual(try events(Data("data: first\r\rdata: second\r\r".utf8)), ["first", "second"])
    }

    func testTrailingUnterminatedEventIsNotDeliveredAsComplete() throws {
        XCTAssertEqual(try events(Data("data: first\n\ndata: unfinished\n".utf8)), ["first"])
    }

    func testEmptyDataAndErrorFramesRemainAvailableToProtocolDecoder() throws {
        let error = "{\"error\":{\"message\":\"Rate limited\"}}"
        XCTAssertEqual(try events(Data("data:\n\ndata: \(error)\n\n".utf8)), ["", error])
    }

    func testInvalidUTF8IsRejectedAtLineBoundary() throws {
        var parser = SSEParser()
        for byte in Data("data: ".utf8) { XCTAssertNil(try parser.append(byte)) }
        XCTAssertNil(try parser.append(0xFF))
        XCTAssertThrowsError(try parser.append(10))
    }

    func testOversizedSingleLineIsRejectedWithoutNeedingTerminator() throws {
        var parser = SSEParser()
        for _ in 0..<1_048_576 { _ = try parser.append(65) }
        XCTAssertThrowsError(try parser.append(65))
    }

    func testOversizedMultilineEventIsRejectedDespiteBoundedIndividualLines() {
        let field = "data: " + String(repeating: "a", count: 400_000) + "\n"
        XCTAssertThrowsError(try events(Data((field + field + field).utf8)))
    }

    private func events(_ data: Data) throws -> [String] {
        var parser = SSEParser()
        var result: [String] = []
        for byte in data {
            if let event = try parser.append(byte) { result.append(event) }
        }
        return result
    }
}
