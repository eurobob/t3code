import Foundation

enum CheckedInProjectScripts {
    private struct ProjectFile: Decodable {
        let scripts: [Script]?
    }

    private struct Script: Decodable {
        let name: String
        let command: String
        let icon: String?
        let runOnWorktreeCreate: Bool?
        let previewUrl: String?
        let autoOpenPreview: Bool?
    }

    private static let supportedIcons = Set([
        "play", "test", "lint", "configure", "build", "debug",
    ])

    static func decode(_ contents: String) -> [ProjectScript] {
        let normalized = removeTrailingCommas(from: removeComments(from: contents))
        guard let data = normalized.data(using: .utf8),
              let file = try? JSONDecoder.t3.decode(ProjectFile.self, from: data) else {
            return []
        }

        return (file.scripts ?? []).prefix(50).enumerated().compactMap { index, script in
            let name = script.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let command = script.command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !command.isEmpty else { return nil }

            let requestedIcon = script.icon ?? "play"
            let previewUrl = script.previewUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
            return ProjectScript(
                id: "checked-in-\(index)",
                name: name,
                command: command,
                icon: supportedIcons.contains(requestedIcon) ? requestedIcon : "play",
                runOnWorktreeCreate: script.runOnWorktreeCreate ?? false,
                previewUrl: previewUrl?.isEmpty == false ? previewUrl : nil,
                autoOpenPreview: previewUrl?.isEmpty == false
                    ? (script.autoOpenPreview ?? false)
                    : nil
            )
        }
    }

    /// Mirrors the checked-in project-file codec used by the web client. JSON
    /// delimiters are ASCII, so scanning Characters keeps quoted Unicode intact
    /// while making comment removal string-aware.
    private static func removeComments(from input: String) -> String {
        let characters = Array(input)
        var output: [Character] = []
        output.reserveCapacity(characters.count)
        var index = 0
        var insideString = false
        var escaped = false

        while index < characters.count {
            let character = characters[index]
            if insideString {
                output.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    insideString = false
                }
                index += 1
                continue
            }

            if character == "\"" {
                insideString = true
                output.append(character)
                index += 1
                continue
            }

            if character == "/", index + 1 < characters.count {
                let next = characters[index + 1]
                if next == "/" {
                    index += 2
                    while index < characters.count, characters[index] != "\n" {
                        index += 1
                    }
                    if index < characters.count {
                        output.append("\n")
                        index += 1
                    }
                    continue
                }
                if next == "*" {
                    index += 2
                    while index < characters.count {
                        if characters[index] == "\n" {
                            output.append("\n")
                        }
                        if characters[index] == "*",
                           index + 1 < characters.count,
                           characters[index + 1] == "/" {
                            index += 2
                            break
                        }
                        index += 1
                    }
                    continue
                }
            }

            output.append(character)
            index += 1
        }

        return String(output)
    }

    private static func removeTrailingCommas(from input: String) -> String {
        let characters = Array(input)
        var output: [Character] = []
        output.reserveCapacity(characters.count)
        var index = 0
        var insideString = false
        var escaped = false

        while index < characters.count {
            let character = characters[index]
            if insideString {
                output.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    insideString = false
                }
                index += 1
                continue
            }

            if character == "\"" {
                insideString = true
            } else if character == "," {
                var lookahead = index + 1
                while lookahead < characters.count, characters[lookahead].isWhitespace {
                    lookahead += 1
                }
                if lookahead < characters.count,
                   characters[lookahead] == "}" || characters[lookahead] == "]" {
                    index += 1
                    continue
                }
            }

            output.append(character)
            index += 1
        }

        return String(output)
    }
}
