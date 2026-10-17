import Foundation

/// Coding mode's cards, fed the frames the server sends (electron/codemode.ts phoneEvent, recorded 10-16).
@main struct CodeModeTests {
    static func frame(_ json: String) -> CodeFrame { try! JSONDecoder().decode(CodeFrame.self, from: Data(json.utf8)) }
    static func card(_ frames: [String]) -> CodeItem {
        var item: CodeItem?
        for json in frames {
            let f = frame(json)
            if item == nil { item = CodeItem(kind: f.kind!, id: f.id!) }
            item!.merge(f)
        }
        return item!
    }

    static func main() {
        assert(codeCommand("/code") == "")
        assert(codeCommand("  /code haru-desktop ") == "haru-desktop")
        assert(codeCommand("/codex") == nil && codeCommand("what is /code") == nil, "only a leading /code is a command")
        assert(terminalCommand("!git status") == "git status" && terminalCommand("  ! ls -la ") == "ls -la" && terminalCommand("!") == "")
        assert(terminalCommand("run git status!") == nil, "only a leading ! is a command")

        // A terminal card: started with the command, ended with output and a non-zero exit.
        let terminal = card([#"{"kind":"tool","id":"sh_1","name":"terminal","status":"running","title":"npm test"}"#,
                             #"{"kind":"tool","id":"sh_1","name":"terminal","status":"done","title":"npm test","output":"1 failed\n","exit":1}"#])
        assert(terminal.title == "npm test" && terminal.exit == 1 && terminal.output == "1 failed\n")

        // A tool card: started with its name only, then its title, then its result; an empty title never wipes the real one.
        let tool = card([#"{"kind":"tool","id":"t1","name":"shell","status":"running","title":""}"#,
                         #"{"kind":"tool","id":"t1","status":"running","title":"npm test"}"#,
                         #"{"kind":"tool","id":"t1","name":"shell","status":"done","output":"ok\n","exit":0}"#])
        assert(tool.name == "shell" && tool.title == "npm test" && tool.status == "done" && tool.output == "ok\n" && tool.exit == 0)

        // Her words stream in as deltas and the end event replaces them with the full text.
        let said = card([#"{"kind":"said","id":"m:0","delta":"Fixed "}"#, #"{"kind":"said","id":"m:0","delta":"it."}"#])
        assert(said.text == "Fixed it.")
        assert(card([#"{"kind":"said","id":"m:0","delta":"Fix"}"#, #"{"kind":"said","id":"m:0","text":"Fixed it."}"#]).text == "Fixed it.")

        // A question, then his answer to it.
        let ask = card([#"{"kind":"ask","id":"per_1","resources":["npm test"]}"#, #"{"kind":"ask","id":"per_1","reply":"once"}"#])
        assert(ask.resources == ["npm test"] && ask.reply == "once")

        // The state frame decodes whole, including fields the cards ignore.
        let state = frame(#"{"kind":"state","folder":"repo","model":"haru/mimo-v2.6-pro","models":[{"id":"haru/mimo-v2.6-pro","name":"MiMo V2.6 Pro"}],"projects":["repo"],"sessionId":"ses_1","spent":{"today":0.1,"cap":5,"resetsAt":null},"items":[{"kind":"you","id":"u1","text":"hi"}],"running":false}"#)
        assert(state.folder == "repo" && state.items?.count == 1 && state.spent?.cap == 5 && state.models?.first?.name == "MiMo V2.6 Pro")
        // A recent-sessions row, as GET /api/code/sessions sends it.
        let rows = try! JSONDecoder().decode(CodeSessions.self, from: Data(#"{"sessions":[{"id":"ses_1","folder":"repo","task":"Fix add()","at":"2026-10-17T17:00:00.000Z","updatedAt":"2026-10-17T17:05:00.123Z","model":"haru/qwen-3-6-plus-uncensored","archived":false,"current":true}]}"#.utf8))
        assert(rows.sessions.first?.folder == "repo" && rows.sessions.first?.current == true && rows.sessions.first?.updated != nil)
        print("code mode: ok")
    }
}
