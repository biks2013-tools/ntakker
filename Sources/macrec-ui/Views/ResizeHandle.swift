// macrec-ui/Views/ResizeHandle.swift
//
// Bottom-edge drag handle that lets the user grow/shrink the popover
// vertically. The handle binds to `popoverHeight: Binding<Double>`,
// updates that binding on drag, and `RootView` wires the binding to
// `@AppStorage("com.macrec.ui.popoverHeight")` so the chosen size
// survives across popover open/close and app restarts. The bridge
// from SwiftUI height → `NSPopover.contentSize` lives in
// `PopoverController` (it observes the AppStorage key and pushes
// the new size onto the popover).
//
// The handle itself is intentionally narrow: a single thin row with a
// centered "grip" indicator. Drag direction is vertical; horizontal
// drag is ignored (the popover keeps its 360pt width).

import SwiftUI

struct ResizeHandle: View {
    /// Live-updated popover height. Caller binds this to a persisted
    /// `@AppStorage` slot.
    @Binding var height: Double

    /// Hard clamp range, applied on every drag tick. The min keeps
    /// the bottom-band lifecycle controls visible; the max prevents
    /// the popover from growing past a reasonable screen height.
    static let minHeight: Double = 360
    static let maxHeight: Double = 1100

    /// Snapshot of `height` taken at the start of a drag so the
    /// translation is applied to a stable origin (prevents jitter
    /// from accumulated rounding when SwiftUI re-renders mid-drag).
    @State private var dragOrigin: Double?

    var body: some View {
        ZStack {
            // Hit area — full row at the bottom of the popover.
            Rectangle()
                .fill(Color.clear)
                .frame(height: 12)
                .contentShape(Rectangle())

            // Visible grip indicator: three short horizontal bars.
            VStack(spacing: 2) {
                Capsule().fill(Color.secondary.opacity(0.35)).frame(width: 32, height: 2)
                Capsule().fill(Color.secondary.opacity(0.35)).frame(width: 32, height: 2)
            }
        }
        .help(String(localized: "Drag to resize the popover. Your size is remembered."))
        .onHover { inside in
            if inside {
                NSCursor.resizeUpDown.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if dragOrigin == nil { dragOrigin = height }
                    let proposed = (dragOrigin ?? height) + value.translation.height
                    height = min(max(proposed, Self.minHeight), Self.maxHeight)
                }
                .onEnded { _ in
                    dragOrigin = nil
                }
        )
    }
}
