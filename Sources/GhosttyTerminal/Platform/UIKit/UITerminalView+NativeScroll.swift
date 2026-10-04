#if canImport(UIKit)
    import UIKit

    @MainActor
    public protocol TerminalNativeScrollHost: AnyObject {
        var isScrollEnabled: Bool { get set }
        var isDecelerating: Bool { get }
        func stopScrolling()
        func updateScrollRouting()
    }

    extension UITerminalView {
        struct NativeScrollState {
            weak var host: (any TerminalNativeScrollHost)?
            var recognizers: [UIPanGestureRecognizer] = []
        }

        public var nativeScrollHost: (any TerminalNativeScrollHost)? {
            get { nativeScroll.host }
            set { nativeScroll.host = newValue }
        }

        var scrollInputRecognizers: [UIPanGestureRecognizer] {
            get { nativeScroll.recognizers }
            set { nativeScroll.recognizers = newValue }
        }

        public func updateNativeScrollRouting() {
            guard let host = nativeScrollHost else { return }
            let terminalOwnsScroll = isMouseCaptured || surface?.isAlternateScreen == true
                || (usesInlineTextSelection && touchSelection.range != nil)
                || scrollInputRecognizers.contains { $0.state == .began || $0.state == .changed }
            let useNativeScroll = !terminalOwnsScroll
            if host.isScrollEnabled != useNativeScroll {
                if useNativeScroll { stopMomentumScrolling() } else { host.stopScrolling() }
                host.isScrollEnabled = useNativeScroll
            }
            for recognizer in scrollInputRecognizers where recognizer.isEnabled != terminalOwnsScroll {
                recognizer.isEnabled = terminalOwnsScroll
            }
        }

        public func beginNativeScroll() {
            stopMomentumScrolling()
            #if !targetEnvironment(macCatalyst)
                softwareKeyboard.tapCandidateArmed = false
            #endif
        }
    }
#endif
