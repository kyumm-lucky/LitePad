#!/usr/bin/env swift
// LitePad 应用图标生成器：纯 Core Graphics 矢量绘制，无外部素材。
// 画面构成：黑色圆角方块（macOS 图标网格：1024 画布内 824 见方、圆角 186）
//          + 居中白纸 + 六行文字条（一行高亮蓝）+ 蓝色光标。
// 用法：swift scripts/make-icon.swift
// 产物：Resources/AppIcon.icns（打包脚本会拷进 .app）、build/AppIcon-1024.png（预览）

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - 设计尺寸（全部按 1024×1024 画布标注，输出时等比缩放）

private let designSize: CGFloat = 1024
private let plateRect = CGRect(x: 100, y: 100, width: 824, height: 824)
private let plateRadius: CGFloat = 186
private let pageRect = CGRect(x: 300, y: 236, width: 424, height: 552)
private let pageRadius: CGFloat = 44

/// 文字条：左端 x、最大宽度、条高、各条宽度占比、各条行中心 y
private let barX: CGFloat = 364
private let barMaxWidth: CGFloat = 296
private let barHeight: CGFloat = 30
private let barWidths: [CGFloat] = [0.80, 0.56, 0.92, 0.44, 0.72, 0.36]
/// 六行等距、条块整体在纸面内上下留白相等（各 81）
private let barCenters: [CGFloat] = [332, 404, 476, 548, 620, 692]
/// 高亮行（第 3 行）与光标所在行（第 4 行）
private let highlightBarIndex = 2
private let caretBarIndex = 3
private let caretGap: CGFloat = 26
private let caretWidth: CGFloat = 14
private let caretHeight: CGFloat = 48

private func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

private let plateTop = rgb(0x101013)
private let plateBottom = rgb(0x000000)
private let plateStroke = rgb(0xFFFFFF, alpha: 0.09)
private let pageTop = rgb(0xFFFFFF)
private let pageBottom = rgb(0xEFEFF2)
private let barBase = rgb(0x232329)
private let barHighlight = rgb(0x2E6BE6)
private let caretColor = rgb(0x0A84FF)

// MARK: - 绘制

private func fillRounded(_ ctx: CGContext, _ rect: CGRect, radius: CGFloat, color: CGColor) {
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setFillColor(color)
    ctx.fillPath()
}

/// 在 rect 内自上而下填充线性渐变（文字方向为屏幕方向，故起点在上边）
private func fillRoundedGradient(_ ctx: CGContext, _ rect: CGRect, radius: CGFloat, from: CGColor, to: CGColor) {
    guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                    colors: [from, to] as CFArray,
                                    locations: [0, 1]) else { return }
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.clip()
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: rect.midX, y: rect.minY),
                           end: CGPoint(x: rect.midX, y: rect.maxY),
                           options: [])
    ctx.restoreGState()
}

/// 画布坐标系翻转为「左上原点、y 向下」，之后所有坐标都与设计标注一致
private func drawIcon(into ctx: CGContext, pixelSize: Int) {
    let scale = CGFloat(pixelSize) / designSize
    ctx.saveGState()
    ctx.translateBy(x: 0, y: CGFloat(pixelSize))
    ctx.scaleBy(x: scale, y: -scale)

    fillRoundedGradient(ctx, plateRect, radius: plateRadius, from: plateTop, to: plateBottom)
    // 深色背景下勾出一道极淡的边界，避免图标与黑壁纸糊在一起
    ctx.addPath(CGPath(roundedRect: plateRect, cornerWidth: plateRadius, cornerHeight: plateRadius, transform: nil))
    ctx.setStrokeColor(plateStroke)
    ctx.setLineWidth(3)
    ctx.strokePath()

    fillRoundedGradient(ctx, pageRect, radius: pageRadius, from: pageTop, to: pageBottom)

    for (index, center) in barCenters.enumerated() {
        let width = barMaxWidth * barWidths[index]
        let bar = CGRect(x: barX, y: center - barHeight / 2, width: width, height: barHeight)
        fillRounded(ctx, bar, radius: barHeight / 2,
                    color: index == highlightBarIndex ? barHighlight : barBase)
    }

    let caretX = barX + barMaxWidth * barWidths[caretBarIndex] + caretGap
    let caret = CGRect(x: caretX, y: barCenters[caretBarIndex] - caretHeight / 2,
                       width: caretWidth, height: caretHeight)
    fillRounded(ctx, caret, radius: caretWidth / 2, color: caretColor)

    ctx.restoreGState()
}

private func renderBitmap(pixelSize: Int, master: CGImage? = nil) -> CGImage {
    guard let ctx = CGContext(data: nil,
                              width: pixelSize,
                              height: pixelSize,
                              bitsPerComponent: 8,
                              bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("无法创建 \(pixelSize)×\(pixelSize) 位图上下文")
    }
    ctx.interpolationQuality = .high
    if let master {
        // 小尺寸由 1024 母版高质量缩放，比直接按小尺寸重绘更干净
        ctx.draw(master, in: CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
    } else {
        drawIcon(into: ctx, pixelSize: pixelSize)
    }
    guard let image = ctx.makeImage() else { fatalError("无法生成 \(pixelSize)×\(pixelSize) 位图") }
    return image
}

private func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                            UTType.png.identifier as CFString,
                                                            1, nil) else {
        throw NSError(domain: "make-icon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "无法写入 \(url.path)"])
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "make-icon", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "PNG 编码失败：\(url.path)"])
    }
}

// MARK: - 主流程

/// .iconset 需要的十个文件：[文件名: 像素边长]
private let iconsetEntries: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

private func run() throws {
    // 与 make-app.sh 一致：脚本位置即项目根，允许从任意目录调用
    let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        .deletingLastPathComponent()
    let root = scriptDir.deletingLastPathComponent()
    let icnsURL = root.appendingPathComponent("Resources/AppIcon.icns")
    let previewURL = root.appendingPathComponent("build/AppIcon-1024.png")

    let fileManager = FileManager.default
    let iconsetURL = fileManager.temporaryDirectory
        .appendingPathComponent("LitePad-\(UUID().uuidString).iconset")
    try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: iconsetURL) }

    let master = renderBitmap(pixelSize: 1024)
    for (name, size) in iconsetEntries {
        try writePNG(size == 1024 ? master : renderBitmap(pixelSize: size, master: master),
                     to: iconsetURL.appendingPathComponent(name))
    }

    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", icnsURL.path]
    try iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else {
        throw NSError(domain: "make-icon", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "iconutil 退出码 \(iconutil.terminationStatus)"])
    }

    // 顺带留一张母版预览（build/ 不入库），便于肉眼检查
    try fileManager.createDirectory(at: previewURL.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
    try writePNG(master, to: previewURL)

    print("✅ 图标已生成: Resources/AppIcon.icns（预览: build/AppIcon-1024.png）")
}

do {
    try run()
} catch {
    FileHandle.standardError.write("❌ 生成图标失败: \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}
