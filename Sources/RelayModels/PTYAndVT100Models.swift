import Foundation

// MARK: - VT100 / xterm-256color / TrueColor Screen Buffer Primitives

public enum TerminalColor: Sendable, Codable, Hashable {
    case defaultForeground
    case defaultBackground
    case ansi16(UInt8)
    case palette256(UInt8)
    case trueColor(r: UInt8, g: UInt8, b: UInt8)
}

public struct TerminalCellAttributes: OptionSet, Sendable, Codable, Hashable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let bold          = TerminalCellAttributes(rawValue: 1 << 0)
    public static let dim           = TerminalCellAttributes(rawValue: 1 << 1)
    public static let italic        = TerminalCellAttributes(rawValue: 1 << 2)
    public static let underline     = TerminalCellAttributes(rawValue: 1 << 3)
    public static let blink         = TerminalCellAttributes(rawValue: 1 << 4)
    public static let inverse       = TerminalCellAttributes(rawValue: 1 << 5)
    public static let hidden        = TerminalCellAttributes(rawValue: 1 << 6)
    public static let strikethrough = TerminalCellAttributes(rawValue: 1 << 7)
}

public struct TerminalCell: Sendable, Codable, Hashable {
    public var grapheme: String
    public var foreground: TerminalColor
    public var background: TerminalColor
    public var attributes: TerminalCellAttributes
    public var columnSpan: UInt8

    public init(
        character: Character = " ",
        foreground: TerminalColor = .defaultForeground,
        background: TerminalColor = .defaultBackground,
        attributes: TerminalCellAttributes = [],
        columnSpan: UInt8 = 1
    ) {
        self.grapheme = String(character)
        self.foreground = foreground
        self.background = background
        self.attributes = attributes
        self.columnSpan = columnSpan
    }

    public init(
        grapheme: String,
        foreground: TerminalColor = .defaultForeground,
        background: TerminalColor = .defaultBackground,
        attributes: TerminalCellAttributes = [],
        columnSpan: UInt8 = 1
    ) {
        self.grapheme = grapheme.isEmpty ? " " : grapheme
        self.foreground = foreground
        self.background = background
        self.attributes = attributes
        self.columnSpan = columnSpan
    }

    public var character: Character {
        grapheme.first ?? " "
    }

    public static let blank = TerminalCell()
}

public enum TerminalCursorShape: String, Sendable, Codable, Hashable {
    case block
    case underline
    case bar
}

public struct TerminalCursorState: Sendable, Codable, Hashable {
    public var row: Int
    public var column: Int
    public var isVisible: Bool
    public var shape: TerminalCursorShape

    public init(
        row: Int = 0,
        column: Int = 0,
        isVisible: Bool = true,
        shape: TerminalCursorShape = .block
    ) {
        self.row = row
        self.column = column
        self.isVisible = isVisible
        self.shape = shape
    }
}

public struct TerminalViewportSnapshot: Sendable, Codable, Hashable {
    public let laneID: String
    public let rows: Int
    public let columns: Int
    public let visibleGrid: [[TerminalCell]]
    public let scrollbackLineCount: Int
    public let cursor: TerminalCursorState
    public let windowTitle: String
    public let isAlternateScreen: Bool
    public let bracketedPasteEnabled: Bool

    public init(
        laneID: String,
        rows: Int,
        columns: Int,
        visibleGrid: [[TerminalCell]],
        scrollbackLineCount: Int,
        cursor: TerminalCursorState,
        windowTitle: String = "",
        isAlternateScreen: Bool = false,
        bracketedPasteEnabled: Bool = false
    ) {
        self.laneID = laneID
        self.rows = rows
        self.columns = columns
        self.visibleGrid = visibleGrid
        self.scrollbackLineCount = scrollbackLineCount
        self.cursor = cursor
        self.windowTitle = windowTitle
        self.isAlternateScreen = isAlternateScreen
        self.bracketedPasteEnabled = bracketedPasteEnabled
    }

    public var plainTextLines: [String] {
        visibleGrid.map { row in
            String(row.map(\.character)).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }
    }
}

public enum PTYExitReason: Sendable, Codable, Hashable, Equatable {
    case exited(code: Int32)
    case signaled(signal: Int32)
    case waitFailed(errnoCode: Int32)

    public var exitCode: Int32? {
        if case .exited(let code) = self { return code }
        return nil
    }

    public var terminationSignal: Int32? {
        if case .signaled(let sig) = self { return sig }
        return nil
    }

    public func localizedDescription(in language: RelayLanguage) -> String {
        switch self {
        case .exited(let code):
            return language.isChinese ? "退出码 \(code)" : "exited with code \(code)"
        case .signaled(let sig):
            return language.isChinese ? "被信号 \(sig) 终止" : "terminated by signal \(sig)"
        case .waitFailed(let err):
            return language.isChinese ? "等待子进程失败（errno \(err)）" : "waitpid failed (errno \(err))"
        }
    }
}

public struct PTYProcessMetrics: Sendable, Codable, Hashable {
    public let laneID: String
    public let pid: Int32
    public let masterFD: Int32
    public let isRunning: Bool
    public let exitStatus: Int32?
    public let terminationSignal: Int32?
    public let exitReason: PTYExitReason?
    public let terminationDescription: String?
    public let bytesReadFromPTY: UInt64
    public let bytesWrittenToPTY: UInt64
    public let startedAt: Date

    public init(
        laneID: String,
        pid: Int32,
        masterFD: Int32,
        isRunning: Bool,
        exitStatus: Int32? = nil,
        terminationSignal: Int32? = nil,
        exitReason: PTYExitReason? = nil,
        terminationDescription: String? = nil,
        bytesReadFromPTY: UInt64 = 0,
        bytesWrittenToPTY: UInt64 = 0,
        startedAt: Date = Date()
    ) {
        self.laneID = laneID
        self.pid = pid
        self.masterFD = masterFD
        self.isRunning = isRunning
        self.exitStatus = exitStatus
        self.terminationSignal = terminationSignal
        self.exitReason = exitReason
        self.terminationDescription = terminationDescription
        self.bytesReadFromPTY = bytesReadFromPTY
        self.bytesWrittenToPTY = bytesWrittenToPTY
        self.startedAt = startedAt
    }
}
