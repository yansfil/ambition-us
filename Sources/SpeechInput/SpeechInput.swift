import AgentContracts
import Foundation

// SpeechInput: 마이크 하나로 레벨·VAD·한국어 스트리밍 전사·단어 시각·준언어 신호를 만든다.
// 진입점은 `LiveSpeechSource`(SpeechSource 구현).

public enum SpeechInputError: Error, Equatable, Sendable, CustomStringConvertible {
    case microphonePermissionDenied
    case noInputDevice
    case engineStartFailed(String)
    case transcriberUnavailable
    case localeUnsupported(String)
    case assetsNotInstalled(String)
    case assetInstallFailed(String)
    case audioFormatUnavailable

    public var description: String {
        switch self {
        case .microphonePermissionDenied: "마이크 권한이 없다"
        case .noInputDevice: "입력 장치가 없다"
        case .engineStartFailed(let reason): "오디오 엔진 시작 실패: \(reason)"
        case .transcriberUnavailable: "이 기기에서 SpeechTranscriber를 쓸 수 없다"
        case .localeUnsupported(let locale): "지원하지 않는 로케일: \(locale)"
        case .assetsNotInstalled(let locale): "음성 인식 자산이 설치되지 않았다: \(locale)"
        case .assetInstallFailed(let reason): "음성 인식 자산 설치 실패: \(reason)"
        case .audioFormatUnavailable: "분석기 입력 형식을 정할 수 없다"
        }
    }
}
