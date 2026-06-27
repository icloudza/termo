import Foundation

/// 统一后台活动描述符：左下角后台中控只认它，不直接耦合具体功能。
/// 携带活动对象本身，使中控各行可直接观察其实时状态/进度；分组与命名由视图按 [[hostId]] 解析。
/// 新增后台功能 = 增加一个 case + 一个对应的中控行，中控骨架与分组逻辑不变。
enum BackgroundActivity: Identifiable {
    case forward(rule: ForwardRule, manager: ForwardManager)
    case transfer(UploadTask)   // 上传 / 下载（由 UploadTask.direction 区分）
    case extract(ExtractTask)

    var id: String {
        switch self {
        case .forward(let r, _): return "fwd-\(r.id.uuidString)"
        case .transfer(let t):   return "xfer-\(t.id.uuidString)"
        case .extract(let e):    return "ext-\(e.id.uuidString)"
        }
    }

    /// 所属主机 id；用于按主机（A/B/C）分组。理论上恒非空（转发规则、传输/解压均带主机）。
    var hostId: String? {
        switch self {
        case .forward(let r, _): return r.hostId
        case .transfer(let t):   return t.hostId
        case .extract(let e):    return e.hostId
        }
    }

    /// 主机被删除等极端情况下，用于兜底显示的主机名（视图优先用现存主机的真实名）。
    var fallbackHostName: String {
        switch self {
        case .forward:           return ""
        case .transfer(let t):   return t.hostName
        case .extract(let e):    return e.hostName
        }
    }
}
