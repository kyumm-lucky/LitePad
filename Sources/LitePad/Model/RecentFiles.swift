import Foundation

/// 最近打开文件记录：UserDefaults 持久化，去重置顶，上限 10 条
enum RecentFiles {
    private static let key = "recentFiles"
    private static let limit = 10

    static func load() -> [URL] {
        UserDefaults.standard.stringArray(forKey: key)?.compactMap(URL.init(string:)) ?? []
    }

    /// 记录一次打开：已存在则置顶，超出上限淘汰最旧；返回更新后的列表
    static func record(_ url: URL) -> [URL] {
        var list = load().filter { $0 != url }
        list.insert(url, at: 0)
        if list.count > limit {
            list.removeLast(list.count - limit)
        }
        save(list)
        return list
    }

    /// 移除一条记录（文件已不存在时调用）；返回更新后的列表
    static func remove(_ url: URL) -> [URL] {
        let list = load().filter { $0 != url }
        save(list)
        return list
    }

    /// 清空全部记录（R12）；下次启动也不再有旧条目
    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func save(_ list: [URL]) {
        UserDefaults.standard.set(list.map(\.absoluteString), forKey: key)
    }
}
