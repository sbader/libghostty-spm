//
//  TerminalViewRepresentable@AppKit.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

#if !canImport(UIKit) && canImport(AppKit)
    import AppKit
    import SwiftUI

    extension TerminalViewRepresentable: NSViewRepresentable {
        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeNSView(context viewContext: Context) -> NSView {
            let view = context.makePlatformView?() ?? TerminalView(frame: .zero)
            viewContext.coordinator.view = view
            configureView(view, initial: true)
            view.focusBridge.onFocusChange = { focused in
                focusBinding.setFocused(focused)
            }
            Self.synchronizeFocus(view, with: focusBinding)
            return context.makePlatformContainer?(view, context) ?? view
        }

        func updateNSView(_ container: NSView, context viewContext: Context) {
            guard let view = viewContext.coordinator.view else { return }
            configureView(view, initial: false)
            context.updatePlatformContainer?(container, context)
            view.focusBridge.onFocusChange = { focused in
                focusBinding.setFocused(focused)
            }
            Self.synchronizeFocus(view, with: focusBinding)
        }

        static func dismantleNSView(_: NSView, coordinator: Coordinator) {
            coordinator.view?.focusBridge.onFocusChange = nil
            coordinator.view = nil
        }
        @MainActor
        final class Coordinator {
            var view: TerminalView?
        }
    }
#endif
