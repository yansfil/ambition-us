import CoreML
import CryptoKit
import Foundation
import os

/// 앱 저장 위치(~/Library/Application Support/Gaze).
public enum GazeStoragePaths {
    public static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Gaze", isDirectory: true)
    }

    public static var models: URL { root.appendingPathComponent("Models", isDirectory: true) }
    public static var compiledModels: URL { models.appendingPathComponent("Compiled", isDirectory: true) }
    /// 예전(landmarks-v1) 형식 보정 파일. 읽기만 한다.
    public static var legacyCalibration: URL { root.appendingPathComponent("calibration.json") }
    /// 추정기 ID·보정 표본·암묵 보정 표본까지 담는 새 보관 파일.
    public static var calibrationArchive: URL { root.appendingPathComponent("calibration-v2.json") }
    public static var diagnostics: URL { root.appendingPathComponent("gaze-diagnostics.json") }
}

enum GazeLog {
    static let estimator = Logger(subsystem: "app.gaze", category: "estimator")
    static let camera = Logger(subsystem: "app.gaze", category: "camera")
    static let calibration = Logger(subsystem: "app.gaze", category: "calibration")
}

/// 변환된 시선 CNN의 메타데이터(`scripts/gaze_model/convert.py`가 기록).
public struct GazeModelInfo: Sendable, Equatable, Codable {
    public enum OutputKind: String, Sendable, Codable {
        /// "gaze" [1,4] = yaw, pitch, yaw 표준편차, pitch 표준편차(라디안). 빈 기댓값은 그래프 안에서 계산.
        case continuous
        /// "yaw"/"pitch" 각각 빈 로짓. Swift에서 softmax 기댓값으로 디코딩한다.
        case logits
    }

    public var arch: String
    public var source: String
    public var testTimeFlip: Bool
    public var crop: FaceCropConfiguration
    public var bins: Int
    public var binWidthDegrees: Double
    public var angleOffsetDegrees: Double
    public var inputName: String
    public var outputKind: OutputKind
    public var version: String

    public init(arch: String = "unknown", source: String = "", testTimeFlip: Bool = false,
                crop: FaceCropConfiguration = .init(), bins: Int = 90, binWidthDegrees: Double = 4,
                angleOffsetDegrees: Double = -180, inputName: String = "image", outputKind: OutputKind = .continuous,
                version: String = "1") {
        self.arch = arch; self.source = source; self.testTimeFlip = testTimeFlip; self.crop = crop; self.bins = bins
        self.binWidthDegrees = binWidthDegrees; self.angleOffsetDegrees = angleOffsetDegrees; self.inputName = inputName
        self.outputKind = outputKind; self.version = version
    }

    /// 보정 모델과 짝을 맞추는 추정기 ID. 모델(구조·TTA·크롭)이 바뀌면 특징 의미가 달라지므로 ID도 바뀐다.
    public var estimatorID: String {
        let crop = String(format: "w%.2fh%.2fo%.2f", self.crop.widthScale, self.crop.heightScale, self.crop.verticalOffset)
        return "cnn-\(arch)\(testTimeFlip ? "-tta" : "")-\(crop)-v\(version)"
    }

    /// `MLModelDescription.metadata[.creatorDefinedKey]` → 정보.
    public init(metadata: [String: String], inputNames: [String], outputNames: [String]) {
        self.init()
        arch = metadata["gaze.arch"] ?? "unknown"
        source = metadata["gaze.source"] ?? ""
        testTimeFlip = metadata["gaze.tta"] == "1"
        bins = metadata["gaze.bins"].flatMap(Int.init) ?? 90
        binWidthDegrees = metadata["gaze.binwidth"].flatMap(Double.init) ?? 4
        angleOffsetDegrees = metadata["gaze.angleOffset"].flatMap(Double.init) ?? -180
        version = metadata["gaze.version"] ?? "1"
        let defaults = FaceCropConfiguration()
        let square = metadata["gaze.cropScale"].flatMap(Double.init)
        crop = FaceCropConfiguration(
            widthScale: metadata["gaze.cropWidthScale"].flatMap(Double.init) ?? square ?? defaults.widthScale,
            heightScale: metadata["gaze.cropHeightScale"].flatMap(Double.init) ?? square ?? defaults.heightScale,
            verticalOffset: metadata["gaze.cropYOffset"].flatMap(Double.init) ?? defaults.verticalOffset)
        inputName = inputNames.contains("image") ? "image" : (inputNames.first ?? "image")
        outputKind = outputNames.contains("gaze") ? .continuous : .logits
    }
}

/// CNN 출력(라디안).
public struct GazeAngles: Sendable, Equatable {
    public var yaw: Double
    public var pitch: Double
    /// 빈 분포의 표준편차(라디안). 눈 감김·가림이면 커진다.
    public var yawSpread: Double
    public var pitchSpread: Double

    public init(yaw: Double, pitch: Double, yawSpread: Double = 0, pitchSpread: Double = 0) {
        self.yaw = yaw; self.pitch = pitch; self.yawSpread = yawSpread; self.pitchSpread = pitchSpread
    }
}

/// 빈 분류 출력 디코딩(L2CS-Net / yakhyo gaze-estimation 규약).
public enum GazeBinDecoder {
    /// 로짓 → (기댓값, 표준편차) 라디안. 각도(도) = Σ softmax(logits)ᵢ · i · binWidth + offset.
    public static func decode(logits: [Double], binWidthDegrees: Double = 4,
                              angleOffsetDegrees: Double = -180) -> (mean: Double, spread: Double)? {
        guard !logits.isEmpty, let peak = logits.max(), peak.isFinite else { return nil }
        let exps = logits.map { Foundation.exp($0 - peak) }
        let total = exps.reduce(0, +)
        guard total > 0 else { return nil }
        var mean = 0.0
        for (i, e) in exps.enumerated() { mean += Double(i) * e }
        mean /= total
        var variance = 0.0
        for (i, e) in exps.enumerated() { variance += (Double(i) - mean) * (Double(i) - mean) * e }
        variance /= total
        let degrees = mean * binWidthDegrees + angleOffsetDegrees
        return (degrees * .pi / 180, variance.squareRoot() * binWidthDegrees * .pi / 180)
    }
}

/// 최근 지연 시간 통계(ms). 비디오 큐 전용 값 타입.
public struct LatencyStats: Sendable, Equatable, Codable {
    public private(set) var count = 0
    public private(set) var mean = 0.0
    public private(set) var recent: [Double] = []
    public var capacity = 120

    public init() {}

    public mutating func add(_ milliseconds: Double) {
        count += 1
        mean += (milliseconds - mean) / Double(min(count, capacity))
        recent.append(milliseconds)
        if recent.count > capacity { recent.removeFirst(recent.count - capacity) }
    }

    public func percentile(_ p: Double) -> Double? {
        guard !recent.isEmpty else { return nil }
        let sorted = recent.sorted()
        let index = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[clamp(index, 0, sorted.count - 1)]
    }

    public var median: Double? { percentile(0.5) }
    public var p95: Double? { percentile(0.95) }
}

public enum GazeModelError: Error, Sendable, CustomStringConvertible {
    case notInstalled([String])
    case invalidModel(String)

    public var description: String {
        switch self {
        case .notInstalled: "시선 CNN 모델이 설치되지 않았습니다(scripts/fetch-gaze-model.sh)."
        case .invalidModel(let reason): "시선 CNN 모델을 쓸 수 없습니다: \(reason)"
        }
    }
}

/// 시선 CNN 찾기·컴파일·캐시.
///
/// 찾는 순서: `GAZE_MODEL_PATH` 환경 변수 → 앱 번들 Resources/GazeEstimator.(mlmodelc|mlpackage)
/// → ~/Library/Application Support/Gaze/Models/GazeEstimator.(mlpackage|mlmodelc).
/// .mlpackage는 `MLModel.compileModel(at:)`로 한 번만 컴파일해 Models/Compiled/에 지문별로 보관한다.
public enum GazeModelStore {
    public static let modelName = "GazeEstimator"

    public static func candidateURLs(bundle: Bundle = .main,
                                     environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        var urls: [URL] = []
        if let path = environment["GAZE_MODEL_PATH"], !path.isEmpty { urls.append(URL(fileURLWithPath: path)) }
        if let resources = bundle.resourceURL {
            urls.append(resources.appendingPathComponent("\(modelName).mlmodelc"))
            urls.append(resources.appendingPathComponent("\(modelName).mlpackage"))
        }
        urls.append(GazeStoragePaths.models.appendingPathComponent("\(modelName).mlpackage"))
        urls.append(GazeStoragePaths.models.appendingPathComponent("\(modelName).mlmodelc"))
        return urls
    }

    public static func locate(bundle: Bundle = .main) -> URL? {
        candidateURLs(bundle: bundle).first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// 패키지 내용 지문(파일 경로·크기·수정 시각). 모델을 바꿔 설치하면 다시 컴파일한다.
    static func fingerprint(of url: URL) -> String {
        var hasher = SHA256()
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        var entries: [String] = []
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) {
            for case let file as URL in enumerator {
                guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                let relative = file.path.replacingOccurrences(of: url.path, with: "")
                entries.append("\(relative)|\(values.fileSize ?? 0)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)")
            }
        }
        for entry in entries.sorted() { hasher.update(data: Data(entry.utf8)) }
        return hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// 컴파일된 .mlmodelc 경로. 캐시에 있으면 재사용한다.
    public static func compiledModel(for source: URL) async throws -> URL {
        if source.pathExtension == "mlmodelc" { return source }
        let cacheDirectory = GazeStoragePaths.compiledModels
        let name = "\(source.deletingPathExtension().lastPathComponent)-\(fingerprint(of: source)).mlmodelc"
        let cached = cacheDirectory.appendingPathComponent(name)
        let fm = FileManager.default
        if fm.fileExists(atPath: cached.path) { return cached }
        let started = Date()
        let temporary = try await MLModel.compileModel(at: source)
        try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        // 같은 모델의 옛 캐시는 지운다.
        let prefix = source.deletingPathExtension().lastPathComponent + "-"
        for stale in (try? fm.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)) ?? []
        where stale.lastPathComponent.hasPrefix(prefix) {
            try? fm.removeItem(at: stale)
        }
        do {
            try fm.moveItem(at: temporary, to: cached)
        } catch {
            if !fm.fileExists(atPath: cached.path) { throw error }
        }
        GazeLog.estimator.info("compiled gaze model in \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s → \(cached.lastPathComponent, privacy: .public)")
        return cached
    }

    public struct Loaded: @unchecked Sendable {
        public let model: MLModel
        public let info: GazeModelInfo
        public let sourceURL: URL
        public let compiledURL: URL
        public let loadSeconds: Double
    }

    public static func load(from source: URL? = nil, computeUnits: MLComputeUnits = .all,
                            bundle: Bundle = .main) async throws -> Loaded {
        guard let source = source ?? locate(bundle: bundle) else {
            throw GazeModelError.notInstalled(candidateURLs(bundle: bundle).map(\.path))
        }
        let started = Date()
        let compiled = try await compiledModel(for: source)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        let model: MLModel
        do {
            model = try await MLModel.load(contentsOf: compiled, configuration: configuration)
        } catch {
            throw GazeModelError.invalidModel("\(error)")
        }
        let description = model.modelDescription
        let metadata = (description.metadata[.creatorDefinedKey] as? [String: String]) ?? [:]
        let info = GazeModelInfo(metadata: metadata, inputNames: Array(description.inputDescriptionsByName.keys),
                                 outputNames: Array(description.outputDescriptionsByName.keys))
        guard description.inputDescriptionsByName[info.inputName]?.type == .image else {
            throw GazeModelError.invalidModel("이미지 입력 '\(info.inputName)'이 없습니다")
        }
        return Loaded(model: model, info: info, sourceURL: source, compiledURL: compiled,
                      loadSeconds: Date().timeIntervalSince(started))
    }
}
