import Foundation
@testable import GhosttyTerminal
import Testing

/// Dictation revises committed text in place; the terminal gets the
/// revision as Deletes and the new remainder.
struct TerminalInputShadowTests {
    @Test
    func `typing at the end sends only the new text`() {
        var shadow = TerminalInputShadow()

        #expect(shadow.insert("ls") == .init(deletions: 0, insertion: "ls"))
        #expect(shadow.insert(" -l") == .init(deletions: 0, insertion: " -l"))
        #expect(shadow.text == "ls -l")
        #expect(shadow.selectedRange == NSRange(location: 5, length: 0))
    }

    @Test
    func `a revised hypothesis deletes back to the common prefix`() {
        var shadow = TerminalInputShadow()
        _ = shadow.insert(" hello word")

        let edit = shadow.replace(NSRange(location: 1, length: 10), with: "hello world")

        #expect(edit == .init(deletions: 1, insertion: "ld"))
        #expect(shadow.text == " hello world")
        #expect(shadow.selectedRange == NSRange(location: 12, length: 0))
    }

    @Test
    func `a selected hypothesis is replaced through insert`() {
        var shadow = TerminalInputShadow()
        _ = shadow.insert(" one two")
        shadow.select(NSRange(location: 5, length: 3))

        #expect(shadow.insert("six") == .init(deletions: 3, insertion: "six"))
        #expect(shadow.text == " one six")
    }

    @Test
    func `editing before the end retypes the rest of the line`() {
        var shadow = TerminalInputShadow()
        _ = shadow.insert("abc")

        #expect(shadow.replace(NSRange(location: 0, length: 1), with: "x") == .init(deletions: 3, insertion: "xbc"))
    }

    @Test
    func `deletions count characters, not utf-16 units`() {
        var shadow = TerminalInputShadow()
        _ = shadow.insert("ok 👍🏽 é")

        #expect(shadow.replace(NSRange(location: 2, length: shadow.length - 2), with: "") == .init(deletions: 4, insertion: ""))
    }

    @Test
    func `delete backward removes one character or reports nothing to delete`() {
        var shadow = TerminalInputShadow()
        #expect(shadow.deleteBackward() == nil)

        _ = shadow.insert("a😀")
        #expect(shadow.deleteBackward() == .init(deletions: 1, insertion: ""))
        #expect(shadow.text == "a")
        #expect(shadow.deleteBackward() == .init(deletions: 1, insertion: ""))
        #expect(shadow.deleteBackward() == nil)
    }

    @Test
    func `the period shortcut keeps two spaces`() {
        var replaced = TerminalInputShadow()
        _ = replaced.insert("word ")
        #expect(replaced.replace(NSRange(location: 4, length: 1), with: ". ") == .init(deletions: 0, insertion: " "))
        #expect(replaced.text == "word  ")

        var split = TerminalInputShadow()
        _ = split.insert("word ")
        _ = split.deleteBackward()
        #expect(split.insert(". ") == .init(deletions: 0, insertion: "  "))
        #expect(split.text == "word  ")

        var inserted = TerminalInputShadow()
        _ = inserted.insert("word ")
        #expect(inserted.insert(". ") == .init(deletions: 0, insertion: " "))
    }

    @Test
    func `dictated punctuation is kept`() {
        var shadow = TerminalInputShadow()
        _ = shadow.insert("hello")

        #expect(shadow.insert(".") == .init(deletions: 0, insertion: "."))
        #expect(shadow.replace(NSRange(location: 0, length: 6), with: "Hello.") == .init(deletions: 6, insertion: "Hello."))
    }

    @Test
    func `out of range edits clamp`() {
        var shadow = TerminalInputShadow()
        _ = shadow.insert("abc")
        shadow.select(NSRange(location: 99, length: 4))

        #expect(shadow.selectedRange == NSRange(location: 3, length: 0))
        #expect(shadow.replace(NSRange(location: -2, length: 3), with: "") == .init(deletions: 3, insertion: "bc"))
        #expect(shadow.text(in: NSRange(location: 1, length: 9)) == nil)
    }

    @Test
    func `the anchor reads as the character before the cursor`() {
        #expect(TerminalInputShadow.anchorText(forTextBeforeCursor: nil) == "\n")
        #expect(TerminalInputShadow.anchorText(forTextBeforeCursor: "") == " ")
        #expect(TerminalInputShadow.anchorText(forTextBeforeCursor: " ") == " ")
        #expect(TerminalInputShadow.anchorText(forTextBeforeCursor: "m") == "m")
        #expect(TerminalInputShadow.anchorText(forTextBeforeCursor: "$") == "$")
        #expect(TerminalInputShadow.anchorText(forTextBeforeCursor: "中") == "中")
        #expect(TerminalInputShadow.anchorText(forTextBeforeCursor: "😀") == "x")
    }

    /// The calls from a device log of "this is dictation", in shadow offsets.
    @Test
    func `streaming dictation is held from its first revision until committed`() {
        var shadow = TerminalInputShadow()

        #expect(shadow.insert("Th") == .init(deletions: 0, insertion: "Th"))
        #expect(shadow.heldText == nil)

        #expect(shadow.replace(NSRange(location: 0, length: 2), with: "This") == .init(deletions: 2, insertion: ""))
        #expect(shadow.heldText == "This")
        #expect(shadow.replace(NSRange(location: 0, length: 4), with: "This is").isEmpty)
        #expect(shadow.replace(NSRange(location: 0, length: 7), with: "this is dictation").isEmpty)
        #expect(shadow.replace(NSRange(location: 0, length: 17), with: "").isEmpty)
        #expect(shadow.insert("this is dictation").isEmpty)
        #expect(shadow.text == "this is dictation")
        #expect(shadow.heldText == "this is dictation")

        #expect(shadow.commitHeld() == .init(deletions: 0, insertion: "this is dictation"))
        #expect(shadow.heldText == nil)
        #expect(shadow.text == "this is dictation")
    }

    @Test
    func `held dictation after typed text keeps the typed text`() {
        var shadow = TerminalInputShadow()
        _ = shadow.insert("git commit -m ")
        _ = shadow.insert("fi")

        #expect(shadow.replace(NSRange(location: 14, length: 2), with: "fix") == .init(deletions: 2, insertion: ""))
        #expect(shadow.heldText == "fix")
        #expect(shadow.commitHeld() == .init(deletions: 0, insertion: "fix"))
        #expect(shadow.text == "git commit -m fix")
    }

    @Test
    func `an edit before held text takes that text back too`() {
        var shadow = TerminalInputShadow()
        _ = shadow.insert("ab")
        _ = shadow.insert("Th")
        _ = shadow.replace(NSRange(location: 2, length: 2), with: "This")

        #expect(shadow.replace(NSRange(location: 1, length: 5), with: "X") == .init(deletions: 1, insertion: ""))
        #expect(shadow.heldText == "X")
        #expect(shadow.commitHeld() == .init(deletions: 0, insertion: "X"))
    }

    @Test
    func `typing, deleting and keyboard shortcuts are never held`() {
        var typed = TerminalInputShadow()
        for character in ["l", "s", " ", "-", "l"] {
            _ = typed.insert(character)
        }
        _ = typed.deleteBackward()
        #expect(typed.heldText == nil)

        var replacement = TerminalInputShadow()
        for character in ["o", "m", "w", " "] {
            _ = replacement.insert(character)
        }
        #expect(replacement.replace(NSRange(location: 0, length: 3), with: "On my way!") == .init(deletions: 4, insertion: "On my way! "))
        #expect(replacement.heldText == nil)

        var period = TerminalInputShadow()
        _ = period.insert("word")
        _ = period.insert(" ")
        _ = period.replace(NSRange(location: 4, length: 1), with: ". ")
        #expect(period.heldText == nil)

        var selected = TerminalInputShadow()
        _ = selected.insert("abc")
        selected.select(NSRange(location: 0, length: 3))
        _ = selected.deleteBackward()
        #expect(selected.heldText == nil)
    }

    @Test
    func `reset drops held text`() {
        var shadow = TerminalInputShadow()
        _ = shadow.insert("Th")
        _ = shadow.replace(NSRange(location: 0, length: 2), with: "This")
        shadow.reset()

        #expect(shadow.heldText == nil)
        #expect(shadow.text.isEmpty)
    }
}
