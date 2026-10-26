import XCTest
@testable import LitePad

final class FileFormatTests: XCTestCase {
    func testUTF8RoundTrip() {
        let text = "hello 世界"
        XCTAssertTrue(TextEncoding.utf8.roundTrips(text, with: Data(text.utf8)))
    }

    func testGB18030RoundTrip() throws {
        let text = "简体中文"
        let data = try XCTUnwrap(TextEncoding.gb18030.encode(text))
        XCTAssertTrue(TextEncoding.gb18030.roundTrips(text, with: data))
    }

    func testLossyDecodeFailsRoundTrip() {
        // 非法 UTF-8 字节经 String(decoding:) 会变成替换字符，再编码必然与磁盘字节不同
        let data = Data([0xFF, 0xFE, 0x41])
        let decoded = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(TextEncoding.utf8.roundTrips(decoded, with: data))
    }

    func testSaveCleanupTrimsTrailingWhitespace() {
        let cleaned = SaveCleanup.applying(to: "a  \nb\t\n",
                                           trimTrailingWhitespace: true,
                                           ensureFinalNewline: false,
                                           lineEnding: .lf)
        XCTAssertEqual(cleaned, "a\nb\n")
    }

    func testSaveCleanupEnsuresFinalNewline() {
        let cleaned = SaveCleanup.applying(to: "a",
                                           trimTrailingWhitespace: false,
                                           ensureFinalNewline: true,
                                           lineEnding: .crlf)
        XCTAssertEqual(cleaned, "a\r\n")
    }

    func testLineEndingApplyingUnifiesMixedEndings() {
        XCTAssertEqual(LineEnding.crlf.applying(to: "a\nb\r\nc"), "a\r\nb\r\nc")
    }
}

final class IndentRulesTests: XCTestCase {
    func testWidthIsClamped() {
        XCTAssertEqual(IndentRules.clampedWidth(0), 1)
        XCTAssertEqual(IndentRules.clampedWidth(99), 16)
        XCTAssertEqual(IndentRules.clampedWidth(4), 4)
    }

    func testIndentUnit() {
        XCTAssertEqual(IndentRules.unit(width: 4, insertSpaces: true), "    ")
        XCTAssertEqual(IndentRules.unit(width: 4, insertSpaces: false), "\t")
    }

    func testLeadingWhitespace() {
        XCTAssertEqual(IndentRules.leadingWhitespace(of: " \t x"), " \t ")
        XCTAssertEqual(IndentRules.leadingWhitespace(of: "x"), "")
    }
}

final class LineOperationsTests: XCTestCase {
    func testDeduplicateKeepsFirstOccurrence() {
        let outcome = LineOperations.apply(.deduplicate, to: "b\na\nb\n",
                                           lineRange: nil, lineComment: nil)
        XCTAssertNil(outcome.errorMessage)
        XCTAssertEqual(outcome.text, "b\na\n")
    }

    func testSortAscending() {
        let outcome = LineOperations.apply(.sortAscending, to: "b\na\n",
                                           lineRange: nil, lineComment: nil)
        XCTAssertEqual(outcome.text, "a\nb\n")
    }

    func testCommentRequiresSymbol() {
        let outcome = LineOperations.apply(.comment, to: "a\n",
                                           lineRange: nil, lineComment: nil)
        XCTAssertNotNil(outcome.errorMessage)
    }
}
