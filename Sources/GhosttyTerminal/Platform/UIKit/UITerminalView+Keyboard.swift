//
//  UITerminalView+Keyboard.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/17.
//

#if canImport(UIKit)
    import GhosttyKit
    import UIKit

    /// Hardware-keyboard routing state; behavior lives in +Keyboard.
    struct HardwareKeyboardState {
        /// A press the key path already delivered, telling the UITextInput
        /// echo to stay silent.
        var keyHandled = false
        /// Copy is handled by the view; its repeat and release never reach the core.
        var touchCopyKeycodes: Set<UInt32> = []
        /// Signatures of keys already delivered this runloop turn by one of
        /// the two paths that can carry a key we register as a `UIKeyCommand`
        /// (the Ctrl combos, Escape). One physical press can reach us twice —
        /// `pressesBegan` and the matching command — and which arrives (or
        /// both) varies by iPadOS version; whichever runs first claims the
        /// press here.
        var recentKeyCommandDeliveries: Set<String> = []
        /// Presses given to the text input system; the surface never saw
        /// them, so their release must not reach it.
        var pressesLoanedToInputMethod: Set<UIPress> = []
        /// Nonzero while `super.pressesBegan` hands presses to the text input
        /// system, telling UITextInput calls that arrive synchronously apart.
        var textInputPressDepth = 0
        /// Presses whose began was forwarded to `super`; their ended must
        /// complete there too.
        var pressesForwardedToInputMethod: Set<UIPress> = []
        /// Last hardware modifier flags seen on a `UIKey`. Pointer events
        /// read this when the hover recognizer is not the live source.
        var heldModifierFlags: UIKeyModifierFlags = []
        /// The held key being repeated, if any. See `startKeyRepeat`.
        var keyRepeat: KeyRepeat?
        var keyRepeatDelay = TerminalKeyRepeat.initialDelay
        var keyRepeatInterval = TerminalKeyRepeat.interval

        /// A repeating key: the press, whose release ends the repeat and
        /// whose key each repeat sends, and the timer that sends them.
        struct KeyRepeat {
            let press: UIPress
            let timer: Timer
        }
    }

    /// Software-keyboard visibility and tap-to-toggle state; behavior in
    /// +Keyboard (observers) and +Interaction (touch handling).
    struct SoftwareKeyboardState {
        var isVisible = false
        /// The active direct-touch sequence can still resolve to a clean
        /// tap. Armed on the first finger down; disarmed by a second
        /// finger, by movement past the slop, by any recognized gesture
        /// (scroll pan, pinch, long press), or by the press running long.
        /// Only a sequence still armed at touch end toggles the keyboard —
        /// a drag, zoom, or hold must never count as the tap.
        var tapCandidateArmed = false
        var tapCandidateStart: CGPoint = .zero
        var tapCandidateTimestamp: TimeInterval = 0
    }

    extension UITerminalView {
        override open func pressesBegan(
            _ presses: Set<UIPress>,
            with event: UIPressesEvent?
        ) {
            #if targetEnvironment(macCatalyst)
                for press in presses {
                    guard let key = press.key else { continue }
                    handleKeyPress(key, action: GHOSTTY_ACTION_PRESS)
                }
            #else
                var forwardedToInputMethod: Set<UIPress> = []
                for press in presses {
                    guard let key = press.key else { continue }
                    // Only the most recent key repeats, as on every desktop:
                    // a new key down ends the old repeat. A modifier going
                    // down leaves it alone — shift pressed mid-repeat does not
                    // stop the letter.
                    if !TerminalKeyRepeat.isModifier(usage: UInt16(key.keyCode.rawValue)) {
                        stopKeyRepeat()
                    }
                    // The press must reach `super` within this call, with its
                    // event: the text input system only interprets the key
                    // event being delivered.
                    if routesKeyToTextInput(key) {
                        TerminalDebugLog.log(
                            .input,
                            "uikit key to text input system code=\(key.keyCode.rawValue) chars=\(TerminalDebugLog.describe(key.characters)) ignoring=\(TerminalDebugLog.describe(key.charactersIgnoringModifiers)) marked=\(inputHandler.hasMarkedText) event=\(event != nil)"
                        )
                        hardwareKeyboard.pressesLoanedToInputMethod.insert(press)
                        hardwareKeyboard.pressesForwardedToInputMethod.insert(press)
                        forwardedToInputMethod.insert(press)
                        continue
                    }
                    // Caps Lock switches the input source in the text input
                    // system, which only sees a press that reaches it.
                    guard handleKeyPress(key, action: GHOSTTY_ACTION_PRESS) else {
                        TerminalDebugLog.log(
                            .input,
                            "uikit key ignored by surface, forwarded to super code=\(key.keyCode.rawValue)"
                        )
                        hardwareKeyboard.pressesForwardedToInputMethod.insert(press)
                        forwardedToInputMethod.insert(press)
                        continue
                    }
                    startKeyRepeat(for: press)
                }
                // `super` is how UIKit feeds a press to the text input system.
                if !forwardedToInputMethod.isEmpty {
                    hardwareKeyboard.textInputPressDepth += 1
                    super.pressesBegan(forwardedToInputMethod, with: event)
                    hardwareKeyboard.textInputPressDepth -= 1
                }
            #endif
        }

        override open func pressesEnded(
            _ presses: Set<UIPress>,
            with event: UIPressesEvent?
        ) {
            #if targetEnvironment(macCatalyst)
                for press in presses {
                    guard let key = press.key else { continue }
                    handleKeyPress(key, action: GHOSTTY_ACTION_RELEASE)
                }
                hardwareKeyboard.keyHandled = false
            #else
                var forwardedToInputMethod: Set<UIPress> = []
                for press in presses {
                    if press === hardwareKeyboard.keyRepeat?.press {
                        stopKeyRepeat()
                    }
                    if hardwareKeyboard.pressesForwardedToInputMethod.remove(press) != nil {
                        forwardedToInputMethod.insert(press)
                    }
                    if hardwareKeyboard.pressesLoanedToInputMethod.remove(press) != nil {
                        // The surface never saw this press (a replayed key
                        // carries its own synthetic release), so it gets no
                        // release either.
                        continue
                    }
                    guard let key = press.key else { continue }
                    handleKeyPress(key, action: GHOSTTY_ACTION_RELEASE)
                }
                hardwareKeyboard.keyHandled = false
                if !forwardedToInputMethod.isEmpty {
                    super.pressesEnded(forwardedToInputMethod, with: event)
                }
            #endif
        }

        override open func pressesCancelled(
            _ presses: Set<UIPress>,
            with event: UIPressesEvent?
        ) {
            hardwareKeyboard.keyHandled = false
            #if !targetEnvironment(macCatalyst)
                for press in presses {
                    if press === hardwareKeyboard.keyRepeat?.press {
                        stopKeyRepeat()
                    }
                    hardwareKeyboard.pressesLoanedToInputMethod.remove(press)
                    hardwareKeyboard.pressesForwardedToInputMethod.remove(press)
                }
            #endif
            super.pressesCancelled(presses, with: event)
        }

        #if !targetEnvironment(macCatalyst)
            /// Whether this press belongs to the text input system rather
            /// than the terminal — see `TerminalIMEComposition` for the rules.
            private func routesKeyToTextInput(_ key: UIKey) -> Bool {
                let flags = filteredModifierFlags(for: key)
                guard flags.isDisjoint(with: [.control, .command]) else { return false }
                return TerminalIMEComposition.routesToTextInput(
                    characters: key.characters,
                    charactersIgnoringModifiers: key.charactersIgnoringModifiers,
                    hasMarkedText: inputHandler.hasMarkedText,
                    inputModeUsesComposition: TerminalIMEComposition
                        .languageUsesComposition(textInputMode?.primaryLanguage)
                )
            }

            /// Logs a UITextInput mutation and whether it answers a press
            /// being handed to the text input system.
            func noteTextInputMutation(_ name: String) {
                TerminalDebugLog.log(
                    .input,
                    "text input \(name) duringPress=\(hardwareKeyboard.textInputPressDepth > 0)"
                )
            }
        #endif

        @discardableResult
        func handleKeyPress(
            _ key: UIKey,
            action: ghostty_input_action_e
        ) -> Bool {
            notePointerModifierFlags(key.modifierFlags)
            guard surface != nil else {
                TerminalDebugLog.log(.input, "uikit key ignored: missing surface")
                return false
            }

            let filteredModifierFlags = filteredModifierFlags(for: key)
            let isCommandModified = filteredModifierFlags.contains(.command)
            let mods = TerminalInputModifiers(from: filteredModifierFlags)
            let keyboardZoomDirection = commandZoomDirection(
                for: key,
                action: action,
                filteredModifierFlags: filteredModifierFlags
            )

            if action == GHOSTTY_ACTION_PRESS,
               shouldSuppressUIKeyInput(for: key, isCommandModified: isCommandModified)
            {
                hardwareKeyboard.keyHandled = true
            }

            TerminalDebugLog.log(
                .input,
                "uikit key action=\(TerminalDebugLog.describe(action)) code=\(key.keyCode.rawValue) chars=\(TerminalDebugLog.describe(key.characters)) ignoring=\(TerminalDebugLog.describe(key.charactersIgnoringModifiers)) mods=0x\(String(filteredModifierFlags.rawValue, radix: 16)) marked=\(inputHandler.hasMarkedText)"
            )

            var keyEvent = ghostty_input_key_s()
            keyEvent.action = action
            keyEvent.mods = mods.ghosttyMods
            // Ghostty expects a platform-native keycode, which it resolves
            // to its internal Key enum via src/input/keycodes.zig. On iOS
            // that table uses macOS virtual keycodes (native_idx = 4), so
            // translate the documented HID usage value from UIKey into the
            // corresponding AppKit keycode here.
            keyEvent.keycode = TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(
                usage: UInt16(key.keyCode.rawValue)
            )
            keyEvent.composing = inputHandler.hasMarkedText

            var consumedFlags = filteredModifierFlags
            consumedFlags.remove(.control)
            consumedFlags.remove(.command)
            keyEvent.consumed_mods = TerminalInputModifiers(from: consumedFlags).ghosttyMods

            guard action == GHOSTTY_ACTION_PRESS || action == GHOSTTY_ACTION_REPEAT else {
                return sendInputKeyEvent(keyEvent)
            }

            let filteredIgnoringModifiers = TerminalInputText.filteredFunctionKeyText(
                key.charactersIgnoringModifiers
            )

            if let codepoint = filteredIgnoringModifiers?.unicodeScalars.first {
                keyEvent.unshifted_codepoint = codepoint.value
            }

            // The key command fallback may have sent this very key already
            // (see `controlKeyCommands` and `escapeKeyCommands`); on systems
            // that deliver both, the first claim wins and this press stays
            // silent.
            if action == GHOSTTY_ACTION_PRESS,
               let input = keyCommandInput(for: key, filteredModifierFlags: filteredModifierFlags),
               !claimKeyCommandDelivery(
                   input: input,
                   modifierFlags: filteredModifierFlags
               )
            {
                return true
            }

            guard !isCommandModified else {
                let consumed = sendInputKeyEvent(keyEvent)
                if let keyboardZoomDirection {
                    scheduleViewportRefreshAfterKeyboardZoom(keyboardZoomDirection)
                }
                return consumed
            }

            var derivedText = TerminalInputText.filteredFunctionKeyText(key.characters)

            // Ctrl+letter arrives with `characters` already collapsed to the
            // raw control byte, which the core's key encoder does not accept
            // as a key. AppKit re-derives the printable text without control
            // (NSEvent.filteredCharacters); UIKey cannot re-apply modifier
            // sets, so the unmodified character stands in.
            if filteredModifierFlags.contains(.control),
               let scalars = derivedText?.unicodeScalars,
               scalars.count == 1,
               let scalar = scalars.first,
               scalar.value < 0x20
            {
                derivedText = filteredIgnoringModifiers
            }

            // Backspace, Return, Tab and Escape report their control
            // character. As text it marks Option consumed, so Option+Backspace
            // would lose Option; AppKit sends these keys without text.
            if let scalars = derivedText?.unicodeScalars,
               scalars.count == 1,
               let scalar = scalars.first,
               scalar.value < 0x20 || scalar.value == 0x7F
            {
                derivedText = nil
            }

            guard let text = derivedText, !text.isEmpty else {
                return sendInputKeyEvent(keyEvent)
            }

            return text.withCString { ptr in
                keyEvent.text = ptr
                return sendInputKeyEvent(keyEvent)
            }
        }

        func shouldSuppressUIKeyInput(
            for key: UIKey,
            isCommandModified: Bool
        ) -> Bool {
            guard !isCommandModified else { return false }
            // Ctrl and Alt combos travel the key path above, which already
            // carries the composed character (option+a → "å") with alt
            // consumed, exactly as AppKit's keyDown does. The text system's
            // echo would type it a second time; for Ctrl it is a bare
            // control byte with the modifier context stripped
            // (`sendTypedText` zeroes mods), which loses the ctrl semantics
            // as well.
            guard !key.characters.isEmpty else {
                return key.keyCode == .keyboardDeleteOrBackspace
            }
            return true
        }

        /// The `UIKeyCommand.input` this press would arrive under, if it is
        /// one of the keys `keyCommands` registers — the shared signature
        /// both paths claim with. Nil for every other key.
        private func keyCommandInput(
            for key: UIKey,
            filteredModifierFlags: UIKeyModifierFlags
        ) -> String? {
            if key.keyCode == .keyboardEscape,
               !filteredModifierFlags.contains(.command)
            {
                return UIKeyCommand.inputEscape
            }
            guard filteredModifierFlags.contains(.control) else { return nil }
            return TerminalInputText.filteredFunctionKeyText(key.charactersIgnoringModifiers)
        }

        /// Pointer-only. Does not change key routing.
        func notePointerModifierFlags(_ flags: UIKeyModifierFlags) {
            let relevant = flags.intersection([
                .shift, .control, .alternate, .command, .alphaShift,
            ])
            guard hardwareKeyboard.heldModifierFlags != relevant else { return }
            hardwareKeyboard.heldModifierFlags = relevant
            refreshPointerPositionForModifierChange()
        }

        private func filteredModifierFlags(for key: UIKey) -> UIKeyModifierFlags {
            var flags = key.modifierFlags
            let isFunctionKey =
                TerminalInputText.filteredFunctionKeyText(key.characters) == nil ||
                TerminalInputText.filteredFunctionKeyText(key.charactersIgnoringModifiers) == nil
            if isFunctionKey {
                flags.remove(.numericPad)
            }
            return flags
        }

        private func commandZoomDirection(
            for key: UIKey,
            action: ghostty_input_action_e,
            filteredModifierFlags: UIKeyModifierFlags
        ) -> KeyboardZoomDirection? {
            guard action == GHOSTTY_ACTION_PRESS || action == GHOSTTY_ACTION_REPEAT else {
                return nil
            }
            guard filteredModifierFlags.contains(.command) else { return nil }

            let candidates = [
                key.characters,
                key.charactersIgnoringModifiers,
            ]
            if candidates.contains(where: { $0 == "+" || $0 == "=" }) {
                return .increase
            }
            if candidates.contains(where: { $0 == "-" || $0 == "_" }) {
                return .decrease
            }
            return nil
        }

        private func scheduleViewportRefreshAfterKeyboardZoom(
            _ direction: KeyboardZoomDirection
        ) {
            TerminalDebugLog.log(
                .actions,
                "keyboard zoom shortcut direction=\(direction.rawValue)"
            )
            #if !targetEnvironment(macCatalyst)
                switch direction {
                case .increase:
                    fontZoom.currentFontSize = min(fontZoom.currentFontSize + 1, Self.maxFontSize)
                case .decrease:
                    fontZoom.currentFontSize = max(fontZoom.currentFontSize - 1, Self.minFontSize)
                }
            #endif

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                core.synchronizeMetrics()
                refreshTextInputGeometry(
                    reason: "keyboard-zoom-\(direction.rawValue)"
                )
            }
        }

        private enum KeyboardZoomDirection: String {
            case increase
            case decrease
        }
    }

    #if !targetEnvironment(macCatalyst)
        // MARK: - Key repeat

        /// UIKit sends one `pressesBegan` for a held key and nothing more
        /// until it goes up: on iOS the repeat is the text input system's,
        /// and it only produces one for a key that reached it. Keys the
        /// terminal handles directly — Delete, an arrow, a Ctrl combination —
        /// stay off that path, so a held one typed exactly once. Their
        /// repeat is generated here instead, as `GHOSTTY_ACTION_REPEAT` events, which both of
        /// ghostty's key encoders write like a press (and the Kitty one
        /// reports as a repeat when the program asked for event types).
        ///
        /// Catalyst is left out: it has not shown the problem, and a repeat
        /// generated on top of one the system already delivers would type
        /// every held key twice.
        extension UITerminalView {
            /// Time a key is held before it repeats. iPadOS exposes the
            /// user's Key Repeat setting to no app, so the host chooses.
            public var keyRepeatDelay: TimeInterval {
                get { hardwareKeyboard.keyRepeatDelay }
                set { hardwareKeyboard.keyRepeatDelay = newValue }
            }

            /// Time between repeats of a held key.
            public var keyRepeatInterval: TimeInterval {
                get { hardwareKeyboard.keyRepeatInterval }
                set { hardwareKeyboard.keyRepeatInterval = newValue }
            }

            /// Starts repeating the key `press` just sent, when
            /// `TerminalKeyRepeat` says it repeats.
            func startKeyRepeat(for press: UIPress) {
                guard let key = press.key else { return }
                let modifierFlags = filteredModifierFlags(for: key)
                guard TerminalKeyRepeat.repeats(
                    usage: UInt16(key.keyCode.rawValue),
                    isCommandModified: modifierFlags.contains(.command),
                    isKeyCommand: keyCommandInput(for: key, filteredModifierFlags: modifierFlags) != nil
                ) else { return }

                stopKeyRepeat()
                let timer = Timer(
                    fire: Date(timeIntervalSinceNow: hardwareKeyboard.keyRepeatDelay),
                    interval: hardwareKeyboard.keyRepeatInterval,
                    repeats: true
                ) { [weak self] timer in
                    guard let self else { return timer.invalidate() }
                    MainActor.assumeIsolated {
                        self.sendKeyRepeat()
                    }
                }
                // `.common`, so a repeat keeps going while a scroll is
                // tracking.
                RunLoop.main.add(timer, forMode: .common)
                hardwareKeyboard.keyRepeat = .init(press: press, timer: timer)
                TerminalDebugLog.log(
                    .input,
                    "key repeat armed code=\(key.keyCode.rawValue) delay=\(hardwareKeyboard.keyRepeatDelay) interval=\(hardwareKeyboard.keyRepeatInterval)"
                )
            }

            func stopKeyRepeat() {
                hardwareKeyboard.keyRepeat?.timer.invalidate()
                hardwareKeyboard.keyRepeat = nil
            }

            private func sendKeyRepeat() {
                // The release normally ends the repeat. Should it never
                // arrive, losing focus or the surface still does, instead of
                // a key that types forever.
                guard let key = hardwareKeyboard.keyRepeat?.press.key,
                      isFirstResponder,
                      surface != nil
                else { return stopKeyRepeat() }
                handleKeyPress(key, action: GHOSTTY_ACTION_REPEAT)
            }
        }
    #endif
#endif
