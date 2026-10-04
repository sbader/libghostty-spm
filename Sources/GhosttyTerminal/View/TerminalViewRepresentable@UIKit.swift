//
//  TerminalViewRepresentable@UIKit.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

#if canImport(UIKit)
    import SwiftUI
    import UIKit

    extension TerminalViewRepresentable: UIViewRepresentable {
        func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        func makeUIView(context viewContext: Context) -> UIView {
            let view = context.makePlatformView?() ?? TerminalView(frame: .zero)
            configureView(view, initial: true)
            viewContext.coordinator.attach(to: view, focusBinding: focusBinding)
            Self.synchronizeFocus(view, with: focusBinding)
            return context.makePlatformContainer?(view, context) ?? view
        }

        func updateUIView(_ container: UIView, context viewContext: Context) {
            guard let view = viewContext.coordinator.view else { return }
            configureView(view, initial: false)
            context.updatePlatformContainer?(container, context)
            viewContext.coordinator.attach(to: view, focusBinding: focusBinding)
            Self.synchronizeFocus(view, with: focusBinding)
        }

        static func dismantleUIView(_: UIView, coordinator: Coordinator) {
            coordinator.detach()
        }

        @MainActor
        final class Coordinator {
            fileprivate var view: TerminalView?
            private var focusBinding: TerminalFocusBinding?

            func attach(
                to view: TerminalView,
                focusBinding: TerminalFocusBinding?
            ) {
                self.view = view
                self.focusBinding = focusBinding
                view.focusBridge.onFocusChange = { [weak self] focused in
                    self?.focusBinding.setFocused(focused)
                }
                // synchronizeFocus can only act on a view that is in a
                // window; at launch the focus request precedes the window,
                // so replay it the moment the view attaches.
                view.focusBridge.onWindowAttach = { [weak self] in
                    guard let self, let view = self.view else { return }
                    TerminalViewRepresentable.synchronizeFocus(
                        view,
                        with: focusBinding
                    )
                }
            }

            func detach() {
                view?.focusBridge.onFocusChange = nil
                view?.focusBridge.onWindowAttach = nil
                focusBinding = nil
                view = nil
            }
        }
    }
#endif
