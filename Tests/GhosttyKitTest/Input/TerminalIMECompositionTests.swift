@testable import GhosttyTerminal
import Testing

// Typed keys drive the terminal; the text input system gets only what needs
// composing — dead keys, marked text, and composition input modes. These
// tests pin that routing.
struct TerminalIMECompositionTests {
    @Test
    func `composition languages are detected by primary language prefix`() {
        #expect(TerminalIMEComposition.languageUsesComposition("zh-Hans"))
        #expect(TerminalIMEComposition.languageUsesComposition("zh-Hant"))
        #expect(TerminalIMEComposition.languageUsesComposition("ja-JP"))
        #expect(TerminalIMEComposition.languageUsesComposition("ko-KR"))

        #expect(!TerminalIMEComposition.languageUsesComposition("en-US"))
        #expect(!TerminalIMEComposition.languageUsesComposition("de-DE"))
        #expect(!TerminalIMEComposition.languageUsesComposition("emoji"))
        #expect(!TerminalIMEComposition.languageUsesComposition("dictation"))
        #expect(!TerminalIMEComposition.languageUsesComposition(nil))
    }

    @Test
    func `marked text claims every key for the input method`() {
        for characters in ["n", " ", "\r", "\u{1B}", "1", "", "UIKeyInputUpArrow"] {
            for composition in [false, true] {
                #expect(TerminalIMEComposition.routesToTextInput(
                    characters: characters,
                    charactersIgnoringModifiers: characters,
                    hasMarkedText: true,
                    inputModeUsesComposition: composition
                ))
            }
        }
    }

    @Test
    func `printable keys go to the terminal in direct input modes`() {
        for characters in ["n", "N", " ", "1", ";", "∫", "é", "\u{A0}"] {
            #expect(!TerminalIMEComposition.routesToTextInput(
                characters: characters,
                charactersIgnoringModifiers: "n",
                hasMarkedText: false,
                inputModeUsesComposition: false
            ))
        }
    }

    @Test
    func `printable keys go to an active composition input mode`() {
        for characters in ["n", "N", " ", "1", ";"] {
            #expect(TerminalIMEComposition.routesToTextInput(
                characters: characters,
                charactersIgnoringModifiers: characters,
                hasMarkedText: false,
                inputModeUsesComposition: true
            ))
        }
    }

    @Test
    func `dead keys go to the text input system in every input mode`() {
        for composition in [false, true] {
            #expect(TerminalIMEComposition.routesToTextInput(
                characters: "",
                charactersIgnoringModifiers: "e",
                hasMarkedText: false,
                inputModeUsesComposition: composition
            ))
        }
    }

    @Test
    func `control and function keys keep driving the terminal`() {
        for characters in [
            "\r", // Return: must stay a real Enter key event
            "\t",
            "\u{1B}", // Escape
            "\u{7F}", // Delete
            "\u{8}",
            "UIKeyInputUpArrow",
            "\u{F700}", // AppKit-style function key scalar
        ] {
            #expect(!TerminalIMEComposition.routesToTextInput(
                characters: characters,
                charactersIgnoringModifiers: characters,
                hasMarkedText: false,
                inputModeUsesComposition: true
            ))
        }
    }

    @Test
    func `modifier-only and empty presses keep driving the terminal`() {
        for ignoring in ["", "\u{8}", "\u{7F}", "UIKeyInputUpArrow"] {
            #expect(!TerminalIMEComposition.routesToTextInput(
                characters: "",
                charactersIgnoringModifiers: ignoring,
                hasMarkedText: false,
                inputModeUsesComposition: true
            ))
        }
    }
}
