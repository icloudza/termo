import SwiftUI

/// 文件操作目标：右击菜单（重命名 / 权限 / 删除 / 上传后刷新）的后端。
/// 由侧栏文件树（FileTreeState）与 SFTP 浏览器（BrowserState）共同实现，使同一套菜单两处复用。
@MainActor
protocol FileOpsTarget: AnyObject {
    func performDelete(_ file: RemoteFile) async -> Result<Void, RemoteFSError>
    func performRename(_ file: RemoteFile, newName: String) async -> Result<String, RemoteFSError>
    func performChmod(_ file: RemoteFile, mode: String) async -> Result<Void, RemoteFSError>
    func currentPerms(_ file: RemoteFile) async -> Int?
    /// 在 dir 下新建文件或文件夹，成功后局部刷新。
    func performCreate(_ name: String, isDir: Bool, inDir dir: String) async -> Result<Void, RemoteFSError>
}

extension View {
    /// 文件行通用右击菜单：上传（仅目录）/ 刷新 / 重命名 / 权限 / 删除。
    /// 重命名、权限、删除经 AppModel 走统一的确认弹窗与操作目标，两处文件视图共用同一套交互。
    /// - onRefresh: 刷新动作各自实现——侧栏走编辑器感知的 `fileMenuRefresh`，浏览器重载当前目录。
    func fileOpsMenu(file: RemoteFile, host: Host, model: AppModel,
                     target: any FileOpsTarget, onRefresh: @escaping () -> Void) -> some View {
        contextMenu {
            if file.isDir {
                Button { model.beginUpload(into: file, host: host) } label: {
                    Label("上传文件…", systemImage: "square.and.arrow.up")
                }
                Button { model.fileMenuRequestCreate(isDir: false, inDir: file.path, host: host, target: target) } label: {
                    Label("新建文件", systemImage: "doc.badge.plus")
                }
                Button { model.fileMenuRequestCreate(isDir: true, inDir: file.path, host: host, target: target) } label: {
                    Label("新建文件夹", systemImage: "folder.badge.plus")
                }
                Divider()
            } else {
                Button { model.downloadFiles([file], host: host) } label: {
                    Label("下载", systemImage: "square.and.arrow.down")
                }
                Divider()
            }
            Button(action: onRefresh) { Label("刷新", systemImage: "arrow.clockwise") }
            Divider()
            Button { model.fileMenuRequestRename(file, host: host, target: target) } label: {
                Label("重命名", systemImage: "pencil")
            }
            Button { model.fileMenuRequestChmod(file, host: host, target: target) } label: {
                Label("权限", systemImage: "lock")
            }
            Divider()
            Button(role: .destructive) {
                model.fileMenuRequestDelete(file, host: host, target: target)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }
}
