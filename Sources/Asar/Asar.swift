//
//  Asar.swift
//  Pure Swift reader / writer for Electron's asar archive format.
//
//  asar 文件结构：
//      [uint32 = 4][uint32 头部尺寸][头部]
//   头部：
//      [uint32 JSON 长度][JSON][填充]
//   文件数据从 `8 + 头部尺寸` 开始，JSON 里每个文件节点的 offset
//   都是相对于这个起点的偏移。
//

import Foundation

/// asar 内的一个节点（文件、目录或符号链接）。
public struct AsarEntry: Hashable, Sendable {
    /// 相对路径，使用 `/` 分隔，不含开头斜杠。
    public let path: String
    /// 文件字节数（目录与链接为 0）。
    public let size: Int
    /// 相对文件数据起点的偏移（目录、链接、unpacked 文件为 0）。
    public let offset: Int
    /// 该文件是否存放在 `<asar>.unpacked/` 目录中。
    public let unpacked: Bool
    /// 符号链接指向的目标，普通文件为 nil。
    public let link: String?
    /// 是否为目录。
    public let isDirectory: Bool

    public init(path: String,
                size: Int = 0,
                offset: Int = 0,
                unpacked: Bool = false,
                link: String? = nil,
                isDirectory: Bool = false) {
        self.path = path
        self.size = size
        self.offset = offset
        self.unpacked = unpacked
        self.link = link
        self.isDirectory = isDirectory
    }
}

public enum AsarError: Error, LocalizedError, Sendable {
    case openFailed(String)
    case malformedHeader(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let path):
            return "无法打开或读取 asar 文件：\(path)"
        case .malformedHeader(let reason):
            return "asar 头部损坏：\(reason)"
        case .writeFailed(let path):
            return "写入失败：\(path)"
        }
    }
}

public enum Asar {

    // MARK: - 读取

    /// 列出归档内的所有条目（含目录），按路径排序。
    public static func entries(at url: URL) throws -> [AsarEntry] {
        let (root, _) = try loadHeader(at: url)
        var result: [AsarEntry] = []

        func walk(_ node: [String: Any], _ prefix: String) {
            guard let files = node["files"] as? [String: Any] else { return }
            for name in files.keys.sorted() {
                guard let meta = files[name] as? [String: Any] else { continue }
                let rel = prefix.isEmpty ? name : prefix + "/" + name

                if meta["files"] != nil {
                    result.append(AsarEntry(path: rel, isDirectory: true))
                    walk(meta, rel)
                } else if let link = meta["link"] as? String {
                    result.append(AsarEntry(path: rel, link: link))
                } else {
                    result.append(AsarEntry(path: rel,
                                            size: intValue(meta["size"]),
                                            offset: intValue(meta["offset"]),
                                            unpacked: (meta["unpacked"] as? Bool) ?? false))
                }
            }
        }

        walk(root, "")
        return result
    }

    /// 把归档完整解包到目标目录。
    ///
    /// - 普通文件按 offset/size 切片写出
    /// - `unpacked` 文件从 `<asar>.unpacked/` 复制
    /// - 符号链接按原样重建
    @discardableResult
    public static func extract(_ url: URL, to destination: URL) throws -> Int {
        let (root, dataStart) = try loadHeader(at: url)

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw AsarError.openFailed(url.path)
        }
        defer { try? handle.close() }

        let fm = FileManager.default
        let unpackedRoot = url.path + ".unpacked"
        var count = 0

        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        func walk(_ node: [String: Any], _ prefix: String) throws {
            guard let files = node["files"] as? [String: Any] else { return }

            for name in files.keys.sorted() {
                guard let meta = files[name] as? [String: Any] else { continue }
                let rel = prefix.isEmpty ? name : prefix + "/" + name
                let target = destination.appendingPathComponent(rel)

                if meta["files"] != nil {
                    try fm.createDirectory(at: target, withIntermediateDirectories: true)
                    try walk(meta, rel)
                    continue
                }

                try fm.createDirectory(at: target.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)

                if let link = meta["link"] as? String {
                    try? fm.removeItem(at: target)
                    try fm.createSymbolicLink(atPath: target.path, withDestinationPath: link)
                    count += 1
                    continue
                }

                if (meta["unpacked"] as? Bool) == true {
                    let source = unpackedRoot + "/" + rel
                    if fm.fileExists(atPath: source) {
                        try? fm.removeItem(at: target)
                        try fm.copyItem(atPath: source, toPath: target.path)
                    } else {
                        // 归档声明了 unpacked 但外部目录里没有，留一个空文件占位
                        fm.createFile(atPath: target.path, contents: Data())
                    }
                    count += 1
                    continue
                }

                let offset = intValue(meta["offset"])
                let size = intValue(meta["size"])
                try handle.seek(toOffset: UInt64(dataStart + offset))
                let data = handle.readData(ofLength: size)
                try data.write(to: target)
                count += 1
            }
        }

        try walk(root, "")
        return count
    }

    /// 按路径查找单个条目。
    public static func entry(at path: String, in url: URL) throws -> AsarEntry? {
        try entries(at: url).first { $0.path == path }
    }

    /// 读取归档内单个文件的内容，无需整体解包。
    public static func data(for path: String, in url: URL) throws -> Data {
        let (root, dataStart) = try loadHeader(at: url)

        // 沿路径逐层查找
        var node: [String: Any] = root
        let comps = path.split(separator: "/").map(String.init)
        guard !comps.isEmpty else { throw AsarError.malformedHeader("路径为空") }

        for comp in comps {
            guard let files = node["files"] as? [String: Any],
                  let next = files[comp] as? [String: Any] else {
                throw AsarError.openFailed("归档内不存在：\(path)")
            }
            node = next
        }

        guard let size = node["size"] as? NSNumber else {
            throw AsarError.openFailed("路径不是文件：\(path)")
        }

        if (node["unpacked"] as? Bool) == true {
            let external = url.path + ".unpacked/" + path
            guard let data = FileManager.default.contents(atPath: external) else {
                throw AsarError.openFailed("unpacked 文件缺失：\(external)")
            }
            return data
        }

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw AsarError.openFailed(url.path)
        }
        defer { try? handle.close() }

        try handle.seek(toOffset: UInt64(dataStart + intValue(node["offset"])))
        return handle.readData(ofLength: size.intValue)
    }

    // MARK: - 写入

    /// 把一个目录打包为 asar。
    ///
    /// - Parameters:
    ///   - directory: 要打包的目录
    ///   - url: 输出的 asar 路径
    ///   - unpacked: 需要放到 `<asar>.unpacked/` 的路径前缀（相对目录，如 `["bin", "node_modules/keytar"]`）
    public static func pack(directory: URL,
                            to url: URL,
                            unpacked: [String] = []) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else {
            throw AsarError.openFailed(directory.path)
        }

        // 1) 按确定性顺序收集所有节点
        var ordered: [(rel: String, absolute: String, isDirectory: Bool, link: String?, size: Int)] = []

        func collect(_ dir: String, _ prefix: String) throws {
            let names = (try? fm.contentsOfDirectory(atPath: dir))?.sorted() ?? []
            for name in names {
                // 跳过我们自己的 unpacked 输出目录，避免递归打包
                if prefix.isEmpty && name == "app.asar.unpacked" { continue }

                let rel = prefix.isEmpty ? name : prefix + "/" + name
                let absolute = dir + "/" + name
                let attrs = try? fm.attributesOfItem(atPath: absolute)
                let type = attrs?[.type] as? FileAttributeType

                if type == .typeSymbolicLink {
                    let target = (try? fm.destinationOfSymbolicLink(atPath: absolute)) ?? ""
                    ordered.append((rel, absolute, false, target, 0))
                } else if type == .typeDirectory {
                    ordered.append((rel, absolute, true, nil, 0))
                    try collect(absolute, rel)
                } else {
                    let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
                    ordered.append((rel, absolute, false, nil, size))
                }
            }
        }
        try collect(directory.path, "")

        // 2) 按收集顺序分配 offset（必须与写数据的顺序完全一致）
        let isUnpacked: (String) -> Bool = { rel in
            unpacked.contains { rel == $0 || rel.hasPrefix($0 + "/") }
        }

        var offsets: [String: Int] = [:]
        var cursor = 0
        for item in ordered where !item.isDirectory && item.link == nil && !isUnpacked(item.rel) {
            offsets[item.rel] = cursor
            cursor += item.size
        }

        // 3) 构建 JSON 树
        let root = NSMutableDictionary()

        /// 取节点的 files 字典，没有就建一个（目录节点可能先于子节点出现）
        func filesOf(_ node: NSMutableDictionary) -> NSMutableDictionary {
            if let existing = node["files"] as? NSMutableDictionary { return existing }
            let created = NSMutableDictionary()
            node["files"] = created
            return created
        }

        func insert(_ rel: String, _ meta: NSMutableDictionary) {
            let comps = rel.split(separator: "/").map(String.init)
            var node = root

            for comp in comps.dropLast() {
                let files = filesOf(node)
                if let existing = files[comp] as? NSMutableDictionary {
                    node = existing
                } else {
                    let created = NSMutableDictionary()
                    files[comp] = created
                    node = created
                }
            }
            filesOf(node)[comps.last!] = meta
        }

        for item in ordered {
            let meta = NSMutableDictionary()
            if item.isDirectory {
                // 目录节点必须带 files 键，否则解析时会被当成 0 字节文件
                let dir = NSMutableDictionary()
                dir["files"] = NSMutableDictionary()
                insert(item.rel, dir)
                continue
            }
            if let link = item.link {
                meta["link"] = link
                insert(item.rel, meta)
                continue
            }
            meta["size"] = item.size
            if isUnpacked(item.rel) {
                meta["unpacked"] = true
            } else {
                // asar 规范里 offset 是字符串
                meta["offset"] = String(offsets[item.rel] ?? 0)
            }
            insert(item.rel, meta)
        }

        // 4) 写头部
        let json = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        var payload = Data()
        payload.append(littleEndian(UInt32(json.count)))
        payload.append(json)
        // 头部按 64 字节对齐（与原实现一致）
        let aligned = ((payload.count + 63) / 64) * 64
        payload.append(Data(repeating: 0, count: aligned - payload.count))

        var header = Data()
        header.append(littleEndian(UInt32(payload.count)))
        header.append(payload)

        var file = Data()
        file.append(littleEndian(UInt32(4)))
        file.append(littleEndian(UInt32(header.count)))
        file.append(header)

        // 5) 按同一顺序追加文件内容
        for item in ordered where !item.isDirectory && item.link == nil && !isUnpacked(item.rel) {
            guard let data = fm.contents(atPath: item.absolute) else {
                throw AsarError.openFailed(item.absolute)
            }
            file.append(data)
        }

        do {
            try file.write(to: url)
        } catch {
            throw AsarError.writeFailed(url.path)
        }

        // 6) 输出 unpacked 文件
        if !unpacked.isEmpty {
            let unpackedRoot = url.path + ".unpacked"
            try? fm.removeItem(atPath: unpackedRoot)
            for item in ordered where !item.isDirectory && item.link == nil && isUnpacked(item.rel) {
                let dest = unpackedRoot + "/" + item.rel
                try? fm.createDirectory(atPath: (dest as NSString).deletingLastPathComponent,
                                        withIntermediateDirectories: true)
                try? fm.copyItem(atPath: item.absolute, toPath: dest)
            }
        }
    }

    // MARK: - 内部

    private static func loadHeader(at url: URL) throws -> ([String: Any], Int) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw AsarError.openFailed(url.path)
        }
        defer { try? handle.close() }

        guard let sizePrefix = try? handle.read(upToCount: 4), sizePrefix.count == 4 else {
            throw AsarError.malformedHeader("缺少 4 字节长度前缀")
        }

        guard let sizeField = try? handle.read(upToCount: 4), sizeField.count == 4 else {
            throw AsarError.malformedHeader("缺少头部尺寸字段")
        }
        let headerSize = Int(readUInt32(sizeField))
        guard headerSize >= 8 else {
            throw AsarError.malformedHeader("头部尺寸异常：\(headerSize)")
        }

        guard let header = try? handle.read(upToCount: headerSize),
              header.count == headerSize else {
            throw AsarError.malformedHeader("头部数据不完整")
        }

        // 头部布局：[uint32 payloadLen][uint32 jsonLen][json][padding]
        let payloadLength = Int(readUInt32(header.prefix(4)))
        guard payloadLength > 0 else {
            throw AsarError.malformedHeader("payload 长度异常")
        }

        let jsonLength = Int(readUInt32(header.dropFirst(4).prefix(4)))
        guard jsonLength > 0, header.count >= 8 + jsonLength else {
            throw AsarError.malformedHeader("JSON 长度越界")
        }

        let json = header.subdata(in: 8..<(8 + jsonLength))
        guard let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else {
            throw AsarError.malformedHeader("JSON 解析失败")
        }

        return (root, 8 + headerSize)
    }

    /// 兼容 asar 里 offset 既可能是字符串、也可能是数字两种写法。
    private static func intValue(_ any: Any?) -> Int {
        if let number = any as? NSNumber { return number.intValue }
        if let text = any as? String { return Int(text) ?? 0 }
        return 0
    }

    private static func readUInt32(_ data: Data) -> UInt32 {
        var value: UInt32 = 0
        for (index, byte) in data.prefix(4).enumerated() {
            value |= UInt32(byte) << (8 * index)
        }
        return value
    }

    private static func littleEndian(_ value: UInt32) -> Data {
        var v = value.littleEndian
        return Data(bytes: &v, count: 4)
    }
}
