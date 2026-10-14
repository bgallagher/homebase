import XCTest
@testable import RackoonCore

final class ServerListTests: XCTestCase {
    private let servers = [
        Server(id: "a", name: "Homelab", host: "homelab.tail1234.ts.net", user: "andy"),
        Server(id: "b", name: "Garage NUC", host: "192.168.1.20", user: "root"),
        Server(id: "c", name: "Hetzner", host: "hz", sshConfigAlias: "hz"),
        Server(id: "d", name: "Café box", host: "cafe.local"),
    ]

    private func ids(_ list: [Server]) -> [String] { list.map(\.id) }

    func testFilterMatchesNameHostUserAndAliasInSavedOrder() {
        XCTAssertEqual(ids(ServerList.filter(servers, query: "")), ["a", "b", "c", "d"])
        XCTAssertEqual(ids(ServerList.filter(servers, query: "  ")), ["a", "b", "c", "d"])
        XCTAssertEqual(ids(ServerList.filter(servers, query: "HOME")), ["a"])
        XCTAssertEqual(ids(ServerList.filter(servers, query: "192.168")), ["b"])
        XCTAssertEqual(ids(ServerList.filter(servers, query: "root")), ["b"])
        XCTAssertEqual(ids(ServerList.filter(servers, query: "hz")), ["c"])
        XCTAssertEqual(ids(ServerList.filter(servers, query: "cafe")), ["d"], "accents are ignored")
        XCTAssertEqual(ids(ServerList.filter(servers, query: "nuc root")), ["b"], "every word must match")
        XCTAssertEqual(ids(ServerList.filter(servers, query: "nuc andy")), [])
    }

    func testMovingOntoAnotherRowTakesItsPlace() {
        XCTAssertEqual(ids(ServerList.moving("a", onto: "c", in: servers)), ["b", "c", "a", "d"])
        XCTAssertEqual(ids(ServerList.moving("d", onto: "a", in: servers)), ["d", "a", "b", "c"])
        XCTAssertEqual(ids(ServerList.moving("b", onto: "b", in: servers)), ["a", "b", "c", "d"])
        XCTAssertEqual(ids(ServerList.moving("x", onto: "a", in: servers)), ["a", "b", "c", "d"])
    }

    func testMovingByStepsStopsAtTheEnds() {
        XCTAssertEqual(ids(ServerList.moving("b", by: -1, in: servers)), ["b", "a", "c", "d"])
        XCTAssertEqual(ids(ServerList.moving("b", by: 1, in: servers)), ["a", "c", "b", "d"])
        XCTAssertEqual(ids(ServerList.moving("a", by: -1, in: servers)), ["a", "b", "c", "d"])
        XCTAssertEqual(ids(ServerList.moving("d", by: 5, in: servers)), ["a", "b", "c", "d"])
    }

    func testMenuPutsTheSelectedRowOverTheCard() {
        typealias L = ServerMenuLayout
        // Card centred at y = 300 in a tall window; the third of five servers is selected.
        let l = L.place(rows: 5, selectedIndex: 2, cardMidY: 300, windowHeight: 900)
        XCTAssertEqual(l.listHeight, 200)
        XCTAssertEqual(l.scrollOffset, 0)
        let rowCentre = l.top + L.header + 2 * L.rowHeight + L.rowHeight / 2
        XCTAssertEqual(rowCentre, 300, "the selected row's centre lands on the card's centre")
        XCTAssertLessThan(l.top, 300 - 2 * L.rowHeight, "it reaches up for the servers above")
    }

    func testMenuIsPushedBackInsideTheWindow() {
        typealias L = ServerMenuLayout
        // The last of ten servers is selected and the card is near the top: the panel would start above the window.
        let up = L.place(rows: 10, selectedIndex: 9, cardMidY: 80, windowHeight: 900)
        XCTAssertEqual(up.top, L.margin)
        // The card near the bottom with the first server selected: the panel would run off the bottom.
        let down = L.place(rows: 10, selectedIndex: 0, cardMidY: 860, windowHeight: 900)
        XCTAssertEqual(down.top + down.height, 900 - L.margin)
    }

    func testLongListsScrollToTheSelectedRow() {
        typealias L = ServerMenuLayout
        // 40 servers in a 600 pt window: the list gets the room there is and starts scrolled to the selected row.
        let l = L.place(rows: 40, selectedIndex: 30, cardMidY: 120, windowHeight: 600)
        XCTAssertEqual(l.height, 600 - 2 * L.margin)
        XCTAssertEqual(l.top, L.margin)
        XCTAssertEqual(l.scrollOffset, 30 * L.rowHeight + L.rowHeight / 2 - l.listHeight / 2)
        // Near the end the list can't scroll past its last row.
        let end = L.place(rows: 40, selectedIndex: 39, cardMidY: 120, windowHeight: 600)
        XCTAssertEqual(end.scrollOffset, 40 * L.rowHeight - end.listHeight)
        // Room kept clear at the top (the title bar) is honoured.
        let clear = L.place(rows: 40, selectedIndex: 0, cardMidY: 60, windowHeight: 600, topLimit: 36)
        XCTAssertEqual(clear.top, 36)
        XCTAssertEqual(clear.height, 600 - 36 - L.margin)
        // The first server opens right over the card when there is room.
        let first = L.place(rows: 4, selectedIndex: 0, cardMidY: 70, windowHeight: 600, topLimit: 36)
        XCTAssertEqual(first.top + L.header + L.rowHeight / 2, 70)
        // A tiny window still shows a row.
        XCTAssertEqual(L.place(rows: 40, selectedIndex: 0, cardMidY: 50, windowHeight: 100).listHeight, L.rowHeight)
    }
}
