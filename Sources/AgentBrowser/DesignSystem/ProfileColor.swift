// ProfileColor.swift
// Maps ProfileRecord.colorName strings to SwiftUI Color values.
// Covers all 10 colors in ProfileRecord.defaultColors.

import SwiftUI

enum ProfileColor {
    static func color(for name: String) -> Color {
        switch name {
        case "blue":   return .blue
        case "green":  return .green
        case "orange": return .orange
        case "purple": return .purple
        case "red":    return .red
        case "teal":   return .teal
        case "pink":   return .pink
        case "indigo": return .indigo
        case "brown":  return .brown
        case "mint":   return .mint
        default:       return .gray
        }
    }
}
