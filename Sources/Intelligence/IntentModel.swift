import AgentContracts
import CoreGraphics
import Foundation

/// 애매한 경우에만 쓰는 원격 판단기. 기본 구현은 `ClaudeIntentClient`.
/// 실패·시간 초과·취소·거절은 모두 `.none`으로 돌려준다.
public protocol IntentModelClient: Sendable {
    func infer(_ request: IntentModelRequest) async -> ModelDecision
}

public enum AmbiguityReason: String, Sendable, Equatable {
    /// 명령 동사는 있지만 대상·내용을 로컬에서 확정하지 못함.
    case unresolvedCommand
    /// 입력란을 보며 부탁 어미로 끝남: 입력할 내용인지 에이전트 요청인지 애매.
    case uncertainRequest
    /// 지시어가 다른 대상을 가리키지만 명령 동사가 없음(질문 등).
    case deicticReference
    /// 에이전트를 불렀지만 명령을 해석하지 못함.
    case agentAddressed
}

/// 모델에 보내는 최소 대상 요약. AX 토큰·pid·번들 ID는 보내지 않는다.
public struct TargetSummary: Sendable, Equatable {
    public let id: String
    public let role: String
    /// 화면에서 읽은 텍스트. 신뢰할 수 없는 데이터로 다룬다.
    public let title: String?
    public let frame: CGRect
    public let isEditable: Bool
    public let isSecure: Bool
    public let isGazed: Bool
    public let spokenReferences: [String]
    public let hasDwell: Bool

    public init(id: String, role: String, title: String?, frame: CGRect, isEditable: Bool, isSecure: Bool,
                isGazed: Bool, spokenReferences: [String], hasDwell: Bool) {
        self.id = id; self.role = role; self.title = title; self.frame = frame; self.isEditable = isEditable
        self.isSecure = isSecure; self.isGazed = isGazed; self.spokenReferences = spokenReferences; self.hasDwell = hasDwell
    }
}

public struct IntentModelRequest: Sendable, Equatable {
    /// 아직 처리하지 않은 발화 부분.
    public let utterance: String
    /// 같은 발화에서 이미 처리(입력·실행 제안)한 앞부분.
    public let alreadyHandled: String
    public let isFinal: Bool
    public let reason: AmbiguityReason
    public let targets: [TargetSummary]
    public let paralinguistic: [ParalinguisticCue.Kind]
    public let nonverbal: [NonverbalCue.Kind]

    public init(utterance: String, alreadyHandled: String, isFinal: Bool, reason: AmbiguityReason,
                targets: [TargetSummary], paralinguistic: [ParalinguisticCue.Kind], nonverbal: [NonverbalCue.Kind]) {
        self.utterance = utterance; self.alreadyHandled = alreadyHandled; self.isFinal = isFinal; self.reason = reason
        self.targets = targets; self.paralinguistic = paralinguistic; self.nonverbal = nonverbal
    }
}

public enum ModelActionKind: String, Sendable, Equatable, CaseIterable {
    case typeText, press, move, setValue
}

public struct ModelActionSpec: Sendable, Equatable {
    public let kind: ModelActionKind
    public let targetID: String
    public let destinationID: String?
    public let text: String?
    public init(kind: ModelActionKind, targetID: String, destinationID: String?, text: String?) {
        self.kind = kind; self.targetID = targetID; self.destinationID = destinationID; self.text = text
    }
}

/// 스키마 검증을 통과한 모델 판단. 대상은 요청에 넣은 요약 id로만 참조한다.
public enum ModelDecision: Sendable, Equatable {
    case none
    case proposal(action: ModelActionSpec, message: String, confidence: Double, risk: RiskLevel)
    /// 제안에는 행동이 없다. 실행 요청으로 바뀌지 않는다.
    case suggestion(anchorTargetID: String?, message: String, confidence: Double)
}

public struct IntentSchemaError: Error, Sendable, Equatable, CustomStringConvertible {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
    public var description: String { "IntentSchemaError(\(reason))" }
}

/// 구조화 출력(output_config.format json_schema) 스키마와 로컬 검증.
/// 서버가 스키마를 강제하더라도 응답은 신뢰하지 않고 여기서 다시 검증한다.
public enum IntentDecisionSchema {
    public static let maxMessageLength = 200
    public static let maxTextLength = 2000

    static let topLevelKeys: Set<String> = ["kind", "action", "anchor_target_id", "message", "confidence", "risk"]
    static let actionKeys: Set<String> = ["type", "target_id", "destination_id", "text"]

    public static let schema: JSONValue = {
        let nullableString: JSONValue = ["anyOf": [["type": "string"], ["type": "null"]]]
        let action: JSONValue = [
            "type": "object",
            "properties": [
                "type": ["type": "string", "enum": .array(ModelActionKind.allCases.map { .string($0.rawValue) })],
                "target_id": ["type": "string"],
                "destination_id": nullableString,
                "text": nullableString,
            ],
            "required": ["type", "target_id", "destination_id", "text"],
            "additionalProperties": false,
        ]
        return [
            "type": "object",
            "properties": [
                "kind": ["type": "string", "enum": ["none", "proposal", "suggestion"]],
                "action": ["anyOf": [action, ["type": "null"]]],
                "anchor_target_id": nullableString,
                "message": ["type": "string"],
                "confidence": ["type": "number"],
                "risk": ["type": "string", "enum": ["low", "medium", "high"]],
            ],
            "required": ["kind", "action", "anchor_target_id", "message", "confidence", "risk"],
            "additionalProperties": false,
        ]
    }()

    public static func decode(_ text: String) -> Result<ModelDecision, IntentSchemaError> {
        guard let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .failure(IntentSchemaError("JSON이 아님"))
        }
        return validate(value)
    }

    public static func validate(_ value: JSONValue) -> Result<ModelDecision, IntentSchemaError> {
        guard let object = value.objectValue else { return .failure(IntentSchemaError("최상위가 객체가 아님")) }
        let keys = Set(object.keys)
        guard keys == topLevelKeys else {
            return .failure(IntentSchemaError("키 불일치: \(keys.symmetricDifference(topLevelKeys).sorted())"))
        }
        guard let kind = object["kind"]?.stringValue, ["none", "proposal", "suggestion"].contains(kind) else {
            return .failure(IntentSchemaError("kind 값 오류"))
        }
        guard let confidence = object["confidence"]?.numberValue, confidence.isFinite, (0...1).contains(confidence) else {
            return .failure(IntentSchemaError("confidence 범위 오류"))
        }
        guard let riskRaw = object["risk"]?.stringValue, let risk = RiskLevel(rawValue: riskRaw) else {
            return .failure(IntentSchemaError("risk 값 오류"))
        }
        guard let message = object["message"]?.stringValue, message.count <= maxMessageLength else {
            return .failure(IntentSchemaError("message 오류"))
        }
        let anchor: String?
        switch object["anchor_target_id"] {
        case .string(let id)?: anchor = id
        case .null?: anchor = nil
        default: return .failure(IntentSchemaError("anchor_target_id 타입 오류"))
        }
        let action: ModelActionSpec?
        switch object["action"] {
        case .null?:
            action = nil
        case .object(let fields)?:
            switch validateAction(fields) {
            case .success(let spec): action = spec
            case .failure(let error): return .failure(error)
            }
        default:
            return .failure(IntentSchemaError("action 타입 오류"))
        }

        switch kind {
        case "proposal":
            guard let action else { return .failure(IntentSchemaError("proposal에 action 없음")) }
            return .success(.proposal(action: action, message: message, confidence: confidence, risk: risk))
        case "suggestion":
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .failure(IntentSchemaError("suggestion message 비어 있음")) }
            // action이 와도 버린다: 제안은 행동이 되지 않는다.
            return .success(.suggestion(anchorTargetID: anchor, message: trimmed, confidence: confidence))
        default:
            return .success(.none)
        }
    }

    private static func validateAction(_ fields: [String: JSONValue]) -> Result<ModelActionSpec, IntentSchemaError> {
        guard Set(fields.keys) == actionKeys else { return .failure(IntentSchemaError("action 키 불일치")) }
        guard let typeRaw = fields["type"]?.stringValue, let kind = ModelActionKind(rawValue: typeRaw) else {
            return .failure(IntentSchemaError("action.type 오류"))
        }
        guard let targetID = fields["target_id"]?.stringValue, !targetID.isEmpty else {
            return .failure(IntentSchemaError("action.target_id 오류"))
        }
        func optionalString(_ key: String) -> (ok: Bool, value: String?) {
            switch fields[key] {
            case .string(let s)?: return (true, s)
            case .null?: return (true, nil)
            default: return (false, nil)
            }
        }
        let destination = optionalString("destination_id")
        let text = optionalString("text")
        guard destination.ok, text.ok else { return .failure(IntentSchemaError("action 필드 타입 오류")) }
        if let value = text.value, value.count > maxTextLength { return .failure(IntentSchemaError("action.text 너무 김")) }
        switch kind {
        case .move:
            guard let dest = destination.value, !dest.isEmpty else { return .failure(IntentSchemaError("move에 destination 없음")) }
        case .typeText:
            guard let value = text.value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(IntentSchemaError("typeText에 text 없음"))
            }
        case .setValue:
            guard text.value != nil else { return .failure(IntentSchemaError("setValue에 text 없음")) }
        case .press:
            break
        }
        return .success(ModelActionSpec(kind: kind, targetID: targetID, destinationID: destination.value, text: text.value))
    }
}
