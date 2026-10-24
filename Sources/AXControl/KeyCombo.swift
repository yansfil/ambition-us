import CoreGraphics
import Foundation

public struct KeyModifiers: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let shift = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let control = KeyModifiers(rawValue: 1 << 3)
    public static let function = KeyModifiers(rawValue: 1 << 4)

    public var cgFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if contains(.command) { flags.insert(.maskCommand) }
        if contains(.shift) { flags.insert(.maskShift) }
        if contains(.option) { flags.insert(.maskAlternate) }
        if contains(.control) { flags.insert(.maskControl) }
        if contains(.function) { flags.insert(.maskSecondaryFn) }
        return flags
    }

    /// 수식 키 자체의 가상 키 코드(누르고 떼는 순서 재현용).
    var keyCodes: [CGKeyCode] {
        var codes: [CGKeyCode] = []
        if contains(.command) { codes.append(55) }
        if contains(.shift) { codes.append(56) }
        if contains(.option) { codes.append(58) }
        if contains(.control) { codes.append(59) }
        if contains(.function) { codes.append(63) }
        return codes
    }
}

/// 수식 키 + 키 하나. 미국 ANSI 배열 가상 키 코드를 쓴다.
public struct KeyCombo: Sendable, Equatable, Hashable {
    public let keyCode: CGKeyCode
    public let modifiers: KeyModifiers

    public init(keyCode: CGKeyCode, modifiers: KeyModifiers = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static let returnKey = KeyCombo(keyCode: 36)
    public static let tab = KeyCombo(keyCode: 48)
    public static let escape = KeyCombo(keyCode: 53)
}

/// xdotool 형식(Claude computer use: "ctrl+a", "Return", "Page_Down")과
/// Orca 형식("CmdOrCtrl+Shift+P")을 모두 받는 키 조합 파서.
public enum KeyComboParser {
    static let modifierNames: [String: KeyModifiers] = [
        "cmd": .command, "command": .command, "super": .command, "meta": .command, "win": .command,
        "cmdorctrl": .command, "commandorcontrol": .command,
        "shift": .shift,
        "alt": .option, "option": .option, "opt": .option,
        "ctrl": .control, "control": .control,
        "fn": .function,
    ]

    static let keyCodes: [String: CGKeyCode] = {
        var map: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
            "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
            "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
            "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
            ".": 47, "`": 50,
            "return": 36, "enter": 36, "tab": 48, "space": 49, "backspace": 51, "escape": 53, "esc": 53,
            "delete": 117, "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "prior": 116,
            "pagedown": 121, "next": 121, "left": 123, "right": 124, "down": 125, "up": 126,
            "arrowleft": 123, "arrowright": 124, "arrowdown": 125, "arrowup": 126,
            "help": 114, "insert": 114, "capslock": 57, "kpenter": 76, "kpdecimal": 65, "kpmultiply": 67,
            "kpadd": 69, "kpsubtract": 78, "kpdivide": 75, "kpequal": 81,
            "minus": 27, "equal": 24, "comma": 43, "period": 47, "slash": 44, "backslash": 42, "semicolon": 41,
            "apostrophe": 39, "quote": 39, "grave": 50, "bracketleft": 33, "bracketright": 30,
        ]
        let fKeys: [CGKeyCode] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        for (i, code) in fKeys.enumerated() { map["f\(i + 1)"] = code }
        let keypad: [CGKeyCode] = [82, 83, 84, 85, 86, 87, 88, 89, 91, 92]
        for (i, code) in keypad.enumerated() { map["kp\(i)"] = code }
        return map
    }()

    /// 쉬프트가 필요한 이름(xdotool "plus" 등).
    static let shiftedNames: [String: CGKeyCode] = ["plus": 24, "underscore": 27, "question": 44, "exclam": 18, "at": 19]

    /// "cmd+shift+p" → KeyCombo. 알 수 없는 이름이면 nil.
    public static func parse(_ text: String) -> KeyCombo? {
        let parts = text.split(separator: "+", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        // "ctrl++"처럼 '+' 자체를 누르는 경우.
        var tokens = parts
        if text.hasSuffix("++") || text == "+" {
            tokens = Array(parts.dropLast(2)) + ["plus"]
        }
        guard let keyName = tokens.last, !keyName.isEmpty else { return nil }
        var modifiers: KeyModifiers = []
        for name in tokens.dropLast() {
            guard let modifier = modifierNames[normalize(name)] else { return nil }
            modifiers.insert(modifier)
        }
        let key = normalize(keyName)
        if let code = keyCodes[key] { return KeyCombo(keyCode: code, modifiers: modifiers) }
        if let code = shiftedNames[key] { return KeyCombo(keyCode: code, modifiers: modifiers.union(.shift)) }
        if keyName.count == 1, let code = keyCodes[keyName.lowercased()] {
            return KeyCombo(keyCode: code, modifiers: modifiers)
        }
        // 수식 키만 누르는 경우("shift").
        if tokens.count == 1, let modifier = modifierNames[key], let code = modifier.keyCodes.first {
            return KeyCombo(keyCode: code, modifiers: [])
        }
        return nil
    }

    /// 공백으로 구분한 여러 조합("ctrl+a Delete").
    public static func parseSequence(_ text: String) -> [KeyCombo]? {
        let items = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !items.isEmpty else { return nil }
        var combos: [KeyCombo] = []
        for item in items {
            guard let combo = parse(item) else { return nil }
            combos.append(combo)
        }
        return combos
    }

    static func normalize(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
    }
}

/// 합성 타이핑 단위. 줄바꿈·탭은 유니코드 이벤트로 잘 안 들어가는 앱이 많아 실제 키로 보낸다.
public enum TypingSegment: Sendable, Equatable {
    case text(String)
    case key(KeyCombo)

    /// CGEvent 유니코드 문자열 한도(UTF-16 20단위)에 맞춰 나눈다. 문자(grapheme)는 쪼개지 않는다.
    public static func segments(for text: String, maxUTF16PerChunk: Int = 20) -> [TypingSegment] {
        var result: [TypingSegment] = []
        var chunk = ""
        var chunkUnits = 0
        func flush() {
            if !chunk.isEmpty { result.append(.text(chunk)) }
            chunk = ""
            chunkUnits = 0
        }
        for character in text {
            switch character {
            case "\n", "\r", "\r\n":
                flush(); result.append(.key(.returnKey))
            case "\t":
                flush(); result.append(.key(.tab))
            default:
                let units = character.utf16.count
                if chunkUnits + units > maxUTF16PerChunk { flush() }
                chunk.append(character)
                chunkUnits += units
            }
        }
        flush()
        return result
    }
}
