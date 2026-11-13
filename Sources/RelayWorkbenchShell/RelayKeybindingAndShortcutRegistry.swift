import AppKit
import Foundation
import RelayModels
import RelayPluginSDK
import RelayWorkspaceStore
import SwiftUI

// MARK: - Key Modifiers, Key Equivalent Tokens & Chord Representation

public struct RelayKeyModifiers: OptionSet, Sendable, Codable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let control = RelayKeyModifiers(rawValue: 1 << 0)
    public static let option  = RelayKeyModifiers(rawValue: 1 << 1)
    public static let shift   = RelayKeyModifiers(rawValue: 1 << 2)
    public static let command = RelayKeyModifiers(rawValue: 1 << 3)

    public init(nsEventFlags: NSEvent.ModifierFlags) {
        let deviceIndependent = nsEventFlags.intersection(.deviceIndependentFlagsMask)
        var resolved: RelayKeyModifiers = []
        if deviceIndependent.contains(.control) { resolved.insert(.control) }
        if deviceIndependent.contains(.option)  { resolved.insert(.option) }
        if deviceIndependent.contains(.shift)   { resolved.insert(.shift) }
        if deviceIndependent.contains(.command) { resolved.insert(.command) }
        self = resolved
    }

    /// Standard Apple Human Interface Guidelines modifier glyph ordering (`⌃⌥⇧⌘`).
    public var glyphString: String {
        var out = ""
        if contains(.control) { out.append("⌃") }
        if contains(.option)  { out.append("⌥") }
        if contains(.shift)   { out.append("⇧") }
        if contains(.command) { out.append("⌘") }
        return out
    }

    public var portableNames: [String] {
        var names: [String] = []
        if contains(.control) { names.append("ctrl") }
        if contains(.option)  { names.append("opt") }
        if contains(.shift)   { names.append("shift") }
        if contains(.command) { names.append("cmd") }
        return names
    }

    public var swiftUIEventModifiers: SwiftUI.EventModifiers {
        var mods: SwiftUI.EventModifiers = []
        if contains(.control) { mods.insert(.control) }
        if contains(.option)  { mods.insert(.option) }
        if contains(.shift)   { mods.insert(.shift) }
        if contains(.command) { mods.insert(.command) }
        return mods
    }
}

public struct RelayKeyEquivalentToken: Sendable, Codable, Hashable, CustomStringConvertible {
    /// Normalized lowercase token (`"1"`, `"k"`, `"return"`, `"escape"`, `"up"`, etc.).
    public let canonicalKey: String

    public init(key rawKey: String) {
        self.canonicalKey = Self.normalize(rawKey)
    }

    public init?(nsEvent: NSEvent) {
        switch nsEvent.keyCode {
        case 36, 76:
            self.canonicalKey = "return"
            return
        case 48:
            self.canonicalKey = "tab"
            return
        case 49:
            self.canonicalKey = "space"
            return
        case 51:
            self.canonicalKey = "delete"
            return
        case 53:
            self.canonicalKey = "escape"
            return
        case 123:
            self.canonicalKey = "left"
            return
        case 124:
            self.canonicalKey = "right"
            return
        case 125:
            self.canonicalKey = "down"
            return
        case 126:
            self.canonicalKey = "up"
            return
        default:
            break
        }

        guard let chars = nsEvent.charactersIgnoringModifiers,
              !chars.isEmpty else {
            return nil
        }
        let normalized = Self.normalize(chars)
        guard !normalized.isEmpty else { return nil }
        self.canonicalKey = normalized
    }

    public var glyphBadge: String {
        switch canonicalKey {
        case "return": return "⏎"
        case "escape": return "⎋"
        case "tab":    return "⇥"
        case "space":  return "␣"
        case "delete": return "⌫"
        case "up":     return "↑"
        case "down":   return "↓"
        case "left":   return "←"
        case "right":  return "→"
        default:
            return canonicalKey.uppercased()
        }
    }

    public var description: String { glyphBadge }

    public var swiftUIKeyEquivalent: SwiftUI.KeyEquivalent? {
        switch canonicalKey {
        case "return": return .return
        case "escape": return .escape
        case "tab":    return .tab
        case "space":  return .space
        case "delete": return .delete
        case "up":     return .upArrow
        case "down":   return .downArrow
        case "left":   return .leftArrow
        case "right":  return .rightArrow
        default:
            guard canonicalKey.count == 1, let ch = canonicalKey.first else {
                return nil
            }
            return SwiftUI.KeyEquivalent(ch)
        }
    }

    public static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch trimmed {
        case "⏎", "↩", "enter", "return", "\r", "\n":
            return "return"
        case "⎋", "esc", "escape", "\u{1B}":
            return "escape"
        case "⇥", "tab", "\t":
            return "tab"
        case "␣", "space", " ":
            return "space"
        case "⌫", "backspace", "delete", "\u{7F}":
            return "delete"
        case "↑", "uparrow", "up":
            return "up"
        case "↓", "downarrow", "down":
            return "down"
        case "←", "leftarrow", "left":
            return "left"
        case "→", "rightarrow", "right":
            return "right"
        default:
            // Map shifted US number row symbols back to canonical digits so ⌘⇧1 normalizes reliably
            switch trimmed {
            case "!": return "1"
            case "@": return "2"
            case "#": return "3"
            case "$": return "4"
            case "%": return "5"
            case "^": return "6"
            case "&": return "7"
            case "*": return "8"
            case "(": return "9"
            case ")": return "0"
            default:  return trimmed
            }
        }
    }
}

public struct RelayKeyStroke: Sendable, Codable, Hashable, CustomStringConvertible {
    public let modifiers: RelayKeyModifiers
    public let key: RelayKeyEquivalentToken

    public init(modifiers: RelayKeyModifiers, key: RelayKeyEquivalentToken) {
        self.modifiers = modifiers
        self.key = key
    }

    public init(modifiers: RelayKeyModifiers, key: String) {
        self.modifiers = modifiers
        self.key = RelayKeyEquivalentToken(key: key)
    }

    public var glyphBadge: String {
        "\(modifiers.glyphString)\(key.glyphBadge)"
    }

    public var portableSpec: String {
        let parts = modifiers.portableNames + [key.canonicalKey]
        return parts.joined(separator: "+")
    }

    public var description: String { glyphBadge }

    public var swiftUIKeyboardShortcut: SwiftUI.KeyboardShortcut? {
        guard let keyEq = key.swiftUIKeyEquivalent else { return nil }
        return SwiftUI.KeyboardShortcut(keyEq, modifiers: modifiers.swiftUIEventModifiers)
    }

    public func matches(nsEvent: NSEvent) -> Bool {
        let eventMods = RelayKeyModifiers(nsEventFlags: nsEvent.modifierFlags)
        guard eventMods == modifiers,
              let eventToken = RelayKeyEquivalentToken(nsEvent: nsEvent) else {
            return false
        }
        return eventToken == key
    }

    /// Parses either macOS glyph notation (`"⌘⇧M"`, `"⌃⌥⌘1"`) or portable plus-separated specs (`"cmd+shift+m"`).
    public static func parse(_ rawSpec: String) -> RelayKeyStroke? {
        let trimmed = rawSpec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.contains("+") {
            let tokens = trimmed
                .split(separator: "+", omittingEmptySubsequences: true)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            guard let lastToken = tokens.last else { return nil }
            var mods: RelayKeyModifiers = []
            for modToken in tokens.dropLast() {
                switch modToken {
                case "cmd", "command", "meta", "super", "⌘":
                    mods.insert(.command)
                case "shift", "⇧":
                    mods.insert(.shift)
                case "opt", "option", "alt", "⌥":
                    mods.insert(.option)
                case "ctrl", "control", "⌃":
                    mods.insert(.control)
                default:
                    return nil
                }
            }
            let keyToken = RelayKeyEquivalentToken(key: lastToken)
            guard !keyToken.canonicalKey.isEmpty else { return nil }
            return RelayKeyStroke(modifiers: mods, key: keyToken)
        }

        var mods: RelayKeyModifiers = []
        var remainder = ""
        for ch in trimmed {
            switch ch {
            case "⌘": mods.insert(.command)
            case "⇧": mods.insert(.shift)
            case "⌥": mods.insert(.option)
            case "⌃": mods.insert(.control)
            default:  remainder.append(ch)
            }
        }
        let keyToken = RelayKeyEquivalentToken(key: remainder)
        guard !keyToken.canonicalKey.isEmpty else { return nil }
        return RelayKeyStroke(modifiers: mods, key: keyToken)
    }
}

public struct RelayKeyChord: Sendable, Codable, Hashable, CustomStringConvertible {
    public let strokes: [RelayKeyStroke]

    public init(strokes: [RelayKeyStroke]) {
        precondition(!strokes.isEmpty, "RelayKeyChord requires at least one RelayKeyStroke")
        self.strokes = Array(strokes.prefix(3))
    }

    public static func single(_ modifiers: RelayKeyModifiers, _ key: String) -> RelayKeyChord {
        RelayKeyChord(strokes: [RelayKeyStroke(modifiers: modifiers, key: key)])
    }

    public static func sequence(_ first: RelayKeyStroke, _ second: RelayKeyStroke) -> RelayKeyChord {
        RelayKeyChord(strokes: [first, second])
    }

    /// Parses single-stroke (`"⌘K"`, `"cmd+shift+m"`) or multi-stroke whitespace-separated chords (`"⌃G ⌃E"`).
    public static func parse(_ rawChord: String) -> RelayKeyChord? {
        let components = rawChord
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !components.isEmpty else { return nil }
        var parsedStrokes: [RelayKeyStroke] = []
        parsedStrokes.reserveCapacity(components.count)
        for comp in components {
            guard let stroke = RelayKeyStroke.parse(comp) else { return nil }
            parsedStrokes.append(stroke)
        }
        return RelayKeyChord(strokes: parsedStrokes)
    }

    public var firstStroke: RelayKeyStroke { strokes[0] }
    public var isMultiStroke: Bool { strokes.count > 1 }

    public var glyphBadge: String {
        strokes.map(\.glyphBadge).joined(separator: " ")
    }

    public var portableSpec: String {
        strokes.map(\.portableSpec).joined(separator: " ")
    }

    public var description: String { glyphBadge }

    /// Returns `true` when `self` is a strict leading prefix of `other` (e.g. `⌃G` shadows `⌃G ⌃E`).
    public func isStrictPrefix(of other: RelayKeyChord) -> Bool {
        guard strokes.count < other.strokes.count else { return false }
        for idx in strokes.indices where strokes[idx] != other.strokes[idx] {
            return false
        }
        return true
    }
}

// MARK: - Shortcut Context Scopes, Bindings & Conflict Diagnostics

public enum RelayShortcutContextScope: String, Sendable, Codable, Hashable, CaseIterable, Identifiable {
    case globalWorkbench        = "Global Workbench"
    case ptyGridFocused         = "2×2 PTY Grid"
    case dagStudioFocused       = "Relay DAG Pipeline"
    case mergeStudioFocused     = "3-Way Semantic Merge"
    case territoryMapFocused    = "2.5D Territory Map"
    case wiretapStudioFocused   = "Wiretap & Budget"
    case guardrailStudioFocused = "Guardrail Plugins"
    case commandPaletteModal    = "Command Palette Modal"

    public var id: String { rawValue }

    public static func scope(for pane: RelayStudioPane) -> RelayShortcutContextScope {
        switch pane {
        case .ptyGrid:          return .ptyGridFocused
        case .dagPipeline:      return .dagStudioFocused
        case .semanticMerge:    return .mergeStudioFocused
        case .territoryMap:     return .territoryMapFocused
        case .wiretapBudget:    return .wiretapStudioFocused
        case .guardrailPlugins: return .guardrailStudioFocused
        }
    }

    /// Determines whether two shortcut scopes can ever be active at the same moment.
    public func overlaps(with other: RelayShortcutContextScope) -> Bool {
        if self == other { return true }
        if self == .commandPaletteModal || other == .commandPaletteModal {
            // Only global palette toggle or modal-scoped bindings apply while palette modal is open
            return false
        }
        if self == .globalWorkbench || other == .globalWorkbench {
            return true
        }
        return false
    }
}

public struct RelayShortcutBinding: Sendable, Codable, Hashable, Identifiable {
    public var id: String { commandID }
    public let commandID: String
    public let title: String
    public let subtitle: String
    public let category: PaletteCommandCategory
    public let scope: RelayShortcutContextScope
    public let defaultChord: RelayKeyChord
    public var activeChord: RelayKeyChord
    public var isEnabled: Bool

    public init(
        commandID: String,
        title: String,
        subtitle: String,
        category: PaletteCommandCategory,
        scope: RelayShortcutContextScope = .globalWorkbench,
        defaultChord: RelayKeyChord,
        activeChord: RelayKeyChord? = nil,
        isEnabled: Bool = true
    ) {
        self.commandID = commandID
        self.title = title
        self.subtitle = subtitle
        self.category = category
        self.scope = scope
        self.defaultChord = defaultChord
        self.activeChord = activeChord ?? defaultChord
        self.isEnabled = isEnabled
    }

    public var isUserCustomized: Bool {
        activeChord != defaultChord
    }

    public var glyphBadge: String {
        activeChord.glyphBadge
    }
}

public enum RelayShortcutConflictKind: String, Sendable, Codable, Hashable {
    case identicalChordCollision       = "IDENTICAL_CHORD_COLLISION"
    case chordPrefixShadowing          = "CHORD_PREFIX_SHADOWING"
    case reservedSystemShortcutWarning = "RESERVED_MACOS_SHORTCUT"
}

public struct RelayShortcutConflict: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let kind: RelayShortcutConflictKind
    public let primaryCommandID: String
    public let secondaryCommandID: String?
    public let conflictingChordBadge: String
    public let effectiveScope: RelayShortcutContextScope
    public let explanation: String

    public init(
        kind: RelayShortcutConflictKind,
        primaryCommandID: String,
        secondaryCommandID: String?,
        conflictingChordBadge: String,
        effectiveScope: RelayShortcutContextScope,
        explanation: String
    ) {
        let pairKey = [primaryCommandID, secondaryCommandID ?? "macos.system"].sorted().joined(separator: "::")
        self.id = "\(kind.rawValue)::\(pairKey)::\(conflictingChordBadge)"
        self.kind = kind
        self.primaryCommandID = primaryCommandID
        self.secondaryCommandID = secondaryCommandID
        self.conflictingChordBadge = conflictingChordBadge
        self.effectiveScope = effectiveScope
        self.explanation = explanation
    }

    public var isBlockingError: Bool {
        switch kind {
        case .identicalChordCollision, .chordPrefixShadowing:
            return true
        case .reservedSystemShortcutWarning:
            return false
        }
    }
}

public enum RelayShortcutRebindError: Error, LocalizedError, Sendable, Equatable {
    case unknownCommandID(String)
    case invalidChordSpecification(String)
    case conflictsDetected([RelayShortcutConflict])

    public var errorDescription: String? {
        switch self {
        case .unknownCommandID(let id):
            return "Unknown shortcut command identifier '\(id)'."
        case .invalidChordSpecification(let raw):
            return "Invalid keybinding chord specification '\(raw)'."
        case .conflictsDetected(let conflicts):
            let summary = conflicts.map(\.explanation).joined(separator: " ")
            return "Keybinding conflict prevented assignment: \(summary)"
        }
    }
}

public enum RelayChordDispatchOutcome: Sendable, Equatable {
    case unmatched
    case awaitingNextStroke(prefixBadge: String, candidateCommandIDs: [String])
    case dispatched(commandID: String, chordBadge: String)
}

// MARK: - Serializable Keymap Override Document

public struct RelayKeymapProfileDocument: Sendable, Codable, Hashable {
    public struct OverrideEntry: Sendable, Codable, Hashable {
        public let commandID: String
        public let portableChord: String
        public let glyphBadge: String
        public let isEnabled: Bool

        public init(commandID: String, portableChord: String, glyphBadge: String, isEnabled: Bool) {
            self.commandID = commandID
            self.portableChord = portableChord
            self.glyphBadge = glyphBadge
            self.isEnabled = isEnabled
        }
    }

    public let schemaVersion: Int
    public let profileName: String
    public let exportedAt: Date
    public let overrides: [OverrideEntry]

    public init(
        schemaVersion: Int = 1,
        profileName: String = "RelayIDE Bauhaus Keymap",
        exportedAt: Date = Date(),
        overrides: [OverrideEntry]
    ) {
        self.schemaVersion = schemaVersion
        self.profileName = profileName
        self.exportedAt = exportedAt
        self.overrides = overrides
    }
}

// MARK: - Customizable Chorded Shortcut Registry & Conflict Detector

@MainActor
public final class RelayKeybindingAndShortcutRegistry: ObservableObject {
    public static let defaultUserDefaultsKey = "io.relayide.workbench.keymap.v1"

    @Published public private(set) var bindings: [RelayShortcutBinding]
    @Published public private(set) var activeConflicts: [RelayShortcutConflict] = []
    @Published public private(set) var pendingChordPrefix: [RelayKeyStroke] = []
    @Published public private(set) var pendingChordStatusText: String?

    public var chordTimeoutSeconds: Double = 1.6
    public var onShortcutTriggered: ((RelayShortcutBinding) -> Void)?

    private let userDefaults: UserDefaults
    private let storageKey: String
    private var chordTimeoutTask: Task<Void, Never>?

    public init(
        initialBindings: [RelayShortcutBinding] = RelayKeybindingAndShortcutRegistry.defaultBindings,
        userDefaults: UserDefaults = .standard,
        storageKey: String = RelayKeybindingAndShortcutRegistry.defaultUserDefaultsKey,
        loadPersistedOverrides: Bool = true
    ) {
        self.bindings = initialBindings
        self.userDefaults = userDefaults
        self.storageKey = storageKey

        if loadPersistedOverrides,
           let persistedData = userDefaults.data(forKey: storageKey) {
            try? applyKeymapDataWithoutPersisting(persistedData)
        }
        self.activeConflicts = detectConflicts(in: self.bindings)
    }

    // MARK: Lookup & SwiftUI Shortcut Query

    public func binding(for commandID: String) -> RelayShortcutBinding? {
        bindings.first { $0.commandID == commandID }
    }

    public func shortcutBadge(for commandID: String) -> String? {
        binding(for: commandID)?.glyphBadge
    }

    /// Returns a SwiftUI `KeyboardShortcut` when the command uses a single-stroke enabled binding.
    public func swiftUIShortcut(for commandID: String) -> SwiftUI.KeyboardShortcut? {
        guard let item = binding(for: commandID),
              item.isEnabled,
              !item.activeChord.isMultiStroke else {
            return nil
        }
        return item.activeChord.firstStroke.swiftUIKeyboardShortcut
    }

    public func badgeDictionary() -> [String: String] {
        var dict: [String: String] = [:]
        dict.reserveCapacity(bindings.count)
        for item in bindings where item.isEnabled {
            dict[item.commandID] = item.glyphBadge
        }
        return dict
    }

    public func syncBadges(into palette: RelayCommandPaletteController) {
        palette.synchronizeShortcutBadges(from: badgeDictionary())
    }

    // MARK: Conflict Detection Engine

    /// Evaluates identical-chord collisions, single-vs-multi-stroke prefix shadowing, and macOS reserved shortcuts.
    public func detectConflicts(in candidateBindings: [RelayShortcutBinding]? = nil) -> [RelayShortcutConflict] {
        let list = (candidateBindings ?? bindings).filter(\.isEnabled)
        var detected: [RelayShortcutConflict] = []
        var seenIDs = Set<String>()

        let reservedMacOSBadges: [RelayKeyStroke: String] = [
            RelayKeyStroke(modifiers: [.command], key: "q"): "macOS Quit Application (⌘Q)",
            RelayKeyStroke(modifiers: [.command], key: "h"): "macOS Hide Window (⌘H)",
            RelayKeyStroke(modifiers: [.command], key: "m"): "macOS Minimize Window (⌘M)"
        ]

        for idx in list.indices {
            let lhs = list[idx]

            // Check reserved single-stroke system shortcuts
            if !lhs.activeChord.isMultiStroke,
               let systemLabel = reservedMacOSBadges[lhs.activeChord.firstStroke] {
                let conflict = RelayShortcutConflict(
                    kind: .reservedSystemShortcutWarning,
                    primaryCommandID: lhs.commandID,
                    secondaryCommandID: nil,
                    conflictingChordBadge: lhs.glyphBadge,
                    effectiveScope: lhs.scope,
                    explanation: "'\(lhs.title)' uses \(lhs.glyphBadge), which intercepts \(systemLabel)."
                )
                if seenIDs.insert(conflict.id).inserted {
                    detected.append(conflict)
                }
            }

            guard idx + 1 < list.count else { continue }
            for jdx in (idx + 1)..<list.count {
                let rhs = list[jdx]
                guard lhs.scope.overlaps(with: rhs.scope) else { continue }
                let specificScope = lhs.scope == .globalWorkbench ? rhs.scope : lhs.scope

                if lhs.activeChord == rhs.activeChord {
                    let conflict = RelayShortcutConflict(
                        kind: .identicalChordCollision,
                        primaryCommandID: lhs.commandID,
                        secondaryCommandID: rhs.commandID,
                        conflictingChordBadge: lhs.glyphBadge,
                        effectiveScope: specificScope,
                        explanation: "'\(lhs.title)' and '\(rhs.title)' both bind \(lhs.glyphBadge) in overlapping scope '\(specificScope.rawValue)'."
                    )
                    if seenIDs.insert(conflict.id).inserted {
                        detected.append(conflict)
                    }
                } else if lhs.activeChord.isStrictPrefix(of: rhs.activeChord) {
                    let conflict = RelayShortcutConflict(
                        kind: .chordPrefixShadowing,
                        primaryCommandID: lhs.commandID,
                        secondaryCommandID: rhs.commandID,
                        conflictingChordBadge: lhs.glyphBadge,
                        effectiveScope: specificScope,
                        explanation: "Single-stroke '\(lhs.title)' (\(lhs.glyphBadge)) shadows multi-stroke chord '\(rhs.title)' (\(rhs.glyphBadge))."
                    )
                    if seenIDs.insert(conflict.id).inserted {
                        detected.append(conflict)
                    }
                } else if rhs.activeChord.isStrictPrefix(of: lhs.activeChord) {
                    let conflict = RelayShortcutConflict(
                        kind: .chordPrefixShadowing,
                        primaryCommandID: rhs.commandID,
                        secondaryCommandID: lhs.commandID,
                        conflictingChordBadge: rhs.glyphBadge,
                        effectiveScope: specificScope,
                        explanation: "Single-stroke '\(rhs.title)' (\(rhs.glyphBadge)) shadows multi-stroke chord '\(lhs.title)' (\(lhs.glyphBadge))."
                    )
                    if seenIDs.insert(conflict.id).inserted {
                        detected.append(conflict)
                    }
                }
            }
        }

        return detected
    }

    public func previewConflicts(
        ifRebinding commandID: String,
        to proposedChord: RelayKeyChord
    ) -> [RelayShortcutConflict] {
        var simulated = bindings
        guard let idx = simulated.firstIndex(where: { $0.commandID == commandID }) else {
            return []
        }
        simulated[idx].activeChord = proposedChord
        simulated[idx].isEnabled = true
        return detectConflicts(in: simulated).filter {
            $0.primaryCommandID == commandID || $0.secondaryCommandID == commandID
        }
    }

    // MARK: Customization & Rebinding

    @discardableResult
    public func rebind(
        commandID: String,
        toSpec rawChordSpec: String,
        allowConflictingOverride: Bool = false
    ) -> Result<RelayShortcutBinding, RelayShortcutRebindError> {
        guard let parsed = RelayKeyChord.parse(rawChordSpec) else {
            return .failure(.invalidChordSpecification(rawChordSpec))
        }
        return rebind(commandID: commandID, to: parsed, allowConflictingOverride: allowConflictingOverride)
    }

    @discardableResult
    public func rebind(
        commandID: String,
        to newChord: RelayKeyChord,
        allowConflictingOverride: Bool = false
    ) -> Result<RelayShortcutBinding, RelayShortcutRebindError> {
        guard let targetIdx = bindings.firstIndex(where: { $0.commandID == commandID }) else {
            return .failure(.unknownCommandID(commandID))
        }

        let candidateConflicts = previewConflicts(ifRebinding: commandID, to: newChord)
        let blocking = candidateConflicts.filter(\.isBlockingError)
        if !blocking.isEmpty && !allowConflictingOverride {
            return .failure(.conflictsDetected(blocking))
        }

        if allowConflictingOverride && !blocking.isEmpty {
            // Automatically disable shadowed/colliding peer bindings when user explicitly forces override
            let peerIDs = Set(blocking.compactMap { conflict -> String? in
                if conflict.primaryCommandID == commandID { return conflict.secondaryCommandID }
                return conflict.primaryCommandID
            })
            for idx in bindings.indices where peerIDs.contains(bindings[idx].commandID) {
                bindings[idx].isEnabled = false
            }
        }

        bindings[targetIdx].activeChord = newChord
        bindings[targetIdx].isEnabled = true
        activeConflicts = detectConflicts(in: bindings)
        persistOverrides()
        return .success(bindings[targetIdx])
    }

    public func setBindingEnabled(commandID: String, isEnabled: Bool) {
        guard let idx = bindings.firstIndex(where: { $0.commandID == commandID }) else { return }
        bindings[idx].isEnabled = isEnabled
        activeConflicts = detectConflicts(in: bindings)
        persistOverrides()
    }

    public func resetBinding(commandID: String) {
        guard let idx = bindings.firstIndex(where: { $0.commandID == commandID }) else { return }
        bindings[idx].activeChord = bindings[idx].defaultChord
        bindings[idx].isEnabled = true
        activeConflicts = detectConflicts(in: bindings)
        persistOverrides()
    }

    public func resetAllToDefaults() {
        for idx in bindings.indices {
            bindings[idx].activeChord = bindings[idx].defaultChord
            bindings[idx].isEnabled = true
        }
        cancelPendingChord()
        activeConflicts = detectConflicts(in: bindings)
        userDefaults.removeObject(forKey: storageKey)
    }

    // MARK: Multi-Stroke Chord State Machine & Event Dispatch

    public func cancelPendingChord() {
        chordTimeoutTask?.cancel()
        chordTimeoutTask = nil
        pendingChordPrefix.removeAll()
        pendingChordStatusText = nil
    }

    @discardableResult
    public func handleNSEvent(
        _ event: NSEvent,
        activePane: RelayStudioPane,
        isCommandPalettePresented: Bool = false
    ) -> Bool {
        guard event.type == .keyDown else { return false }
        let mods = RelayKeyModifiers(nsEventFlags: event.modifierFlags)
        guard let token = RelayKeyEquivalentToken(nsEvent: event) else { return false }

        // Escape cancels any in-flight multi-stroke chord immediately
        if mods.isEmpty && token.canonicalKey == "escape" && !pendingChordPrefix.isEmpty {
            cancelPendingChord()
            return true
        }

        let stroke = RelayKeyStroke(modifiers: mods, key: token)
        let outcome = handleKeyStroke(
            stroke,
            activePane: activePane,
            isCommandPalettePresented: isCommandPalettePresented
        )
        switch outcome {
        case .unmatched:
            return false
        case .awaitingNextStroke, .dispatched:
            return true
        }
    }

    public func handleKeyStroke(
        _ stroke: RelayKeyStroke,
        activePane: RelayStudioPane,
        isCommandPalettePresented: Bool = false
    ) -> RelayChordDispatchOutcome {
        let paneScope = RelayShortcutContextScope.scope(for: activePane)
        let eligibleBindings = bindings.filter { item in
            guard item.isEnabled else { return false }
            if isCommandPalettePresented {
                return item.commandID == "workbench.commandPalette" || item.scope == .commandPaletteModal
            }
            return item.scope == .globalWorkbench || item.scope == paneScope
        }

        var candidateSequence = pendingChordPrefix
        candidateSequence.append(stroke)

        // Prefer pane-specific exact match over global exact match
        let exactMatches = eligibleBindings.filter { $0.activeChord.strokes == candidateSequence }
        if let chosen = exactMatches.first(where: { $0.scope == paneScope }) ?? exactMatches.first {
            cancelPendingChord()
            onShortcutTriggered?(chosen)
            return .dispatched(commandID: chosen.commandID, chordBadge: chosen.glyphBadge)
        }

        // Check if candidateSequence is a leading prefix of one or more multi-stroke chords
        let prefixCandidates = eligibleBindings.filter { binding in
            guard binding.activeChord.strokes.count > candidateSequence.count else { return false }
            return Array(binding.activeChord.strokes.prefix(candidateSequence.count)) == candidateSequence
        }

        if !prefixCandidates.isEmpty {
            pendingChordPrefix = candidateSequence
            let badge = candidateSequence.map(\.glyphBadge).joined(separator: " ")
            pendingChordStatusText = "Awaiting next key for chord (\(badge)…)"
            scheduleChordTimeout()
            return .awaitingNextStroke(
                prefixBadge: badge,
                candidateCommandIDs: prefixCandidates.map(\.commandID)
            )
        }

        // If we were mid-chord and this stroke failed to complete, reset and retry as fresh single stroke
        if !pendingChordPrefix.isEmpty {
            cancelPendingChord()
            return handleKeyStroke(
                stroke,
                activePane: activePane,
                isCommandPalettePresented: isCommandPalettePresented
            )
        }

        return .unmatched
    }

    private func scheduleChordTimeout() {
        chordTimeoutTask?.cancel()
        let delayNs = UInt64(max(0.35, chordTimeoutSeconds) * 1_000_000_000.0)
        chordTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayNs)
            guard !Task.isCancelled else { return }
            self?.cancelPendingChord()
        }
    }

    // MARK: Import / Export JSON Keymap

    public func exportKeymapJSON(profileName: String = "RelayIDE Bauhaus Keymap") throws -> Data {
        let overrides = bindings
            .filter { $0.isUserCustomized || !$0.isEnabled }
            .map {
                RelayKeymapProfileDocument.OverrideEntry(
                    commandID: $0.commandID,
                    portableChord: $0.activeChord.portableSpec,
                    glyphBadge: $0.glyphBadge,
                    isEnabled: $0.isEnabled
                )
            }
        let doc = RelayKeymapProfileDocument(profileName: profileName, overrides: overrides)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(doc)
    }

    public func importKeymapJSON(_ data: Data) throws {
        try applyKeymapDataWithoutPersisting(data)
        activeConflicts = detectConflicts(in: bindings)
        persistOverrides()
    }

    private func applyKeymapDataWithoutPersisting(_ data: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let doc = try decoder.decode(RelayKeymapProfileDocument.self, from: data)
        for entry in doc.overrides {
            guard let idx = bindings.firstIndex(where: { $0.commandID == entry.commandID }) else { continue }
            if let parsed = RelayKeyChord.parse(entry.portableChord) ?? RelayKeyChord.parse(entry.glyphBadge) {
                bindings[idx].activeChord = parsed
            }
            bindings[idx].isEnabled = entry.isEnabled
        }
    }

    private func persistOverrides() {
        guard let encoded = try? exportKeymapJSON() else { return }
        userDefaults.set(encoded, forKey: storageKey)
    }

    // MARK: Pre-Registered Default RelayIDE Keymap

    public static let defaultBindings: [RelayShortcutBinding] = [
        // ⌘1 .. ⌘6 Studio Views
        RelayShortcutBinding(
            commandID: "studio.ptyGrid",
            title: "Open 2×2 Multi-Vendor PTY Multiplexer",
            subtitle: "Switch workbench canvas to live VT100/TrueColor agent terminals",
            category: .studioNavigation,
            scope: .globalWorkbench,
            defaultChord: .single([.command], "1")
        ),
        RelayShortcutBinding(
            commandID: "studio.dagPipeline",
            title: "Open Topological Relay DAG & CPM View",
            subtitle: "Switch workbench canvas to parallel execution waves & critical path",
            category: .studioNavigation,
            scope: .globalWorkbench,
            defaultChord: .single([.command], "2")
        ),
        RelayShortcutBinding(
            commandID: "studio.semanticMerge",
            title: "Open 3-Way Semantic AST Merge Studio",
            subtitle: "Switch workbench canvas to declaration-level merge & conflict resolver",
            category: .studioNavigation,
            scope: .globalWorkbench,
            defaultChord: .single([.command], "3")
        ),
        RelayShortcutBinding(
            commandID: "studio.territoryMap",
            title: "Open 2.5D Isometric Territory & Coupling Map",
            subtitle: "Switch workbench canvas to module instability towers & ownership fences",
            category: .studioNavigation,
            scope: .globalWorkbench,
            defaultChord: .single([.command], "4")
        ),
        RelayShortcutBinding(
            commandID: "studio.wiretapBudget",
            title: "Open Loopback Wiretap & Spend Flamechart",
            subtitle: "Switch workbench canvas to SSE TTFT spans, DLP audit & circuit breakers",
            category: .studioNavigation,
            scope: .globalWorkbench,
            defaultChord: .single([.command], "5")
        ),
        RelayShortcutBinding(
            commandID: "studio.guardrailPlugins",
            title: "Open JavaScriptCore Guardrail Plugins & Scratchpad",
            subtitle: "Switch workbench canvas to policy packs, micro-profiler & hook traces",
            category: .studioNavigation,
            scope: .globalWorkbench,
            defaultChord: .single([.command], "6")
        ),

        // Core Workbench & Multi-Agent Operations
        RelayShortcutBinding(
            commandID: "workbench.commandPalette",
            title: "Toggle Fuzzy Command Palette",
            subtitle: "Open or dismiss Bauhaus subsequence-scored command launcher",
            category: .studioNavigation,
            scope: .globalWorkbench,
            defaultChord: .single([.command], "k")
        ),
        RelayShortcutBinding(
            commandID: "pty.broadcastInput",
            title: "Broadcast Input Across Selected PTY Lanes",
            subtitle: "Open synchronized multi-vendor terminal prompt broadcaster",
            category: .ptyMultiplexer,
            scope: .globalWorkbench,
            defaultChord: .single([.command, .shift], "b")
        ),
        RelayShortcutBinding(
            commandID: "merge.runThreeWaySemantic",
            title: "Run 3-Way Semantic AST Merge",
            subtitle: "Reconcile concurrent worktree declarations & highlight body conflicts",
            category: .semanticMerge,
            scope: .globalWorkbench,
            defaultChord: .single([.command, .shift], "m")
        ),
        RelayShortcutBinding(
            commandID: "wiretap.tripOrResetCircuitBreaker",
            title: "Trip or Reset Lane Budget Circuit Breaker",
            subtitle: "Toggle loopback HTTP 429 budget circuit breaker on selected vendor lane",
            category: .wiretapAndBudget,
            scope: .globalWorkbench,
            defaultChord: .single([.command, .shift], "k")
        ),

        // Transactional Undo/Redo, Checkpoints, FTS5 Search & Chrome Docking
        RelayShortcutBinding(
            commandID: "journal.undo",
            title: "Undo Last Workspace Mutation",
            subtitle: "Revert territory, merge, budget or guardrail mutation via SQLite journal",
            category: .workspaceAndJournal,
            scope: .globalWorkbench,
            defaultChord: .single([.command], "z")
        ),
        RelayShortcutBinding(
            commandID: "journal.redo",
            title: "Redo Workspace Mutation",
            subtitle: "Re-apply reverted workspace operation from persistent redo stack",
            category: .workspaceAndJournal,
            scope: .globalWorkbench,
            defaultChord: .single([.command, .shift], "z")
        ),
        RelayShortcutBinding(
            commandID: "journal.createCheckpoint",
            title: "Create Named Workspace Checkpoint",
            subtitle: "Persist full multi-lane checkpoint into .relayproj/workspace.sqlite",
            category: .workspaceAndJournal,
            scope: .globalWorkbench,
            defaultChord: .single([.command, .shift], "s")
        ),
        RelayShortcutBinding(
            commandID: "workbench.ftsSearch",
            title: "Search Transcripts & Merges (SQLite FTS5)",
            subtitle: "Toggle bottom FTS5 BM25 search drawer across agent terminals & handoffs",
            category: .workspaceAndJournal,
            scope: .globalWorkbench,
            defaultChord: .single([.command, .shift], "f")
        ),
        RelayShortcutBinding(
            commandID: "workbench.exportHTMLDossier",
            title: "Export Standalone Bauhaus HTML Dossier",
            subtitle: "Render offline single-file campaign audit report",
            category: .workspaceAndJournal,
            scope: .globalWorkbench,
            defaultChord: .single([.command, .shift], "e")
        ),
        RelayShortcutBinding(
            commandID: "workbench.toggleRightInspector",
            title: "Toggle Right Inspector Drawer",
            subtitle: "Show or hide territory globs, AST symbols, DLP & JSC micro-profiler",
            category: .studioNavigation,
            scope: .globalWorkbench,
            defaultChord: .single([.command, .option], "i")
        ),
        RelayShortcutBinding(
            commandID: "workbench.toggleBottomDrawer",
            title: "Toggle Bottom Telemetry & FTS5 Drawer",
            subtitle: "Show or hide FTS5 search, verifier console & SSE wiretap feed",
            category: .studioNavigation,
            scope: .globalWorkbench,
            defaultChord: .single([.command], "j")
        ),

        // Multi-Stroke Chorded Sequences (⌃G … / ⌃M …)
        RelayShortcutBinding(
            commandID: "guardrail.evalScratchpad",
            title: "Evaluate JSC Guardrail Scratchpad",
            subtitle: "Execute capability-gated JavaScriptCore scratchpad with micro-profiling",
            category: .guardrailsAndPlugins,
            scope: .guardrailStudioFocused,
            defaultChord: .sequence(
                RelayKeyStroke(modifiers: [.control], key: "g"),
                RelayKeyStroke(modifiers: [.control], key: "e")
            )
        ),
        RelayShortcutBinding(
            commandID: "guardrail.exportPolicyPack",
            title: "Export .relay-guardrails.json Policy Pack",
            subtitle: "Serialize enabled guardrail rules & thresholds to workspace root",
            category: .guardrailsAndPlugins,
            scope: .guardrailStudioFocused,
            defaultChord: .sequence(
                RelayKeyStroke(modifiers: [.control], key: "g"),
                RelayKeyStroke(modifiers: [.control], key: "p")
            )
        ),
        RelayShortcutBinding(
            commandID: "merge.acceptCleanAutoMerged",
            title: "Stage All Clean Semantic AST Auto-Merges",
            subtitle: "Accept disjoint struct/method auto-merges while keeping body conflicts flagged",
            category: .semanticMerge,
            scope: .mergeStudioFocused,
            defaultChord: .sequence(
                RelayKeyStroke(modifiers: [.control], key: "m"),
                RelayKeyStroke(modifiers: [.control], key: "a")
            )
        )
    ]
}

// MARK: - Unified RelayWorkbenchCoordinator for Studio UI Integration

@MainActor
public final class RelayWorkbenchCoordinator: ObservableObject {
    public let shellState: RelayWorkbenchShellState
    public let preferences: RelayUserPreferences
    public let commandPalette: RelayCommandPaletteController
    public let splitWorkspace: RelaySplitWorkspaceController
    public let toastCenter: RelayToastCenter
    public let shortcutRegistry: RelayKeybindingAndShortcutRegistry

    public var onRunSemanticMergeRequested: (() -> Void)?
    public var onToggleCircuitBreakerRequested: ((String) -> Void)?
    public var onBroadcastInputRequested: (() -> Void)?
    public var onUndoRequested: (() -> Void)?
    public var onRedoRequested: (() -> Void)?
    public var onCreateCheckpointRequested: (() -> Void)?
    public var onExportHTMLDossierRequested: (() -> Void)?

    public init(
        shellState: RelayWorkbenchShellState = RelayWorkbenchShellState(),
        preferences: RelayUserPreferences = RelayUserPreferences(),
        commandPalette: RelayCommandPaletteController = RelayCommandPaletteController(),
        splitWorkspace: RelaySplitWorkspaceController = RelaySplitWorkspaceController(),
        toastCenter: RelayToastCenter = RelayToastCenter(),
        shortcutRegistry: RelayKeybindingAndShortcutRegistry = RelayKeybindingAndShortcutRegistry()
    ) {
        self.shellState = shellState
        self.preferences = preferences
        self.commandPalette = commandPalette
        self.splitWorkspace = splitWorkspace
        self.toastCenter = toastCenter
        self.shortcutRegistry = shortcutRegistry

        shortcutRegistry.syncBadges(into: commandPalette)

        commandPalette.onCommandTriggered = { [weak self] item in
            self?.dispatchCommand(id: item.id, targetPane: item.targetPane)
        }
        shortcutRegistry.onShortcutTriggered = { [weak self] binding in
            let targetPane = self?.commandPalette.catalog.first(where: { $0.id == binding.commandID })?.targetPane
            self?.dispatchCommand(id: binding.commandID, targetPane: targetPane)
        }
    }

    public func selectStudioPane(_ pane: RelayStudioPane) {
        shellState.activePane = pane
        splitWorkspace.openOrActivatePane(pane)
    }

    public func dispatchCommand(id commandID: String, targetPane: RelayStudioPane? = nil) {
        if let targetPane {
            selectStudioPane(targetPane)
        }

        switch commandID {
        case "studio.ptyGrid":
            selectStudioPane(.ptyGrid)
        case "studio.dagPipeline":
            selectStudioPane(.dagPipeline)
        case "studio.semanticMerge":
            selectStudioPane(.semanticMerge)
        case "studio.territoryMap":
            selectStudioPane(.territoryMap)
        case "studio.wiretapBudget":
            selectStudioPane(.wiretapBudget)
        case "studio.guardrailPlugins":
            selectStudioPane(.guardrailPlugins)
        case "workbench.commandPalette":
            commandPalette.togglePresented()
            shellState.isCommandPalettePresented = commandPalette.isPresented
        case "pty.broadcastInput":
            selectStudioPane(.ptyGrid)
            splitWorkspace.isBroadcastComposerPresented.toggle()
            onBroadcastInputRequested?()
        case "merge.runThreeWaySemantic":
            selectStudioPane(.semanticMerge)
            onRunSemanticMergeRequested?()
        case "wiretap.tripOrResetCircuitBreaker":
            selectStudioPane(.wiretapBudget)
            onToggleCircuitBreakerRequested?(shellState.selectedLaneID)
        case "journal.undo":
            onUndoRequested?()
        case "journal.redo":
            onRedoRequested?()
        case "journal.createCheckpoint":
            onCreateCheckpointRequested?()
        case "workbench.ftsSearch":
            splitWorkspace.toggleBottomDrawer(tab: .ftsSearch)
        case "workbench.exportHTMLDossier":
            onExportHTMLDossierRequested?()
        case "workbench.toggleRightInspector":
            splitWorkspace.toggleRightInspector()
        case "workbench.toggleBottomDrawer":
            splitWorkspace.toggleBottomDrawer()
        default:
            break
        }
    }
}
