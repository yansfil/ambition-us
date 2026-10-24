import AgentContracts
import CoreGraphics
import Foundation

func contractsChecks() async {
    await suite("Contracts") {
        check(RiskLevel.low < RiskLevel.high, "위험도 순서")
        let word = WordTiming(word: "이거", start: .init(nanoseconds: 10), end: .init(nanoseconds: 20), confidence: 0.9)
        let update = TranscriptUpdate(utteranceID: UUID(), revision: 2, text: "이거를", stablePrefix: "이거",
                                      words: [word], isFinal: false)
        let decoded = try JSONDecoder().decode(TranscriptUpdate.self, from: JSONEncoder().encode(update))
        check(decoded == update, "TranscriptUpdate 직렬화 왕복")

        // 통합 때 더한 필드: 기본값과 직렬화.
        let binding = DeicticBinding(word: word, target: nil, confidence: 0.5)
        check(binding.role == .unknown, "DeicticBinding.role 기본값 unknown")
        let roled = DeicticBinding(word: word, target: nil, confidence: 0.5, role: .destination)
        let roledRoundTrip = try JSONDecoder().decode(DeicticBinding.self, from: JSONEncoder().encode(roled))
        check(roledRoundTrip == roled, "DeicticBinding 역할 직렬화 왕복")
        var bindingJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(roled)) as? [String: Any] ?? [:]
        bindingJSON["role"] = nil
        let oldBinding = try JSONDecoder().decode(DeicticBinding.self, from: JSONSerialization.data(withJSONObject: bindingJSON))
        check(oldBinding.role == .unknown, "역할 없는 예전 JSON → unknown")

        let cue = NonverbalCue(time: .init(nanoseconds: 5), kind: .prolongedDwell, targetID: "gaze-region-1@1",
                               confidence: 0.8, point: CGPoint(x: 10, y: 20), displayID: 1)
        let cueRoundTrip = try JSONDecoder().decode(NonverbalCue.self, from: JSONEncoder().encode(cue))
        check(cueRoundTrip == cue, "NonverbalCue 위치 직렬화 왕복")
        let retargeted = cue.withTargetID("ax-1")
        check(retargeted.targetID == "ax-1" && retargeted.point == cue.point && retargeted.kind == cue.kind,
              "withTargetID는 대상 키만 바꿈")
        check(NonverbalCue(time: .init(nanoseconds: 5), kind: .headNod, targetID: nil, confidence: 0.8).point == nil,
              "머리 제스처 단서는 위치 없음")

        let target = UITarget(token: "t", pid: 1, appBundleID: nil, role: "AXButton", title: nil, frame: .zero,
                              isEditable: false, isSecure: false, supportedActions: [], observedAt: .init(nanoseconds: 1))
        let proposal = ActionProposal(id: UUID(), action: .press(target: target), basedOnUtterance: UUID(),
                                      basedOnRevision: 1, rationale: "r", risk: .low, expiresAt: .init(nanoseconds: 9))
        check(proposal.origin == .intent, "ActionProposal.origin 기본값 intent")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(proposal)) as? [String: Any] ?? [:]
        json["origin"] = nil
        let old = try JSONDecoder().decode(ActionProposal.self, from: JSONSerialization.data(withJSONObject: json))
        check(old == proposal, "origin 없는 예전 JSON → intent")
        check(ActionOutcome.Status(rawValue: "rejected") == .rejected, "ActionOutcome.Status.rejected")

        let clock = UptimeClock()
        let a = clock.now(), b = clock.now()
        check(a <= b && a.nanoseconds > 0, "UptimeClock 단조 증가")
        check(abs(Double(a.nanoseconds) - Double(DispatchTime.now().uptimeNanoseconds)) < 1e9,
              "UptimeClock = DispatchTime uptime 기준")
    }
}
