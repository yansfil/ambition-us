import AppKit
import AgentContracts

// 통합 담당(W8)이 코디네이터를 연결한다. 지금은 메뉴 막대 상주 앱의 진입점만 둔다.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.run()
