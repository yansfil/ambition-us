import AppCore
import AppKit
import Overlay

// Gaze: 웹캠 시선 + 상시 한국어 음성으로 macOS 앱을 다루는 메뉴 막대 상주 에이전트.
//
// 실행 인자
//   --demo        가짜 상태로 오버레이만 띄운다(카메라·마이크·접근성 불필요).
//   --mouse-gaze  카메라 대신 마우스 커서를 시선으로 쓴다(보정 불필요).

let arguments = Set(CommandLine.arguments.dropFirst())

if arguments.contains("--demo") || arguments.contains("--overlay-demo") {
    OverlayDemo.runStandalone()
}

let options = LaunchOptions(gazeMode: arguments.contains("--mouse-gaze") ? .mouse : .camera)
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let appDelegate = GazeAppDelegate(options: options)
application.delegate = appDelegate
application.run()
