import Foundation

/// 시선 진단 스냅샷(~/Library/Application Support/Gaze/gaze-diagnostics.json). 사용자 실측 결과를 확인하는 용도.
public struct GazeDiagnostics: Sendable, Codable, Equatable {
    public struct Estimator: Sendable, Codable, Equatable {
        public var kind: String
        public var identifier: String
        public var modelArch: String?
        public var modelSource: String?
        public var testTimeFlip: Bool?
        public var cropWidthScale: Double?
        public var cropHeightScale: Double?
        public var cropVerticalOffset: Double?
        public var modelPath: String?
        public var compiledPath: String?
        public var loadSeconds: Double?
        public var fallbackReason: String?
    }

    public struct Camera: Sendable, Codable, Equatable {
        public var width: Int
        public var height: Int
        public var frameRate: Double
        public var pixelFormat: String
    }

    public struct Timing: Sendable, Codable, Equatable {
        public var framesProcessed: Int
        public var framesWithFace: Int
        public var framesWithFeatures: Int
        public var visionMedianMs: Double?
        public var visionP95Ms: Double?
        public var estimatorMedianMs: Double?
        public var estimatorP95Ms: Double?
        public var cnnMedianMs: Double?
        public var cnnP95Ms: Double?
        public var frameMedianMs: Double?
        public var frameP95Ms: Double?
        /// 30fps 프레임 예산.
        public var budgetMs: Double
    }

    public struct Calibration: Sendable, Codable, Equatable {
        public var displayID: UInt32
        public var revision: Int
        public var estimatorID: String
        public var structure: String
        public var lambda: Double
        public var crossValidatedRMSEPoints: Double
        public var crossValidatedRMSECm: Double?
        public var trainingRMSEPoints: Double
        public var validationMeanPoints: Double?
        public var validationMeanCm: Double?
        public var validationRMSEPoints: Double?
        public var validationMaxPoints: Double?
        public var targets: Int
        public var samples: Int
        public var implicitSamples: Int
        public var structureScores: [String: Double]

        public init(_ model: CalibrationModel) {
            let ppcm = model.display.pointsPerCentimeter
            displayID = model.display.id
            revision = model.revision
            estimatorID = model.estimatorID
            structure = "\(model.kind.rawValue)+\(model.auxiliaryTerms.rawValue)"
            lambda = model.lambda
            crossValidatedRMSEPoints = model.crossValidatedRMSE
            crossValidatedRMSECm = ppcm.map { model.crossValidatedRMSE / $0 }
            trainingRMSEPoints = model.trainingRMSE
            validationMeanPoints = model.validation?.meanError
            validationMeanCm = model.validation?.meanErrorCm
            validationRMSEPoints = model.validation?.rmse
            validationMaxPoints = model.validation?.maxError
            targets = model.targetCount
            samples = model.sampleCount
            implicitSamples = model.implicitCount
            structureScores = Dictionary(model.structureScores.map {
                ("\($0.structure.kind.rawValue)+\($0.structure.auxiliary.rawValue)@λ\($0.lambda)", $0.crossValidatedRMSE)
            }, uniquingKeysWith: { a, _ in a })
        }
    }

    public var updatedAt: Date
    public var estimator: Estimator
    public var camera: Camera?
    public var timing: Timing
    public var calibrations: [Calibration]
    public var implicit: ImplicitCalibrationStats

    public func write(to url: URL = GazeStoragePaths.diagnostics) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
