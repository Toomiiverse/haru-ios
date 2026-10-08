import SwiftUI

struct PhoneToolsView:View {
    private let tools=PhoneTools.shared
    private let groups=[("weather","Apple weather"),("reminders","All permitted reminder lists"),("calendar","All permitted calendars"),("contacts","Contact lookup"),("health","Recorded sleep and steps"),("location","Location"),("maps","Open directions in Maps"),("open","Browser and Haru settings")]
    var body:some View {
        List {
            Section {LabeledContent("Connection",value:tools.connected ? "Connected":"Open Haru to connect");Button("Use this iPhone as the default"){Task{await tools.makeDefault()}}.disabled(!tools.connected)}
            Section("Allow explicit phone requests") {
                ForEach(groups,id:\.0){domain,title in Toggle(title,isOn:Binding(get:{tools.enabled(domain)},set:{on in Task{await tools.setEnabled(domain,on)}}))}
            }
            Section {Text("Haru reads only what you allow. Clear requests can create or change reminders and events. Deletion needs your confirmation. Actions do not wait to run later when this phone is unavailable. Health and contacts are read-only. Calls, texts and emails are not included.")}
            if let problem=tools.problem{Section("Needs attention"){Text(problem)}}
            if !tools.lastResult.isEmpty{Section("Last result"){Text(tools.lastResult)}}
            Section {Link("Apple Weather attribution",destination:URL(string:"https://weatherkit.apple.com/legal-attribution.html")!)}
        }.navigationTitle("Phone tools")
    }
}
