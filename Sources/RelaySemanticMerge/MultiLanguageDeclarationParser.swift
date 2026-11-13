import Foundation
import RelayModels

// MARK: - Pure-Swift Multi-Language (Swift / Python / TS / Rust / Go) Declaration AST Parser

public struct MultiLanguageDeclarationParser: Sendable {
    public init() {}

    public func parseDeclarations(source: String, language: SourceLanguage) -> [ASTDeclarationNode] {
        switch language {
        case .swift, .typeScript, .rust, .go:
            return parseBraceDelimitedDeclarations(source: source, language: language)
        case .python:
            return parsePythonIndentationDeclarations(source: source)
        case .json, .markdown, .plainText:
            return parseSectionalFallback(source: source)
        }
    }

    /// Computes a whitespace-normalized FNV-1a 64-bit structural fingerprint.
    public static func structuralFingerprint(of source: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        var lastWasSpace = false
        for scalar in source.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !lastWasSpace {
                    hash ^= 0x20
                    hash = hash &* 0x0000_0100_0000_01B3
                    lastWasSpace = true
                }
            } else {
                lastWasSpace = false
                for b in String(scalar).utf8 {
                    hash ^= UInt64(b)
                    hash = hash &* 0x0000_0100_0000_01B3
                }
            }
        }
        return hash
    }

    // MARK: - Brace-Delimited Parser (Swift, TypeScript, Rust, Go)

    private func parseBraceDelimitedDeclarations(source: String, language: SourceLanguage) -> [ASTDeclarationNode] {
        let rawLines = source.components(separatedBy: "\n")
        guard !rawLines.isEmpty else { return [] }

        var nodes: [ASTDeclarationNode] = []
        var importLines: [String] = []
        var importStartLine = 1
        var importEndLine = 1

        var triviaLines: [String] = []
        var triviaStartLine: Int?

        var lineIdx = 0
        while lineIdx < rawLines.count {
            let line = rawLines[lineIdx]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Collect contiguous leading imports into one canonical Import Group node
            if isImportStatement(trimmed, language: language) {
                if importLines.isEmpty {
                    importStartLine = lineIdx + 1
                }
                importLines.append(line)
                importEndLine = lineIdx + 1
                lineIdx += 1
                continue
            } else if !importLines.isEmpty && trimmed.isEmpty {
                // Allow blank lines inside header import group only if next non-empty line is also an import
                var peek = lineIdx + 1
                while peek < rawLines.count && rawLines[peek].trimmingCharacters(in: .whitespaces).isEmpty {
                    peek += 1
                }
                if peek < rawLines.count && isImportStatement(rawLines[peek].trimmingCharacters(in: .whitespaces), language: language) {
                    lineIdx += 1
                    continue
                } else {
                    nodes.append(makeImportGroupNode(lines: importLines, startLine: importStartLine, endLine: importEndLine))
                    importLines.removeAll()
                }
            } else if !importLines.isEmpty {
                nodes.append(makeImportGroupNode(lines: importLines, startLine: importStartLine, endLine: importEndLine))
                importLines.removeAll()
            }

            if trimmed.isEmpty {
                if !triviaLines.isEmpty {
                    triviaLines.append(line)
                }
                lineIdx += 1
                continue
            }

            if isTriviaOrAttribute(trimmed, language: language) {
                if triviaStartLine == nil { triviaStartLine = lineIdx + 1 }
                triviaLines.append(line)
                lineIdx += 1
                continue
            }

            // Start of a top-level declaration or statement
            let declStart = triviaStartLine ?? (lineIdx + 1)
            let leadingTrivia = triviaLines.isEmpty ? "" : (triviaLines.joined(separator: "\n") + "\n")
            triviaLines.removeAll()
            triviaStartLine = nil

            let headerInfo = classifyDeclarationHeader(trimmed, language: language)
            var declBodyLines: [String] = [line]
            var braceBalance = netBraceDelta(in: line)
            var sawOpeningBrace = line.contains("{")

            var scanIdx = lineIdx + 1
            // Handle signature spanning multiple lines before opening `{`
            while !sawOpeningBrace && scanIdx < rawLines.count && headerInfo.expectsBodyBlock {
                let nextLine = rawLines[scanIdx]
                let nextTrim = nextLine.trimmingCharacters(in: .whitespaces)
                declBodyLines.append(nextLine)
                braceBalance += netBraceDelta(in: nextLine)
                if nextLine.contains("{") {
                    sawOpeningBrace = true
                } else if nextTrim.hasSuffix(";") {
                    break
                }
                scanIdx += 1
            }

            while sawOpeningBrace && braceBalance > 0 && scanIdx < rawLines.count {
                let nextLine = rawLines[scanIdx]
                declBodyLines.append(nextLine)
                braceBalance += netBraceDelta(in: nextLine)
                scanIdx += 1
            }

            let declEnd = max(declStart, scanIdx)
            let declSource = declBodyLines.joined(separator: "\n")
            let children = parseNestedContainerMembers(
                containerKind: headerInfo.kind,
                containerName: headerInfo.symbolName,
                declLines: declBodyLines,
                baseLineNumber: lineIdx + 1,
                language: language
            )
            let refs = extractReferencedIdentifiers(in: declSource, excluding: headerInfo.symbolName)

            nodes.append(
                ASTDeclarationNode(
                    kind: headerInfo.kind,
                    symbolName: headerInfo.symbolName,
                    qualifiedKey: "\(headerInfo.kind.rawValue):\(headerInfo.symbolName)",
                    parameterSignature: headerInfo.signature,
                    startLine: declStart,
                    endLine: declEnd,
                    leadingTrivia: leadingTrivia,
                    declarationSource: declSource,
                    referencedSymbols: refs,
                    children: children,
                    structuralFingerprint: Self.structuralFingerprint(of: declSource)
                )
            )
            lineIdx = scanIdx
        }

        if !importLines.isEmpty {
            nodes.append(makeImportGroupNode(lines: importLines, startLine: importStartLine, endLine: importEndLine))
        }

        return nodes
    }

    private func parseNestedContainerMembers(
        containerKind: ASTDeclarationKind,
        containerName: String,
        declLines: [String],
        baseLineNumber: Int,
        language: SourceLanguage
    ) -> [ASTDeclarationNode] {
        switch containerKind {
        case .structDecl, .classDecl, .enumDecl, .protocolOrInterface, .extensionOrImpl:
            break
        default:
            return []
        }
        guard declLines.count >= 3 else { return [] }

        // Strip outer container opening line(s) up to first `{` and final closing `}`
        var firstBraceLine = 0
        while firstBraceLine < declLines.count && !declLines[firstBraceLine].contains("{") {
            firstBraceLine += 1
        }
        guard firstBraceLine + 1 < declLines.count - 1 else { return [] }
        let innerSlice = Array(declLines[(firstBraceLine + 1)..<(declLines.count - 1)])
        let innerSource = innerSlice.joined(separator: "\n")
        let rawChildren = parseBraceDelimitedDeclarations(source: innerSource, language: language)

        return rawChildren.map { child in
            let adjustedKind: ASTDeclarationKind = (child.kind == .functionDecl) ? .methodDecl : child.kind
            let qKey = "\(containerName).\(child.symbolName)"
            return ASTDeclarationNode(
                kind: adjustedKind,
                symbolName: child.symbolName,
                qualifiedKey: qKey,
                parameterSignature: child.parameterSignature,
                startLine: baseLineNumber + firstBraceLine + child.startLine,
                endLine: baseLineNumber + firstBraceLine + child.endLine,
                leadingTrivia: child.leadingTrivia,
                declarationSource: child.declarationSource,
                referencedSymbols: child.referencedSymbols,
                importedModules: child.importedModules,
                children: [],
                structuralFingerprint: child.structuralFingerprint
            )
        }
    }

    // MARK: - Python Indentation-Aware Declaration Parser

    private func parsePythonIndentationDeclarations(source: String) -> [ASTDeclarationNode] {
        let rawLines = source.components(separatedBy: "\n")
        var nodes: [ASTDeclarationNode] = []
        var importLines: [String] = []
        var importStart = 1
        var decorators: [String] = []

        var i = 0
        while i < rawLines.count {
            let line = rawLines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = leadingIndentSpaces(line)

            if indent == 0 && (trimmed.hasPrefix("import ") || trimmed.hasPrefix("from ")) {
                if importLines.isEmpty { importStart = i + 1 }
                importLines.append(line)
                i += 1
                continue
            } else if !importLines.isEmpty && !trimmed.isEmpty {
                nodes.append(makeImportGroupNode(lines: importLines, startLine: importStart, endLine: i))
                importLines.removeAll()
            }

            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                i += 1
                continue
            }

            if indent == 0 && trimmed.hasPrefix("@") {
                decorators.append(line)
                i += 1
                continue
            }

            if indent == 0 && (trimmed.hasPrefix("def ") || trimmed.hasPrefix("async def ") || trimmed.hasPrefix("class ")) {
                let isClass = trimmed.hasPrefix("class ")
                let header = classifyDeclarationHeader(trimmed, language: .python)
                let startLine = i + 1 - decorators.count
                let trivia = decorators.isEmpty ? "" : (decorators.joined(separator: "\n") + "\n")
                decorators.removeAll()

                var bodyLines = [line]
                var j = i + 1
                while j < rawLines.count {
                    let next = rawLines[j]
                    let nextTrim = next.trimmingCharacters(in: .whitespaces)
                    if nextTrim.isEmpty || leadingIndentSpaces(next) > 0 {
                        bodyLines.append(next)
                        j += 1
                    } else {
                        break
                    }
                }
                while bodyLines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true && bodyLines.count > 1 {
                    bodyLines.removeLast()
                }
                let declSrc = bodyLines.joined(separator: "\n")
                nodes.append(
                    ASTDeclarationNode(
                        kind: isClass ? .classDecl : .functionDecl,
                        symbolName: header.symbolName,
                        qualifiedKey: "\(isClass ? "Class" : "Function"):\(header.symbolName)",
                        parameterSignature: header.signature,
                        startLine: startLine,
                        endLine: i + bodyLines.count,
                        leadingTrivia: trivia,
                        declarationSource: declSrc,
                        referencedSymbols: extractReferencedIdentifiers(in: declSrc, excluding: header.symbolName),
                        structuralFingerprint: Self.structuralFingerprint(of: declSrc)
                    )
                )
                i = j
                continue
            }

            // Top-level constant/assignment
            let header = classifyDeclarationHeader(trimmed, language: .python)
            nodes.append(
                ASTDeclarationNode(
                    kind: header.kind,
                    symbolName: header.symbolName,
                    startLine: i + 1,
                    endLine: i + 1,
                    declarationSource: line,
                    structuralFingerprint: Self.structuralFingerprint(of: line)
                )
            )
            i += 1
        }

        if !importLines.isEmpty {
            nodes.append(makeImportGroupNode(lines: importLines, startLine: importStart, endLine: rawLines.count))
        }
        return nodes
    }

    private func parseSectionalFallback(source: String) -> [ASTDeclarationNode] {
        let blocks = source.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return blocks.enumerated().map { idx, block in
            let firstLine = block.components(separatedBy: "\n").first ?? "block_\(idx)"
            let key = String(firstLine.prefix(40)).trimmingCharacters(in: .whitespaces)
            return ASTDeclarationNode(
                kind: .topLevelBlock,
                symbolName: key.isEmpty ? "block_\(idx)" : key,
                startLine: idx + 1,
                endLine: idx + 1,
                declarationSource: block,
                structuralFingerprint: Self.structuralFingerprint(of: block)
            )
        }
    }

    // MARK: - Lexical & Header Helpers

    private struct HeaderClassification {
        let kind: ASTDeclarationKind
        let symbolName: String
        let signature: String
        let expectsBodyBlock: Bool
    }

    private func classifyDeclarationHeader(_ trimmed: String, language: SourceLanguage) -> HeaderClassification {
        let patterns: [(String, ASTDeclarationKind, Bool)] = [
            (#"(?:public|private|internal|fileprivate|open|final|actor|export|default|pub(?:\([^)]+\))?|async|\s)*\bstruct\s+([A-Za-z_][A-Za-z0-9_]*)"#, .structDecl, true),
            (#"(?:public|private|internal|open|final|abstract|export|default|\s)*\bclass\s+([A-Za-z_][A-Za-z0-9_]*)"#, .classDecl, true),
            (#"(?:public|private|internal|indirect|export|pub|\s)*\benum\s+([A-Za-z_][A-Za-z0-9_]*)"#, .enumDecl, true),
            (#"(?:public|private|internal|export|pub|\s)*\b(?:protocol|interface|trait)\s+([A-Za-z_][A-Za-z0-9_]*)"#, .protocolOrInterface, true),
            (#"(?:public|private|internal|\s)*\b(?:extension|impl)\s+([A-Za-z_][A-Za-z0-9_<>,:\s]*)"#, .extensionOrImpl, true),
            (#"(?:public|private|internal|open|static|class|mutating|override|export|async|pub(?:\([^)]+\))?|unsafe|\s)*\b(?:func|function|fn|def)\s+([A-Za-z_][A-Za-z0-9_]*)"#, .functionDecl, true),
            (#"\binit\s*(\??)\s*\("#, .methodDecl, true),
            (#"(?:public|private|internal|export|pub|\s)*\b(?:typealias|type)\s+([A-Za-z_][A-Za-z0-9_]*)"#, .typeAlias, false),
            (#"(?:public|private|internal|static|export|pub|\s)*\b(?:let|var|const)\s+([A-Za-z_][A-Za-z0-9_]*)"#, .constantOrVar, false),
            (#"^([A-Za-z_][A-Za-z0-9_]*)\s*="#, .constantOrVar, false)
        ]

        let ns = trimmed as NSString
        for (pat, kind, hasBlock) in patterns {
            if let rx = try? NSRegularExpression(pattern: pat),
               let m = rx.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)),
               m.numberOfRanges >= 2 {
                let rawSym = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                let sym = kind == .methodDecl && rawSym.isEmpty ? "init" : (rawSym.isEmpty ? "init\(rawSym)" : rawSym)
                let sig = extractParenSignature(from: trimmed)
                let hasComputedBraces = trimmed.contains("{")
                return HeaderClassification(
                    kind: kind,
                    symbolName: sym,
                    signature: sig,
                    expectsBodyBlock: hasBlock || hasComputedBraces
                )
            }
        }

        let fallbackToken = trimmed
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .first { !$0.isEmpty } ?? "statement"
        return HeaderClassification(
            kind: .topLevelBlock,
            symbolName: fallbackToken,
            signature: "",
            expectsBodyBlock: trimmed.contains("{")
        )
    }

    private func extractParenSignature(from line: String) -> String {
        guard let open = line.firstIndex(of: "(") else { return "" }
        var depth = 0
        var idx = open
        while idx < line.endIndex {
            let ch = line[idx]
            if ch == "(" { depth += 1 }
            if ch == ")" {
                depth -= 1
                if depth == 0 {
                    let afterClose = line.index(after: idx)
                    let tail = line[afterClose...]
                    if let brace = tail.firstIndex(of: "{") {
                        return String(line[open..<brace]).trimmingCharacters(in: .whitespaces)
                    } else if let colon = tail.firstIndex(of: ":") {
                        return String(line[open..<colon]).trimmingCharacters(in: .whitespaces)
                    }
                    return String(line[open...idx])
                }
            }
            idx = line.index(after: idx)
        }
        return String(line[open...])
    }

    private func isImportStatement(_ trimmed: String, language: SourceLanguage) -> Bool {
        switch language {
        case .swift:
            return trimmed.hasPrefix("import ") || trimmed.hasPrefix("@_exported import ")
        case .typeScript:
            return trimmed.hasPrefix("import ")
        case .rust:
            return trimmed.hasPrefix("use ") || trimmed.hasPrefix("pub use ")
        case .go:
            return trimmed.hasPrefix("package ") || trimmed.hasPrefix("import ")
        case .python:
            return trimmed.hasPrefix("import ") || trimmed.hasPrefix("from ")
        default:
            return false
        }
    }

    private func isTriviaOrAttribute(_ trimmed: String, language: SourceLanguage) -> Bool {
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("*") || trimmed.hasPrefix("*/") {
            return true
        }
        switch language {
        case .swift, .typeScript:
            return trimmed.hasPrefix("@") && !trimmed.contains("func ") && !trimmed.contains("struct ") && !trimmed.contains("class ")
        case .rust:
            return trimmed.hasPrefix("#[") || trimmed.hasPrefix("#![")
        default:
            return false
        }
    }

    private func makeImportGroupNode(lines: [String], startLine: Int, endLine: Int) -> ASTDeclarationNode {
        let cleaned = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let src = cleaned.joined(separator: "\n")
        return ASTDeclarationNode(
            kind: .importGroup,
            symbolName: "__imports__",
            qualifiedKey: "ImportBlock:__imports__",
            startLine: startLine,
            endLine: endLine,
            declarationSource: src,
            importedModules: cleaned,
            structuralFingerprint: Self.structuralFingerprint(of: src)
        )
    }

    private func netBraceDelta(in line: String) -> Int {
        var delta = 0
        var inDoubleQuote = false
        var inSingleQuote = false
        var escaped = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if escaped {
                escaped = false
                i += 1
                continue
            }
            if c == "\\" && (inDoubleQuote || inSingleQuote) {
                escaped = true
                i += 1
                continue
            }
            if !inSingleQuote && !inDoubleQuote && c == "/" && i + 1 < chars.count && chars[i + 1] == "/" {
                break // line comment
            }
            if c == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
            } else if c == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
            } else if !inDoubleQuote && !inSingleQuote {
                if c == "{" { delta += 1 }
                if c == "}" { delta -= 1 }
            }
            i += 1
        }
        return delta
    }

    private func leadingIndentSpaces(_ line: String) -> Int {
        var count = 0
        for ch in line {
            if ch == " " { count += 1 }
            else if ch == "\t" { count += 4 }
            else { break }
        }
        return count
    }

    private func extractReferencedIdentifiers(in source: String, excluding ownName: String) -> [String] {
        let pattern = #"\b([A-Za-z_][A-Za-z0-9_]*)\s*\("#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = source as NSString
        let matches = regex.matches(in: source, range: NSRange(location: 0, length: ns.length))
        let keywords: Set<String> = [
            "if", "for", "while", "switch", "guard", "catch", "return", "sizeof",
            "func", "def", "fn", "function", "init", "print", ownName
        ]
        var out: [String] = []
        var seen = Set<String>()
        for m in matches where m.numberOfRanges >= 2 {
            let sym = ns.substring(with: m.range(at: 1))
            if !keywords.contains(sym) && seen.insert(sym).inserted {
                out.append(sym)
            }
        }
        return out
    }
}
