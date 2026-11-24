import XCTest
@testable import HackMail

final class GmailSearchQueryTests: XCTestCase {
    func testRemovesSpaceAfterOperatorColon() {
        XCTAssertEqual(GmailSearchQuery.normalized("to: tim subject: blade"), "to:tim subject:blade")
    }

    func testKeepsAlreadyCompactAndPlainQueries() {
        XCTAssertEqual(GmailSearchQuery.normalized("to:tim subject:blade"), "to:tim subject:blade")
        XCTAssertEqual(GmailSearchQuery.normalized("blade runner"), "blade runner")
    }

    func testHandlesQuotedValuesNegationAndCase() {
        XCTAssertEqual(GmailSearchQuery.normalized("Subject: \"blade runner\" -from: tim"), "Subject:\"blade runner\" -from:tim")
    }

    func testDoesNotTouchNonOperatorsOrEmptyOperatorValues() {
        XCTAssertEqual(GmailSearchQuery.normalized("note: hello"), "note: hello")
        XCTAssertEqual(GmailSearchQuery.normalized("to: subject:blade"), "to: subject:blade")
    }
}
