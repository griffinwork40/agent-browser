// DesignTokens.swift
// Static constants for the Agent Browser design system.
// No cases — use the static properties directly (e.g. Spacing.px8, Radius.medium).

import SwiftUI

// MARK: - Spacing

/// Layout spacing scale in points.
enum Spacing {
    static let px2:  CGFloat = 2
    static let px4:  CGFloat = 4
    static let px6:  CGFloat = 6
    static let px8:  CGFloat = 8
    static let px12: CGFloat = 12
    static let px16: CGFloat = 16
    static let px20: CGFloat = 20
    static let px24: CGFloat = 24
    static let px32: CGFloat = 32
    static let px48: CGFloat = 48
}

// MARK: - Typography

/// Semantic type scale. Returns SwiftUI Fonts.
enum Typography {
    /// 28pt semi-bold rounded — splash headers, empty-state titles.
    static var displayLarge: Font {
        .system(size: 28, weight: .semibold, design: .rounded)
    }
    /// 17pt semi-bold — section titles, popover headers.
    static var title: Font {
        .system(size: 17, weight: .semibold)
    }
    /// 13pt regular — primary UI text.
    static var body: Font {
        .system(size: 13)
    }
    /// 11pt regular — secondary annotations, timestamps.
    static var caption: Font {
        .system(size: 11)
    }
    /// 11pt medium — badges, labels that need visual weight.
    static var label: Font {
        .system(size: 11, weight: .medium)
    }
    /// 12pt monospaced — URLs, code snippets, agent output.
    static var mono: Font {
        .system(size: 12, design: .monospaced)
    }
}

// MARK: - Radius

/// Corner-radius scale in points.
enum Radius {
    static let small:  CGFloat = 4
    static let medium: CGFloat = 8
    static let large:  CGFloat = 12
    /// Use for pill-shaped controls (badges, tags, address bar).
    static let pill:   CGFloat = 999
}

// MARK: - Motion

/// Animation duration constants in seconds.
enum Motion {
    /// Micro-interactions: hover states, checkmarks.
    static let micro:    TimeInterval = 0.10
    /// Standard: most state transitions.
    static let standard: TimeInterval = 0.25
    /// Enter: elements appearing on screen.
    static let enter:    TimeInterval = 0.35
    /// Exit: elements leaving screen.
    static let exit:     TimeInterval = 0.18
}

// MARK: - ControlSize

/// Fixed dimension constants for common controls.
enum ControlSize {
    /// 24×24 pt — compact icon buttons (close/pin in dense rows).
    static let iconButtonSmall:   CGFloat = 24
    /// 28×28 pt — standard toolbar icon buttons.
    static let iconButtonRegular: CGFloat = 28
    /// 40 pt — sidebar / tab-list row height.
    static let tabRowHeight:      CGFloat = 40
    /// 240 pt — default sidebar width.
    static let sidebarWidth:      CGFloat = 240
    /// 52 pt — address-bar toolbar height.
    static let toolbarHeight:     CGFloat = 52
}

// MARK: - Opacity

/// Semantic opacity levels.
enum Opacity {
    /// Disabled controls.
    static let disabled:  Double = 0.35
    /// Secondary text / icons.
    static let secondary: Double = 0.60
    /// Hover / pressed highlight background fill.
    static let subtle:    Double = 0.08
    /// Divider lines, separators.
    static let divider:   Double = 0.12
}
