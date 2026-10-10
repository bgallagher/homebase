import Foundation
import XCTest
@testable import RackoonCore

final class FaviconLinksTests: XCTestCase {
    private let base = URL(string: "https://app.example.com/dash/index.html")!

    func testOriginIsTheCacheKey() {
        XCTAssertEqual(FaviconLinks.origin(of: "https://App.Example.com/x?y=1"), "https://app.example.com")
        XCTAssertEqual(FaviconLinks.origin(of: "https://a.com:443/"), "https://a.com")
        XCTAssertEqual(FaviconLinks.origin(of: "http://100.125.183.84:8080/path"), "http://100.125.183.84:8080")
        XCTAssertEqual(FaviconLinks.origin(of: "http://a.com:80"), "http://a.com")
        XCTAssertNil(FaviconLinks.origin(of: "ftp://a.com"))
        XCTAssertNil(FaviconLinks.origin(of: "not a url"))
        XCTAssertEqual(FaviconLinks.defaultIcon(for: "http://a.com:8080")?.absoluteString, "http://a.com:8080/favicon.ico")
    }

    func testRanksAppleTouchThenPNGThenSVGThenICOAndResolvesRelativeLinks() {
        let html = """
        <html><head>
        <link rel="stylesheet" href="/s.css">
        <link rel="shortcut icon" href="/favicon.ico">
        <link rel="icon" type="image/svg+xml" href="logo.svg">
        <LINK REL="icon" TYPE="image/png" sizes="32x32" HREF='/img/32.png'>
        <link rel="icon" type="image/png" sizes="16x16 48x48" href="/img/48.png">
        <link rel="apple-touch-icon" sizes="180x180" href="//cdn.example.com/touch.png">
        <link rel="mask-icon" href="/mask.svg" color="#000">
        </head></html>
        """
        let urls = FaviconLinks.candidates(in: html, base: base).map(\.url.absoluteString)
        XCTAssertEqual(urls, ["https://cdn.example.com/touch.png", "https://app.example.com/img/48.png", "https://app.example.com/img/32.png",
                              "https://app.example.com/dash/logo.svg", "https://app.example.com/favicon.ico"])
    }

    func testSkipsNonHTTPAndNonIconLinksAndDuplicates() {
        let html = """
        <link rel="icon" href="data:image/png;base64,AAAA">
        <link rel="icon" href="javascript:alert(1)">
        <link rel="canonical" href="https://app.example.com/">
        <link rel="icon" href="/a.png"><link rel="icon" href="/a.png">
        <link rel="icon">
        """
        XCTAssertEqual(FaviconLinks.candidates(in: html, base: base).map(\.url.absoluteString), ["https://app.example.com/a.png"])
        XCTAssertTrue(FaviconLinks.candidates(in: "<html>no links</html>", base: base).isEmpty)
    }

    func testAttributeParsingHandlesQuotesEntitiesAndOrder() {
        let attrs = FaviconLinks.attributes(of: #"<link href="/i.png?a=1&amp;b=2" rel=icon type='image/png' sizes=64x64>"#)
        XCTAssertEqual(attrs["href"], "/i.png?a=1&b=2")
        XCTAssertEqual(attrs["rel"], "icon")
        XCTAssertEqual(attrs["type"], "image/png")
        XCTAssertEqual(attrs["sizes"], "64x64")
    }

    func testLimit() {
        let html = (1...9).map { #"<link rel="icon" sizes="\#($0)x\#($0)" href="/\#($0).png">"# }.joined()
        XCTAssertEqual(FaviconLinks.candidates(in: html, base: base, limit: 3).count, 3)
        XCTAssertEqual(FaviconLinks.candidates(in: html, base: base, limit: 3).first?.size, 9)
    }
}
