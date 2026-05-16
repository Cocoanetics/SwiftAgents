//
//  URLSession+LinuxCompat.swift
//  Providers
//
//  Shims `URLSession.bytes(for:)` and `URLSession.AsyncBytes` on platforms
//  where Foundation's networking pieces live in `FoundationNetworking`
//  (Linux / Windows). swift-corelibs-foundation does not ship those
//  Darwin-only APIs, so building any file that references them fails
//  with `value of type 'URLSession' has no member 'bytes'` and
//  `'AsyncBytes' is not a member type of class 'FoundationNetworking.URLSession'`.
//
//  The shim is not a true byte stream — it performs the regular
//  `URLSession.data(for:)` call, buffers the full body in memory, and
//  replays it as an `AsyncThrowingStream<UInt8, Error>` plus a `.lines`
//  helper. Good enough to type-check and run the non-streaming code
//  paths the test target exercises; consumers that need actual
//  incremental streaming on Linux should swap in a real HTTP client.

#if canImport(FoundationNetworking)
import Foundation
import FoundationNetworking

public extension URLSession {
    struct AsyncBytes: AsyncSequence, Sendable {
        public typealias Element = UInt8

        private let data: Data

        init(data: Data) {
            self.data = data
        }

        public struct AsyncIterator: AsyncIteratorProtocol {
            var iterator: Data.Iterator
            public mutating func next() async throws -> UInt8? {
                iterator.next()
            }
        }

        public func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(iterator: data.makeIterator())
        }

        public var lines: AsyncLineSequence {
            AsyncLineSequence(data: data)
        }

        public struct AsyncLineSequence: AsyncSequence, Sendable {
            public typealias Element = String

            private let data: Data

            init(data: Data) {
                self.data = data
            }

            public struct AsyncIterator: AsyncIteratorProtocol {
                var lines: Array<Substring>.Iterator
                public mutating func next() async throws -> String? {
                    lines.next().map(String.init)
                }
            }

            public func makeAsyncIterator() -> AsyncIterator {
                let string = String(decoding: data, as: UTF8.self)
                // `\r\n` and `\n` both behave as line breaks on macOS's
                // `URLSession.AsyncBytes.lines`; mirror that here.
                let normalized = string.replacingOccurrences(of: "\r\n", with: "\n")
                let pieces = normalized.split(separator: "\n", omittingEmptySubsequences: false)
                // Drop a trailing empty element produced by a final newline,
                // matching Darwin's behaviour where a stream ending in `\n`
                // does not yield an extra empty line.
                var array = Array(pieces)
                if array.last?.isEmpty == true {
                    array.removeLast()
                }
                return AsyncIterator(lines: array.makeIterator())
            }
        }
    }

    func bytes(for request: URLRequest) async throws -> (AsyncBytes, URLResponse) {
        let (data, response) = try await data(for: request)
        return (AsyncBytes(data: data), response)
    }
}
#endif
