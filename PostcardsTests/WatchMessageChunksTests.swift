import XCTest

final class WatchMessageChunksTests: XCTestCase {
    private func bytes(_ count: Int) -> Data {
        Data((0..<count).map { UInt8($0 % 251) })
    }

    // MARK: - Splitting

    func testSmallBlobIsOneChunk() {
        let data = bytes(10)
        XCTAssertEqual(WatchMessageChunks.chunks(of: data, maxChunkSize: 16), [data])
    }

    func testEmptyBlobIsStillOneChunk() {
        XCTAssertEqual(WatchMessageChunks.chunks(of: Data(), maxChunkSize: 16), [Data()])
    }

    func testLargeBlobSplitsIntoFullChunksAndARemainder() {
        let chunks = WatchMessageChunks.chunks(of: bytes(40), maxChunkSize: 16)
        XCTAssertEqual(chunks.map(\.count), [16, 16, 8])
        XCTAssertEqual(chunks.reduce(into: Data()) { $0.append($1) }, bytes(40))
    }

    func testExactMultipleHasNoEmptyTrailingChunk() {
        XCTAssertEqual(WatchMessageChunks.chunks(of: bytes(32), maxChunkSize: 16).map(\.count), [16, 16])
    }

    func testSplittingASliceUsesItsOwnBytes() {
        let whole = bytes(100)
        let slice = whole[50..<90]
        let chunks = WatchMessageChunks.chunks(of: slice, maxChunkSize: 16)
        XCTAssertEqual(chunks.reduce(into: Data()) { $0.append($1) }, Data(slice))
    }

    // MARK: - Reassembly

    func testSingleChunkBlobIsCompleteImmediately() {
        var assembler = WatchChunkAssembler()
        XCTAssertEqual(assembler.add(chunk: bytes(5), index: 0, count: 1, blobID: "a"), bytes(5))
        XCTAssertEqual(assembler.incompleteBlobCount, 0)
    }

    func testChunksReassembleInOrderWhateverOrderTheyArrive() {
        let chunks = WatchMessageChunks.chunks(of: bytes(40), maxChunkSize: 16)
        var assembler = WatchChunkAssembler()

        XCTAssertNil(assembler.add(chunk: chunks[2], index: 2, count: 3, blobID: "a"))
        XCTAssertNil(assembler.add(chunk: chunks[0], index: 0, count: 3, blobID: "a"))
        XCTAssertEqual(assembler.add(chunk: chunks[1], index: 1, count: 3, blobID: "a"), bytes(40))
        XCTAssertEqual(assembler.incompleteBlobCount, 0)
    }

    func testARepeatedChunkIsIgnored() {
        let chunks = WatchMessageChunks.chunks(of: bytes(20), maxChunkSize: 16)
        var assembler = WatchChunkAssembler()

        XCTAssertNil(assembler.add(chunk: chunks[0], index: 0, count: 2, blobID: "a"))
        XCTAssertNil(assembler.add(chunk: chunks[0], index: 0, count: 2, blobID: "a"))
        XCTAssertEqual(assembler.add(chunk: chunks[1], index: 1, count: 2, blobID: "a"), bytes(20))
    }

    func testInterleavedBlobsAssembleIndependently() {
        let first = WatchMessageChunks.chunks(of: bytes(20), maxChunkSize: 16)
        let second = WatchMessageChunks.chunks(of: Data(bytes(20).reversed()), maxChunkSize: 16)
        var assembler = WatchChunkAssembler()

        XCTAssertNil(assembler.add(chunk: first[0], index: 0, count: 2, blobID: "a"))
        XCTAssertNil(assembler.add(chunk: second[0], index: 0, count: 2, blobID: "b"))
        XCTAssertEqual(assembler.add(chunk: second[1], index: 1, count: 2, blobID: "b"), Data(bytes(20).reversed()))
        XCTAssertEqual(assembler.add(chunk: first[1], index: 1, count: 2, blobID: "a"), bytes(20))
    }

    func testNonsenseIndicesAreRejected() {
        var assembler = WatchChunkAssembler()
        XCTAssertNil(assembler.add(chunk: bytes(1), index: 2, count: 2, blobID: "a"))
        XCTAssertNil(assembler.add(chunk: bytes(1), index: -1, count: 2, blobID: "a"))
        XCTAssertNil(assembler.add(chunk: bytes(1), index: 0, count: 0, blobID: "a"))
        XCTAssertEqual(assembler.incompleteBlobCount, 0)
    }

    func testAChunkClaimingADifferentCountForAKnownBlobIsIgnored() {
        var assembler = WatchChunkAssembler()
        XCTAssertNil(assembler.add(chunk: bytes(1), index: 0, count: 2, blobID: "a"))
        XCTAssertNil(assembler.add(chunk: bytes(1), index: 1, count: 3, blobID: "a"))
        XCTAssertEqual(assembler.incompleteBlobCount, 1)
    }

    func testTheOldestIncompleteBlobIsDroppedPastCapacity() {
        var assembler = WatchChunkAssembler(capacity: 2)
        XCTAssertNil(assembler.add(chunk: bytes(1), index: 0, count: 2, blobID: "a"))
        XCTAssertNil(assembler.add(chunk: bytes(1), index: 0, count: 2, blobID: "b"))
        XCTAssertNil(assembler.add(chunk: bytes(1), index: 0, count: 2, blobID: "c"))
        XCTAssertEqual(assembler.incompleteBlobCount, 2)

        // "a" was dropped, so its second chunk starts it afresh rather than completing it.
        XCTAssertNil(assembler.add(chunk: bytes(1), index: 1, count: 2, blobID: "a"))
        // "c" survived.
        XCTAssertNotNil(assembler.add(chunk: bytes(1), index: 1, count: 2, blobID: "c"))
    }
}
