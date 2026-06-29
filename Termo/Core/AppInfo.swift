import Foundation

/// 应用版本信息的统一入口。
///
/// 版本号的**唯一源**是 Termo/Info.plist 的 CFBundleShortVersionString / CFBundleVersion；
/// 运行期由本类从主包读取，打包脚本从构建产物的 Info.plist 读取。升版本只需改 Info.plist 一处。
enum AppInfo {
    /// 市场版本号，如 "0.7.6.1"。
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    /// 构建号，如 "18"。
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }

    /// 关于页展示用版本行：「版本 0.7.6.1 (build 18)」。
    /// 取不到时（非 .app 运行等极端情况）回退通用文案，不内嵌具体版本号以免与真实值不一致。
    static var versionLine: String {
        guard !version.isEmpty else { return "开发版" }
        return build.isEmpty ? "版本 \(version)" : "版本 \(version) (build \(build))"
    }
}
