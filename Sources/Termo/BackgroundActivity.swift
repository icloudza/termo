import Foundation

/// 统一后台活动描述符：左下角后台中控只认它，不直接耦合具体功能。
/// 分组用的 hostId/主机名为**取值快照**（由 @MainActor 的 AppModel 构建时读出），故本类型可保持 nonisolated，
/// 满足 Identifiable 的 nonisolated 要求；具体任务对象仅放在 payload 里，供中控各行在主线程上下文中观察其实时状态。
/// 新增后台功能 = 增加一个 payload case + 一个对应的中控行，中控骨架与分组逻辑不变。
struct BackgroundActivity: Identifiable {
    enum Payload {
        case forward(rule: ForwardRule, manager: ForwardManager)
        case transfer(UploadTask)   // 上传 / 下载（由 UploadTask.direction 区分）
        case extract(ExtractTask)
    }

    let id: String
    let hostId: String?          // 分组依据；用于按主机（A/B/C）分组
    let fallbackHostName: String // 主机被删除等情况下兜底显示用（视图优先用现存主机的真实名）
    let payload: Payload
}
