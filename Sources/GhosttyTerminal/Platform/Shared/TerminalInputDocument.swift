import Foundation

/// The document a text input client presents to the system: `anchorLength`
/// positions whose text the client supplies, then the committed input
/// shadow, then the marked text. Positions handed to the system are document
/// positions; the shadow and marked-text state work in their own offsets, and
/// this is the one place that converts between them.
struct TerminalInputDocument {
    let anchorLength: Int
    var committedLength = 0
    let markedLength: Int

    var length: Int {
        anchorLength + committedLength + markedLength
    }

    private var markedStart: Int {
        anchorLength + committedLength
    }

    /// The document position of an offset into the marked text.
    func position(ofMarkedOffset offset: Int) -> Int {
        markedStart + min(max(offset, 0), markedLength)
    }

    /// The marked-text offset nearest a document position: anything before
    /// the marked text is its start.
    func markedOffset(of position: Int) -> Int {
        min(max(position - markedStart, 0), markedLength)
    }

    /// The part of a document range that lies in the marked text, in
    /// marked-text offsets.
    func markedRange(of range: NSRange) -> NSRange {
        let start = markedOffset(of: range.location)
        let end = max(markedOffset(of: range.location + range.length), start)
        return NSRange(location: start, length: end - start)
    }

    /// The document position of an offset into the committed shadow.
    func position(ofCommittedOffset offset: Int) -> Int {
        anchorLength + min(max(offset, 0), committedLength)
    }

    /// The part of a document range that lies in the committed shadow, in
    /// shadow offsets. The anchor contributes nothing.
    func committedRange(of range: NSRange) -> NSRange {
        let start = min(max(range.location - anchorLength, 0), committedLength)
        let end = min(max(range.location + range.length - anchorLength, start), committedLength)
        return NSRange(location: start, length: end - start)
    }
}
