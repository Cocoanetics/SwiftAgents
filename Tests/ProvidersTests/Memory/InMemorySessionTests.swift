//
//  InMemorySessionTests.swift
//  ProvidersTests
//
//  Offline tests for the InMemorySession actor: add / get / pop / clear,
//  the `limit` tail-slice semantics, and seeded initial state.
//

import Foundation
@testable import Providers
import Testing

struct InMemorySessionTests {
    @Test("Empty session starts with no items")
    func emptyOnInit() async {
        let session = InMemorySession()
        let items = await session.getItems(limit: nil)
        #expect(items.isEmpty)
    }

    @Test("addItems appends in order; getItems returns chronological")
    func appendInOrder() async {
        let session = InMemorySession()
        await session.addItems([
            .userMessage("first"),
            .userMessage("second")
        ])
        await session.addItems([.userMessage("third")])

        let items = await session.getItems(limit: nil)
        #expect(items.count == 3)
        if case let .message(msg) = items[0],
           case let .inputText(text) = msg.content.first {
            #expect(text == "first")
        } else { Issue.record("unexpected shape at 0") }
        if case let .message(msg) = items[2],
           case let .inputText(text) = msg.content.first {
            #expect(text == "third")
        } else { Issue.record("unexpected shape at 2") }
    }

    @Test("limit slices from the tail")
    func limitTakesMostRecent() async {
        let session = InMemorySession()
        await session.addItems([
            .userMessage("a"),
            .userMessage("b"),
            .userMessage("c"),
            .userMessage("d")
        ])

        let lastTwo = await session.getItems(limit: 2)
        #expect(lastTwo.count == 2)
        if case let .message(msg) = lastTwo[0],
           case let .inputText(text) = msg.content.first {
            #expect(text == "c")
        } else { Issue.record("unexpected") }
    }

    @Test("limit larger than count returns all")
    func limitLargerThanCount() async {
        let session = InMemorySession()
        await session.addItems([.userMessage("only")])
        let items = await session.getItems(limit: 99)
        #expect(items.count == 1)
    }

    @Test("popItem removes and returns the last item")
    func popItem() async {
        let session = InMemorySession()
        await session.addItems([
            .userMessage("keep"),
            .userMessage("popped")
        ])

        let popped = await session.popItem()
        #expect(popped != nil)
        if case let .message(msg) = popped,
           case let .inputText(text) = msg.content.first {
            #expect(text == "popped")
        } else { Issue.record("unexpected pop shape") }

        let remaining = await session.getItems(limit: nil)
        #expect(remaining.count == 1)
    }

    @Test("popItem on empty session returns nil")
    func popEmpty() async {
        let session = InMemorySession()
        let popped = await session.popItem()
        #expect(popped == nil)
    }

    @Test("clearSession wipes all items")
    func clearSession() async {
        let session = InMemorySession()
        await session.addItems([.userMessage("a"), .userMessage("b")])
        await session.clearSession()
        let items = await session.getItems(limit: nil)
        #expect(items.isEmpty)
    }

    @Test("Sessions can be seeded at construction for resume scenarios")
    func seededSession() async {
        let session = InMemorySession(
            sessionId: "saved-session",
            items: [.userMessage("hello"), .userMessage("world")]
        )
        let items = await session.getItems(limit: nil)
        #expect(items.count == 2)
        #expect(await session.sessionId == "saved-session")
    }
}
