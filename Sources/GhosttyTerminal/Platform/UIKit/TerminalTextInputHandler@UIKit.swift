//
//  TerminalTextInputHandler@UIKit.swift
//  libghostty-spm
//

#if canImport(UIKit)
    import GhosttyKit
    import UIKit

    @MainActor
    final class TerminalTextInputHandler {
        private weak var view: UITerminalView?
        private var markedTextState = TerminalMarkedTextState()
        private var shadow = TerminalInputShadow()
        /// The anchor's text from the shadow's first edit until it resets;
        /// see `anchorText`.
        private var shadowAnchorText: String?

        var hasMarkedText: Bool {
            markedTextState.hasMarkedText
        }

        /// Positions the UITextInput document holds before the marked text.
        ///
        /// The software keyboard's held Delete stops the moment the caret is
        /// at the start of the document: before every repeat, UIKit's
        /// `handleAutoDeleteWithExecutionContext:` asks
        /// `-[UIResponder _selectionAtDocumentStart]` — `compare(
        /// selectedTextRange.start, beginningOfDocument) == .orderedSame` —
        /// and clears the repeat timer when it says yes. A terminal's
        /// document is only ever the composition, empty at a prompt, so the
        /// caret was always at its start and a held Delete sent exactly one
        /// backspace. One position of anchor ahead of the composition keeps
        /// the caret off the start; it reads as the character before the
        /// terminal's cursor (`anchorText`). Catalyst has no software
        /// keyboard and keeps the plain document.
        #if targetEnvironment(macCatalyst)
            private static let documentAnchorLength = 0
        #else
            private static let documentAnchorLength = 1
        #endif

        /// The UITextInput document. Every `TerminalTextPosition` the view
        /// hands UIKit is a position in it.
        var document: TerminalInputDocument {
            TerminalInputDocument(
                anchorLength: Self.documentAnchorLength,
                committedLength: shadow.length,
                markedLength: markedTextState.documentLength
            )
        }

        /// What the anchor reads as: the character before the terminal's
        /// cursor where the shadow starts. Dictation reads it to decide
        /// whether to put a space before its first word, as iTerm2 serves
        /// the screen for dictation spacing on macOS. Kept while the shadow
        /// empties: dictation's final result deletes its hypothesis and
        /// inserts again before the terminal has echoed the deletes.
        private var anchorText: String {
            if let shadowAnchorText {
                return shadowAnchorText
            }
            return TerminalInputShadow.anchorText(forTextBeforeCursor: view?.surface?.textBeforeCursor())
        }

        init(view: UITerminalView) {
            self.view = view
        }

        // MARK: - Text Input

        func insertText(
            _ text: String,
            applyingStickyModifiers: Bool = false
        ) {
            guard let view else { return }

            TerminalDebugLog.log(
                .input,
                "insertText text=\(TerminalDebugLog.describe(text)) marked=\(hasMarkedText)"
            )

            view.inputDelegate?.textWillChange(view)
            view.inputDelegate?.selectionWillChange(view)

            if markedTextState.hasMarkedText {
                markedTextState.clear()
                view.surface?.preedit("")
            }
            commit(text, applyingStickyModifiers: applyingStickyModifiers)
            view.refreshInputAccessoryContent()

            view.inputDelegate?.selectionDidChange(view)
            view.inputDelegate?.textDidChange(view)
        }

        /// Committed text joins the shadow and reaches the terminal as the
        /// shadow's edit. Text the shadow cannot revise later — sticky
        /// modified keys, lines — ends it.
        private func commit(_ text: String, applyingStickyModifiers: Bool) {
            #if !targetEnvironment(macCatalyst)
                if applyingStickyModifiers {
                    commitHeldDictation(reason: "sticky modifiers")
                    resetShadow()
                    _ = view?.handleStickyCommittedText(text)
                    return
                }
            #endif
            freezeAnchorText()
            apply(shadow.insert(text), reason: "commit")
        }

        /// The cursor moves past the shadow's own text, so the anchor is
        /// read once, before the shadow's first edit.
        private func freezeAnchorText() {
            guard shadowAnchorText == nil, Self.documentAnchorLength > 0 else { return }
            shadowAnchorText = anchorText
            TerminalDebugLog.log(
                .ime,
                "shadow anchor=\(TerminalDebugLog.describe(shadowAnchorText))"
            ) // Debug: dictation
        }

        private func resetShadow() {
            shadow.reset()
            shadowAnchorText = nil
        }

        /// Sends a shadow edit: one Delete per character removed, then the
        /// new text.
        private func apply(_ edit: TerminalInputShadow.Edit, reason: String) {
            TerminalDebugLog.log(
                .ime,
                "shadow \(reason) deletions=\(edit.deletions) insertion=\(TerminalDebugLog.describe(edit.insertion)) shadow=\(TerminalDebugLog.describe(shadow.text)) selected=\(TerminalDebugLog.describe(shadow.selectedRange))"
            ) // Debug: dictation
            guard let view else { return }
            for _ in 0 ..< edit.deletions {
                view.sendBackspaceKey()
            }
            // Text with a line break goes as a paste and cannot be revised.
            if edit.insertion.contains(where: \.isNewline) {
                resetShadow()
            }
            sendTypedText(edit.insertion)
            if !hasMarkedText {
                view.surface?.preedit(shadow.heldText ?? "")
            }
        }

        // MARK: - Held dictation

        var holdsDictation: Bool {
            shadow.heldStart != nil
        }

        /// Sends held dictation to the terminal; it stays in the shadow as
        /// committed text the input system can still read.
        func commitHeldDictation(reason: String) {
            guard holdsDictation else { return }
            TerminalDebugLog.log(
                .ime,
                "dictation commit reason=\(reason) held=\(TerminalDebugLog.describe(shadow.heldText))"
            ) // Debug: dictation
            apply(shadow.commitHeld(), reason: "commit held")
        }

        /// UIKit's final dictation result. The hypothesis it replaces has
        /// already been deleted through the document.
        func insertDictationResult(_ text: String) {
            TerminalDebugLog.log(
                .ime,
                "dictation result text=\(TerminalDebugLog.describe(text)) held=\(TerminalDebugLog.describe(shadow.heldText))"
            ) // Debug: dictation
            if !text.isEmpty {
                insertText(text)
            }
            commitHeldDictation(reason: "result")
        }

        /// Deliver keyboard text the way a hardware keystroke does: on a key
        /// event that carries the text, so ghostty's key encoder writes the
        /// bytes.
        ///
        /// `ghostty_surface_text` is documented as "treated like a paste" —
        /// it lands in `completeClipboardPaste`, so with bracketed paste
        /// (mode 2004) active every software-keyboard character reaches the
        /// shell wrapped in `ESC[200~ … ESC[201~`. zsh renders a pasted
        /// region with `zle_highlight`'s `paste:standout`, which is why the
        /// character just typed shows up reverse-video until the next edit
        /// redraws the line. AppKit never hits this because typed text rides
        /// its `keyDown` event, and the bundled sample app never hits it
        /// because its simulated shell has no bracketed paste at all.
        ///
        /// The keycode is deliberately out of the AppKit virtual-keycode
        /// table, so ghostty resolves the physical key to `.unidentified`
        /// and encodes from the text alone. Both of ghostty's encoders
        /// handle that: the legacy one writes unmodified printable text
        /// directly, and the Kitty one treats an unmapped key carrying UTF-8
        /// as a pure text event — the same shape IME commits already had.
        ///
        /// Real pastes (the accessory's Paste button, the edit menu's
        /// `paste(_:)`) keep using `paste(text:)`, where the bracketed-paste
        /// markers belong. Text with newlines is routed there too: whatever
        /// produced it, a shell must not see those lines as Return presses.
        private func sendTypedText(_ text: String) {
            guard let view, !text.isEmpty else { return }

            guard !text.contains(where: \.isNewline) else {
                TerminalDebugLog.log(
                    .input,
                    "typed text has newlines, sending as paste bytes=\(text.utf8.count)"
                )
                view.paste(text: text)
                return
            }

            var event = ghostty_input_key_s()
            event.action = GHOSTTY_ACTION_PRESS
            event.mods = ghostty_input_mods_e(rawValue: 0)
            event.consumed_mods = ghostty_input_mods_e(rawValue: 0)
            event.keycode = 0xFFFF
            event.composing = false
            event.unshifted_codepoint = text.unicodeScalars.first.map(\.value) ?? 0

            text.withCString { ptr in
                event.text = ptr
                view.sendInputKeyEvent(event)
            }
        }

        func setMarkedText(_ text: String?, selectedRange: NSRange) {
            guard let view else { return }
            commitHeldDictation(reason: "marked text")
            let shouldNotifySelectionChange = shouldNotifySelectionChange

            TerminalDebugLog.log(
                .ime,
                "setMarkedText text=\(TerminalDebugLog.describe(text)) selected=\(TerminalDebugLog.describe(selectedRange))"
            )

            #if !targetEnvironment(macCatalyst)
                if let text, !text.isEmpty {
                    if view.stickyModifiers.hasActiveModifiers {
                        view.inputDelegate?.textWillChange(view)
                        if shouldNotifySelectionChange {
                            view.inputDelegate?.selectionWillChange(view)
                        }

                        markedTextState.clear()
                        resetShadow()
                        view.surface?.preedit("")
                        _ = view.handleStickyMarkedText(text)
                        view.refreshInputAccessoryContent()

                        if shouldNotifySelectionChange {
                            view.inputDelegate?.selectionDidChange(view)
                        }
                        view.inputDelegate?.textDidChange(view)
                        return
                    }
                }
            #endif

            view.dismissTouchSelection()
            view.inputDelegate?.textWillChange(view)
            view.inputDelegate?.selectionWillChange(view)

            // The composition sits at the terminal's cursor, after the shadow.
            shadow.select(NSRange(location: shadow.length, length: 0))
            markedTextState.setMarkedText(text, selectedRange: selectedRange)

            if let text = markedTextState.text, !text.isEmpty {
                view.surface?.preedit(text)
            } else {
                view.surface?.preedit("")
            }
            view.refreshInputAccessoryContent()

            view.inputDelegate?.selectionDidChange(view)
            view.inputDelegate?.textDidChange(view)
        }

        func unmarkText(
            applyingStickyModifiers: Bool = false
        ) {
            guard let view else { return }
            let shouldNotifySelectionChange = shouldNotifySelectionChange
            let committedText = markedTextState.text

            TerminalDebugLog.log(
                .ime,
                "unmarkText committed=\(TerminalDebugLog.describe(committedText))"
            )

            view.inputDelegate?.textWillChange(view)
            if shouldNotifySelectionChange {
                view.inputDelegate?.selectionWillChange(view)
            }

            markedTextState.clear()
            view.surface?.preedit("")
            if let committedText, !committedText.isEmpty {
                commit(committedText, applyingStickyModifiers: applyingStickyModifiers)
            }
            view.refreshInputAccessoryContent()

            if shouldNotifySelectionChange {
                view.inputDelegate?.selectionDidChange(view)
            }
            view.inputDelegate?.textDidChange(view)
        }

        func markedTextRange() -> TerminalTextRange? {
            guard markedTextState.hasMarkedText else { return nil }
            return TerminalTextRange(
                location: document.position(ofMarkedOffset: markedTextState.markedRange.location),
                length: markedTextState.markedRange.length
            )
        }

        func selectedTextRange() -> TerminalTextRange {
            guard hasMarkedText else {
                return TerminalTextRange(
                    location: document.position(ofCommittedOffset: shadow.selectedRange.location),
                    length: shadow.selectedRange.length
                )
            }
            return TerminalTextRange(
                location: document.position(ofMarkedOffset: markedTextState.selectedRange.location),
                length: markedTextState.selectedRange.length
            )
        }

        func setSelectedTextRange(_ range: UITextRange?) {
            guard hasMarkedText else {
                let committedRange = if let range = range as? TerminalTextRange {
                    document.committedRange(of: NSRange(location: range.location, length: range.length))
                } else {
                    NSRange(location: shadow.length, length: 0)
                }
                guard shadow.selectedRange != committedRange else { return }
                TerminalDebugLog.log(
                    .ime,
                    "shadow select range=\(TerminalDebugLog.describe(committedRange)) length=\(shadow.length)"
                ) // Debug: dictation
                notifySelectionWillChange()
                shadow.select(committedRange)
                notifySelectionDidChange()
                return
            }
            let clampedRange = if let range = range as? TerminalTextRange {
                document.markedRange(of: NSRange(location: range.location, length: range.length))
            } else {
                NSRange(location: 0, length: 0)
            }
            guard markedTextState.selectedRange != clampedRange else { return }
            TerminalDebugLog.log(
                .ime,
                "setSelectedTextRange range=\(TerminalDebugLog.describe(clampedRange))"
            )
            notifySelectionWillChange()
            markedTextState.setMarkedText(markedTextState.text, selectedRange: clampedRange)
            notifySelectionDidChange()
        }

        func text(in range: TerminalTextRange) -> String? {
            let document = document
            guard range.location >= 0, range.length >= 0, range.location + range.length <= document.length else { return nil }
            let documentRange = NSRange(location: range.location, length: range.length)
            let anchor = documentRange.location < document.anchorLength && documentRange.length > 0 ? anchorText : ""
            let committed = shadow.text(in: document.committedRange(of: documentRange)) ?? ""
            let marked = markedTextState.text(in: document.markedRange(of: documentRange)) ?? ""
            return anchor + committed + marked
        }

        // MARK: - Shadow

        /// Applies the input system's replacement of committed text. False
        /// when marked text is open: the replacement is the composition's.
        func replaceCommittedText(_ range: TerminalTextRange, with text: String) -> Bool {
            guard let view, !hasMarkedText else { return false }
            let committedRange = document.committedRange(of: NSRange(location: range.location, length: range.length))
            view.inputDelegate?.textWillChange(view)
            view.inputDelegate?.selectionWillChange(view)
            freezeAnchorText()
            apply(shadow.replace(committedRange, with: text), reason: "replace")
            view.inputDelegate?.selectionDidChange(view)
            view.inputDelegate?.textDidChange(view)
            return true
        }

        /// Deletes before the caret in the shadow. False with nothing there:
        /// the Delete goes to the terminal as a plain key.
        func deleteBackwardInCommittedText() -> Bool {
            guard let view, !hasMarkedText else { return false }
            var updated = shadow
            guard let edit = updated.deleteBackward() else {
                shadow = updated
                return false
            }
            view.inputDelegate?.textWillChange(view)
            view.inputDelegate?.selectionWillChange(view)
            shadow = updated
            apply(edit, reason: "deleteBackward")
            view.inputDelegate?.selectionDidChange(view)
            view.inputDelegate?.textDidChange(view)
            return true
        }

        /// The terminal line changed by other means — a key, a paste, focus
        /// moving — so the shadow no longer describes it.
        func resetCommittedText(reason: String) {
            guard let view else { return }
            commitHeldDictation(reason: reason)
            // An emptied shadow still holds its anchor.
            guard shadow.length > 0 else {
                shadowAnchorText = nil
                return
            }
            TerminalDebugLog.log(
                .ime,
                "shadow reset reason=\(reason) shadow=\(TerminalDebugLog.describe(shadow.text))"
            ) // Debug: dictation
            view.inputDelegate?.textWillChange(view)
            view.inputDelegate?.selectionWillChange(view)
            resetShadow()
            view.inputDelegate?.selectionDidChange(view)
            view.inputDelegate?.textDidChange(view)
        }

        func deleteBackwardInMarkedText() -> Bool {
            guard let view else { return false }
            guard markedTextState.hasMarkedText else { return false }
            let shouldNotifySelectionChange = shouldNotifySelectionChange
            TerminalDebugLog.log(
                .ime,
                "deleteBackwardInMarkedText selected=\(TerminalDebugLog.describe(markedTextState.selectedRange))"
            )
            view.inputDelegate?.textWillChange(view)
            if shouldNotifySelectionChange {
                view.inputDelegate?.selectionWillChange(view)
            }

            _ = markedTextState.deleteBackward()
            view.surface?.preedit(markedTextState.text ?? "")
            view.refreshInputAccessoryContent()

            if shouldNotifySelectionChange {
                view.inputDelegate?.selectionDidChange(view)
            }
            view.inputDelegate?.textDidChange(view)
            return true
        }

        func notifyGeometryDidChange(reason: String) {
            guard let view else { return }
            TerminalDebugLog.log(
                .ime,
                "notifyGeometryDidChange reason=\(reason) selected=\(TerminalDebugLog.describe(markedTextState.selectedRange)) documentLength=\(markedTextState.documentLength) marked=\(hasMarkedText)"
            )
            view.inputDelegate?.selectionWillChange(view)
            view.inputDelegate?.selectionDidChange(view)
            if view.isFirstResponder {
                view.reloadInputViews()
            }
        }

        private var shouldNotifySelectionChange: Bool {
            hasMarkedText
                || shadow.length > 0
                || markedTextState.selectedRange.location != 0
                || markedTextState.selectedRange.length != 0
        }

        private func notifySelectionWillChange() {
            if let view {
                view.inputDelegate?.selectionWillChange(view)
            }
        }

        private func notifySelectionDidChange() {
            if let view {
                view.inputDelegate?.selectionDidChange(view)
            }
        }
    }
#endif
