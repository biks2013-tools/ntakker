// macrec-ui/Views/ResizeHandle.swift
//
// Bottom-edge drag handle that lets the user grow/shrink the popover
// in BOTH dimensions (plan-008-followup-1: horizontal resize). It binds
// to `width: Binding<Double>` + `height: Binding<Double>`, updates
// both on every drag tick, and `RootView` wires each binding to a
// dedicated `@AppStorage` slot so the chosen size survives across
// popover open/close and app restarts. The bridge from SwiftUI
// width/height → `NSPopover.contentSize` lives in `PopoverController`
// (it observes both AppStorage keys and pushes the new size onto the
// AppKit popover).
//
// The handle itself is intentionally narrow: a single thin row at the
// bottom of the popover with a centered "grip" indicator. Drag in any
// direction is honored — vertical translation drives `height`,
// horizontal translation drives `width`. Per-axis clamps are applied
// independently so the user can pin one axis and freely drag the other.
//
// Cursor: `NSCursor.openHand` while hovering the handle, signalling
// that the strip can be dragged in any direction (the macOS HIG-canonical
// 4-way move/resize cursor). `frameResize(position:directions:)` is
// available on macOS 15+ but its position-anchored variants assume the
// cursor is on a window edge / corner — using it on a centered strip
// produces visually-misleading directional arrows. `openHand` is the
// honest signal here.

import AppKit
import SwiftUI

struct ResizeHandle: View {
    /// Live-updated popover width. Caller binds this to a persisted
    /// `@AppStorage` slot (e.g. `com.macrec.ui.popoverWidth`).
    @Binding var width: Double

    /// Live-updated popover height. Caller binds this to a persisted
    /// `@AppStorage` slot (e.g. `com.macrec.ui.popoverHeight`).
    @Binding var height: Double

    /// Hard clamp range for the height axis. plan-015 (FR-IRQ-61)
    /// raised the floor to 440 so the new Pattern-C status bar +
    /// segmented control + minimal body all stay legible, and lowered
    /// the ceiling to 820 (fits a 13" MBP visibleFrame comfortably).
    static let minHeight: Double = 440
    static let maxHeight: Double = 820

    /// Hard clamp range for the width axis. plan-015 (FR-IRQ-59..61):
    /// `min` is calibrated so the status bar's `[ New Session ][ Save… ]`
    /// pair plus the mic + sys indicators plus state pill + clock all
    /// fit without overflow; `max` keeps the popover from feeling
    /// "panel"-sized rather than "popover"-sized.
    static let minWidth: Double = 440
    static let maxWidth: Double = 760

    /// Snapshots of `width` and `height` taken at the start of a drag
    /// so each axis's translation is applied to a stable origin
    /// (prevents jitter from accumulated rounding when SwiftUI
    /// re-renders mid-drag).
    @State private var dragOriginWidth: Double?
    @State private var dragOriginHeight: Double?

    var body: some View {
        ZStack {
            // Hit area — full row at the bottom of the popover.
            Rectangle()
                .fill(Color.clear)
                .frame(height: 12)
                .contentShape(Rectangle())

            // Visible grip indicator: two short horizontal bars.
            VStack(spacing: 2) {
                Capsule().fill(Color.secondary.opacity(0.35)).frame(width: 32, height: 2)
                Capsule().fill(Color.secondary.opacity(0.35)).frame(width: 32, height: 2)
            }
        }
        .help(String(localized: "Drag to resize the popover in any direction. Your size is remembered."))
        .onHover { inside in
            if inside {
                NSCursor.openHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if dragOriginHeight == nil { dragOriginHeight = height }
                    if dragOriginWidth  == nil { dragOriginWidth  = width  }
                    let proposedH = (dragOriginHeight ?? height) + value.translation.height
                    let proposedW = (dragOriginWidth  ?? width)  + value.translation.width
                    height = min(max(proposedH, Self.minHeight), Self.maxHeight)
                    width  = min(max(proposedW, Self.minWidth),  Self.maxWidth)
                }
                .onEnded { _ in
                    dragOriginHeight = nil
                    dragOriginWidth  = nil
                }
        )
    }
}
