import Compression
import Foundation
import RelayModels

// MARK: - Pure-Swift `.git` Layout, Reference, Worktree & Loose Object Models

public struct GitRepositoryDirectories: Sendable, Codable, Hashable {
    /// Working tree directory (nil for bare repositories).
    public let workingTreePath: String?
    /// Worktree-specific git directory (`.git` or `.git/worktrees/<name>`).
    public let gitDirPath: String
    /// Shared common git directory containing `objects/`, `packed-refs`, and `worktrees/`.
    public let commonGitDirPath: String
    public let isLinkedWorktree: Bool
    public let isBareRepository: Bool

    public init(
        workingTreePath: String?,
        gitDirPath: String,
        commonGitDirPath: String,
        isLinkedWorktree: Bool,
        isBareRepository: Bool
    ) {
        self.workingTreePath = workingTreePath
        self.gitDirPath = gitDirPath
        self.commonGitDirPath = commonGitDirPath
        self.isLinkedWorktree = isLinkedWorktree
        self.isBareRepository = isBareRepository
    }
}

public enum GitInspectedHEAD: Sendable, Codable, Hashable {
    case symbolic(refName: String, targetOID: String?)
    case detached(commitOID: String)

    public var resolvedCommitOID: String? {
        switch self {
        case .symbolic(_, let oid): return oid
        case .detached(let oid):    return oid
        }
    }

    public var shortBranchName: String? {
        guard case .symbolic(let ref, _) = self else { return nil }
        if ref.hasPrefix("refs/heads/") {
            return String(ref.dropFirst("refs/heads/".count))
        }
        return ref
    }
}

public enum GitReferenceNamespace: String, Sendable, Codable, Hashable {
    case localBranch = "heads"
    case remoteTracking = "remotes"
    case tag = "tags"
    case other = "other"
}

public struct GitReferenceRecord: Sendable, Codable, Hashable, Identifiable {
    public var id: String { fullRefName }
    public let fullRefName: String
    public let shortName: String
    public let namespace: GitReferenceNamespace
    public let targetOID: String
    public let peeledTagCommitOID: String?
    public let isPackedOnly: Bool

    public init(
        fullRefName: String,
        shortName: String,
        namespace: GitReferenceNamespace,
        targetOID: String,
        peeledTagCommitOID: String? = nil,
        isPackedOnly: Bool = false
    ) {
        self.fullRefName = fullRefName
        self.shortName = shortName
        self.namespace = namespace
        self.targetOID = targetOID
        self.peeledTagCommitOID = peeledTagCommitOID
        self.isPackedOnly = isPackedOnly
    }

    public var effectiveCommitOID: String {
        peeledTagCommitOID ?? targetOID
    }
}

public struct InspectedGitWorktreeRecord: Sendable, Codable, Hashable, Identifiable {
    public var id: String { worktreeName }
    public let worktreeName: String
    public let workingDirectoryPath: String
    public let adminGitDirPath: String
    public let head: GitInspectedHEAD
    public let isMainWorktree: Bool
    public let isLocked: Bool
    public let lockReason: String?
    public let workingDirectoryExistsOnDisk: Bool

    public init(
        worktreeName: String,
        workingDirectoryPath: String,
        adminGitDirPath: String,
        head: GitInspectedHEAD,
        isMainWorktree: Bool,
        isLocked: Bool,
        lockReason: String?,
        workingDirectoryExistsOnDisk: Bool
    ) {
        self.worktreeName = worktreeName
        self.workingDirectoryPath = workingDirectoryPath
        self.adminGitDirPath = adminGitDirPath
        self.head = head
        self.isMainWorktree = isMainWorktree
        self.isLocked = isLocked
        self.lockReason = lockReason
        self.workingDirectoryExistsOnDisk = workingDirectoryExistsOnDisk
    }
}

public enum GitLooseObjectKind: String, Sendable, Codable, Hashable {
    case commit
    case tree
    case blob
    case tag
}

public struct GitRawLooseObject: Sendable, Hashable {
    public let oid: String
    public let kind: GitLooseObjectKind
    public let declaredSize: Int
    public let payload: Data

    public init(oid: String, kind: GitLooseObjectKind, declaredSize: Int, payload: Data) {
        self.oid = oid
        self.kind = kind
        self.declaredSize = declaredSize
        self.payload = payload
    }
}

public struct GitActorSignature: Sendable, Codable, Hashable {
    public let name: String
    public let email: String
    public let timestamp: Date
    public let timezoneOffsetMinutes: Int
    public let rawTimezone: String

    public init(
        name: String,
        email: String,
        timestamp: Date,
        timezoneOffsetMinutes: Int,
        rawTimezone: String
    ) {
        self.name = name
        self.email = email
        self.timestamp = timestamp
        self.timezoneOffsetMinutes = timezoneOffsetMinutes
        self.rawTimezone = rawTimezone
    }
}

public struct GitInspectedCommitObject: Sendable, Codable, Hashable, Identifiable {
    public var id: String { oid }
    public let oid: String
    public let treeOID: String
    public let parentOIDs: [String]
    public let author: GitActorSignature
    public let committer: GitActorSignature
    public let encoding: String?
    public let gpgSignature: String?
    public let subject: String
    public let messageBody: String
    public let fullMessage: String

    public init(
        oid: String,
        treeOID: String,
        parentOIDs: [String],
        author: GitActorSignature,
        committer: GitActorSignature,
        encoding: String? = nil,
        gpgSignature: String? = nil,
        subject: String,
        messageBody: String,
        fullMessage: String
    ) {
        self.oid = oid
        self.treeOID = treeOID
        self.parentOIDs = parentOIDs
        self.author = author
        self.committer = committer
        self.encoding = encoding
        self.gpgSignature = gpgSignature
        self.subject = subject
        self.messageBody = messageBody
        self.fullMessage = fullMessage
    }

    public func toGitCommitNode(decorations: [String] = []) -> GitCommitNode {
        GitCommitNode(
            oid: oid,
            parentOIDs: parentOIDs,
            authorName: author.name,
            authorEmail: author.email,
            authoredAt: author.timestamp,
            subject: subject,
            decorations: decorations
        )
    }
}

public enum GitTreeEntryType: String, Sendable, Codable, Hashable {
    case regularFile
    case executableFile
    case symbolicLink
    case directoryTree
    case gitlinkSubmodule
}

public struct GitTreeEntryRecord: Sendable, Codable, Hashable, Identifiable {
    public var id: String { "\(name):\(entryOID)" }
    public let modeOctal: String
    public let entryType: GitTreeEntryType
    public let name: String
    public let entryOID: String

    public init(modeOctal: String, entryType: GitTreeEntryType, name: String, entryOID: String) {
        self.modeOctal = modeOctal
        self.entryType = entryType
        self.name = name
        self.entryOID = entryOID
    }
}

public struct GitAnnotatedTagObject: Sendable, Codable, Hashable, Identifiable {
    public var id: String { oid }
    public let oid: String
    public let targetOID: String
    public let targetKind: String
    public let tagName: String
    public let tagger: GitActorSignature?
    public let message: String

    public init(
        oid: String,
        targetOID: String,
        targetKind: String,
        tagName: String,
        tagger: GitActorSignature?,
        message: String
    ) {
        self.oid = oid
        self.targetOID = targetOID
        self.targetKind = targetKind
        self.tagName = tagName
        self.tagger = tagger
        self.message = message
    }
}

// MARK: - Pure-Swift `.git` Metadata, Ref & Loose-Object Reader

public struct GitRepositoryObjectInspector: Sendable {
    public init() {}

    // MARK: - `.git` Directory & Linked Worktree Pointer Resolution

    public func resolveRepositoryDirectories(at path: String) throws -> GitRepositoryDirectories {
        let fm = FileManager.default
        let stdInput = URL(fileURLWithPath: path).standardizedFileURL.path
        let dotGitCandidate = (stdInput as NSString).appendingPathComponent(".git")

        var isDir: ObjCBool = false
        if fm.fileExists(atPath: dotGitCandidate, isDirectory: &isDir) {
            if isDir.boolValue {
                return GitRepositoryDirectories(
                    workingTreePath: stdInput,
                    gitDirPath: dotGitCandidate,
                    commonGitDirPath: dotGitCandidate,
                    isLinkedWorktree: false,
                    isBareRepository: false
                )
            } else {
                // Linked worktree `.git` pointer file: `gitdir: /path/to/repo/.git/worktrees/lane-xyz`
                let rawPointer = try String(contentsOfFile: dotGitCandidate, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard rawPointer.hasPrefix("gitdir:") else {
                    throw RelayIDEError.gitRepositoryNotFound(path)
                }
                let rawGitDir = String(rawPointer.dropFirst("gitdir:".count)).trimmingCharacters(in: .whitespaces)
                let resolvedGitDir = Self.resolvePossiblyRelativePath(rawGitDir, relativeTo: stdInput)
                let commonDir = Self.resolveCommonDir(forGitDir: resolvedGitDir)
                return GitRepositoryDirectories(
                    workingTreePath: stdInput,
                    gitDirPath: resolvedGitDir,
                    commonGitDirPath: commonDir,
                    isLinkedWorktree: true,
                    isBareRepository: false
                )
            }
        }

        // Check if `stdInput` itself is a `.git` or bare repository directory
        let headFile = (stdInput as NSString).appendingPathComponent("HEAD")
        if fm.fileExists(atPath: headFile) {
            let commonDir = Self.resolveCommonDir(forGitDir: stdInput)
            let isWorktreeAdmin = commonDir != stdInput
            return GitRepositoryDirectories(
                workingTreePath: nil,
                gitDirPath: stdInput,
                commonGitDirPath: commonDir,
                isLinkedWorktree: isWorktreeAdmin,
                isBareRepository: !isWorktreeAdmin
            )
        }

        throw RelayIDEError.gitRepositoryNotFound(path)
    }

    // MARK: - `HEAD`, `refs/*`, `packed-refs` & `.git/worktrees/*` Readers

    public func readHEAD(at repositoryOrWorktreePath: String) throws -> GitInspectedHEAD {
        let dirs = try resolveRepositoryDirectories(at: repositoryOrWorktreePath)
        let refMap = try buildReferenceLookupMap(commonGitDir: dirs.commonGitDirPath)
        return try readHEADFile(
            atFilePath: (dirs.gitDirPath as NSString).appendingPathComponent("HEAD"),
            commonGitDir: dirs.commonGitDirPath,
            refLookup: refMap
        )
    }

    public func listAllReferences(at repositoryOrWorktreePath: String) throws -> [GitReferenceRecord] {
        let dirs = try resolveRepositoryDirectories(at: repositoryOrWorktreePath)
        let packed = parsePackedRefs(commonGitDir: dirs.commonGitDirPath)
        let loose = scanLooseRefs(commonGitDir: dirs.commonGitDirPath)

        var mergedByRef: [String: GitReferenceRecord] = [:]
        for p in packed {
            mergedByRef[p.fullRefName] = p
        }
        // Loose refs override `packed-refs` entries per Git ref resolution rules
        for (refName, rawValue) in loose {
            let oid = resolveSymbolicOrDirectRefValue(rawValue, looseMap: loose, packedMap: mergedByRef, depth: 0)
            guard Self.looksLikeHexOID(oid) else { continue }
            mergedByRef[refName] = Self.makeReferenceRecord(
                fullRefName: refName,
                targetOID: oid,
                peeledOID: nil,
                isPackedOnly: false
            )
        }

        return mergedByRef.values.sorted { $0.fullRefName < $1.fullRefName }
    }

    /// Reads the primary repository worktree AND all `.git/worktrees/*` entries directly from disk without spawning `git`.
    public func inspectWorktrees(at repositoryOrWorktreePath: String) throws -> [InspectedGitWorktreeRecord] {
        let dirs = try resolveRepositoryDirectories(at: repositoryOrWorktreePath)
        let commonDir = dirs.commonGitDirPath
        let refLookup = try buildReferenceLookupMap(commonGitDir: commonDir)
        let fm = FileManager.default
        var results: [InspectedGitWorktreeRecord] = []

        // 1. Main worktree (parent of `.git` when non-bare)
        let mainHeadPath = (commonDir as NSString).appendingPathComponent("HEAD")
        if fm.fileExists(atPath: mainHeadPath) {
            let mainRoot: String
            if (commonDir as NSString).lastPathComponent == ".git" {
                mainRoot = (commonDir as NSString).deletingLastPathComponent
            } else {
                mainRoot = dirs.workingTreePath ?? commonDir
            }
            let mainHead = try readHEADFile(atFilePath: mainHeadPath, commonGitDir: commonDir, refLookup: refLookup)
            results.append(
                InspectedGitWorktreeRecord(
                    worktreeName: "main",
                    workingDirectoryPath: mainRoot,
                    adminGitDirPath: commonDir,
                    head: mainHead,
                    isMainWorktree: true,
                    isLocked: false,
                    lockReason: nil,
                    workingDirectoryExistsOnDisk: fm.fileExists(atPath: mainRoot)
                )
            )
        }

        // 2. Linked worktrees under `<commonGitDir>/worktrees/<name>`
        let worktreesAdminRoot = (commonDir as NSString).appendingPathComponent("worktrees")
        if let entries = try? fm.contentsOfDirectory(atPath: worktreesAdminRoot).sorted() {
            for name in entries {
                let wtAdminDir = (worktreesAdminRoot as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: wtAdminDir, isDirectory: &isDir), isDir.boolValue else {
                    continue
                }

                let headFile = (wtAdminDir as NSString).appendingPathComponent("HEAD")
                let gitdirFile = (wtAdminDir as NSString).appendingPathComponent("gitdir")
                let lockedFile = (wtAdminDir as NSString).appendingPathComponent("locked")
                guard fm.fileExists(atPath: headFile), fm.fileExists(atPath: gitdirFile) else {
                    continue
                }

                let rawGitdirTarget = (try? String(contentsOfFile: gitdirFile, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let resolvedDotGitFile = Self.resolvePossiblyRelativePath(rawGitdirTarget, relativeTo: wtAdminDir)
                let wtWorkingRoot = (resolvedDotGitFile as NSString).lastPathComponent == ".git"
                    ? (resolvedDotGitFile as NSString).deletingLastPathComponent
                    : resolvedDotGitFile

                let head = (try? readHEADFile(atFilePath: headFile, commonGitDir: commonDir, refLookup: refLookup))
                    ?? .detached(commitOID: "")

                let isLocked = fm.fileExists(atPath: lockedFile)
                let lockReason: String?
                if isLocked {
                    let reason = (try? String(contentsOfFile: lockedFile, encoding: .utf8))?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    lockReason = (reason?.isEmpty == false) ? reason : nil
                } else {
                    lockReason = nil
                }

                results.append(
                    InspectedGitWorktreeRecord(
                        worktreeName: name,
                        workingDirectoryPath: wtWorkingRoot,
                        adminGitDirPath: wtAdminDir,
                        head: head,
                        isMainWorktree: false,
                        isLocked: isLocked,
                        lockReason: lockReason,
                        workingDirectoryExistsOnDisk: fm.fileExists(atPath: wtWorkingRoot)
                    )
                )
            }
        }

        return results
    }

    // MARK: - Loose Git Object Zlib Inflater & Commit / Tree / Tag Parsers

    public func readLooseObject(at repositoryOrWorktreePath: String, oid: String) throws -> GitRawLooseObject {
        let dirs = try resolveRepositoryDirectories(at: repositoryOrWorktreePath)
        return try readLooseObjectFromCommonGitDir(dirs.commonGitDirPath, oid: oid)
    }

    public func readCommitObject(at repositoryOrWorktreePath: String, commitOID: String) throws -> GitInspectedCommitObject {
        let raw = try readLooseObject(at: repositoryOrWorktreePath, oid: commitOID)
        guard raw.kind == .commit else {
            throw RelayIDEError.gitPlumbingFailure(
                command: "loose-object commit \(commitOID)",
                exitCode: 1,
                stderr: "Expected commit object, found '\(raw.kind.rawValue)'"
            )
        }
        return try parseCommitPayload(oid: raw.oid, payload: raw.payload)
    }

    public func readTreeEntries(at repositoryOrWorktreePath: String, treeOID: String) throws -> [GitTreeEntryRecord] {
        let raw = try readLooseObject(at: repositoryOrWorktreePath, oid: treeOID)
        guard raw.kind == .tree else {
            throw RelayIDEError.gitPlumbingFailure(
                command: "loose-object tree \(treeOID)",
                exitCode: 1,
                stderr: "Expected tree object, found '\(raw.kind.rawValue)'"
            )
        }
        return parseTreePayload(raw.payload)
    }

    public func readAnnotatedTag(at repositoryOrWorktreePath: String, tagOID: String) throws -> GitAnnotatedTagObject {
        let raw = try readLooseObject(at: repositoryOrWorktreePath, oid: tagOID)
        guard raw.kind == .tag else {
            throw RelayIDEError.gitPlumbingFailure(
                command: "loose-object tag \(tagOID)",
                exitCode: 1,
                stderr: "Expected tag object, found '\(raw.kind.rawValue)'"
            )
        }
        return parseAnnotatedTagPayload(oid: raw.oid, payload: raw.payload)
    }

    /// Walks loose commit objects starting from `startOIDs` up to `maxCommits` without invoking external `git`.
    public func walkLooseCommitGraph(
        at repositoryOrWorktreePath: String,
        fromOIDs startOIDs: [String]? = nil,
        maxCommits: Int = 200
    ) throws -> [GitInspectedCommitObject] {
        let dirs = try resolveRepositoryDirectories(at: repositoryOrWorktreePath)
        let seeds: [String]
        if let explicit = startOIDs, !explicit.isEmpty {
            seeds = explicit
        } else {
            let refs = try listAllReferences(at: repositoryOrWorktreePath)
            var discovered = refs.map(\.effectiveCommitOID)
            if let headOID = (try? readHEAD(at: repositoryOrWorktreePath))?.resolvedCommitOID {
                discovered.insert(headOID, at: 0)
            }
            seeds = discovered
        }

        var visited = Set<String>()
        var queue: [String] = seeds.filter { Self.looksLikeHexOID($0) }
        var commits: [GitInspectedCommitObject] = []

        var qIdx = 0
        while qIdx < queue.count && commits.count < maxCommits {
            let oid = queue[qIdx]
            qIdx += 1
            guard visited.insert(oid).inserted else { continue }
            guard let raw = try? readLooseObjectFromCommonGitDir(dirs.commonGitDirPath, oid: oid),
                  raw.kind == .commit,
                  let commit = try? parseCommitPayload(oid: raw.oid, payload: raw.payload) else {
                continue
            }
            commits.append(commit)
            for parent in commit.parentOIDs where !visited.contains(parent) {
                queue.append(parent)
            }
        }

        return commits
    }

    /// Parses a raw Git `commit` object payload (`tree`, `parent`*, `author`, `committer`, `gpgsig`, message).
    public func parseCommitPayload(oid: String, payload: Data) throws -> GitInspectedCommitObject {
        let text = String(decoding: payload, as: UTF8.self)
        let splitIdx = text.range(of: "\n\n")
        let headerPart = splitIdx != nil ? String(text[..<splitIdx!.lowerBound]) : text
        let rawMessage = splitIdx != nil ? String(text[splitIdx!.upperBound...]) : ""

        var treeOID = ""
        var parents: [String] = []
        var authorSig = GitActorSignature(name: "Unknown", email: "", timestamp: Date(timeIntervalSince1970: 0), timezoneOffsetMinutes: 0, rawTimezone: "+0000")
        var committerSig = authorSig
        var encoding: String?
        var gpgLines: [String]?

        let headerLines = headerPart.components(separatedBy: "\n")
        var idx = 0
        while idx < headerLines.count {
            let line = headerLines[idx]
            if line.hasPrefix("tree ") {
                treeOID = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("parent ") {
                parents.append(String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("author ") {
                authorSig = Self.parseActorSignature(String(line.dropFirst(7)))
            } else if line.hasPrefix("committer ") {
                committerSig = Self.parseActorSignature(String(line.dropFirst(10)))
            } else if line.hasPrefix("encoding ") {
                encoding = String(line.dropFirst(9)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("gpgsig ") {
                var sig = [String(line.dropFirst(7))]
                while idx + 1 < headerLines.count && headerLines[idx + 1].hasPrefix(" ") {
                    idx += 1
                    sig.append(String(headerLines[idx].dropFirst()))
                }
                gpgLines = sig
            } else {
                // Skip any other multi-line continuation headers (e.g. `mergetag`)
                while idx + 1 < headerLines.count && headerLines[idx + 1].hasPrefix(" ") {
                    idx += 1
                }
            }
            idx += 1
        }

        let trimmedMessage = rawMessage.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        let firstNewline = trimmedMessage.firstIndex(of: "\n")
        let subject = firstNewline != nil ? String(trimmedMessage[..<firstNewline!]) : trimmedMessage
        let body = firstNewline != nil
            ? String(trimmedMessage[trimmedMessage.index(after: firstNewline!)...]).trimmingCharacters(in: .newlines)
            : ""

        return GitInspectedCommitObject(
            oid: oid,
            treeOID: treeOID,
            parentOIDs: parents,
            author: authorSig,
            committer: committerSig,
            encoding: encoding,
            gpgSignature: gpgLines?.joined(separator: "\n"),
            subject: subject,
            messageBody: body,
            fullMessage: trimmedMessage
        )
    }

    /// Parses binary Git `tree` object entries (`<mode> <name>\0<20-byte-oid>`).
    public func parseTreePayload(_ payload: Data) -> [GitTreeEntryRecord] {
        let bytes = Array(payload)
        var entries: [GitTreeEntryRecord] = []
        var pos = 0

        while pos < bytes.count {
            guard let spaceIdx = bytes[pos...].firstIndex(of: 0x20),
                  let nulIdx = bytes[(spaceIdx + 1)...].firstIndex(of: 0x00),
                  nulIdx + 20 < bytes.count else {
                break
            }

            let modeStr = String(decoding: bytes[pos..<spaceIdx], as: UTF8.self)
            let nameStr = String(decoding: bytes[(spaceIdx + 1)..<nulIdx], as: UTF8.self)
            let oidBytes = bytes[(nulIdx + 1)...(nulIdx + 20)]
            let hexOID = oidBytes.map { String(format: "%02x", $0) }.joined()

            let entryType: GitTreeEntryType
            switch modeStr {
            case "40000", "040000": entryType = .directoryTree
            case "100755":          entryType = .executableFile
            case "120000":          entryType = .symbolicLink
            case "160000":          entryType = .gitlinkSubmodule
            default:                entryType = .regularFile
            }

            entries.append(
                GitTreeEntryRecord(
                    modeOctal: modeStr,
                    entryType: entryType,
                    name: nameStr,
                    entryOID: hexOID
                )
            )
            pos = nulIdx + 21
        }
        return entries
    }

    public func parseAnnotatedTagPayload(oid: String, payload: Data) -> GitAnnotatedTagObject {
        let text = String(decoding: payload, as: UTF8.self)
        let splitIdx = text.range(of: "\n\n")
        let headerPart = splitIdx != nil ? String(text[..<splitIdx!.lowerBound]) : text
        let msg = splitIdx != nil ? String(text[splitIdx!.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines) : ""

        var targetOID = ""
        var targetKind = "commit"
        var tagName = ""
        var tagger: GitActorSignature?

        for line in headerPart.components(separatedBy: "\n") {
            if line.hasPrefix("object ") {
                targetOID = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("type ") {
                targetKind = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("tag ") {
                tagName = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("tagger ") {
                tagger = Self.parseActorSignature(String(line.dropFirst(7)))
            }
        }

        return GitAnnotatedTagObject(
            oid: oid,
            targetOID: targetOID,
            targetKind: targetKind,
            tagName: tagName,
            tagger: tagger,
            message: msg
        )
    }

    // MARK: - Internal Loose Object Zlib Decompressor & Ref Helpers

    private func readLooseObjectFromCommonGitDir(_ commonGitDir: String, oid: String) throws -> GitRawLooseObject {
        let cleanOID = oid.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard cleanOID.count >= 4 else {
            throw RelayIDEError.gitPlumbingFailure(command: "readLooseObject", exitCode: 1, stderr: "Invalid short OID '\(oid)'")
        }

        let fanoutDir = String(cleanOID.prefix(2))
        let restPrefix = String(cleanOID.dropFirst(2))
        let objectsSubdir = ((commonGitDir as NSString).appendingPathComponent("objects") as NSString)
            .appendingPathComponent(fanoutDir)

        var resolvedFullOID = cleanOID
        var objectFilePath = (objectsSubdir as NSString).appendingPathComponent(restPrefix)

        if !FileManager.default.fileExists(atPath: objectFilePath), cleanOID.count < 40 {
            // Support abbreviated SHA prefix lookup in `.git/objects/<xx>/`
            if let candidates = try? FileManager.default.contentsOfDirectory(atPath: objectsSubdir) {
                let matching = candidates.filter { $0.lowercased().hasPrefix(restPrefix) }
                if matching.count == 1 {
                    objectFilePath = (objectsSubdir as NSString).appendingPathComponent(matching[0])
                    resolvedFullOID = fanoutDir + matching[0].lowercased()
                }
            }
        }

        guard FileManager.default.fileExists(atPath: objectFilePath) else {
            throw RelayIDEError.gitPlumbingFailure(
                command: "loose-object \(cleanOID)",
                exitCode: 1,
                stderr: "Loose object file not found (object may reside in a packfile or missing)"
            )
        }

        let compressed = try Data(contentsOf: URL(fileURLWithPath: objectFilePath))
        let inflated = try Self.inflateRFC1950ZlibStream(compressed)

        guard let nulIndex = inflated.firstIndex(of: 0x00) else {
            throw RelayIDEError.gitPlumbingFailure(
                command: "loose-object \(resolvedFullOID)",
                exitCode: 1,
                stderr: "Corrupt Git loose object: missing NUL header separator"
            )
        }

        let headerStr = String(decoding: inflated[..<nulIndex], as: UTF8.self)
        let headerParts = headerStr.split(separator: " ", maxSplits: 1)
        guard headerParts.count == 2,
              let kind = GitLooseObjectKind(rawValue: String(headerParts[0])),
              let size = Int(headerParts[1]) else {
            throw RelayIDEError.gitPlumbingFailure(
                command: "loose-object \(resolvedFullOID)",
                exitCode: 1,
                stderr: "Malformed Git object header '\(headerStr)'"
            )
        }

        let payloadStart = inflated.index(after: nulIndex)
        let payload = Data(inflated[payloadStart...])
        return GitRawLooseObject(oid: resolvedFullOID, kind: kind, declaredSize: size, payload: payload)
    }

    /// Inflates an RFC 1950 zlib-wrapped stream (2-byte CMF/FLG header + RFC 1951 DEFLATE + 4-byte Adler-32 checksum) using Apple's `Compression` streaming decoder.
    public static func inflateRFC1950ZlibStream(_ data: Data) throws -> Data {
        let bytes = Array(data)
        guard bytes.count >= 6 else {
            throw RelayIDEError.gitPlumbingFailure(command: "zlib-inflate", exitCode: 1, stderr: "Truncated zlib stream (< 6 bytes)")
        }

        let cmf = bytes[0]
        let flg = bytes[1]
        let headerCheck = (UInt16(cmf) << 8) | UInt16(flg)
        guard (cmf & 0x0F) == 8, headerCheck % 31 == 0 else {
            throw RelayIDEError.gitPlumbingFailure(command: "zlib-inflate", exitCode: 1, stderr: "Invalid RFC 1950 zlib header")
        }

        let deflateStart = ((flg & 0x20) != 0) ? 6 : 2
        let deflateEnd = bytes.count - 4
        guard deflateStart <= deflateEnd else {
            throw RelayIDEError.gitPlumbingFailure(command: "zlib-inflate", exitCode: 1, stderr: "Empty DEFLATE body in zlib stream")
        }

        let rawDeflate = Array(bytes[deflateStart..<deflateEnd])
        let expectedAdler = (UInt32(bytes[deflateEnd]) << 24)
            | (UInt32(bytes[deflateEnd + 1]) << 16)
            | (UInt32(bytes[deflateEnd + 2]) << 8)
            | UInt32(bytes[deflateEnd + 3])

        // Stream decode raw RFC 1951 DEFLATE via `compression_stream` (`COMPRESSION_ZLIB`)
        let dummyPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        dummyPtr.initialize(to: 0)
        defer { dummyPtr.deallocate() }

        var stream = compression_stream(
            dst_ptr: dummyPtr,
            dst_size: 0,
            src_ptr: UnsafePointer(dummyPtr),
            src_size: 0,
            state: nil
        )
        let initStatus = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
        guard initStatus != COMPRESSION_STATUS_ERROR else {
            throw RelayIDEError.gitPlumbingFailure(command: "zlib-inflate", exitCode: 1, stderr: "compression_stream_init failed")
        }
        defer { compression_stream_destroy(&stream) }

        let chunkSize = 32_768
        let dstChunk = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { dstChunk.deallocate() }

        var decompressed = Data()
        decompressed.reserveCapacity(rawDeflate.count * 3)

        try rawDeflate.withUnsafeBufferPointer { srcBuf in
            guard let srcBase = srcBuf.baseAddress else { return }
            stream.src_ptr = srcBase
            stream.src_size = srcBuf.count

            while true {
                stream.dst_ptr = dstChunk
                stream.dst_size = chunkSize

                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunkSize - stream.dst_size
                if produced > 0 {
                    decompressed.append(dstChunk, count: produced)
                }

                switch status {
                case COMPRESSION_STATUS_END:
                    return
                case COMPRESSION_STATUS_OK:
                    if produced == 0 && stream.src_size == 0 {
                        return
                    }
                default:
                    throw RelayIDEError.gitPlumbingFailure(command: "zlib-inflate", exitCode: 1, stderr: "DEFLATE stream decode error")
                }
            }
        }

        let actualAdler = computeAdler32(decompressed)
        guard actualAdler == expectedAdler else {
            throw RelayIDEError.gitPlumbingFailure(
                command: "zlib-inflate",
                exitCode: 1,
                stderr: String(format: "Adler-32 checksum mismatch (0x%08x != 0x%08x)", actualAdler, expectedAdler)
            )
        }
        return decompressed
    }

    public static func computeAdler32(_ data: Data) -> UInt32 {
        let modAdler: UInt32 = 65_521
        var s1: UInt32 = 1
        var s2: UInt32 = 0
        for b in data {
            s1 = (s1 + UInt32(b)) % modAdler
            s2 = (s2 + s1) % modAdler
        }
        return (s2 << 16) | s1
    }

    private static func parseActorSignature(_ raw: String) -> GitActorSignature {
        // Format: `Author Name <author@domain.tld> 1731485141 +1300`
        guard let openAngle = raw.firstIndex(of: "<"),
              let closeAngle = raw[openAngle...].firstIndex(of: ">") else {
            return GitActorSignature(
                name: raw.trimmingCharacters(in: .whitespaces),
                email: "",
                timestamp: Date(timeIntervalSince1970: 0),
                timezoneOffsetMinutes: 0,
                rawTimezone: "+0000"
            )
        }

        let name = String(raw[..<openAngle]).trimmingCharacters(in: .whitespaces)
        let email = String(raw[raw.index(after: openAngle)..<closeAngle]).trimmingCharacters(in: .whitespaces)
        let tail = String(raw[raw.index(after: closeAngle)...]).trimmingCharacters(in: .whitespaces)
        let parts = tail.split(separator: " ")

        let epoch = parts.first.flatMap { TimeInterval($0) } ?? 0.0
        let tzRaw = parts.count >= 2 ? String(parts[1]) : "+0000"
        let tzMinutes = parseTimezoneMinutes(tzRaw)

        return GitActorSignature(
            name: name,
            email: email,
            timestamp: Date(timeIntervalSince1970: epoch),
            timezoneOffsetMinutes: tzMinutes,
            rawTimezone: tzRaw
        )
    }

    private static func parseTimezoneMinutes(_ tz: String) -> Int {
        guard tz.count == 5, (tz.hasPrefix("+") || tz.hasPrefix("-")) else { return 0 }
        let sign = tz.hasPrefix("-") ? -1 : 1
        let digits = tz.dropFirst()
        let hh = Int(digits.prefix(2)) ?? 0
        let mm = Int(digits.suffix(2)) ?? 0
        return sign * (hh * 60 + mm)
    }

    private func readHEADFile(
        atFilePath headFilePath: String,
        commonGitDir: String,
        refLookup: [String: String]
    ) throws -> GitInspectedHEAD {
        let raw = try String(contentsOfFile: headFilePath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("ref:") {
            let refName = String(raw.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            let targetOID = refLookup[refName] ?? readSingleLooseRef(commonGitDir: commonGitDir, refName: refName)
            return .symbolic(refName: refName, targetOID: targetOID)
        }
        return .detached(commitOID: raw)
    }

    private func buildReferenceLookupMap(commonGitDir: String) throws -> [String: String] {
        let packed = parsePackedRefs(commonGitDir: commonGitDir)
        let loose = scanLooseRefs(commonGitDir: commonGitDir)
        var packedMap: [String: GitReferenceRecord] = [:]
        var out: [String: String] = [:]
        for p in packed {
            packedMap[p.fullRefName] = p
            out[p.fullRefName] = p.targetOID
        }
        for (refName, rawVal) in loose {
            let resolved = resolveSymbolicOrDirectRefValue(rawVal, looseMap: loose, packedMap: packedMap, depth: 0)
            if Self.looksLikeHexOID(resolved) {
                out[refName] = resolved
            }
        }
        return out
    }

    private func readSingleLooseRef(commonGitDir: String, refName: String) -> String? {
        let full = (commonGitDir as NSString).appendingPathComponent(refName)
        guard let content = try? String(contentsOfFile: full, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        return Self.looksLikeHexOID(content) ? content : nil
    }

    private func scanLooseRefs(commonGitDir: String) -> [String: String] {
        let refsRoot = (commonGitDir as NSString).appendingPathComponent("refs")
        guard let enumerator = FileManager.default.enumerator(atPath: refsRoot) else {
            return [:]
        }
        var out: [String: String] = [:]
        while let rel = enumerator.nextObject() as? String {
            let absPath = (refsRoot as NSString).appendingPathComponent(rel)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: absPath, isDirectory: &isDir), !isDir.boolValue {
                if let val = try? String(contentsOfFile: absPath, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !val.isEmpty {
                    out["refs/\(rel)"] = val
                }
            }
        }
        return out
    }

    private func parsePackedRefs(commonGitDir: String) -> [GitReferenceRecord] {
        let packedPath = (commonGitDir as NSString).appendingPathComponent("packed-refs")
        guard let raw = try? String(contentsOfFile: packedPath, encoding: .utf8) else {
            return []
        }

        var records: [GitReferenceRecord] = []
        for rawLine in raw.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            // Peeled tag target line `^<commitOID>` applies to the preceding tag record
            if line.hasPrefix("^"), !records.isEmpty {
                let peeled = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                if Self.looksLikeHexOID(peeled) {
                    let prev = records.removeLast()
                    records.append(
                        GitReferenceRecord(
                            fullRefName: prev.fullRefName,
                            shortName: prev.shortName,
                            namespace: prev.namespace,
                            targetOID: prev.targetOID,
                            peeledTagCommitOID: peeled,
                            isPackedOnly: true
                        )
                    )
                }
                continue
            }

            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let oid = String(parts[0])
            let refName = String(parts[1])
            guard Self.looksLikeHexOID(oid) else { continue }
            records.append(Self.makeReferenceRecord(fullRefName: refName, targetOID: oid, peeledOID: nil, isPackedOnly: true))
        }
        return records
    }

    private func resolveSymbolicOrDirectRefValue(
        _ rawValue: String,
        looseMap: [String: String],
        packedMap: [String: GitReferenceRecord],
        depth: Int
    ) -> String {
        guard depth < 8 else { return "" }
        if rawValue.hasPrefix("ref:") {
            let targetRef = String(rawValue.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            if let nextLoose = looseMap[targetRef] {
                return resolveSymbolicOrDirectRefValue(nextLoose, looseMap: looseMap, packedMap: packedMap, depth: depth + 1)
            }
            return packedMap[targetRef]?.targetOID ?? ""
        }
        return rawValue
    }

    private static func makeReferenceRecord(
        fullRefName: String,
        targetOID: String,
        peeledOID: String?,
        isPackedOnly: Bool
    ) -> GitReferenceRecord {
        if fullRefName.hasPrefix("refs/heads/") {
            return GitReferenceRecord(
                fullRefName: fullRefName,
                shortName: String(fullRefName.dropFirst("refs/heads/".count)),
                namespace: .localBranch,
                targetOID: targetOID,
                peeledTagCommitOID: peeledOID,
                isPackedOnly: isPackedOnly
            )
        }
        if fullRefName.hasPrefix("refs/remotes/") {
            return GitReferenceRecord(
                fullRefName: fullRefName,
                shortName: String(fullRefName.dropFirst("refs/remotes/".count)),
                namespace: .remoteTracking,
                targetOID: targetOID,
                peeledTagCommitOID: peeledOID,
                isPackedOnly: isPackedOnly
            )
        }
        if fullRefName.hasPrefix("refs/tags/") {
            return GitReferenceRecord(
                fullRefName: fullRefName,
                shortName: String(fullRefName.dropFirst("refs/tags/".count)),
                namespace: .tag,
                targetOID: targetOID,
                peeledTagCommitOID: peeledOID,
                isPackedOnly: isPackedOnly
            )
        }
        return GitReferenceRecord(
            fullRefName: fullRefName,
            shortName: fullRefName,
            namespace: .other,
            targetOID: targetOID,
            peeledTagCommitOID: peeledOID,
            isPackedOnly: isPackedOnly
        )
    }

    private static func resolvePossiblyRelativePath(_ candidate: String, relativeTo baseDir: String) -> String {
        if candidate.hasPrefix("/") {
            return URL(fileURLWithPath: candidate).standardizedFileURL.path
        }
        return URL(fileURLWithPath: baseDir).appendingPathComponent(candidate).standardizedFileURL.path
    }

    private static func resolveCommonDir(forGitDir gitDir: String) -> String {
        let commonDirFile = (gitDir as NSString).appendingPathComponent("commondir")
        guard let rel = try? String(contentsOfFile: commonDirFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rel.isEmpty else {
            return gitDir
        }
        return resolvePossiblyRelativePath(rel, relativeTo: gitDir)
    }

    private static func looksLikeHexOID(_ s: String) -> Bool {
        guard s.count == 40 || s.count == 64 else { return false }
        return s.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 0x30 && scalar.value <= 0x39)
                || (scalar.value >= 0x61 && scalar.value <= 0x66)
                || (scalar.value >= 0x41 && scalar.value <= 0x46)
        }
    }
}

// MARK: - Commit DAG Ahead/Behind Divergence, Merge-Base & Topological Ancestry Calculator

public enum GitBranchDivergenceRelation: String, Sendable, Codable, Hashable {
    case identical = "IDENTICAL"
    case fastForwardAhead = "AHEAD_ONLY"
    case fastForwardBehind = "BEHIND_ONLY"
    case diverged = "DIVERGED"
    case unrelatedHistories = "UNRELATED"
}

public struct GitAheadBehindDivergence: Sendable, Codable, Hashable {
    public let localOID: String
    public let upstreamOID: String
    public let aheadCount: Int
    public let behindCount: Int
    public let aheadCommitOIDs: [String]
    public let behindCommitOIDs: [String]
    public let mergeBaseOIDs: [String]
    public let relation: GitBranchDivergenceRelation

    public init(
        localOID: String,
        upstreamOID: String,
        aheadCommitOIDs: [String],
        behindCommitOIDs: [String],
        mergeBaseOIDs: [String],
        relation: GitBranchDivergenceRelation
    ) {
        self.localOID = localOID
        self.upstreamOID = upstreamOID
        self.aheadCount = aheadCommitOIDs.count
        self.behindCount = behindCommitOIDs.count
        self.aheadCommitOIDs = aheadCommitOIDs
        self.behindCommitOIDs = behindCommitOIDs
        self.mergeBaseOIDs = mergeBaseOIDs
        self.relation = relation
    }
}

public struct GitGraphSwimlaneRow: Sendable, Codable, Hashable, Identifiable {
    public var id: String { commit.oid }
    public let commit: GitCommitNode
    public let topologicalIndex: Int
    public let activeColumn: Int
    public let totalActiveColumns: Int
    public let parentEdges: [(parentOID: String, targetColumn: Int)]

    public init(
        commit: GitCommitNode,
        topologicalIndex: Int,
        activeColumn: Int,
        totalActiveColumns: Int,
        parentEdges: [(parentOID: String, targetColumn: Int)]
    ) {
        self.commit = commit
        self.topologicalIndex = topologicalIndex
        self.activeColumn = activeColumn
        self.totalActiveColumns = totalActiveColumns
        self.parentEdges = parentEdges
    }

    public static func == (lhs: GitGraphSwimlaneRow, rhs: GitGraphSwimlaneRow) -> Bool {
        lhs.commit == rhs.commit
            && lhs.topologicalIndex == rhs.topologicalIndex
            && lhs.activeColumn == rhs.activeColumn
            && lhs.totalActiveColumns == rhs.totalActiveColumns
            && lhs.parentEdges.count == rhs.parentEdges.count
            && zip(lhs.parentEdges, rhs.parentEdges).allSatisfy { $0.parentOID == $1.parentOID && $0.targetColumn == $1.targetColumn }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(commit)
        hasher.combine(topologicalIndex)
        hasher.combine(activeColumn)
        hasher.combine(totalActiveColumns)
        for edge in parentEdges {
            hasher.combine(edge.parentOID)
            hasher.combine(edge.targetColumn)
        }
    }

    enum CodingKeys: String, CodingKey {
        case commit
        case topologicalIndex
        case activeColumn
        case totalActiveColumns
        case parentOIDs
        case targetColumns
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.commit = try c.decode(GitCommitNode.self, forKey: .commit)
        self.topologicalIndex = try c.decode(Int.self, forKey: .topologicalIndex)
        self.activeColumn = try c.decode(Int.self, forKey: .activeColumn)
        self.totalActiveColumns = try c.decode(Int.self, forKey: .totalActiveColumns)
        let pOIDs = try c.decode([String].self, forKey: .parentOIDs)
        let cols = try c.decode([Int].self, forKey: .targetColumns)
        self.parentEdges = Array(zip(pOIDs, cols)).map { ($0.0, $0.1) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(commit, forKey: .commit)
        try c.encode(topologicalIndex, forKey: .topologicalIndex)
        try c.encode(activeColumn, forKey: .activeColumn)
        try c.encode(totalActiveColumns, forKey: .totalActiveColumns)
        try c.encode(parentEdges.map(\.parentOID), forKey: .parentOIDs)
        try c.encode(parentEdges.map(\.targetColumn), forKey: .targetColumns)
    }
}

public struct GitCommitDAGAnalyzer: Sendable {
    private let nodesByOID: [String: GitCommitNode]

    public init(commits: [GitCommitNode]) {
        var map: [String: GitCommitNode] = [:]
        map.reserveCapacity(commits.count)
        for node in commits {
            map[node.oid] = node
        }
        self.nodesByOID = map
    }

    public init(inspectedCommits: [GitInspectedCommitObject]) {
        self.init(commits: inspectedCommits.map { $0.toGitCommitNode() })
    }

    /// Returns `true` iff `ancestorOID == descendantOID` or `ancestorOID` is reachable along parent edges from `descendantOID`.
    public func isAncestor(ancestorOID: String, of descendantOID: String) -> Bool {
        if ancestorOID == descendantOID {
            return nodesByOID[ancestorOID] != nil
        }
        return reachableAncestorsWithMinDistance(from: descendantOID)[ancestorOID] != nil
    }

    /// Computes all non-dominated Lowest Common Ancestors (`git merge-base --all` semantics), handling criss-cross merges accurately.
    public func findMergeBases(leftOID: String, rightOID: String) -> [String] {
        if leftOID == rightOID {
            return nodesByOID[leftOID] != nil ? [leftOID] : []
        }

        let leftAncestors = reachableAncestorsWithMinDistance(from: leftOID)
        let rightAncestors = reachableAncestorsWithMinDistance(from: rightOID)

        let commonOIDs = Set(leftAncestors.keys).intersection(rightAncestors.keys)
        guard !commonOIDs.isEmpty else { return [] }

        // Eliminate any common ancestor `X` that is a strict ancestor of another common ancestor `Y`
        var dominated = Set<String>()
        for candidate in commonOIDs {
            // Walk strictly past `candidate` (`distance > 0`)
            if let node = nodesByOID[candidate] {
                for parent in node.parentOIDs {
                    let strictAncs = reachableAncestorsWithMinDistance(from: parent)
                    for anc in strictAncs.keys where commonOIDs.contains(anc) {
                        dominated.insert(anc)
                    }
                }
            }
        }

        let minimalCommon = commonOIDs.subtracting(dominated)
        return minimalCommon.sorted { a, b in
            let distA = (leftAncestors[a] ?? 0) + (rightAncestors[a] ?? 0)
            let distB = (leftAncestors[b] ?? 0) + (rightAncestors[b] ?? 0)
            if distA != distB { return distA < distB }
            return a < b
        }
    }

    /// Computes exact symmetric difference (`ahead` = reachable from `local` but not `upstream`; `behind` = reachable from `upstream` but not `local`).
    public func computeAheadBehind(localOID: String, upstreamOID: String) -> GitAheadBehindDivergence {
        if localOID == upstreamOID {
            let bases = nodesByOID[localOID] != nil ? [localOID] : []
            return GitAheadBehindDivergence(
                localOID: localOID,
                upstreamOID: upstreamOID,
                aheadCommitOIDs: [],
                behindCommitOIDs: [],
                mergeBaseOIDs: bases,
                relation: .identical
            )
        }

        let localSet = reachableAncestorsWithMinDistance(from: localOID)
        let upstreamSet = reachableAncestorsWithMinDistance(from: upstreamOID)
        let mergeBases = findMergeBases(leftOID: localOID, rightOID: upstreamOID)

        let aheadOIDs = localSet.keys
            .filter { upstreamSet[$0] == nil }
            .sorted { (localSet[$0] ?? 0) < (localSet[$1] ?? 0) }
        let behindOIDs = upstreamSet.keys
            .filter { localSet[$0] == nil }
            .sorted { (upstreamSet[$0] ?? 0) < (upstreamSet[$1] ?? 0) }

        let relation: GitBranchDivergenceRelation
        if mergeBases.isEmpty {
            relation = .unrelatedHistories
        } else if !aheadOIDs.isEmpty && behindOIDs.isEmpty {
            relation = .fastForwardAhead
        } else if aheadOIDs.isEmpty && !behindOIDs.isEmpty {
            relation = .fastForwardBehind
        } else if aheadOIDs.isEmpty && behindOIDs.isEmpty {
            relation = .identical
        } else {
            relation = .diverged
        }

        return GitAheadBehindDivergence(
            localOID: localOID,
            upstreamOID: upstreamOID,
            aheadCommitOIDs: aheadOIDs,
            behindCommitOIDs: behindOIDs,
            mergeBaseOIDs: mergeBases,
            relation: relation
        )
    }

    /// Orders commits topologically (children strictly before parents, newest timestamp tie-breaker) and assigns visual branch swimlane columns.
    public func buildTopologicalSwimlanes() -> [GitGraphSwimlaneRow] {
        // Compute child in-degree (number of known children referencing each commit)
        var childInDegree: [String: Int] = [:]
        for oid in nodesByOID.keys {
            childInDegree[oid] = 0
        }
        for node in nodesByOID.values {
            for p in node.parentOIDs where nodesByOID[p] != nil {
                childInDegree[p, default: 0] += 1
            }
        }

        var ready = childInDegree.filter { $0.value == 0 }.map(\.key)
        ready.sort { a, b in
            let dA = nodesByOID[a]?.authoredAt ?? .distantPast
            let dB = nodesByOID[b]?.authoredAt ?? .distantPast
            return dA != dB ? (dA > dB) : (a < b)
        }

        var topoCommits: [GitCommitNode] = []
        topoCommits.reserveCapacity(nodesByOID.count)

        while !ready.isEmpty {
            let currentOID = ready.removeFirst()
            guard let node = nodesByOID[currentOID] else { continue }
            topoCommits.append(node)

            for p in node.parentOIDs where nodesByOID[p] != nil {
                let rem = (childInDegree[p] ?? 1) - 1
                childInDegree[p] = rem
                if rem == 0 {
                    ready.append(p)
                }
            }
            ready.sort { a, b in
                let dA = nodesByOID[a]?.authoredAt ?? .distantPast
                let dB = nodesByOID[b]?.authoredAt ?? .distantPast
                return dA != dB ? (dA > dB) : (a < b)
            }
        }

        // Assign parallel swimlane column slots top-down
        var activeSlots: [String?] = []
        var rows: [GitGraphSwimlaneRow] = []
        rows.reserveCapacity(topoCommits.count)

        for (idx, commit) in topoCommits.enumerated() {
            let col: Int
            if let existingCol = activeSlots.firstIndex(of: commit.oid) {
                col = existingCol
                // Collapse duplicate reservations pointing at the same merge parent
                for otherIdx in (existingCol + 1)..<activeSlots.count where activeSlots[otherIdx] == commit.oid {
                    activeSlots[otherIdx] = nil
                }
            } else if let freeCol = activeSlots.firstIndex(where: { $0 == nil }) {
                col = freeCol
                activeSlots[freeCol] = commit.oid
            } else {
                col = activeSlots.count
                activeSlots.append(commit.oid)
            }

            let knownParents = commit.parentOIDs.filter { nodesByOID[$0] != nil }
            var parentEdges: [(parentOID: String, targetColumn: Int)] = []

            if knownParents.isEmpty {
                activeSlots[col] = nil
            } else {
                // First parent continues straight down `col` unless already tracked in an earlier column
                let firstParent = knownParents[0]
                if let alreadyCol = activeSlots.firstIndex(of: firstParent) {
                    activeSlots[col] = nil
                    parentEdges.append((firstParent, alreadyCol))
                } else {
                    activeSlots[col] = firstParent
                    parentEdges.append((firstParent, col))
                }

                // Secondary merge parents reserve side columns
                for mergeParent in knownParents.dropFirst() {
                    if let existingParentCol = activeSlots.firstIndex(of: mergeParent) {
                        parentEdges.append((mergeParent, existingParentCol))
                    } else if let freeSlot = activeSlots.firstIndex(where: { $0 == nil }) {
                        activeSlots[freeSlot] = mergeParent
                        parentEdges.append((mergeParent, freeSlot))
                    } else {
                        let newCol = activeSlots.count
                        activeSlots.append(mergeParent)
                        parentEdges.append((mergeParent, newCol))
                    }
                }
            }

            while activeSlots.last == .some(nil) {
                activeSlots.removeLast()
            }

            rows.append(
                GitGraphSwimlaneRow(
                    commit: commit,
                    topologicalIndex: idx,
                    activeColumn: col,
                    totalActiveColumns: max(1, activeSlots.count),
                    parentEdges: parentEdges
                )
            )
        }

        return rows
    }

    private func reachableAncestorsWithMinDistance(from startOID: String) -> [String: Int] {
        guard nodesByOID[startOID] != nil else { return [:] }
        var dist: [String: Int] = [startOID: 0]
        var queue: [String] = [startOID]
        var head = 0

        while head < queue.count {
            let cur = queue[head]
            head += 1
            let curDist = dist[cur] ?? 0
            guard let node = nodesByOID[cur] else { continue }
            for parent in node.parentOIDs where nodesByOID[parent] != nil {
                if dist[parent] == nil {
                    dist[parent] = curDist + 1
                    queue.append(parent)
                }
            }
        }
        return dist
    }
}
