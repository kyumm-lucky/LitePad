import Foundation

/// 按文件监听磁盘变化：每个文件一个 vnode 事件源，写入 / 删除 / 重命名 / 属性变化都会上报。
/// 只在主线程使用；会话按标签生命周期挂载与回收，事件只负责通知，重载策略仍由会话决定
final class FileWatcher {
    private var sources: [URL: DispatchSourceFileSystemObject] = [:]

    /// 开始监听一个文件；同一路径重复挂载时忽略
    func watch(_ url: URL, onChange: @escaping () -> Void) {
        let key = url.standardizedFileURL
        guard sources[key] == nil else { return }
        let descriptor = open(key.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .attrib],
            queue: .main)
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(descriptor) }
        source.resume()
        sources[key] = source
    }

    /// 取消监听；文件已删除或重命名时也走这里
    func unwatch(_ url: URL) {
        guard let source = sources.removeValue(forKey: url.standardizedFileURL) else { return }
        source.cancel()
    }

    func unwatchAll() {
        for source in sources.values {
            source.cancel()
        }
        sources.removeAll()
    }
}
