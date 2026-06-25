import SwiftUI
import AppKit
import CodeEditSourceEditor
import CodeEditLanguages

/// 代码编辑器视图：包一层 CodeEditSourceEditor 的 SourceEditor（原生 TextKit 内核）。
/// 高亮 / 补全 UI / 查找替换(⌘F) / 缩略图 / 自动缩进 / 括号配对 全由该成熟库提供。
struct RemoteCodeEditor: View {
    @Binding var text: String        // EditorState.text：远程拉回的内容，双向回写
    let editable: Bool               // .text → true；.readonlyText → false
    let fileName: String             // 用于按扩展名识别语言
    let colors: ThemeColors
    let isDark: Bool
    let font: NSFont
    let showMinimap: Bool

    @State private var editorState = SourceEditorState()

    private var language: CodeLanguage {
        // detectLanguageFrom 只读路径扩展名/文件名，不访问磁盘；远程文件用 fileURLWithPath 构造即可
        CodeLanguage.detectLanguageFrom(url: URL(fileURLWithPath: fileName))
    }

    var body: some View {
        SourceEditor(
            $text,
            language: language,
            configuration: SourceEditorConfiguration(
                appearance: .init(
                    theme: EditorTheme.termo(colors: colors, isDark: isDark),
                    font: font,
                    wrapLines: false,                 // 代码不折行（水平滚动）
                    tabWidth: 4
                ),
                behavior: .init(
                    isEditable: editable,
                    isSelectable: true,
                    indentOption: .spaces(count: 4)   // 自动缩进单位
                ),
                peripherals: .init(
                    showGutter: true,                 // 行号
                    showMinimap: showMinimap,
                    showFoldingRibbon: false           // 关掉那条杂乱的常驻折叠竖条（Xcode 也不常驻显示）
                )
            ),
            state: $editorState
        )
    }
}

extension EditorTheme {
    /// 从 termo 的 ThemeColors + VSCode Dark+/Light+ 风配色映射出 EditorTheme（颜色均为 NSColor）。
    static func termo(colors: ThemeColors, isDark: Bool) -> EditorTheme {
        let fg = NSColor(hex: colors.termFg)
        let bg = NSColor(hex: colors.termBg)

        let comment, string, number, keyword, type, function, variable, constant: NSColor
        if isDark {
            comment  = NSColor(hex: 0x6a9955)
            string   = NSColor(hex: 0xce9178)
            number   = NSColor(hex: 0xb5cea8)
            keyword  = NSColor(hex: 0x569cd6)
            type     = NSColor(hex: 0x4ec9b0)
            function = NSColor(hex: 0xdcdcaa)
            variable = NSColor(hex: 0x9cdcfe)
            constant = NSColor(hex: 0x4fc1ff)
        } else {
            comment  = NSColor(hex: 0x008000)
            string   = NSColor(hex: 0xa31515)
            number   = NSColor(hex: 0x098658)
            keyword  = NSColor(hex: 0x0000ff)
            type     = NSColor(hex: 0x267f99)
            function = NSColor(hex: 0x795e26)
            variable = NSColor(hex: 0x001080)
            constant = NSColor(hex: 0x0070c1)
        }

        return EditorTheme(
            text:           Attribute(color: fg),
            insertionPoint: NSColor(hex: colors.termCaret),
            invisibles:     Attribute(color: fg.withAlphaComponent(0.25)),
            background:     bg,
            lineHighlight:  fg.withAlphaComponent(0.06),
            selection:      NSColor(hex: colors.termSelection),
            keywords:       Attribute(color: keyword, bold: true),
            commands:       Attribute(color: function),   // 函数调用类
            types:          Attribute(color: type),
            attributes:     Attribute(color: variable),
            variables:      Attribute(color: variable),
            values:         Attribute(color: constant),
            numbers:        Attribute(color: number),
            strings:        Attribute(color: string),
            characters:     Attribute(color: string),
            comments:       Attribute(color: comment, italic: true)
        )
    }
}
