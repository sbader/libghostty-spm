//
//  TerminalIMEComposition.swift
//  libghostty-spm
//
//  Routing decisions for hardware keys between the terminal and the text
//  input system. Pure logic, kept platform-free so the macOS test suite can
//  pin it.
//

import Foundation

enum TerminalIMEComposition {
    /// Whether the input mode identified by `primaryLanguage` composes text
    /// through marked-text preedit instead of inserting each keystroke
    /// directly. These are the modes where a raw hardware key must not reach
    /// the terminal: the input method turns key sequences into text.
    static func languageUsesComposition(_ primaryLanguage: String?) -> Bool {
        guard let primaryLanguage else { return false }
        let language = primaryLanguage.lowercased()
        return language.hasPrefix("zh")
            || language.hasPrefix("ja")
            || language.hasPrefix("ko")
    }

    /// Whether a hardware key press belongs to the text input system rather
    /// than the terminal.
    ///
    /// Typed keys go to the terminal: the text input system shows its accent
    /// menu for a held character key, and a terminal repeats it instead.
    /// The text input system gets only what needs composing:
    /// - every key while marked text is on screen — it moves the composition
    ///   caret, picks candidates, commits, or cancels;
    /// - a dead key (Option-E on U.S., ´ on German), which reports no
    ///   characters until the input method composes it;
    /// - printable keys while a composition input mode is active.
    /// Control characters (Return, Tab, Escape, Delete…) and function keys
    /// keep driving the terminal. Ctrl and Cmd combinations are filtered out
    /// by the caller.
    static func routesToTextInput(
        characters: String?,
        charactersIgnoringModifiers: String?,
        hasMarkedText: Bool,
        inputModeUsesComposition: Bool
    ) -> Bool {
        if hasMarkedText { return true }
        if characters?.isEmpty == true, isPrintable(charactersIgnoringModifiers) { return true }
        return inputModeUsesComposition && isPrintable(characters)
    }

    private static func isPrintable(_ characters: String?) -> Bool {
        guard
            let text = TerminalInputText.filteredFunctionKeyText(characters),
            !text.isEmpty
        else { return false }
        return !text.unicodeScalars.contains {
            $0.value < 0x20 || $0.value == 0x7F
        }
    }
}
