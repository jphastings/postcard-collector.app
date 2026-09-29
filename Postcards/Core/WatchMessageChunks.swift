import Foundation

/// The pure half of sending a blob (a card face, a collection's details) as WatchConnectivity
/// messages rather than as a file — see `WatchRelay`'s "Blobs as messages". A message is
/// capped at 64KB, so the phone cuts a blob into chunks and the watch stitches them back
/// together. Kept free of WatchConnectivity so it's unit-testable.
enum WatchMessageChunks {
    /// `data` cut into consecutive pieces of at most `maxChunkSize` bytes, in order. Always at
    /// least one piece — even for empty data — so every blob is announced by a message.
    static func chunks(of data: Data, maxChunkSize: Int) -> [Data] {
        let size = max(maxChunkSize, 1)
        guard data.count > size else { return [Data(data)] }
        return stride(from: 0, to: data.count, by: size).map { offset in
            let lower = data.startIndex + offset
            let upper = data.startIndex + min(offset + size, data.count)
            return data.subdata(in: lower..<upper)
        }
    }
}

/// Stitches chunked blobs back together on the watch. Holds at most `capacity` incomplete
/// blobs, dropping the oldest: a blob whose chunks stopped arriving (the phone went out of
/// range mid-send) is re-sent whole through the reliable file queue, so its partial copy here
/// is only ever garbage.
struct WatchChunkAssembler {
    private struct Partial {
        var chunks: [Data?]
        var receivedCount = 0
    }

    let capacity: Int
    private var partials: [String: Partial] = [:]
    /// Incomplete blob ids, oldest first.
    private var order: [String] = []

    init(capacity: Int = 4) {
        self.capacity = max(capacity, 1)
    }

    /// How many blobs are part-way through arriving.
    var incompleteBlobCount: Int { partials.count }

    /// Adds one chunk, returning the whole blob once its last missing chunk arrives. `nil`
    /// while the blob is incomplete, and for a chunk whose index or count doesn't make sense.
    /// A repeated chunk is ignored.
    mutating func add(chunk: Data, index: Int, count: Int, blobID: String) -> Data? {
        guard count > 0, index >= 0, index < count else { return nil }
        guard count > 1 else { return chunk }

        let isNew = partials[blobID] == nil
        var partial = partials[blobID] ?? Partial(chunks: Array(repeating: nil, count: count))
        guard partial.chunks.count == count else { return nil }
        if partial.chunks[index] == nil {
            partial.chunks[index] = chunk
            partial.receivedCount += 1
        }

        guard partial.receivedCount < count else {
            partials[blobID] = nil
            order.removeAll { $0 == blobID }
            var whole = Data()
            for case let piece? in partial.chunks {
                whole.append(piece)
            }
            return whole
        }

        partials[blobID] = partial
        if isNew {
            order.append(blobID)
            while order.count > capacity {
                partials[order.removeFirst()] = nil
            }
        }
        return nil
    }
}
