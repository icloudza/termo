//
//  FindMethod.swift
//  CodeEditSourceEditor
//
//  Created by Austin Condiff on 5/2/25.
//

enum FindMethod: CaseIterable {
    case contains
    case matchesWord
    case startsWith
    case endsWith
    case regularExpression

    var displayName: String {
        switch self {
        case .contains:
            return "包含"
        case .matchesWord:
            return "全字匹配"
        case .startsWith:
            return "前缀匹配"
        case .endsWith:
            return "后缀匹配"
        case .regularExpression:
            return "正则表达式"
        }
    }
}
