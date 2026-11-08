import Foundation
import Testing
@testable import StulpKit

@Suite("Gebeurtenissen")
struct EventParserTests {
    /// What Stulp writes: a connected comment, framed events, keepalives.
    @Test func framesCommentsAndKeepalives() {
        var parser = EventParser()
        let lines = [
            ": connected", "",
            "id: 1", "event: device.update",
            #"data: {"manager":"devices","type":"device.update","id":"d1","data":{"id":"d1","name":"Lamp"}}"#, "",
            ": keepalive", "",
            "id: 2", "event: flow.update", #"data: {"manager":"flow","type":"flow.update","id":"f1","data":null}"#, "",
        ]
        let events = lines.compactMap { parser.feed($0) }
        #expect(events.count == 2)
        #expect(events[0].manager == "devices")
        #expect(events[0].type == "device.update")
        #expect(events[0].id == "d1")
        #expect(events[0].data?["name"] == "Lamp")
        #expect(events[1].type == "flow.update")
        #expect(events[1].data == nil)
    }

    /// `AsyncLineSequence` drops empty lines: the next `event:` line ends the previous event.
    @Test func withoutBlankLines() {
        var parser = EventParser()
        let lines = [
            "event: a", #"data: {"manager":"apps","type":"app.state"}"#,
            "event: b", #"data: {"manager":"store","type":"store.reload"}"#,
        ]
        var events = lines.compactMap { parser.feed($0) }
        if let last = parser.feed("") { events.append(last) }
        #expect(events.map(\.type) == ["app.state", "store.reload"])
        #expect(events.map(\.manager) == ["apps", "store"])
    }

    @Test func multiLineData() {
        var parser = EventParser()
        _ = parser.feed("event: notification.create")
        _ = parser.feed(#"data: {"manager":"notifications","#)
        _ = parser.feed(#"data: "type":"notification.create","data":{"excerpt":"Deurbel"}}"#)
        let event = parser.feed("")
        #expect(event?.type == "notification.create")
        #expect(event?.data?["excerpt"] == "Deurbel")
    }

    @Test func garbageIsSkipped() {
        var parser = EventParser()
        _ = parser.feed("data: not json")
        #expect(parser.feed("") == nil)
        _ = parser.feed(#"data:{"manager":"system","type":"system.update"}"#)
        #expect(parser.feed("")?.type == "system.update")
    }
}
