//
//  FindPanelMode.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 4/18/25.
//

enum FindPanelMode: CaseIterable {
    case find
    case replace

    var displayName: String {
        switch self {
        case .find:
            return "查找"
        case .replace:
            return "替换"
        }
    }
}
