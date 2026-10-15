// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EchoPrompt",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "EchoPrompt", targets: ["TelePrompterApp"])],
    targets: [.executableTarget(name: "TelePrompterApp")]
)
