// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LitePad",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "LitePad",
            path: "Sources/LitePad",
            linkerSettings: [
                // 裸二进制（swift run / Xcode 直接运行）没有 .app 包，Bundle.main 取不到
                // CFBundleLocalizations，AppKit/SwiftUI 的标准菜单会回落成英文。
                // 以资源段方式嵌入 Info.plist 声明简体中文，使开发运行也能得到中文菜单。
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/DevRunInfo.plist",
                ])
            ]
        )
    ]
)
