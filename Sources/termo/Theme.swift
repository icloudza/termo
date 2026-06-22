import AppKit
import SwiftUI

// Catppuccin Mocha 调色板（深色）。浅色主题后续再加。
enum Pal {
    static let crust = Color(hex: 0x11111b) // 活动栏
    static let mantle = Color(hex: 0x181825) // 侧栏 / 标签栏
    static let base = Color(hex: 0x1e1e2e) // 工作区
    static let surface0 = Color(hex: 0x313244)
    static let text = Color(hex: 0xcdd6f4)
    static let textBright = Color(hex: 0xe6eafc)
    static let subtext = Color(hex: 0xa6adc8)
    static let overlay = Color(hex: 0x7f849c)
    static let mauve = Color(hex: 0xcba6f7) // 强调色
    static let green = Color(hex: 0xa6e3a1)
    static let yellow = Color(hex: 0xf9e2af)
    static let red = Color(hex: 0xf38ba8)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: 1
        )
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: 1
        )
    }
}
