import AgentContracts
import CoreGraphics
import Foundation

/// 트리 한 노드에서 읽은 접근성 속성. 실제 AX와 가짜 노드가 같은 형태를 쓴다.
public struct AXNodeInfo: Sendable, Equatable {
    public var role: String
    public var subrole: String?
    public var roleDescription: String?
    public var title: String?
    public var descriptionText: String?
    public var value: String?
    public var placeholder: String?
    /// 전역 AX 좌표(좌상단 원점).
    public var frame: CGRect?
    public var isValueSettable: Bool
    public var isFocused: Bool
    public var isEnabled: Bool
    public var isHidden: Bool
    public var actions: [String]

    public init(role: String, subrole: String? = nil, roleDescription: String? = nil, title: String? = nil,
                descriptionText: String? = nil, value: String? = nil, placeholder: String? = nil, frame: CGRect? = nil,
                isValueSettable: Bool = false, isFocused: Bool = false, isEnabled: Bool = true, isHidden: Bool = false,
                actions: [String] = []) {
        self.role = role; self.subrole = subrole; self.roleDescription = roleDescription; self.title = title
        self.descriptionText = descriptionText; self.value = value; self.placeholder = placeholder; self.frame = frame
        self.isValueSettable = isValueSettable; self.isFocused = isFocused; self.isEnabled = isEnabled
        self.isHidden = isHidden; self.actions = actions
    }

    public var isSecure: Bool { AXSemantics.isSecure(role: role, subrole: subrole) }

    /// 이름도, 값도, 동작도 없는 묶음 노드. 압축 시 줄을 만들지 않는다.
    public var isFlattenable: Bool {
        AXSemantics.flattenableRoles.contains(role)
            && AXSemantics.clean(title, maxLength: 1) == nil
            && AXSemantics.clean(descriptionText, maxLength: 1) == nil
            && AXSemantics.clean(value, maxLength: 1) == nil
            && AXSemantics.clean(placeholder, maxLength: 1) == nil
            && actions.allSatisfy { AXSemantics.noiseActions.contains($0) }
            && !isValueSettable && !isFocused
    }
}

public struct AppStateLimits: Sendable, Equatable {
    /// 실제 트리 깊이 한도(압축으로 생략된 단계도 센다).
    public var maxDepth: Int
    /// 출력 줄(색인) 수 한도.
    public var maxNodes: Int
    /// 노드 하나에서 따라갈 자식 수 한도. 긴 표·목록에서 폭주를 막는다.
    public var maxChildrenPerNode: Int
    public var maxLabelLength: Int
    public var flattenUnlabeledGroups: Bool
    /// 줄 끝에 " [x,y wxh]" 프레임을 붙인다. 프레임은 항상 elements에도 들어 있다.
    public var includeFramesInText: Bool

    public init(maxDepth: Int = 40, maxNodes: Int = 600, maxChildrenPerNode: Int = 200, maxLabelLength: Int = 160,
                flattenUnlabeledGroups: Bool = true, includeFramesInText: Bool = false) {
        self.maxDepth = maxDepth; self.maxNodes = maxNodes; self.maxChildrenPerNode = maxChildrenPerNode
        self.maxLabelLength = maxLabelLength; self.flattenUnlabeledGroups = flattenUnlabeledGroups
        self.includeFramesInText = includeFramesInText
    }
}

public struct AppStateTruncation: Sendable, Equatable, Codable {
    public var maxDepthReached: Bool
    public var maxNodesReached: Bool
    /// 자식 수 한도로 건너뛴 자식 수.
    public var omittedChildren: Int

    public init(maxDepthReached: Bool = false, maxNodesReached: Bool = false, omittedChildren: Int = 0) {
        self.maxDepthReached = maxDepthReached; self.maxNodesReached = maxNodesReached
        self.omittedChildren = omittedChildren
    }

    public var truncated: Bool { maxDepthReached || maxNodesReached || omittedChildren > 0 }
}

/// 깊이·개수 한도를 지키며 트리를 전위 순회하고 출력 줄마다 연속 색인을 붙인다.
/// `Handle`은 실제 AXUIElement 래퍼이거나 검사용 가짜 노드다.
public struct AXTreeWalker<Handle> {
    public struct Node {
        public let index: Int
        /// 출력 들여쓰기 깊이(압축된 묶음은 세지 않는다).
        public let depth: Int
        public let info: AXNodeInfo
        public let handle: Handle
    }

    public struct Result {
        public var nodes: [Node]
        public var truncation: AppStateTruncation
    }

    private let info: (Handle) -> AXNodeInfo
    private let children: (Handle) -> [Handle]

    public init(info: @escaping (Handle) -> AXNodeInfo, children: @escaping (Handle) -> [Handle]) {
        self.info = info
        self.children = children
    }

    public func walk(root: Handle, limits: AppStateLimits) -> Result {
        var result = Result(nodes: [], truncation: AppStateTruncation())
        visit(root, rawDepth: 0, printDepth: 0, limits: limits, into: &result)
        return result
    }

    private func visit(_ handle: Handle, rawDepth: Int, printDepth: Int, limits: AppStateLimits, into result: inout Result) {
        if result.nodes.count >= limits.maxNodes {
            result.truncation.maxNodesReached = true
            return
        }
        let nodeInfo = info(handle)
        if nodeInfo.isHidden { return }
        let flatten = limits.flattenUnlabeledGroups && rawDepth > 0 && nodeInfo.isFlattenable
        var childDepth = printDepth
        if !flatten {
            result.nodes.append(Node(index: result.nodes.count, depth: printDepth, info: nodeInfo, handle: handle))
            childDepth = printDepth + 1
        }
        let kids = children(handle)
        guard !kids.isEmpty else { return }
        if rawDepth + 1 > limits.maxDepth {
            result.truncation.maxDepthReached = true
            return
        }
        let limit = max(0, limits.maxChildrenPerNode)
        if kids.count > limit { result.truncation.omittedChildren += kids.count - limit }
        for kid in kids.prefix(limit) {
            visit(kid, rawDepth: rawDepth + 1, printDepth: childDepth, limits: limits, into: &result)
            if result.truncation.maxNodesReached { return }
        }
    }
}

/// Orca `get-app-state` 형식을 따른 트리 텍스트.
public enum AppStateFormatter {
    /// 들여쓰기 없는 한 줄. 예: "2 text entry area (settable) - 메모 내용".
    public static func line(index: Int, info: AXNodeInfo, limits: AppStateLimits = .init()) -> String {
        let maxLen = limits.maxLabelLength
        var text = "\(index) "
        text += AXSemantics.clean(info.roleDescription, maxLength: 60)?.lowercased() ?? AXSemantics.humanizedRole(info.role)
        if info.isValueSettable { text += " (settable)" }
        if info.isSecure { text += " (secure)" }
        if !info.isEnabled { text += " (disabled)" }

        let name = AXSemantics.clean(info.title, maxLength: maxLen) ?? AXSemantics.clean(info.descriptionText, maxLength: maxLen)
        let value = info.isSecure ? nil : AXSemantics.clean(info.value, maxLength: maxLen)
        if let name, let value, value != name {
            text += " - \(name): \(value)"
        } else if let name {
            text += " - \(name)"
        } else if let value {
            text += " - \(value)"
        } else if let placeholder = AXSemantics.clean(info.placeholder, maxLength: maxLen) {
            text += " - placeholder: \(placeholder)"
        }

        let secondary = AXSemantics.secondaryActions(info.actions).map(AXSemantics.humanizedAction)
        if !secondary.isEmpty { text += ", Secondary Actions: " + secondary.joined(separator: ", ") }
        if limits.includeFramesInText, let f = info.frame?.standardized {
            text += " [\(Int(f.minX.rounded())),\(Int(f.minY.rounded())) \(Int(f.width.rounded()))x\(Int(f.height.rounded()))]"
        }
        return text
    }

    public static func treeText(appName: String, bundleID: String?, pid: Int32, windowTitle: String?,
                                nodes: [(index: Int, depth: Int, info: AXNodeInfo)], focusedIndex: Int?,
                                truncation: AppStateTruncation, limits: AppStateLimits = .init()) -> String {
        var lines: [String] = []
        lines.append("App=\(bundleID ?? appName) (pid \(pid))")
        if let title = AXSemantics.clean(windowTitle, maxLength: limits.maxLabelLength) {
            lines.append("Window: \"\(title)\", App: \(appName).")
        } else {
            lines.append("App: \(appName).")
        }
        lines.append("")
        for node in nodes {
            lines.append(String(repeating: "\t", count: node.depth) + line(index: node.index, info: node.info, limits: limits))
        }
        if truncation.truncated {
            var why: [String] = []
            if truncation.maxNodesReached { why.append("element limit \(limits.maxNodes) reached") }
            if truncation.maxDepthReached { why.append("depth limit \(limits.maxDepth) reached") }
            if truncation.omittedChildren > 0 { why.append("\(truncation.omittedChildren) children omitted") }
            lines.append("… truncated: " + why.joined(separator: ", "))
        }
        if let focusedIndex, let focused = nodes.first(where: { $0.index == focusedIndex }) {
            lines.append("")
            lines.append("The focused UI element is \(line(index: focused.index, info: focused.info, limits: limits)).")
        }
        return lines.joined(separator: "\n")
    }
}

public struct AppStateElement: Sendable, Equatable, Codable {
    public let index: Int
    public let depth: Int
    public let target: UITarget

    public init(index: Int, depth: Int, target: UITarget) {
        self.index = index; self.depth = depth; self.target = target
    }
}

/// 앱 하나의 압축 접근성 스냅샷. 색인은 짧게만 유효하며, 동작에는 elements의 UITarget(token)을 쓴다.
public struct AppStateSnapshot: Sendable, Equatable, Codable {
    public let pid: Int32
    public let appName: String
    public let bundleID: String?
    public let windowTitle: String?
    /// 대상 창 프레임(전역 AX 좌표).
    public let windowFrame: CGRect?
    public let treeText: String
    public let elements: [AppStateElement]
    public let focusedIndex: Int?
    public let truncation: AppStateTruncation
    public let capturedAt: MonotonicTime

    public init(pid: Int32, appName: String, bundleID: String?, windowTitle: String?, windowFrame: CGRect?,
                treeText: String, elements: [AppStateElement], focusedIndex: Int?, truncation: AppStateTruncation,
                capturedAt: MonotonicTime) {
        self.pid = pid; self.appName = appName; self.bundleID = bundleID; self.windowTitle = windowTitle
        self.windowFrame = windowFrame; self.treeText = treeText; self.elements = elements
        self.focusedIndex = focusedIndex; self.truncation = truncation; self.capturedAt = capturedAt
    }

    public var elementCount: Int { elements.count }

    public func element(index: Int) -> AppStateElement? {
        elements.first { $0.index == index }
    }

    /// 전역 좌표를 포함하는 가장 작은 요소(같으면 더 깊은 요소). 시선 좌표를 색인으로 바꿀 때 쓴다.
    public func element(at point: CGPoint) -> AppStateElement? {
        var best: AppStateElement?
        var bestArea = CGFloat.infinity
        for element in elements {
            let frame = element.target.frame.standardized
            guard frame.width > 0, frame.height > 0, frame.contains(point) else { continue }
            let area = frame.width * frame.height
            if area < bestArea || (area == bestArea && element.depth >= (best?.depth ?? 0)) {
                best = element
                bestArea = area
            }
        }
        return best
    }
}
