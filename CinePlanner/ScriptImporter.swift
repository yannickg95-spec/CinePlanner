//
//  ScriptImporter.swift
//  CinePlanner
//
//  Created by Yannick Giraud on 17/12/2025.
//
//  Imports screenplay scenes from PDF files

import Foundation
import PDFKit
import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Result of a script import: how many scenes were created plus any
/// parser diagnostics worth showing to the user.
struct ScriptImportResult {
    let sceneCount: Int
    let warnings: [String]
}

struct ScriptImporter {

    /// Imports scenes from a PDF screenplay into a specific script version.
    /// Runs on the main actor because it mutates SwiftData models.
    @MainActor
    static func importScenes(from url: URL, into version: ScriptVersion, project: Project) async throws -> ScriptImportResult {
        guard let pdfDocument = PDFDocument(url: url) else {
            print("❌ Failed to create PDFDocument from URL")
            throw ScriptImportError.invalidPDF
        }

        print("✅ PDF loaded successfully with \(pdfDocument.pageCount) pages")

        // Store PDF data in the version for later viewing
        if let pdfData = try? Data(contentsOf: url) {
            version.pdfData = pdfData
        }

        // Extract text from all pages with page mapping
        var fullText = ""
        var lineToPageMap: [Int: Int] = [:] // Maps line index to PDF page index
        var currentLineNumber = 0

        for pageIndex in 0..<pdfDocument.pageCount {
            if let page = pdfDocument.page(at: pageIndex),
               let pageContent = page.string {
                let pageLines = pageContent.components(separatedBy: .newlines)

                // Map each line to its page number
                for _ in pageLines {
                    lineToPageMap[currentLineNumber] = pageIndex
                    currentLineNumber += 1
                }

                fullText += pageContent + "\n"
            }
        }

        print("📝 Extracted \(fullText.count) characters from PDF")

        // Detect failed extraction: no text at all, or a large share of U+FFFD
        // replacement characters (what text extraction emits for undecodable glyphs).
        let scalarCount = fullText.unicodeScalars.count
        let replacementCount = fullText.unicodeScalars.lazy.filter { $0.value == 0xFFFD }.count
        let replacementRatio = scalarCount > 0 ? Double(replacementCount) / Double(scalarCount) : 0
        let hasNoText = fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if hasNoText || replacementRatio > 0.2 {
            print("⚠️ PDF text extraction failed (empty: \(hasNoText), replacement ratio: \(Int(replacementRatio * 100))%)")
            throw ScriptImportError.textExtractionFailed
        }

        // Parse scenes from the text
        let lines = fullText.components(separatedBy: .newlines)
        let parseResult = ScreenplayParser.parse(lines: lines, lineToPageMap: lineToPageMap)
        let scenes = parseResult.scenes

        print("🎬 Found \(scenes.count) scenes (\(parseResult.skippedLines.count) candidate lines skipped)")

        // Separate this version's existing scenes into those with shots and those without
        let scenesWithShots = version.scenes.filter { !$0.shots.isEmpty }
        let scenesWithoutShots = version.scenes.filter { $0.shots.isEmpty }

        // Remove scenes without shots
        if !scenesWithoutShots.isEmpty {
            print("🗑️ Removing \(scenesWithoutShots.count) scene\(scenesWithoutShots.count == 1 ? "" : "s") without shots")
            for scene in scenesWithoutShots {
                if let index = project.scenes.firstIndex(where: { $0 === scene }) {
                    project.scenes.remove(at: index)
                }
                if let index = version.scenes.firstIndex(where: { $0 === scene }) {
                    version.scenes.remove(at: index)
                }
            }
        }

        // Keep scenes that have shots, flagged as archived so they list separately
        if !scenesWithShots.isEmpty {
            print("📦 Preserving \(scenesWithShots.count) scene\(scenesWithShots.count == 1 ? "" : "s") with shots")
            for scene in scenesWithShots {
                scene.isArchived = true
            }
        }

        // Find the first scene's absolute PDF page number to use as the offset
        let firstScenePDFPage = scenes.first?.pageNumber ?? 0
        version.pdfPageOffset = firstScenePDFPage

        // Add new scenes to the version at the beginning
        var newSceneObjects: [Scene] = []

        for (index, sceneInfo) in scenes.enumerated() {
            let scene = Scene(sceneNumber: sceneInfo.number)
            scene.project = project
            scene.scriptVersion = version
            scene.nickname = sceneInfo.name
            scene.isInterior = sceneInfo.isInterior
            scene.isDay = sceneInfo.isDay
            scene.suffix = sceneInfo.suffix
            scene.scriptTimeOfDay = sceneInfo.timeOfDay
            scene.sortOrder = index  // Set sortOrder for new scenes at the top

            // Store page number relative to first scene (first scene = page 1)
            // Example: If first scene is on PDF page 5, scenes will be numbered 1, 2, 3...
            scene.scriptPageNumber = (sceneInfo.pageNumber - firstScenePDFPage) + 1
            scene.scriptLineNumber = sceneInfo.lineNumber

            // Characters cued between this scene's heading and the next scene's —
            // used to auto-label the scene map's mannequins on CineStager import.
            let nextSceneLine = (index + 1 < scenes.count) ? scenes[index + 1].lineNumber : lines.count
            scene.sceneCharacterNames = ScreenplayParser.charactersIn(
                lines: lines, from: sceneInfo.lineNumber, to: nextSceneLine)

            // Legacy: older builds read the PDF page offset from the first scene
            if index == 0 {
                scene.pdfPageOffset = firstScenePDFPage
            }

            newSceneObjects.append(scene)
            print("  ✓ Scene \(scene.sceneNumber)\(scene.suffix): \(scene.isInterior ? "INT" : "EXT") - \(scene.nickname) - \(scene.isDay ? "DAY" : "NIGHT") [Scene Page \(scene.scriptPageNumber), PDF Page \(sceneInfo.pageNumber + 1)]")
        }

        // Update sortOrder for old scenes to place them after new scenes
        for (index, oldScene) in scenesWithShots.enumerated() {
            oldScene.sortOrder = newSceneObjects.count + index
        }

        // Add new scenes to the project
        for newScene in newSceneObjects {
            project.scenes.append(newScene)
        }

        // Detect characters and register any new ones (each gets its own color),
        // used for the scene map's mannequin markers.
        let characterNames = ScreenplayParser.extractCharacters(lines: lines)
        project.addScriptCharacters(named: characterNames)
        print("👥 Detected \(characterNames.count) character\(characterNames.count == 1 ? "" : "s"): \(characterNames.joined(separator: ", "))")

        // Persist now so the new scenes get permanent, stable persistentModelIDs.
        // Otherwise a later autosave flips their temporary IDs to permanent ones,
        // which breaks the ID-keyed scene matching in the shot-transfer window.
        try? project.modelContext?.save()

        // Turn parser diagnostics into user-facing warnings (capped)
        var warnings: [String] = []
        for skipped in parseResult.skippedLines.prefix(3) {
            warnings.append("Line \(skipped.lineNumber): \(skipped.reason)")
        }
        if parseResult.skippedLines.count > 3 {
            warnings.append("…and \(parseResult.skippedLines.count - 3) more skipped lines (see console log)")
        }

        return ScriptImportResult(sceneCount: scenes.count, warnings: warnings)
    }
}

// MARK: - Screenplay Parser

/// Pure screenplay scene-heading parser. It has no PDF, model, or UI
/// dependencies so the detection logic can be unit tested with plain strings.
enum ScreenplayParser {

    struct ParseResult {
        var scenes: [SceneInfo] = []
        var skippedLines: [(lineNumber: Int, reason: String)] = []
    }

    struct HeadingMatch {
        var number: Int?
        var suffix: String
        var isInterior: Bool
        var location: String
        var timeOfDay: String
    }

    private enum LineResult {
        case heading(HeadingMatch)
        case skipped(String)   // contained INT/EXT but was rejected, with the reason
        case notAHeading
    }

    // A detected scene after the first pass, before unnumbered scenes have been
    // assigned a number. `explicitNumber == nil` means the script did not give
    // this scene a number (neither inline nor in a margin); the second pass fills
    // it in from its numbered neighbours.
    private struct PendingScene {
        var explicitNumber: Int?
        var explicitSuffix: String
        let isInterior: Bool
        let location: String
        let timeOfDay: String
        let pageNumber: Int
        let lineNumber: Int
    }

    // MARK: Patterns

    // INT / EXT / INT./EXT. / I/E / EST. — the trailing lookahead rejects the token
    // inside longer words (INTERIOR, EXTERNAL, ...).
    private static let typeTokenCore = "(INT\\s*\\.?\\s*/\\s*EXT|EXT\\s*\\.?\\s*/\\s*INT|I/E|INT|EXT|EST\\.)(?![A-Za-z])"

    // Same token as a standalone word — the lookbehind additionally rejects
    // occurrences inside words (WINTER, NEXT, BEST, ...).
    private static let typeToken = "(?<![A-Za-z])" + typeTokenCore

    // Full heading anchored at the start of the line, with an optional leading scene
    // number: "INT. KITCHEN - DAY", "12 INT. KITCHEN - DAY", "3A EXT. STREET - NIGHT",
    // "4.A INT. STAL, OCHTEND." — the separator between the number and its suffix
    // letter is optional too, since some scripts write the A-scene as "4.A".
    // The separator after the number is optional because PDF extraction often glues
    // the margin number straight onto the heading ("3BINT. HUIS - DAG"), which is
    // also why this uses the lookbehind-free token: the anchor and the explicit
    // number group already constrain what can precede INT/EXT.
    // Groups: 1 = number, 2 = number suffix, 3 = type, 4 = remainder.
    private static let anchoredHeadingRegex = try! NSRegularExpression(
        pattern: "^(?:(\\d{1,3})\\s*[.\\-]?\\s*([A-Za-z]{1,2})?[\\s.\\-]*)?" + typeTokenCore + "[\\s.:/]*(.*)$",
        options: [.caseInsensitive]
    )

    // Case-sensitive variant used for the prefixed-heading path, where the
    // whole line must be uppercase anyway.
    private static let typeSearchRegex = try! NSRegularExpression(pattern: typeToken)

    // Case-insensitive "does this line mention INT/EXT at all" pre-check.
    private static let typeAnywhereRegex = try! NSRegularExpression(pattern: typeToken, options: [.caseInsensitive])

    // Leading transition like "CUT TO: " before a heading on the same line.
    private static let transitionPrefixRegex = try! NSRegularExpression(pattern: "^[A-Z][A-Z .']{0,18}:\\s*")

    // Sentence words indicating the text before INT/EXT is prose, not a
    // production prefix like "SCRIPTDAG 7".
    private static let stopWordRegex = try! NSRegularExpression(pattern: "\\b(THE|AND|TO|OF|IS|ARE|WAS|WERE|IN|AT|ON|WITH|A|DE|HET|EEN|EN|VAN|NAAR)\\b")

    // Scene number at the start of a production prefix ("2b SCRIPTDAG ...").
    private static let leadingNumberRegex = try! NSRegularExpression(pattern: "^(\\d{1,3})\\s*([A-Za-z]{1,2})?(?![A-Za-z0-9])")

    // Scene number repeated at the end of the heading (shooting-script margin numbers).
    private static let trailingNumberRegex = try! NSRegularExpression(pattern: "[\\s.](\\d{1,3})([A-Za-z]{1,2})?\\.?\\s*$")

    // A line that is nothing but a bare number, e.g. "42" or "7A" — margin scene
    // numbers. Deliberately excludes "42." / "(42)": page numbers usually carry
    // punctuation, and absorbing those as scene numbers was a real failure mode.
    // The dot before the suffix letter is allowed only when a letter follows it,
    // so "7.A" is a scene number while "42." stays excluded as a page number.
    private static let numberOnlyLineRegex = try! NSRegularExpression(pattern: "^(\\d{1,3})(?:[.\\-]?([A-Za-z]{1,2}))?$")

    // A margin scene number doubled by extraction when the heading row carries
    // the number in both margins: "3 3", "17b 17b". Unlike a bare number, this
    // form can't be a page number, so it's trusted even before the script has
    // shown any inline scene numbers.
    private static let doubledNumberLineRegex = try! NSRegularExpression(pattern: "^(\\d{1,3})([A-Za-z]{0,2})\\s+\\1\\2$")

    // Period/comma separating location from time when no dash is used
    // ("INT. CAFÉ. AVOND, DONKER").
    private static let punctSeparatorRegex = try! NSRegularExpression(pattern: "[.,]\\s+")

    // Dash separating location from time-of-day ("KITCHEN - DAY"). Requires a
    // space on at least one side so hyphenated locations ("DRIVE-IN") survive.
    private static let dashSeparatorRegex = try! NSRegularExpression(pattern: "(?:\\s+[-–—]+\\s*|\\s*[-–—]+\\s+)")

    // MARK: Time-of-day keywords

    // Day/night keywords across the languages the app supports. All lists are
    // checked for every script — screenwriters routinely mix English time-of-day
    // into non-English scripts, so gating on a detected language only loses scenes.
    private static let nightKeywords: [String] = [
        "NIGHT", "EVENING",                             // English
        "NUIT", "SOIR",                                 // French
        "NOCHE",                                        // Spanish
        "NACHT", "ABEND",                               // German / Dutch
        "NOTTE", "SERA",                                // Italian
        "NOITE",                                        // Portuguese
        "AVOND", "DONKER",                              // Dutch (donker = dark)
        "夜", "晩", "晚上", "夜晚",                       // Japanese / Chinese
        "밤", "저녁"                                     // Korean
    ]

    private static let dayKeywords: [String] = [
        "DAY", "MORNING", "AFTERNOON", "DAWN", "DUSK", "SUNRISE", "SUNSET",       // English
        "JOUR", "MATIN", "APRÈS-MIDI", "AUBE", "CRÉPUSCULE",                      // French
        "DÍA", "DIA", "MAÑANA", "TARDE", "AMANECER", "ATARDECER",                 // Spanish
        "TAG", "NACHMITTAG", "DÄMMERUNG", "SONNENAUFGANG", "MORGEN",              // German
        "GIORNO", "MATTINA", "POMERIGGIO", "ALBA", "TRAMONTO",                    // Italian
        "MANHÃ", "AMANHECER", "ANOITECER",                                        // Portuguese
        "DAG", "OCHTEND", "MIDDAG", "DAGERAAD", "SCHEMERING", "LICHT", "SCHEMER", // Dutch (licht = light)
        "昼", "朝", "午後", "夜明け", "夕暮れ", "白天", "早上", "下午", "黎明", "黄昏", // Japanese / Chinese
        "낮", "아침", "오후", "새벽", "황혼"                                        // Korean
    ]

    // Time indicators that don't say day or night but still belong to the
    // time-of-day part of a heading.
    private static let neutralTimeKeywords: [String] = [
        "CONTINUOUS", "LATER", "MOMENTS LATER", "SAME TIME", "SAME",
        "MAGIC HOUR", "GOLDEN HOUR", "TWILIGHT"
    ]

    // Modifier words allowed inside a time-of-day segment ("EARLY MORNING",
    // "LATER THAT NIGHT", "NEXT DAY", Dutch "EVEN LATER").
    private static let timeModifierWords: Set<String> = [
        "EARLY", "LATE", "LATER", "THAT", "NEXT", "SAME", "THE", "FOLLOWING", "MOMENTS", "PRE", "EVEN"
    ]

    // MARK: Parsing

    static func parse(lines: [String], lineToPageMap: [Int: Int]) -> ParseResult {
        var result = ParseResult()

        // First pass: detect headings and read whatever scene numbers the script
        // gives explicitly (inline or from a margin line). Unnumbered scenes are
        // left with `explicitNumber == nil` and numbered in the second pass, so an
        // auto-assigned number can never steal a value a later scene explicitly claims.
        var pending: [PendingScene] = []
        var lastExplicitNumber: Int?            // Last scene number that came from the script itself
        var scriptUsesSceneNumbers = false      // Whether the script has shown scene numbers (inline or doubled margins)

        for (index, rawLine) in lines.enumerated() {
            let lineNumber = index + 1

            var line = rawLine.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

            if line.isEmpty { continue }

            // Strip a leading transition ("CUT TO: INT. KITCHEN - DAY") so the
            // heading behind it is still detected.
            if let match = transitionPrefixRegex.firstMatch(in: line, options: [], range: fullRange(line)),
               let range = Range(match.range, in: line) {
                let remainder = String(line[range.upperBound...])
                if typeAnywhereRegex.firstMatch(in: remainder, options: [], range: fullRange(remainder)) != nil {
                    line = remainder
                }
            }

            switch evaluateLine(line) {
            case .notAHeading:
                continue

            case .skipped(let reason):
                print("  ⚠️ Line \(lineNumber) skipped — \(reason): '\(line.prefix(80))'")
                result.skippedLines.append((lineNumber, reason))

            case .heading(var heading):
                if heading.number != nil {
                    scriptUsesSceneNumbers = true
                } else {
                    // Margin scene numbers often land on the line just above or just
                    // below their heading, either doubled ("3 3", both margins) or
                    // bare ("17b"). Doubled numbers are unambiguous and always
                    // trusted. Bare numbers are only trusted once the script has
                    // shown it numbers its scenes, so stray numbers (like bare page
                    // numbers) aren't absorbed. Both must plausibly continue the
                    // scene sequence.
                    for neighborIndex in [index - 1, index + 1] where neighborIndex >= 0 && neighborIndex < lines.count {
                        let neighbor = lines[neighborIndex].trimmingCharacters(in: .whitespaces)

                        let match: NSTextCheckingResult?
                        var isDoubled = false
                        if let doubled = doubledNumberLineRegex.firstMatch(in: neighbor, options: [], range: fullRange(neighbor)) {
                            match = doubled
                            isDoubled = true
                        } else if scriptUsesSceneNumbers {
                            match = numberOnlyLineRegex.firstMatch(in: neighbor, options: [], range: fullRange(neighbor))
                        } else {
                            match = nil
                        }

                        guard let match,
                              let validated = validatedSceneNumber(digits: group(match, 1, in: neighbor),
                                                                   suffix: group(match, 2, in: neighbor)),
                              isPlausibleNextNumber(validated.0, suffix: validated.1, after: lastExplicitNumber) else {
                            continue
                        }
                        heading.number = validated.0
                        if heading.suffix.isEmpty { heading.suffix = validated.1 }
                        if isDoubled { scriptUsesSceneNumbers = true }
                        print("  🔗 Line \(lineNumber): took scene number \(validated.0)\(validated.1) from line \(neighborIndex + 1)")
                        break
                    }
                }

                if let explicit = heading.number {
                    lastExplicitNumber = explicit
                }

                pending.append(PendingScene(
                    explicitNumber: heading.number,
                    explicitSuffix: heading.suffix,
                    isInterior: heading.isInterior,
                    location: heading.location,
                    timeOfDay: heading.timeOfDay,
                    pageNumber: lineToPageMap[index] ?? 0,
                    lineNumber: index
                ))
            }
        }

        // Second pass: assign a number to every scene, filling unnumbered runs
        // from their explicit neighbours.
        result.scenes = assignSceneNumbers(pending)
        return result
    }

    /// Assigns a final number + suffix to every detected scene.
    ///
    /// Scenes the script numbered explicitly keep their number. An unnumbered run
    /// is resolved from the explicit numbers bracketing it:
    /// - Between explicit `P` and `N`: if there is numeric room (`N - P - 1 >=`
    ///   the run length) the scenes fill the gap (`P+1, P+2, …`) — the common
    ///   "extraction missed a number" case. If there is no room, they are treated
    ///   as inserts and lettered off `P` (`PA`, `PB`, …) — the "6, 6A, 7" case —
    ///   so they never collide with `N`.
    /// - After the last explicit number (trailing): the sequence simply continues
    ///   (`P+1, P+2, …`).
    /// - Before the first explicit number, or when the script has no numbers at
    ///   all: numbered sequentially from 1 by reading position, which leaves later
    ///   explicit numbers (and any gaps they imply) untouched.
    /// A final pass guarantees every (number, suffix) pair is unique.
    private static func assignSceneNumbers(_ pending: [PendingScene]) -> [SceneInfo] {
        guard !pending.isEmpty else { return [] }

        var numbers = [Int](repeating: 0, count: pending.count)
        var suffixes = [String](repeating: "", count: pending.count)

        var i = 0
        var prevAnchor: Int?
        while i < pending.count {
            if let explicit = pending[i].explicitNumber {
                numbers[i] = explicit
                suffixes[i] = pending[i].explicitSuffix.uppercased()
                prevAnchor = explicit
                i += 1
                continue
            }

            // An unnumbered run [i, j)
            var j = i
            while j < pending.count && pending[j].explicitNumber == nil { j += 1 }
            let count = j - i
            let nextAnchor = j < pending.count ? pending[j].explicitNumber : nil
            fillRun(start: i, count: count, prev: prevAnchor, next: nextAnchor,
                    numbers: &numbers, suffixes: &suffixes)
            i = j
        }

        // Guarantee uniqueness: any repeated (number, suffix) — a genuine duplicate
        // heading, or a rare fill collision — gets the next free letter suffix.
        var used: Set<String> = []
        for k in 0..<pending.count {
            var suffix = suffixes[k]
            if used.contains("\(numbers[k])\(suffix)") {
                var letterIndex = 0
                while used.contains("\(numbers[k])\(letterSuffix(letterIndex))") {
                    letterIndex += 1
                }
                suffix = letterSuffix(letterIndex)
                suffixes[k] = suffix
            }
            used.insert("\(numbers[k])\(suffix)")
        }

        return pending.indices.map { k in
            SceneInfo(
                number: numbers[k],
                suffix: suffixes[k],
                name: pending[k].location,
                isInterior: pending[k].isInterior,
                isDay: classifyTime(pending[k].timeOfDay) ?? true,
                timeOfDay: pending[k].timeOfDay,
                pageNumber: pending[k].pageNumber,
                lineNumber: pending[k].lineNumber
            )
        }
    }

    private static func fillRun(start: Int, count: Int, prev: Int?, next: Int?,
                                numbers: inout [Int], suffixes: inout [String]) {
        guard let prev = prev else {
            // Leading run (nothing numbered precedes it) or a script with no
            // numbers at all: number sequentially from 1 by reading position.
            for k in 0..<count { numbers[start + k] = start + 1 + k }
            return
        }

        // `next == nil` (trailing run) leaves unlimited room, so the sequence
        // simply continues past the last explicit number.
        let slots = (next ?? Int.max) - prev - 1
        if slots >= count {
            for k in 0..<count { numbers[start + k] = prev + 1 + k }
        } else {
            // No numeric room before the next scene → inserts lettered off `prev`.
            for k in 0..<count {
                numbers[start + k] = prev
                suffixes[start + k] = letterSuffix(k)
            }
        }
    }

    // MARK: Line evaluation

    /// The location a heading line yields — the very value the importer stored as
    /// the scene's nickname. The PDF viewer uses this to match a scene to its
    /// heading by *exact* location, because substring matching confuses a location
    /// with its own sub-locations ("NORTHUP HOUSE" vs "NORTHUP HOUSE - BEDROOM").
    static func headingLocation(of line: String) -> String? {
        if case .heading(let match) = evaluateLine(line) { return match.location }
        return nil
    }

    // MARK: Character cues

    private static let cueTransitions: Set<String> = [
        "CUT TO", "FADE IN", "FADE OUT", "FADE TO", "DISSOLVE TO", "SMASH CUT",
        "SMASH CUT TO", "MATCH CUT", "INTERCUT", "BACK TO", "THE END", "CONTINUED",
        "CONT'D", "TITLE", "SUPER", "MONTAGE", "OMITTED", "END", "LATER",
        "MOMENTS LATER", "CONTINUOUS", "PRELAP", "V.O.", "O.S.", "FADE",
    ]

    /// Returns the character name if `line` reads as a screenplay character cue —
    /// an all-caps name (parentheticals like "(V.O.)" stripped), short, not a scene
    /// heading or transition. Nil otherwise.
    private static func characterCueName(_ line: String) -> String? {
        var name = line.trimmingCharacters(in: .whitespaces)
        // Strip a trailing parenthetical extension: "JOHN (V.O.)" → "JOHN".
        if let r = name.range(of: "\\s*\\(.*\\)\\s*$", options: .regularExpression) {
            name.removeSubrange(r)
        }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: " :"))
        guard name.count >= 2, name.count <= 30 else { return nil }
        guard name == name.uppercased() else { return nil }              // all caps
        guard name.rangeOfCharacter(from: .lowercaseLetters) == nil,
              name.rangeOfCharacter(from: .uppercaseLetters) != nil else { return nil }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ .'’-&0123456789")
        guard name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        guard name.split(separator: " ").count <= 4 else { return nil }
        if cueTransitions.contains(name) { return nil }
        if typeAnywhereRegex.firstMatch(in: name, options: [], range: fullRange(name)) != nil { return nil }
        return name
    }

    /// Best-effort list of characters (ordered by first appearance) — a cue line
    /// immediately followed by dialogue. Only cues *after the first scene heading*
    /// count, which drops title-page text (title, author) that would otherwise
    /// read as a cue; that gate is strong enough that a single appearance is
    /// enough, so characters who speak only once still register.
    static func extractCharacters(lines: [String]) -> [String] {
        var seen = Set<String>()
        var order: [String] = []
        var pastFrontMatter = false
        for i in lines.indices {
            if case .heading = evaluateLine(lines[i]) { pastFrontMatter = true }
            guard pastFrontMatter, let name = characterCueName(lines[i]) else { continue }
            // The next non-empty line should be dialogue, not another cue/heading.
            var j = i + 1
            while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
            guard j < lines.count else { continue }
            if characterCueName(lines[j]) != nil { continue }
            if case .heading = evaluateLine(lines[j]) { continue }
            if seen.insert(name.uppercased()).inserted { order.append(name) }
        }
        return order
    }

    /// Character names cued within the line range [from, to) — used to pre-fill a
    /// scene's characters (a scene spans from its heading to the next scene's).
    static func charactersIn(lines: [String], from: Int, to: Int) -> [String] {
        var seen = Set<String>()
        var order: [String] = []
        let hi = min(to, lines.count)
        var i = max(0, from)
        while i < hi {
            if let name = characterCueName(lines[i]) {
                var j = i + 1
                while j < hi, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                if j < hi {
                    let nextIsHeading = { if case .heading = evaluateLine(lines[j]) { return true } else { return false } }()
                    if characterCueName(lines[j]) == nil, !nextIsHeading,
                       seen.insert(name.uppercased()).inserted {
                        order.append(name)
                    }
                }
            }
            i += 1
        }
        return order
    }

    private static func evaluateLine(_ line: String) -> LineResult {
        // Path 1: heading anchored at the start of the line (any casing) —
        // "INT. KITCHEN - DAY", "12 INT. KITCHEN - DAY", "3BINT. HUIS - DAG", ...
        // Tried before the standalone-token check because a glued margin number
        // ("3BINT.") puts a letter directly before INT.
        if let match = anchoredHeadingRegex.firstMatch(in: line, options: [], range: fullRange(line)) {
            let numberAndSuffix = validatedSceneNumber(digits: group(match, 1, in: line),
                                                       suffix: group(match, 2, in: line))
            let typeText = group(match, 3, in: line) ?? ""
            let rest = trimGluedProse(group(match, 4, in: line) ?? "")
            return makeHeading(
                number: numberAndSuffix?.0,
                suffix: numberAndSuffix?.1 ?? "",
                typeToken: typeText,
                rest: rest,
                uppercaseProbe: typeText + " " + rest
            )
        }

        // Quick reject: no standalone INT/EXT-style token anywhere
        guard typeAnywhereRegex.firstMatch(in: line, options: [], range: fullRange(line)) != nil else {
            return .notAHeading
        }

        // Path 2: prefixed heading ("SCRIPTDAG 7 EXT. STREET - DAY",
        // "2b SCRIPTDAG 2 EXT. STREET - DAY").
        guard let typeMatch = typeSearchRegex.firstMatch(in: line, options: [], range: fullRange(line)),
              let typeRange = Range(typeMatch.range, in: line) else {
            return .skipped("INT/EXT is not at the start of the line and the line is not an uppercase heading")
        }

        let prefix = String(line[..<typeRange.lowerBound]).trimmingCharacters(in: .whitespaces)

        if prefix.count > 30 {
            return .skipped("text before INT/EXT is too long (\(prefix.count) characters)")
        }

        let upperPrefix = prefix.uppercased()
        if stopWordRegex.firstMatch(in: upperPrefix, options: [], range: fullRange(upperPrefix)) != nil {
            return .skipped("text before INT/EXT reads like a sentence")
        }

        var rest = String(line[typeRange.upperBound...])
        rest = trimGluedProse(rest.trimmingCharacters(in: CharacterSet(charactersIn: " ./:")))

        // Scene headings are uppercase in every standard screenplay format, which
        // filters out dialogue and action lines that merely mention INT or EXT.
        // Only the heading portion is checked, because PDF extraction often glues
        // the (lowercase) action text that follows a heading onto the same line.
        let headingText = prefix + " " + String(line[typeRange]) + " " + rest
        guard isMostlyUppercase(headingText) else {
            return .skipped("looks like prose, not an uppercase scene heading")
        }

        var number: Int?
        var suffix = ""
        if let match = leadingNumberRegex.firstMatch(in: prefix, options: [], range: fullRange(prefix)),
           let validated = validatedSceneNumber(digits: group(match, 1, in: prefix),
                                                suffix: group(match, 2, in: prefix)) {
            number = validated.0
            suffix = validated.1
        }

        return makeHeading(number: number, suffix: suffix,
                           typeToken: String(line[typeRange]), rest: rest,
                           uppercaseProbe: headingText)
    }

    /// Cuts action text that PDF extraction glued onto a heading line. Headings
    /// are uppercase, so cut at the first word containing a lowercase letter.
    /// Falls back to the full text when everything is mixed/lower case (e.g. a
    /// Fountain-style "int. kitchen - day" heading).
    private static func trimGluedProse(_ rest: String) -> String {
        var kept: [String] = []
        for word in rest.components(separatedBy: " ") {
            if word.unicodeScalars.contains(where: { CharacterSet.lowercaseLetters.contains($0) }) {
                break
            }
            kept.append(word)
        }
        let trimmed = kept.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? rest : trimmed
    }

    private static func makeHeading(number: Int?, suffix: String,
                                    typeToken: String, rest: String,
                                    uppercaseProbe: String) -> LineResult {
        let normalizedType = typeToken.uppercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ".", with: "")

        // "EST." (establishing shot) is only trusted on uppercase headings — the
        // case-insensitive anchored match would otherwise fire on prose like "Est. 1892".
        if normalizedType == "EST" && !isMostlyUppercase(uppercaseProbe) {
            return .skipped("'EST.' outside an uppercase heading")
        }

        let isInterior: Bool
        switch normalizedType {
        case "INT/EXT", "I/E", "INT":
            isInterior = true   // Default to interior for combined INT/EXT
        default:                // "EXT", "EXT/INT", "EST"
            isInterior = false
        }

        let (location, timeOfDay) = splitLocationAndTime(rest, leadingNumber: number)

        guard !location.isEmpty else {
            return .skipped("no location name after INT/EXT")
        }

        return .heading(HeadingMatch(
            number: number,
            suffix: suffix,
            isInterior: isInterior,
            location: location,
            timeOfDay: timeOfDay
        ))
    }

    /// Splits the text after INT/EXT into location and time-of-day, and strips a
    /// shooting-script margin number from the end when it duplicates the leading one.
    private static func splitLocationAndTime(_ rest: String, leadingNumber: Int?) -> (location: String, timeOfDay: String) {
        var seg = rest.trimmingCharacters(in: .whitespaces)

        // Right-margin scene number ("12 INT. KITCHEN - DAY 12"): strip only when
        // it matches the leading number, so story-day notation ("- DAY 2") and
        // locations ending in digits ("ROOM 101") are left alone.
        if let leadingNumber,
           let match = trailingNumberRegex.firstMatch(in: seg, options: [], range: fullRange(seg)),
           let digits = group(match, 1, in: seg),
           Int(digits) == leadingNumber,
           let matchRange = Range(match.range, in: seg) {
            seg = String(seg[..<matchRange.lowerBound])
        }

        // Peel time indicators off the end, dash by dash, so compound headings
        // like "KITCHEN - DAY - CONTINUOUS" keep multi-part locations intact.
        var segments = splitOnDashes(seg)
        var timeSegments: [String] = []
        while segments.count > 1, let last = segments.last, isTimeIndicator(last) {
            timeSegments.insert(segments.removeLast(), at: 0)
        }

        // Fallback for time segments with extra words ("DAY (FLASHBACK)",
        // "NACHT, DONKER (FEBRUARI) SCRIPTDAG 2"): if the strict pass found
        // nothing but the last segment mentions day or night, use it.
        if timeSegments.isEmpty, segments.count > 1, let last = segments.last, classifyTime(last) != nil {
            timeSegments.append(segments.removeLast())
        }

        // Some scripts separate location and time with a period or comma instead
        // of a dash ("INT. AMSTERDAMS CAFÉ. AVOND, DONKER"). If no time was found
        // yet, split the last segment at the leftmost period/comma followed by a
        // word from the time vocabulary.
        if timeSegments.isEmpty, let lastSegment = segments.last {
            let punctMatches = punctSeparatorRegex.matches(in: lastSegment, options: [], range: fullRange(lastSegment))
            for match in punctMatches {
                guard let range = Range(match.range, in: lastSegment) else { continue }
                let candidate = String(lastSegment[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                guard classifyTime(candidate) != nil,
                      let firstWord = candidate.components(separatedBy: " ").first,
                      isTimeVocabularyWord(firstWord.uppercased()) else { continue }
                segments[segments.count - 1] = String(lastSegment[..<range.lowerBound])
                timeSegments = [candidate]
                break
            }
        }

        let location = segments.joined(separator: " - ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " .,-–—"))
        let timeOfDay = timeSegments.joined(separator: " - ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " .,"))

        return (location, timeOfDay)
    }

    // MARK: Time-of-day classification

    /// true = day, false = night, nil = no recognizable day/night keyword.
    static func classifyTime(_ timeOfDay: String) -> Bool? {
        guard !timeOfDay.isEmpty else { return nil }
        let upper = timeOfDay.uppercased()
        for keyword in nightKeywords where upper.contains(keyword) { return false }
        for keyword in dayKeywords where upper.contains(keyword) { return true }
        return nil
    }

    /// Whether a dash-separated segment is purely a time indicator ("DAY",
    /// "NIGHT 3", "EARLY MORNING", "CONTINUOUS") rather than part of the location
    /// ("SUNSET BOULEVARD").
    private static func isTimeIndicator(_ segment: String) -> Bool {
        let upper = segment.uppercased().trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        if upper.isEmpty { return false }
        if neutralTimeKeywords.contains(upper) { return true }   // exact phrase ("MOMENTS LATER")

        // Otherwise every word must be a known time keyword, a modifier, or a
        // story-day number ("DAY 2").
        let words = upper.components(separatedBy: " ")
        return words.allSatisfy { word in
            let cleaned = word.trimmingCharacters(in: CharacterSet(charactersIn: ".,()"))
            if cleaned.isEmpty { return true }
            if Int(cleaned) != nil { return true }
            return isTimeVocabularyWord(cleaned)
        }
    }

    /// Whether a single (already uppercased) word belongs to the time-of-day
    /// vocabulary: a day/night/neutral keyword or a modifier like "EARLY".
    private static func isTimeVocabularyWord(_ word: String) -> Bool {
        let cleaned = word.trimmingCharacters(in: CharacterSet(charactersIn: ".,()"))
        guard !cleaned.isEmpty else { return false }
        return timeModifierWords.contains(cleaned)
            || nightKeywords.contains(cleaned)
            || dayKeywords.contains(cleaned)
            || neutralTimeKeywords.contains(cleaned)
    }

    // MARK: Helpers

    /// Validates a potential scene number + suffix. Rejects ordinals ("2ND", "3RD")
    /// that are street addresses rather than scene numbers.
    private static func validatedSceneNumber(digits: String?, suffix: String?) -> (Int, String)? {
        guard let digits, let number = Int(digits), number > 0, number <= 999 else { return nil }
        let cleanSuffix = (suffix ?? "").uppercased()
        if ["ST", "ND", "RD", "TH"].contains(cleanSuffix) { return nil }
        return (number, cleanSuffix)
    }

    private static func isPlausibleNextNumber(_ number: Int, suffix: String, after last: Int?) -> Bool {
        guard let last else { return (1...20).contains(number) }
        // A lettered scene shares its base number with the previous scene ("3" → "3A"),
        // so equality is plausible when there is a suffix.
        if suffix.isEmpty {
            return number > last && number <= last + 20
        }
        return number >= last && number <= last + 20
    }

    /// Scene headings are uppercase in standard screenplay formats. Requires ≥ 90%
    /// of cased letters to be uppercase (leaves room for a stray lowercase suffix).
    private static func isMostlyUppercase(_ line: String) -> Bool {
        var upper = 0
        var cased = 0
        for scalar in line.unicodeScalars {
            if CharacterSet.uppercaseLetters.contains(scalar) {
                upper += 1
                cased += 1
            } else if CharacterSet.lowercaseLetters.contains(scalar) {
                cased += 1
            }
        }
        guard cased > 0 else { return false }
        return Double(upper) / Double(cased) >= 0.9
    }

    private static func splitOnDashes(_ text: String) -> [String] {
        let matches = dashSeparatorRegex.matches(in: text, options: [], range: fullRange(text))
        guard !matches.isEmpty else { return [text.trimmingCharacters(in: .whitespaces)] }

        var segments: [String] = []
        var start = text.startIndex
        for match in matches {
            guard let range = Range(match.range, in: text), range.lowerBound >= start else { continue }
            segments.append(String(text[start..<range.lowerBound]))
            start = range.upperBound
        }
        segments.append(String(text[start...]))
        return segments.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// 0 → "A", 1 → "B", ... 25 → "Z", 26 → "AA", ...
    private static func letterSuffix(_ index: Int) -> String {
        var i = index
        var result = ""
        repeat {
            result = String(UnicodeScalar(UInt8(65 + i % 26))) + result
            i = i / 26 - 1
        } while i >= 0
        return result
    }

    private static func fullRange(_ string: String) -> NSRange {
        NSRange(string.startIndex..., in: string)
    }

    private static func group(_ match: NSTextCheckingResult, _ index: Int, in string: String) -> String? {
        guard index < match.numberOfRanges, let range = Range(match.range(at: index), in: string) else { return nil }
        return String(string[range])
    }
}

// MARK: - Supporting Types

struct SceneInfo {
    let number: Int
    let suffix: String
    let name: String
    let isInterior: Bool
    let isDay: Bool
    let timeOfDay: String    // Raw time-of-day text from the heading ("DAY", "NIGHT - CONTINUOUS", ...)
    let pageNumber: Int      // PDF page index (0-based)
    let lineNumber: Int      // Line number in extracted text
}

enum ScriptImportError: LocalizedError {
    case invalidPDF
    case parsingFailed
    case noScenesFound
    case textExtractionFailed
    
    var errorDescription: String? {
        switch self {
        case .invalidPDF:
            return "The selected file is not a valid PDF."
        case .parsingFailed:
            return "Failed to parse the screenplay. Make sure it follows standard screenplay formatting."
        case .noScenesFound:
            return "No scenes were found in the screenplay."
        case .textExtractionFailed:
            return """
            Unable to extract text from this PDF.
            
            This PDF may be copy-protected, use custom fonts, or be a scanned image.
            
            The PDF has been imported for viewing, but scenes could not be automatically detected. You can manually add scenes and specify their page numbers in the scene editor.
            """
        }
    }
    
    var recoverySuggestion: String? {
        switch self {
        case .textExtractionFailed:
            return "You can still view the PDF and manually add scenes with page numbers."
        default:
            return nil
        }
    }
}

// MARK: - PDF Viewer View

/// A menu-as-button styled like the scene-map toolbar's gear pill (SegmentedGroup):
/// a 40×34 cell with a subtle fill and rounded border. Used on iPad and Mac.
private struct SegmentedGearButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 40, height: 34)
            .contentShape(Rectangle())
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.22), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

struct ScriptPDFViewer: View {
    let project: Project
    let version: ScriptVersion?
    let selectedScenePage: Int? // Page to jump to when scene is selected
    var selectedScene: Scene? = nil // Used to scroll the scene heading to the top
    let selectedShot: Shot? // Currently selected shot for coverage display
    var onScenesImported: ((ScriptImportResult) -> Void)? = nil
    var requestImport: Binding<Bool>? = nil // Parent sets true to auto-open the import prompt
    /// When true, a banner asks the user to scroll to the new scene's start and
    /// tap Done; the current page is then reported back via `onFinishMarking`.
    var isMarkingScenePage: Bool = false
    var markingSceneLabel: String = ""
    var onFinishMarking: ((Int) -> Void)? = nil
    var onCancelMarking: (() -> Void)? = nil
    /// iPhone: the coverage margin is owned by the editor (its gear lives beside the
    /// tabs), so it's passed in and the in-view gear/margin sheet aren't used here.
    var coverageMarginOverride: Double? = nil

    @State private var isImporting = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var cachedPDFDocument: PDFDocument? = nil
    @State private var showImportOptions = false
    @State private var autoLoadScenes = false
    @State private var showRemoveConfirmation = false
    @State private var showMarginSheet = false
    /// Live copy of the version's coverage-line margin, so the slider updates the
    /// PDF overlay immediately (SwiftUI can't observe the model class directly).
    @State private var coverageMargin: Double = 0.15
    @State private var currentPageIndex = 0

    private var currentPDFData: Data? {
        version?.pdfData ?? project.scriptPDFData
    }

    /// Script settings: replace, delete, or adjust the coverage-line margin.
    private var scriptGearMenu: some View {
        Menu {
            Button {
                showImportOptions = true
            } label: {
                Label("Replace Script…", systemImage: "arrow.triangle.2.circlepath")
            }
            Button {
                coverageMargin = version?.coverageLineMargin ?? 0.15
                showMarginSheet = true
            } label: {
                Label("Set Coverage Margin…", systemImage: "arrow.left.and.right")
            }
            Divider()
            Button(role: .destructive) {
                showRemoveConfirmation = true
            } label: {
                Label("Delete Script", systemImage: "trash")
            }
        } label: {
            Image(systemName: "gearshape")
                .font(DeviceLayout.isPhone ? .callout : .system(size: 16, weight: .medium))
                // iPhone: plain secondary icon (it floats in its own circle). iPad/Mac:
                // the default label colour inside the pill, matching the scene-map gear.
                .applyIf(DeviceLayout.isPhone) { $0.foregroundStyle(.secondary) }
        }
        .menuIndicator(.hidden)
        // iPad + Mac: present the menu as a button with the scene-map gear's pill.
        .applyIf(!DeviceLayout.isPhone) {
            $0.menuStyle(.button).buttonStyle(SegmentedGearButtonStyle()).fixedSize()
        }
        .help("Script settings — replace, delete, or set the coverage margin")
    }

    /// The Set-Coverage-Margin sheet: a slider that moves the coverage lines
    /// nearer to / further from the script text, live.
    private var marginSheet: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text("Coverage Margin")
                    .font(.title3).fontWeight(.semibold)
                Text("Move the coverage lines closer to or further from the script text, to match this script's left margin.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                Image(systemName: "text.alignleft").foregroundStyle(.secondary)
                Slider(value: $coverageMargin, in: 0.05...0.35)
                    .onChange(of: coverageMargin) { _, new in
                        version?.coverageLineMargin = new
                    }
                Image(systemName: "text.alignright").foregroundStyle(.secondary)
            }

            Text("\(Int((coverageMargin * 100).rounded()))% of page width")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            HStack {
                Button("Reset") {
                    coverageMargin = 0.15
                    version?.coverageLineMargin = 0.15
                }
                Spacer()
                Button("Done") {
                    try? version?.modelContext?.save()
                    showMarginSheet = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(maxWidth: 420)
    }

    /// Prompt shown while placing a new scene: scroll to its first page, tap Done.
    /// Rendered as a bold, full-width call-to-action so it can't be mistaken for a
    /// passive label — the user must act (scroll, then Done).
    private var markingBanner: some View {
        HStack(spacing: 14) {
            Image(systemName: "hand.point.up.left.fill")
                .font(.title2)
                .symbolEffect(.pulse, options: .repeating)
            VStack(alignment: .leading, spacing: 2) {
                Text("Placing Scene \(markingSceneLabel)")
                    .font(.headline)
                Text("Scroll the script to where this scene begins, then tap Done.")
                    .font(.subheadline)
                    .opacity(0.9)
            }
            Spacer(minLength: 8)
            Button("Cancel") { onCancelMarking?() }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .tint(.white)
            Button {
                onFinishMarking?(currentPageIndex)
            } label: {
                Text("Done").fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.white)
            .foregroundStyle(Color.blue)
            .keyboardShortcut(.defaultAction)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(Color.blue)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with import button
            if currentPDFData == nil {
                VStack(spacing: 20) {
                    Spacer()
                    
                    Image(systemName: "doc.text.viewfinder")
                        .font(.system(size: 60))
                        .foregroundStyle(.secondary)
                    
                    Text("No Script Imported")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text("Import a screenplay PDF to view it here")
                        .font(.body)
                        .foregroundStyle(.secondary)
                    
                    Button {
                        showImportOptions = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.badge.plus")
                            Text("Import Script PDF")
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.platformTextBackground)
            } else {
                // PDF Viewer
                VStack(spacing: 0) {
                    // Toolbar — title centered, remove button on the trailing edge.
                    // iPhone omits it: the Script tab already labels this view, and
                    // the full-screen cover has its own bar.
                    if !DeviceLayout.isPhone {
                        Text("Script")
                            .font(.title3.bold())
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity)
                            .overlay(alignment: .trailing) { scriptGearMenu }
                            .padding(.horizontal, 12)
                            .frame(height: ProjectEditorView.paneHeaderHeight)
                            .background(Color.platformControlBackground)

                        Divider()
                    }

                    if isMarkingScenePage {
                        markingBanner
                        Divider()
                    }

                    // PDF Content
                    PDFContentView(
                        pdfData: currentPDFData,
                        pageToDisplay: selectedScenePage,
                        sceneToAlign: selectedScene,
                        selectedShot: selectedShot,
                        project: project,
                        version: version,
                        coverageMargin: CGFloat(coverageMarginOverride ?? coverageMargin),
                        cachedDocument: $cachedPDFDocument,
                        currentPageIndex: $currentPageIndex
                    )
                    .clipped()
                    // iPhone's settings gear lives beside the tabs (see ProjectEditorView).
                }
            }
        }
        .onAppear {
            coverageMargin = version?.coverageLineMargin ?? 0.15
            // Consume a pending import request set before this viewer mounted (iPhone
            // opens the script sheet on "New Version"); onChange only sees changes
            // that happen while mounted, so catch an already-true flag here.
            if requestImport?.wrappedValue == true {
                requestImport?.wrappedValue = false
                showImportOptions = true
            }
        }
        .onChange(of: version) {
            // Swap the document in place rather than nil-ing it. Nil-ing removed the
            // PDF view and rebuilt it from scratch on every version switch (a new
            // PDFView, document load, coordinator and layout), which froze iPad.
            // Setting a new document keeps the same view and updates it in place.
            cachedPDFDocument = currentPDFData.flatMap { PDFDocument(data: $0) }
            coverageMargin = version?.coverageLineMargin ?? 0.15
        }
        .sheet(isPresented: $showMarginSheet) {
            marginSheet
                #if os(iOS)
                .presentationDetents([.height(300)])
                #endif
        }
        .onChange(of: requestImport?.wrappedValue ?? false) { _, shouldImport in
            if shouldImport {
                showImportOptions = true
                requestImport?.wrappedValue = false
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { result in
            Task { @MainActor in
                await handlePDFImport(result: result)
            }
        }
        .sheet(isPresented: $showImportOptions) {
            ScriptImportOptionsSheet(
                isPresented: $showImportOptions,
                onAutoLoad: {
                    autoLoadScenes = true
                    showImportOptions = false
                    isImporting = true
                },
                onSkip: {
                    autoLoadScenes = false
                    showImportOptions = false
                    isImporting = true
                }
            )
        }
        .alert("Import Failed", isPresented: $showError) {
            Button("OK") { }
        } message: {
            Text(errorMessage)
        }
        .alert("Remove Script?", isPresented: $showRemoveConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Remove", role: .destructive) {
                version?.pdfData = nil
                project.scriptPDFData = nil
                cachedPDFDocument = nil
            }
        } message: {
            Text("Are you sure you want to remove the script? The PDF will be deleted from this script version.")
        }
    }

    @MainActor
    private func handlePDFImport(result: Result<[URL], Error>) async {
        do {
            let urls = try result.get()
            guard let url = urls.first else { return }

            // Request security-scoped access to the file
            guard url.startAccessingSecurityScopedResource() else {
                errorMessage = "Unable to access the selected file."
                showError = true
                return
            }

            defer {
                url.stopAccessingSecurityScopedResource()
            }

            if autoLoadScenes, let version {
                let importResult = try await ScriptImporter.importScenes(from: url, into: version, project: project)
                cachedPDFDocument = nil
                print("✅ Imported PDF and \(importResult.sceneCount) scene\(importResult.sceneCount == 1 ? "" : "s")")
                if importResult.sceneCount > 0 {
                    onScenesImported?(importResult)
                }
                return
            }

            // Validate it's a PDF
            guard PDFDocument(url: url) != nil else {
                errorMessage = "The selected file is not a valid PDF."
                showError = true
                return
            }

            // Read PDF data
            guard let pdfData = try? Data(contentsOf: url) else {
                errorMessage = "Unable to read the PDF file."
                showError = true
                return
            }

            // Save to the script version
            if let version {
                version.pdfData = pdfData
            } else {
                project.scriptPDFData = pdfData
            }
            cachedPDFDocument = nil // Clear cache so it gets recreated
            print("✅ Imported PDF (\(pdfData.count) bytes) for viewing")

        } catch {
            errorMessage = "Import failed: \(error.localizedDescription)"
            showError = true
        }
    }
}

// MARK: - Script Import Options Sheet

struct ScriptImportOptionsSheet: View {
    @Binding var isPresented: Bool
    let onAutoLoad: () -> Void
    let onSkip: () -> Void

    // Matches the script step of NewProjectSheet — same frame, header, card rows
    // and footer — so importing a script reads the same whether it happens on a
    // new project or a new version.
    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Import Script",
                        subtitle: "Import a screenplay PDF to create scenes automatically, or bring in the PDF for reading only.")

            Divider()

            VStack(spacing: 10) {
                SheetActionCard(
                    icon: "sparkles",
                    title: "Auto-Load Scenes from Script",
                    detail: "Pick a screenplay PDF. Every scene heading becomes a scene, ready for shots.",
                    isProminent: true,
                    action: onAutoLoad
                )

                SheetActionCard(
                    icon: "doc.text",
                    title: "Import PDF Only",
                    detail: "Show the script alongside your shots without detecting any scenes.",
                    action: onSkip
                )

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(16)

            Divider()

            HStack {
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
            }
            .padding(16)
        }
        .adaptiveSheetFrame(width: 520, height: 400)
    }
}

// Separate view to handle PDF document caching
private struct PDFContentView: View {
    let pdfData: Data?
    let pageToDisplay: Int?
    let sceneToAlign: Scene?
    let selectedShot: Shot?
    let project: Project
    let version: ScriptVersion?
    var coverageMargin: CGFloat = 0.15
    @Binding var cachedDocument: PDFDocument?
    @Binding var currentPageIndex: Int

    var body: some View {
        Group {
            if let pdfData = pdfData {
                if let document = cachedDocument {
                    #if canImport(UIKit)
                    // iPad: a lazy continuous scroller (renders only visible pages) so
                    // continuous scrolling works without PDFView's whole-document
                    // layout freeze.
                    LazyContinuousPDFView(
                        document: document,
                        pageToDisplay: pageToDisplay,
                        sceneToAlign: sceneToAlign,
                        selectedShot: selectedShot,
                        project: project,
                        version: version,
                        coverageMargin: coverageMargin,
                        currentPageIndex: $currentPageIndex
                    )
                    #else
                    PDFViewerWithCoverageRepresentable(
                        document: document,
                        pageToDisplay: pageToDisplay,
                        sceneToAlign: sceneToAlign,
                        selectedShot: selectedShot,
                        project: project,
                        version: version,
                        coverageMargin: coverageMargin,
                        currentPageIndex: $currentPageIndex
                    )
                    #endif
                } else {
                    Color.clear
                        .onAppear {
                            if let newDocument = PDFDocument(data: pdfData) {
                                cachedDocument = newDocument
                            }
                        }
                }
            } else {
                ContentUnavailableView(
                    "Unable to Display PDF",
                    systemImage: "exclamationmark.triangle",
                    description: Text("The PDF data is corrupted or invalid")
                )
            }
        }
    }
}

struct PDFViewerWithCoverageRepresentable {
    let document: PDFDocument
    let pageToDisplay: Int? // 0-based page index
    let sceneToAlign: Scene? // Scroll so this scene's heading sits at the top
    let selectedShot: Shot? // Currently selected shot
    let project: Project // Need project to get all shots for vertical lines
    let version: ScriptVersion? // Scope coverage lines to this script version's scenes
    var coverageMargin: CGFloat = 0.15 // Right edge of the coverage-line band (fraction of page width)
    /// The page the user is currently looking at (0-based). Reported upward so the
    /// editor can capture it when placing a new scene's script page.
    @Binding var currentPageIndex: Int

    /// Scrolls so the scene's heading is at the top of the visible area, rather
    /// than just showing the page it happens to be on. Falls back to the top of
    /// the page when the heading can't be located in the page text.
    private func scroll(_ pdfView: PDFView, to page: PDFPage, scene: Scene?) {
        if let scene, let headingTop = headingTopY(for: scene, on: page) {
            // PDFDestination's point becomes the top-left of the visible area.
            // The margin (page coords, y grows upward) keeps the heading clearly
            // below the top edge rather than flush against it.
            let destination = PDFDestination(page: page, at: CGPoint(x: 0, y: headingTop + 14))
            pdfView.go(to: destination)
        } else {
            pdfView.go(to: page)
        }
    }

    /// A line that reads as a scene heading. INT/EXT must be a standalone word,
    /// otherwise "POINT", "WINTER" and friends match.
    private func isHeadingLine(_ line: String) -> Bool {
        line.uppercased().range(of: "(?<![A-Z])(INT|EXT|I/E)(?![A-Z])",
                                options: .regularExpression) != nil
    }

    /// Top edge (in page coordinates) of this scene's heading line.
    ///
    /// Locations repeat constantly in a script ("APPARTEMENT ANNA" many times over),
    /// so matching on the name alone lands on the wrong heading. Instead this finds
    /// the *nth* heading on the page, where n is this scene's position among the
    /// scenes that live on that page — then sanity-checks it against the location.
    private func headingTopY(for scene: Scene, on page: PDFPage) -> CGFloat? {
        let targetPage = scene.absolutePDFPage
        let scenesOnPage = (version?.orderedScenes ?? project.scenes.sorted { $0.sortOrder < $1.sortOrder })
            .filter { $0.absolutePDFPage == targetPage }
        let occurrence = scenesOnPage.firstIndex(where: { $0 === scene }) ?? 0

        let location = scene.nickname.trimmingCharacters(in: .whitespaces).uppercased()

        // Ask PDFKit for the page's lines as selections and read each line's bounds
        // directly, rather than mapping an offset in `page.string` onto
        // `characterBounds(at:)`. Those two index spaces are *not* interchangeable:
        // even when their lengths match exactly, a page whose content stream isn't
        // in reading order maps an offset onto a character one or two lines away,
        // putting the anchor below the real heading. Measured on 12 Years a Slave,
        // most headings were off by a harmless 3pt but some by a full 29pt (two
        // lines), and one resolved to y=0 — which is what made this look random.
        guard let wholePage = page.selection(for: page.bounds(for: .mediaBox)) else { return nil }

        var headings: [(location: String, top: CGFloat)] = []
        for line in wholePage.selectionsByLine() {
            guard let raw = line.string?.trimmingCharacters(in: .whitespaces),
                  isHeadingLine(raw) else { continue }
            // Re-parse through the importer's own heading parser so the location
            // reads identically to the one stored on the scene.
            let parsed = ScreenplayParser.headingLocation(of: raw) ?? raw
            headings.append((parsed.trimmingCharacters(in: .whitespaces).uppercased(),
                             line.bounds(for: page).maxY))
        }
        guard !headings.isEmpty else { return nil }

        // Position is the primary signal: the nth scene on a page is the nth
        // heading on it. That holds whenever the page mapping is right, which is
        // the overwhelming majority of the time.
        let positional = headings[min(occurrence, headings.count - 1)]

        // Location is only a *check* on that, never the lead. Confirming the
        // positional pick names the right location catches the case where a
        // scene's stored page number is off by one; searching by location first
        // would instead break the common case, since consecutive scenes routinely
        // share a location stem ("ORLEANS" and "ORLEANS - GALLEY").
        if location.isEmpty || positional.location == location {
            return positional.top
        }

        let named = headings.filter { $0.location == location }
        guard !named.isEmpty else { return positional.top }

        // One location can legitimately repeat on a page, so pick by this scene's
        // position among the same-location scenes on it.
        let sameLocation = scenesOnPage.filter {
            $0.nickname.trimmingCharacters(in: .whitespaces).uppercased() == location
        }
        let index = sameLocation.firstIndex(where: { $0 === scene }) ?? 0
        return named[min(index, named.count - 1)].top
    }

    func makeContainer(_ coordinator: Coordinator) -> PlatformViewBase {
        let containerView = PlatformViewBase()
        // Clip to bounds so coverage lines/highlights for text scrolled above the
        // viewport don't spill upward over the "Script" header.
        containerView.clipsToBounds = true

        let pdfView = PDFView()
        pdfView.document = document
        pdfView.autoScales = true
        #if canImport(UIKit)
        // Single-page (paged) on iPad: laying out the whole screenplay continuously
        // froze on every version switch. macOS keeps continuous vertical scrolling.
        pdfView.displayMode = .singlePage
        pdfView.usePageViewController(true)
        #else
        pdfView.displayMode = .singlePageContinuous
        #endif
        pdfView.displayDirection = .vertical
        
        // Configure selection appearance
        pdfView.highlightedSelections = []
        
        // Store reference in coordinator
        coordinator.pdfView = pdfView
        coordinator.containerView = containerView
        
        // Add PDF view to container
        containerView.addSubview(pdfView)
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pdfView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: containerView.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])
        
        // Create overlay view for coverage indicators
        let overlayView = PDFCoverageOverlayView()
        overlayView.pdfView = pdfView
        overlayView.marginFraction = coverageMargin
        coordinator.overlayView = overlayView
        containerView.addSubview(overlayView)
        overlayView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            overlayView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            overlayView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            overlayView.topAnchor.constraint(equalTo: containerView.topAnchor),
            overlayView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])
        
        // Listen for PDF view changes to update overlay
        coordinator.pageChangeObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.PDFViewPageChanged,
            object: pdfView,
            queue: .main
        ) { [weak coordinator = coordinator] _ in
            overlayView.requestRedraw()
            if let page = pdfView.currentPage, let idx = pdfView.document?.index(for: page) {
                coordinator?.onPageChange?(idx)
            }
        }
        
        // Repaint the overlay as the PDF scrolls. macOS: observe the NSScrollView's
        // bounds. iOS: KVO the internal UIScrollView's contentOffset — this fires
        // only while scrolling (nothing when idle), unlike a continuous timer.
        #if os(macOS)
        if let scrollView = pdfView.subviews.first(where: { $0 is NSScrollView }) as? NSScrollView {
            scrollView.contentView.postsBoundsChangedNotifications = true
            coordinator.scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { _ in
                overlayView.requestRedraw()
            }
        }
        #else
        if let scrollView = pdfView.firstScrollView {
            coordinator.scrollOffsetObservation = scrollView.observe(\.contentOffset, options: [.new]) { [weak overlayView] _, _ in
                overlayView?.requestRedraw()
            }
        }
        #endif
        
        // Also listen for scale changes
        coordinator.scaleChangeObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.PDFViewScaleChanged,
            object: pdfView,
            queue: .main
        ) { _ in
            overlayView.requestRedraw()
        }
        
        // Listen for selection mode notifications
        coordinator.setupNotifications()

        // Navigate to initial page if specified
        if let pageIndex = pageToDisplay,
           let page = document.page(at: pageIndex) {
            // Layout isn't settled on first appearance, so align on the next tick
            let scene = sceneToAlign
            DispatchQueue.main.async {
                scroll(pdfView, to: page, scene: scene)
            }
            coordinator.lastDisplayedPage = pageIndex
            coordinator.lastAlignedScene = scene?.persistentModelID
            print("📄 PDF Viewer: Navigated to page \(pageIndex + 1)")
        }
        
        return containerView
    }
    
    func updateContainer(_ nsView: PlatformViewBase, _ coordinator: Coordinator) {
        guard let pdfView = coordinator.pdfView else { return }

        // Keep the "current page" report wired to the latest binding.
        coordinator.onPageChange = { idx in
            if currentPageIndex != idx { currentPageIndex = idx }
        }

        // Update document if it changed
        if pdfView.document !== document {
            pdfView.document = document
        }
        
        // Navigate when the target scene (or its page) changes. Keyed on the scene
        // as well, so picking another scene on the same page still re-aligns.
        let sceneID = sceneToAlign?.persistentModelID
        if let pageIndex = pageToDisplay,
           pageIndex != coordinator.lastDisplayedPage || sceneID != coordinator.lastAlignedScene,
           let page = document.page(at: pageIndex) {
            // Scroll on the next tick so PDFView has finished laying out; going
            // immediately can land short of the target.
            let scene = sceneToAlign
            DispatchQueue.main.async {
                scroll(pdfView, to: page, scene: scene)
            }
            coordinator.lastDisplayedPage = pageIndex
            coordinator.lastAlignedScene = sceneID
            print("📄 PDF Viewer: Navigated to page \(pageIndex + 1)")
        }
        
        // Update overlay with current shot and all shots from project.
        if let overlayView = coordinator.overlayView {
            overlayView.selectedShot = selectedShot
            overlayView.marginFraction = coverageMargin

            // Collect all shots with coverage from all scenes
            var allShotsWithCoverage: [Shot] = []
            for scene in (version?.scenes ?? project.scenes) {
                for shot in scene.shots {
                    if let selections = shot.scriptCoverageSelections, !selections.isEmpty {
                        allShotsWithCoverage.append(shot)
                    }
                }
            }
            overlayView.allShotsWithCoverage = allShotsWithCoverage
            overlayView.requestRedraw()
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator {
        var lastDisplayedPage: Int? = nil
        var lastAlignedScene: PersistentIdentifier? = nil
        var pdfView: PDFView?
        var containerView: PlatformViewBase?
        var overlayView: PDFCoverageOverlayView?
        var selectionModeObserver: NSObjectProtocol?
        var captureObserver: NSObjectProtocol?
        var cancelObserver: NSObjectProtocol?
        var scrollObserver: NSObjectProtocol?
        var scrollOffsetObservation: NSKeyValueObservation?
        var pageChangeObserver: NSObjectProtocol?
        var scaleChangeObserver: NSObjectProtocol?
        var onPageChange: ((Int) -> Void)?
        var displayTimer: Timer?
        var isInSelectionMode = false
        var currentSelectionShot: Shot?
        var selectionStartPage: PDFPage?
        
        func setupNotifications() {
            selectionModeObserver = NotificationCenter.default.addObserver(
                forName: .startScriptTextSelection,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self = self,
                      let shot = notification.userInfo?["shot"] as? Shot else { return }
                
                self.enterSelectionMode(for: shot)
            }
            // No continuous redraw timer: the overlay repaints on scroll (macOS: the
            // NSScrollView bounds observer; iOS: the scroll-view contentOffset KVO in
            // makeContainer) and on page/scale/coverage changes. A 30fps timer ran
            // heavy per-frame PDFKit coordinate conversions and pegged iPad's main
            // thread while just viewing a coverage-heavy script.
        }
        
        func enterSelectionMode(for shot: Shot) {
            print("🎯 Entering text selection mode for shot \(shot.displayNumber)")
            isInSelectionMode = true
            currentSelectionShot = shot

            // The instruction and Done/Cancel now live in the SwiftUI coverage
            // card, so tell it selection has started rather than overlaying the PDF.
            NotificationCenter.default.post(
                name: .scriptSelectionModeChanged, object: nil,
                userInfo: ["active": true, "shotID": shot.persistentModelID])

            // Done/Cancel in the card drive the same capture/cancel as before.
            captureObserver = NotificationCenter.default.addObserver(
                forName: .captureScriptSelection, object: nil, queue: .main) { [weak self] _ in
                self?.captureSelection()
            }
            cancelObserver = NotificationCenter.default.addObserver(
                forName: .cancelScriptSelection, object: nil, queue: .main) { [weak self] _ in
                self?.cancelSelection()
            }

            if pdfView != nil { startTrackingSelection() }
        }
        
        func startTrackingSelection() {
            guard let pdfView = pdfView else { return }
            
            // Monitor selection changes
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self = self else { return }
                
                if self.isInSelectionMode {
                    // Continue tracking
                    self.startTrackingSelection()
                }
            }
        }
        
        func captureSelection() {
            guard let pdfView = pdfView,
                  let selection = pdfView.currentSelection,
                  let shot = currentSelectionShot,
                  !(selection.string?.isEmpty ?? true) else {
                print("⚠️ No text selected or selection is empty")
                exitSelectionMode()
                return
            }
            
            print("📝 Capturing selection for shot \(shot.displayNumber)")
            print("   Selected text: '\(selection.string?.prefix(50) ?? "")'...")
            
            // Convert selection to our data model
            var pageRanges: [PageTextRange] = []
            
            // Get all pages that have selections
            let pages = selection.pages
            
            for page in pages {
                guard let pageIndex = pdfView.document?.index(for: page) else { continue }
                
                // Get all line selections for better accuracy
                var boundsForPage: [PDFSelectionBounds] = []
                
                let lineSelections = selection.selectionsByLine()
                for lineSelection in lineSelections {
                    if lineSelection.pages.contains(page) {
                        // Get bounds in page coordinates (these are what we need to store)
                        let lineBounds = lineSelection.bounds(for: page)
                        if !lineBounds.isEmpty {
                            boundsForPage.append(PDFSelectionBounds(from: lineBounds))
                            print("   ✓ Stored bounds in page coords: \(lineBounds)")
                        }
                    }
                }
                
                // Fallback: if no line selections, use the whole selection bounds
                if boundsForPage.isEmpty {
                    let bounds = selection.bounds(for: page)
                    if !bounds.isEmpty {
                        boundsForPage.append(PDFSelectionBounds(from: bounds))
                        print("   ✓ Stored fallback bounds: \(bounds)")
                    }
                }
                
                if !boundsForPage.isEmpty {
                    pageRanges.append(PageTextRange(pageIndex: pageIndex, selections: boundsForPage))
                    print("   ✓ Page \(pageIndex + 1): \(boundsForPage.count) selection(s)")
                }
            }
            
            if !pageRanges.isEmpty {
                // Extract the selected text
                let selectedText = selection.string ?? ""
                let textSelection = ScriptTextSelection(pageRanges: pageRanges, fullText: selectedText)
                
                // Update shot (create array if needed)
                if shot.scriptCoverageSelections == nil {
                    shot.scriptCoverageSelections = []
                }
                shot.scriptCoverageSelections?.append(textSelection)
                
                print("✅ Saved coverage with \(pageRanges.count) page(s)")
                print("   📝 Text: \"\(selectedText.prefix(50))...\"")
                
                // Update overlay
                overlayView?.requestRedraw()
            } else {
                print("⚠️ No valid page ranges found in selection")
            }
            
            // Exit selection mode
            exitSelectionMode()
        }
        
        func cancelSelection() {
            print("❌ Selection cancelled")
            exitSelectionMode()
        }
        
        func exitSelectionMode() {
            isInSelectionMode = false
            currentSelectionShot = nil

            // Clear selection
            pdfView?.clearSelection()

            // Tell the coverage card selection mode is over so it hides the
            // instruction and Done/Cancel.
            NotificationCenter.default.post(
                name: .scriptSelectionModeChanged, object: nil,
                userInfo: ["active": false])

            if let observer = captureObserver {
                NotificationCenter.default.removeObserver(observer)
                captureObserver = nil
            }
            if let observer = cancelObserver {
                NotificationCenter.default.removeObserver(observer)
                cancelObserver = nil
            }
        }
        
        deinit {
            displayTimer?.invalidate()
            displayTimer = nil
            scrollOffsetObservation?.invalidate()

            if let observer = selectionModeObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = captureObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = cancelObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = scrollObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = pageChangeObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = scaleChangeObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}

#if canImport(UIKit)
private extension UIView {
    /// The first `UIScrollView` in this view's subtree (PDFView wraps its document
    /// in a private scroll view), for observing scroll offset.
    var firstScrollView: UIScrollView? {
        if let scroll = self as? UIScrollView { return scroll }
        for sub in subviews {
            if let found = sub.firstScrollView { return found }
        }
        return nil
    }
}
#endif

// MARK: - Coverage Overlay View

class PDFCoverageOverlayView: PlatformViewBase {
    weak var pdfView: PDFView?
    var selectedShot: Shot?
    var allShotsWithCoverage: [Shot] = []
    /// Right edge of the coverage-line band, as a fraction of page width.
    var marginFraction: CGFloat = 0.15

    // Color palette for different shots within the same scene
    private let shotColors: [PlatformColor] = [
        .systemBlue,
        .systemGreen,
        .systemOrange,
        .systemPurple,
        .systemPink,
        .systemTeal,
        .systemIndigo,
        .systemRed,
        .systemYellow,
        .systemBrown
    ]

    override init(frame frameRect: CGRect) {
        super.init(frame: frameRect)
        #if canImport(UIKit)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false   // let touches reach the PDF view below
        #else
        wantsLayer = true
        layer?.backgroundColor = .clear
        #endif
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Repaints the overlay, cross-platform.
    func requestRedraw() {
        #if canImport(UIKit)
        setNeedsDisplay()
        #else
        needsDisplay = true
        #endif
    }

    #if os(macOS)
    override var isFlipped: Bool {
        return false // Don't flip - we'll handle coordinate conversion manually
    }

    // Allow mouse events to pass through to the PDF view below
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
    #endif

    // A shot's coverage colour is a pure function of its position within its
    // scene. Deterministic (no scroll- or page-dependent collision avoidance) so
    // it matches the iPad viewer and every exporter exactly.
    private func color(for shot: Shot) -> PlatformColor {
        guard let scene = shot.scene,
              let index = scene.orderedShots.firstIndex(where: { $0 === shot }) else { return .systemBlue }
        return shotColors[index % shotColors.count]
    }
    
    // Place overlapping lines across the left page margin before stacking them.
    private func calculateLineX(
        for shot: Shot,
        at verticalRange: ClosedRange<CGFloat>,
        within xRange: ClosedRange<CGFloat>,
        minimumCenterSpacing: CGFloat,
        existingLines: inout [(range: ClosedRange<CGFloat>, offset: CGFloat, shot: Shot)]
    ) -> CGFloat {
        let usableWidth = xRange.upperBound - xRange.lowerBound
        guard usableWidth > 0 else {
            return xRange.lowerBound
        }

        let targetSlotCount = 8
        let targetSpacing = targetSlotCount > 1 ? usableWidth / CGFloat(targetSlotCount - 1) : usableWidth
        let minimumSpacing = max(6, min(minimumCenterSpacing, targetSpacing))
        let slotCount = max(1, Int(floor(usableWidth / minimumSpacing)) + 1)
        let actualSpacing = slotCount > 1 ? usableWidth / CGFloat(slotCount - 1) : 0

        for slotIndex in 0..<slotCount {
            let candidateX = xRange.upperBound - (CGFloat(slotIndex) * actualSpacing)
            let conflicts = existingLines.contains { existing in
                existing.range.overlaps(verticalRange) && abs(existing.offset - candidateX) < max(minimumSpacing - 1, actualSpacing * 0.75)
            }

            if !conflicts {
                existingLines.append((range: verticalRange, offset: candidateX, shot: shot))
                return candidateX
            }
        }

        let fallbackX = xRange.lowerBound
        existingLines.append((range: verticalRange, offset: fallbackX, shot: shot))
        return fallbackX
    }

    private func pageBoundsInOverlay(for pageRange: PageTextRange, document: PDFDocument, pdfView: PDFView) -> CGRect? {
        guard let page = document.page(at: pageRange.pageIndex) else {
            return nil
        }

        let pageBoundsInView = pdfView.convert(page.bounds(for: .mediaBox), from: page)
        let pageBoundsInOverlay = convert(pageBoundsInView, from: pdfView)
        return pageBoundsInOverlay.isEmpty ? nil : pageBoundsInOverlay
    }

    override func draw(_ dirtyRect: CGRect) {
        super.draw(dirtyRect)
        #if canImport(UIKit)
        guard let context = UIGraphicsGetCurrentContext() else { return }
        #else
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        #endif
        render(in: context)
    }

    /// A resolved coverage line: where its vertical bar sits, and where its shot
    /// number would rest above it at the base font.
    private struct CoveragePlacement {
        let pageX: CGFloat
        let minY: CGFloat
        let maxY: CGFloat
        let color: PlatformColor
        let label: String
        let baseLabelRect: CGRect
        let minPageX: CGFloat
        let maxPageX: CGFloat
    }

    private func render(in context: CGContext) {
        guard let pdfView = pdfView,
              let document = pdfView.document else { return }

        // Pass 1: resolve every coverage line's placement. Lines still fan out
        // across the left margin so their bars don't sit on top of each other.
        var existingLines: [(range: ClosedRange<CGFloat>, offset: CGFloat, shot: Shot)] = []
        var placements: [CoveragePlacement] = []
        for shot in allShotsWithCoverage {
            guard let selections = shot.scriptCoverageSelections else { continue }
            for selection in selections {
                if let placement = linePlacement(for: selection, shot: shot,
                                                 pdfView: pdfView, document: document,
                                                 existingLines: &existingLines) {
                    placements.append(placement)
                }
            }
        }

        // One scale that keeps every shot number centered above its own line yet
        // never lets two labels overlap — the numbers shrink together on a narrow
        // pane instead of being shuffled around.
        let scale = labelScale(for: placements)

        // Pass 2: draw the bars, then the (scaled) shot numbers above them.
        for placement in placements {
            context.setStrokeColor(placement.color.cgColor)
            context.setLineWidth(max(1, 3 * scale))
            context.move(to: CGPoint(x: placement.pageX, y: placement.minY))
            context.addLine(to: CGPoint(x: placement.pageX, y: placement.maxY))
            context.strokePath()
            drawLabel(placement, scale: scale, in: context)
        }

        // Draw highlighted text for selected shot only
        if let shot = selectedShot,
           let selections = shot.scriptCoverageSelections {
            for selection in selections {
                drawHighlightedText(for: selection, in: context, pdfView: pdfView, document: document)
            }
        }
    }

    /// The largest uniform label scale (≤ 1) at which no two shot numbers overlap.
    private func labelScale(for placements: [CoveragePlacement]) -> CGFloat {
        let minScale: CGFloat = 0.4
        let pad: CGFloat = 2
        var scale: CGFloat = 1
        for i in placements.indices {
            for j in (i + 1)..<placements.count {
                let a = placements[i].baseLabelRect
                let b = placements[j].baseLabelRect
                // Only labels that share vertical space can collide.
                guard a.minY < b.maxY, b.minY < a.maxY else { continue }
                let dx = abs(a.midX - b.midX)
                let needed = (a.width + b.width) / 2
                guard needed > 0, dx < needed + pad else { continue }
                scale = min(scale, max(0, dx - pad) / needed)
            }
        }
        return max(minScale, min(1, scale))
    }

    /// Draws a shot number centered above its line at the shared scale.
    private func drawLabel(_ placement: CoveragePlacement, scale: CGFloat, in context: CGContext) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: PlatformFont.boldSystemFont(ofSize: 11 * scale),
            .foregroundColor: placement.color
        ]
        let string = NSAttributedString(string: placement.label, attributes: attributes)
        let size = string.size()
        let padding: CGFloat = 4
        var x = placement.pageX - size.width / 2
        x = min(max(x, placement.minPageX), max(placement.minPageX, placement.maxPageX - size.width))
        #if os(macOS)
        let y = max(placement.minY, placement.maxY) + padding   // y-up: above the top
        #else
        let y = min(placement.minY, placement.maxY) - padding - size.height
        #endif
        string.draw(at: CGPoint(x: x, y: y))
    }
    
    private func linePlacement(
        for selection: ScriptTextSelection,
        shot: Shot,
        pdfView: PDFView,
        document: PDFDocument,
        existingLines: inout [(range: ClosedRange<CGFloat>, offset: CGFloat, shot: Shot)]
    ) -> CoveragePlacement? {

        // Calculate the overall vertical extent of the selection across all pages
        var minY: CGFloat = .infinity
        var maxY: CGFloat = -.infinity
        var textMinX: CGFloat = .infinity
        var pageMinX: CGFloat = .infinity
        var pageMaxX: CGFloat = -.infinity
        var foundAnyBounds = false
        
        for pageRange in selection.pageRanges {
            guard let page = document.page(at: pageRange.pageIndex) else {
                continue
            }

            if let pageBoundsInOverlay = pageBoundsInOverlay(for: pageRange, document: document, pdfView: pdfView) {
                pageMinX = min(pageMinX, pageBoundsInOverlay.minX)
                pageMaxX = max(pageMaxX, pageBoundsInOverlay.maxX)
            }
            
            for selectionBounds in pageRange.selections {
                let boundsInPage = selectionBounds.cgRect
                
                // Convert from PDF page coordinates to view coordinates
                // PDFView.convert handles the coordinate system transformation
                let boundsInView = pdfView.convert(boundsInPage, from: page)
                
                // Convert to overlay view's coordinate system
                let boundsInOverlay = convert(boundsInView, from: pdfView)
                
                // Check if bounds are valid and visible
                guard !boundsInOverlay.isEmpty else {
                    continue
                }
                
                minY = min(minY, boundsInOverlay.minY)
                maxY = max(maxY, boundsInOverlay.maxY)
                textMinX = min(textMinX, boundsInOverlay.minX)
                
                foundAnyBounds = true
            }
        }
        
        if foundAnyBounds && minY != .infinity && maxY != -.infinity && minY < maxY {
            // Calculate line position with overlap prevention
            let verticalRange = minY...maxY
            let horizontalInset: CGFloat = 6
            let minimumPageX = pageMinX.isFinite ? pageMinX + horizontalInset : horizontalInset
            let maximumPageX = pageMaxX.isFinite ? pageMaxX - horizontalInset : bounds.maxX - horizontalInset
            let pageWidth = max(0, pageMaxX - pageMinX)
            let marginLimitX = pageMinX + (pageWidth * marginFraction)
            let lineRangeUpperBound = min(maximumPageX, marginLimitX)
            let lineRangeLowerBound = min(minimumPageX, lineRangeUpperBound)
            
            // Deterministic per-shot colour (matches iPad viewer and exporters).
            let lineColor = color(for: shot)
            print("   ✏️ [EDITOR DRAW] Using color \(lineColor) for shot \(shot.displayNumber)")

            // Draw shot number at the top
            let shotLabel = shot.displayNumber
            let attributes: [NSAttributedString.Key: Any] = [
                .font: PlatformFont.boldSystemFont(ofSize: 11),
                .foregroundColor: lineColor
            ]
            
            let attributedString = NSAttributedString(string: shotLabel, attributes: attributes)
            let textSize = attributedString.size()
            let padding: CGFloat = 4
            let labelWidth = textSize.width
            let pageX = calculateLineX(
                for: shot,
                at: verticalRange,
                within: lineRangeLowerBound...lineRangeUpperBound,
                minimumCenterSpacing: labelWidth + 6,
                existingLines: &existingLines
            )
            
            // The label's resting rect at the base font, centered above the line's
            // visual top. The overlay is y-up on macOS (larger Y = top) and y-down
            // on iOS (smaller Y = top), so the "above" direction differs.
            #if os(macOS)
            let labelTopY = max(minY, maxY)
            let baseLabelRect = CGRect(x: pageX - textSize.width / 2, y: labelTopY + padding,
                                       width: labelWidth, height: textSize.height)
            #else
            let labelTopY = min(minY, maxY)
            let baseLabelRect = CGRect(x: pageX - textSize.width / 2,
                                       y: labelTopY - padding - textSize.height,
                                       width: labelWidth, height: textSize.height)
            #endif
            return CoveragePlacement(
                pageX: pageX, minY: minY, maxY: maxY, color: lineColor,
                label: shotLabel, baseLabelRect: baseLabelRect,
                minPageX: minimumPageX, maxPageX: maximumPageX)
        }
        return nil
    }
    
    private func drawHighlightedText(for selection: ScriptTextSelection, in context: CGContext, pdfView: PDFView, document: PDFDocument) {
        // Draw yellow highlight for each selection bounds
        context.setFillColor(PlatformColor.systemYellow.withAlphaComponent(0.3).cgColor)
        
        for pageRange in selection.pageRanges {
            guard let page = document.page(at: pageRange.pageIndex) else { continue }
            
            for selectionBounds in pageRange.selections {
                let boundsInPage = selectionBounds.cgRect
                
                // Convert from PDF page coordinates to view coordinates
                let boundsInView = pdfView.convert(boundsInPage, from: page)
                
                // Convert to overlay view's coordinate system
                let boundsInOverlay = convert(boundsInView, from: pdfView)
                
                // Only draw if valid
                guard !boundsInOverlay.isEmpty else {
                    continue
                }
                
                // Fill the rectangle with highlight color
                context.fill(boundsInOverlay)
            }
        }
    }
}

// MARK: - Representable conformances (cross-platform)

#if canImport(UIKit)
extension PDFViewerWithCoverageRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> PlatformViewBase { makeContainer(context.coordinator) }
    func updateUIView(_ view: PlatformViewBase, context: Context) { updateContainer(view, context.coordinator) }
}
#else
extension PDFViewerWithCoverageRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> PlatformViewBase { makeContainer(context.coordinator) }
    func updateNSView(_ view: PlatformViewBase, context: Context) { updateContainer(view, context.coordinator) }
}
#endif
