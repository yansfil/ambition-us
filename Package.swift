// swift-tools-version: 6.2
import PackageDescription

let modules: [Target.Dependency] = ["AgentContracts", "Gaze", "SpeechInput", "AXControl", "Overlay", "Fusion",
                                     "Intelligence", "Control"]

let package = Package(
    name: "Gaze",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "GazeApp", targets: ["GazeApp"])],
    targets: [
        .target(name: "AgentContracts"),
        .target(name: "Gaze", dependencies: ["AgentContracts"]),
        .target(name: "SpeechInput", dependencies: ["AgentContracts"]),
        .target(name: "AXControl", dependencies: ["AgentContracts"]),
        .target(name: "Overlay", dependencies: ["AgentContracts"]),
        .target(name: "Fusion", dependencies: ["AgentContracts"]),
        .target(name: "Intelligence", dependencies: ["AgentContracts"]),
        .target(name: "Control", dependencies: ["AgentContracts"]),
        // 통합 코어: 스트림 방송, 모듈 연결, 받아쓰기 드라이버, 실제 구성(AgentAssembly).
        .target(name: "AppCore", dependencies: modules),
        .executableTarget(name: "GazeApp", dependencies: modules + ["AppCore"]),
        // Xcode 없는 환경에서 `swift run GazeChecks`로 실행하는 검사 하네스.
        .executableTarget(name: "GazeChecks", dependencies: modules + ["AppCore"]),
    ]
)
