import Foundation

/// The text the input system committed since the terminal line last changed
/// some other way, kept so the input system can read it back and revise it.
///
/// iOS dictation inserts a hypothesis, reads the text before the caret to
/// find it again, and replaces it as recognition improves; with nothing to
/// read back it stops after the first words. The terminal already has the
/// text, so a revision becomes edits a line editor understands: one Delete
/// per character after the unchanged prefix, then the new remainder.
/// SwiftTerm handles dictation the same way.
///
/// Dictation is held back from the terminal, as macOS keeps it marked: once
/// the input system revises the text it inserted last — what streaming
/// dictation does with each better hypothesis — that text is taken back and
/// held from then on. Typing never revises its own insertion, and a text
/// replacement shortcut replaces the typed word, not the space inserted
/// last. Held text stays in the shadow for the input system to revise and
/// is shown as preedit until committed.
struct TerminalInputShadow {
    struct Edit: Equatable {
        var deletions: Int
        var insertion: String

        var isEmpty: Bool {
            deletions == 0 && insertion.isEmpty
        }
    }

    private(set) var text = ""
    private(set) var selectedRange = NSRange(location: 0, length: 0)
    /// The last edit deleted a trailing space, the first half of the
    /// keyboard's split period shortcut.
    private var deletedTrailingSpace = false
    /// Where the input system's last insertion or replacement landed.
    private var lastInsertion: NSRange?
    /// Where held text starts; the text from here is not in the terminal.
    private(set) var heldStart: Int?

    var length: Int {
        (text as NSString).length
    }

    var heldText: String? {
        heldStart.map { (text as NSString).substring(from: $0) }
    }

    /// The part of the shadow the terminal has.
    private var sentText: String {
        heldStart.map { (text as NSString).substring(to: $0) } ?? text
    }

    mutating func reset() {
        self = TerminalInputShadow()
    }

    mutating func select(_ range: NSRange) {
        selectedRange = clamped(range)
    }

    func text(in range: NSRange) -> String? {
        guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= length else { return nil }
        return (text as NSString).substring(with: range)
    }

    mutating func insert(_ replacement: String) -> Edit {
        replace(selectedRange, with: replacement)
    }

    /// Replaces `range` and leaves the caret after the replacement. The edit
    /// covers only what the terminal has; held text changes in place.
    mutating func replace(_ range: NSRange, with replacement: String) -> Edit {
        replace(range, with: replacement, revisable: true)
    }

    /// Sends the held text: the edit inserts it.
    mutating func commitHeld() -> Edit {
        let old = sentText
        heldStart = nil
        return Self.edit(from: old, to: sentText)
    }

    private mutating func replace(_ range: NSRange, with replacement: String, revisable: Bool) -> Edit {
        let range = clamped(range)
        let shortcut = periodShortcutReplacement(range, with: replacement)
        let replacement = shortcut ?? replacement
        let revision = revisable && shortcut == nil && !replacement.isEmpty
            && range.length > 0 && range == lastInsertion && NSMaxRange(range) == length
        deletedTrailingSpace = false
        let old = sentText
        text = (text as NSString).replacingCharacters(in: range, with: replacement)
        selectedRange = NSRange(location: range.location + (replacement as NSString).length, length: 0)
        lastInsertion = NSRange(location: range.location, length: (replacement as NSString).length)
        if let heldStart {
            self.heldStart = min(heldStart, range.location)
        } else if revision {
            heldStart = range.location
        }
        return Self.edit(from: old, to: sentText)
    }

    /// Nil with nothing before the caret: the Delete is the terminal's.
    mutating func deleteBackward() -> Edit? {
        guard selectedRange.length == 0 else {
            return replace(selectedRange, with: "", revisable: false)
        }
        guard selectedRange.location > 0 else {
            deletedTrailingSpace = false
            return nil
        }
        let characterRange = (text as NSString).rangeOfComposedCharacterSequence(at: selectedRange.location - 1)
        let trailingSpace = NSMaxRange(characterRange) == length && text(in: characterRange) == " "
        let edit = replace(characterRange, with: "", revisable: false)
        deletedTrailingSpace = trailingSpace
        return edit
    }

    /// One UTF-16 unit for the document's anchor position: a line break at
    /// the start of a row, a space for a blank cell, a stand-in letter for a
    /// character that needs more units.
    static func anchorText(forTextBeforeCursor text: String?) -> String {
        guard let text else { return "\n" }
        guard let last = text.last, !last.isWhitespace else { return " " }
        return String(last).utf16.count == 1 ? String(last) : "x"
    }

    static func edit(from old: String, to new: String) -> Edit {
        let oldCharacters = Array(old)
        let newCharacters = Array(new)
        var prefix = 0
        while prefix < min(oldCharacters.count, newCharacters.count),
              oldCharacters[prefix] == newCharacters[prefix]
        {
            prefix += 1
        }
        return Edit(
            deletions: oldCharacters.count - prefix,
            insertion: String(newCharacters[prefix...])
        )
    }

    /// The keyboard's double-space period shortcut stays two spaces, as it
    /// was while the document held no text for the shortcut to see. It
    /// arrives either as a replacement of the trailing spaces or as a
    /// Delete of the trailing space followed by "." or ". ".
    private func periodShortcutReplacement(_ range: NSRange, with replacement: String) -> String? {
        guard replacement == "." || replacement == ". " else { return nil }
        if deletedTrailingSpace {
            return replacement == "." ? " " : "  "
        }
        guard NSMaxRange(range) == length, let old = text(in: range) else { return nil }
        if range.length == 0 {
            return replacement == ". " && text.hasSuffix(" ") ? " " : nil
        }
        guard old.count <= 2, old.allSatisfy({ $0 == " " }) else { return nil }
        if old.count == 2 { return old }
        return replacement == "." ? " " : "  "
    }

    private func clamped(_ range: NSRange) -> NSRange {
        let location = min(max(range.location, 0), length)
        let end = min(max(range.location + max(range.length, 0), location), length)
        return NSRange(location: location, length: end - location)
    }
}
