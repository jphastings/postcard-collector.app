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
    enum Outcome: Equatable {
        /// Taken in; more chunks to come.
        case incomplete
        /// The last missing chunk: here's the whole blob.
        case complete(Data)
        /// Nothing this chunk can complete — a nonsense index or count, or a later chunk of a
        /// blob whose start was dropped — so the phone should send the blob another way.
        case rejected
    }

    private struct Partial {
        var chunks: [Data?]
        var receivedCount = 0
    }

    let capacity: Int
    private var partials: [String: Partial] = [:]
    /// Incomplete blob ids, oldest first.
    private var order: [String] = []

    init(capacity: Int = 16) {
        self.capacity = max(capacity, 1)
    }

    /// How many blobs are part-way through arriving.
    var incompleteBlobCount: Int { partials.count }

    /// Adds one chunk. The phone sends a blob's chunks in order, each acknowledged before the
    /// next, so a later chunk with no earlier ones here means the blob's start was dropped —
    /// rejected, like a chunk whose index or count doesn't make sense. A repeated chunk is
    /// taken in without effect.
    mutating func add(chunk: Data, index: Int, count: Int, blobID: String) -> Outcome {
        guard count > 0, index >= 0, index < count else { return .rejected }
        guard count > 1 else { return .complete(chunk) }

        let existing = partials[blobID]
        guard existing != nil || index == 0 else { return .rejected }
        var partial = existing ?? Partial(chunks: Array(repeating: nil, count: count))
        guard partial.chunks.count == count else { return .rejected }
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
            return .complete(whole)
        }

        partials[blobID] = partial
        if existing == nil {
            order.append(blobID)
            while order.count > capacity {
                partials[order.removeFirst()] = nil
            }
        }
        return .incomplete
    }
}
