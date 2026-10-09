import Foundation
import UIKit
import Observation
import EventKit
import Contacts
import CoreLocation
import MapKit
import HealthKit
import WeatherKit

/// Device adapter. Core selects operations; this class only checks the platform
/// permissions, retained command, expiration and current object before execution.
@MainActor @Observable final class PhoneTools: NSObject {
    static let shared = PhoneTools()
    var connected = false
    var problem: String?
    var lastResult = ""
    var weatherMark: URL?
    var weatherLegal: URL?
    var domains = Set<String>()
    var foreground = false
    var carPlayActive = false
    var carPlayDirections: ((String, String, Double) async throws -> [String: Any])?
    private var presented: Bool { foreground || carPlayActive }
    var callActive = false
    private var socket: URLSessionWebSocketTask?
    private var loop: Task<Void,Never>?
    private var beat: Task<Void,Never>?
    private var serverClock: (Double,Double)?
    private func nowMilliseconds()->Double { if let (server,uptime)=serverClock{return server+(ProcessInfo.processInfo.systemUptime-uptime)*1000};return Date().timeIntervalSince1970*1000 }
    func commandIsCurrent(_ expiry: Double) -> Bool { nowMilliseconds() < expiry }
    private var generation = UUID()
    private let events = EKEventStore()
    private let contacts = CNContactStore()
    private let health = HKHealthStore()
    private let defaults = UserDefaults.standard
    private let journalURL: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("PhoneTools",isDirectory:true)
        try? FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        return url.appendingPathComponent("receipts.json")
    }()
    private var receipts: [String:[String:Any]] = [:]
    private var executing = Set<String>()
    private var grants:[String:CheckedContinuation<Void,Error>]=[:]
    override init(){super.init();for domain in ["weather","reminders","calendar","contacts","health","location","maps","open"] {let key="phoneTools."+domain;if defaults.object(forKey:key)==nil {let prior=["health":"health.enabled","location":"where.enabled","reminders":"reminders.enabled"][domain];if let prior{defaults.set(defaults.bool(forKey:prior),forKey:key)}};if defaults.bool(forKey:key){domains.insert(domain)}};if let bytes=try? Data(contentsOf:journalURL),let rows=try? JSONSerialization.jsonObject(with:bytes) as? [String:[String:Any]]{receipts=rows}}
    func enabled(_ domain:String)->Bool{domains.contains(domain)}
    func setEnabled(_ domain:String,_ on:Bool) async {
        do {
            if on {
                switch domain {
                case "reminders":guard try await events.requestFullAccessToReminders() else {throw Failure("ios_permission_required")}
                case "calendar":guard try await events.requestFullAccessToEvents() else {throw Failure("ios_permission_required")}
                case "contacts":guard try await contacts.requestAccess(for:.contacts) else {throw Failure("ios_permission_required")}
                case "health":try await health.requestAuthorization(toShare:[],read:[HKCategoryType(.sleepAnalysis),HKQuantityType(.stepCount)])
                case "location":try await PhoneLocation.shared.authorise()
                default:break
                }
            }
            defaults.set(on,forKey:"phoneTools."+domain);if on{domains.insert(domain)}else{domains.remove(domain)};problem=nil
            if connected{await hello()}
        } catch {problem=error.localizedDescription}
    }
    func activity(foreground:Bool?=nil,callActive:Bool?=nil,carPlayActive:Bool?=nil){
        if let foreground{self.foreground=foreground};if let callActive{self.callActive=callActive}
        if let carPlayActive { self.carPlayActive = carPlayActive }
        if presented || self.callActive {if loop==nil{start()}} else {stop()}
    }
    func makeDefault() async {try? await send(["type":"default"])}
    func stop(){generation=UUID();loop?.cancel();beat?.cancel();loop=nil;beat=nil;socket?.cancel(with:.goingAway,reason:nil);socket=nil;connected=false}
    private func start(){
        let epoch=generation
        loop=Task { [weak self] in
            guard let self else{return}
            while !Task.isCancelled,self.generation==epoch,self.presented || self.callActive {
                do {
                    let client=Session.savedClient();var parts=URLComponents(url:client.base.appendingPathComponent("/api/ios/session"),resolvingAgainstBaseURL:false)!
                    parts.scheme=parts.scheme=="https" ? "wss":"ws"
                    var request=URLRequest(url:parts.url!)
                    if let cookies=HTTPCookieStorage.shared.cookies(for:client.base){for(k,v) in HTTPCookie.requestHeaderFields(with:cookies){request.setValue(v,forHTTPHeaderField:k)}}
                    let ws=client.session.webSocketTask(with:request);self.socket=ws;ws.resume();await self.hello()
                    self.beat=Task { [weak self] in
                        while !Task.isCancelled {try? await Task.sleep(for:.seconds(10));guard let self else{return};try? await self.send(["type":"heartbeat","foreground":self.presented,"callActive":self.callActive])}
                    }
                    while !Task.isCancelled,self.generation==epoch {
                        let message=try await ws.receive();guard case .string(let raw)=message,raw.utf8.count<=262144,let data=raw.data(using:.utf8),let frame=try JSONSerialization.jsonObject(with:data) as? [String:Any] else{throw Failure("ios_invalid_frame")}
                        switch frame["type"] as? String {
                        case "ready":if let now=frame["nowMs"] as? Double{self.serverClock=(now,ProcessInfo.processInfo.systemUptime)};self.connected=true;for (key,receipt) in self.receipts { if receipt["type"] as? String=="result",receipt["acknowledged"] as? Bool != true,receipt["server"] as? String == Session.savedClient().base.absoluteString {try await self.send(receipt)} else if receipt["type"] as? String=="started",receipt["server"] as? String == Session.savedClient().base.absoluteString,!self.executing.contains(key),let op=receipt["operationId"] as? String {try await self.send(["type":"result","commandId":key,"operationId":op,"data":["ok":false,"unknown":true,"status":"unknown"]])}}
                        case "command":Task {await self.execute(frame)}
                        case "grant":if let id=frame["commandId"] as? String,let wait=self.grants.removeValue(forKey:id){wait.resume()}
                        case "receipt_ack":if let id=frame["commandId"] as? String,var old=self.receipts[id]{old["acknowledged"]=true;try? self.retain(id,old);if frame["mirrorConfirmed"] as? Bool==true,let data=old["data"] as? [String:Any],let item=data["itemId"] as? String,data["listName"] as? String=="Haru"{Reminders.shared.acknowledgeBridge(item,serverId:frame["canonicalAgendaId"] as? String)}}
                        default:break
                        }
                    }
                }catch{self.problem=error.localizedDescription}
                self.connected=false;self.beat?.cancel();self.socket?.cancel(with:.goingAway,reason:nil)
                try? await Task.sleep(for:.seconds(3)) // Reconnect transport only; never execute cached requests.
            }
            if self.generation==epoch{self.loop=nil}
        }
    }
    private func hello() async {
        var caps=Dictionary(uniqueKeysWithValues:["weather","reminders","calendar","contacts","health","location","maps","open"].map{($0,enabled($0))})
        caps["reminders"]=enabled("reminders") && EKEventStore.authorizationStatus(for:.reminder) == .fullAccess
        caps["calendar"]=enabled("calendar") && EKEventStore.authorizationStatus(for:.event) == .fullAccess
        try? await send(["version":1,"type":"hello","name":UIDevice.current.name,"appVersion":(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")+" ("+(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "")+")","timezone":TimeZone.current.identifier,"foreground":presented,"callActive":callActive,"capabilities":caps])
    }
    private func send(_ frame:[String:Any]) async throws {
        guard let socket else{throw Failure("ios_not_connected")}
        let bytes=try JSONSerialization.data(withJSONObject:frame);guard bytes.count<=262144 else{throw Failure("ios_result_too_large")}
        try await socket.send(.string(String(decoding:bytes,as:UTF8.self)))
    }
    private func retain(_ id:String,_ value:[String:Any]) throws {
        var scoped=value;scoped["server"]=Session.savedClient().base.absoluteString;receipts[id]=scoped
        let bytes=try JSONSerialization.data(withJSONObject:receipts)
        try bytes.write(to:journalURL,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
    }
    private func execute(_ command:[String:Any]) async {
        guard let id=command["commandId"] as? String,let op=command["operationId"] as? String,let tool=command["tool"] as? String,let args=command["args"] as? [String:Any],let expires=command["expiresAt"] as? Double,command["version"] as? Int==1 else{return}
        if let old=receipts[id] {
            if old["type"] as? String=="result"{try? await send(old)}
            else if !executing.contains(id){try? await send(["type":"result","commandId":id,"operationId":op,"data":["ok":false,"unknown":true,"status":"unknown"]])}
            return
        }
        var began=false
        do {
            guard nowMilliseconds()<expires else{throw Failure("ios_command_expired")}
            guard presented || callActive else{throw Failure("ios_foreground_required")}
            let domain=String(tool.dropFirst(4));guard enabled(domain) else{throw Failure("ios_permission_required")}
            let carSafeWhileLocked = carPlayActive && ["ios_maps", "ios_weather", "ios_location"].contains(tool)
            guard UIApplication.shared.isProtectedDataAvailable || carSafeWhileLocked else{throw Failure("ios_foreground_required")}
            if tool=="ios_maps"{guard presented else{throw Failure("ios_foreground_required")}}
            if tool=="ios_open"{guard foreground, !carPlayActive else{throw Failure("ios_foreground_required")}}
            try validatePermission(tool)
            try await claim(id,operation:op)
            guard nowMilliseconds()<expires,presented || callActive else{throw Failure("ios_command_expired")}
            // Persist before any framework mutation. A crash in this interval
            // becomes unknown, not permission to repeat the operation.
            try retain(id,["type":"started","operationId":op]);began=true;executing.insert(id)
            let result=try await run(tool,args:args,operation:id,expires:expires)
            let receipt:[String:Any]=["type":"result","commandId":id,"operationId":op,"data":result]
            try retain(id,receipt);executing.remove(id);lastResult=String(describing:result["title"] ?? result["place"] ?? "Completed")
            try? await send(receipt)
        }catch{
            executing.remove(id)
            let mutation=command["access"] as? String=="mutation"
            var value:[String:Any]=began && mutation && !(error is Failure) ? ["ok":false,"unknown":true,"status":"unknown"]:["ok":false,"error":(error as? Failure)?.code ?? "ios_framework_error","executed":false]
            if let weatherError=error as? WeatherFailure {value["framework"]=["stage":weatherError.stage,"domain":weatherError.domain,"code":weatherError.number]}
            let receipt:[String:Any]=["type":"result","commandId":id,"operationId":op,"data":value]
            try? retain(id,receipt);try? await send(receipt);problem=error.localizedDescription
        }
    }
    private func claim(_ id:String,operation:String) async throws {
        try await withCheckedThrowingContinuation{(wait:CheckedContinuation<Void,Error>) in
            grants[id]=wait
            Task {do{try await self.send(["type":"claim","commandId":id,"operationId":operation])}catch{self.grants.removeValue(forKey:id)?.resume(throwing:error)}}
            Task {try? await Task.sleep(for:.seconds(3));self.grants.removeValue(forKey:id)?.resume(throwing:Failure("ios_command_expired"))}
        }
    }
    private func validatePermission(_ tool:String) throws {
        if tool=="ios_calendar",EKEventStore.authorizationStatus(for:.event) != .fullAccess{throw Failure("ios_permission_required")}
        if tool=="ios_reminders",EKEventStore.authorizationStatus(for:.reminder) != .fullAccess{throw Failure("ios_permission_required")}
        if tool=="ios_contacts"{let permission=CNContactStore.authorizationStatus(for:.contacts);if #available(iOS 18.0,*){guard permission == .authorized || permission == .limited else{throw Failure("ios_permission_required")}}else{guard permission == .authorized else{throw Failure("ios_permission_required")}}}
    }
    private func iso(_ date:Date)->String{ISO8601DateFormatter().string(from:date)}
    private func date(_ value:String) throws -> Date {
        if let date=ISO8601DateFormatter().date(from:value){return date}
        let f=DateFormatter();f.calendar=Calendar(identifier:.gregorian);f.locale=Locale(identifier:"en_US_POSIX");f.dateFormat="yyyy-MM-dd";f.timeZone = .current
        guard value.count==10,let date=f.date(from:value),f.string(from:date)==value else{throw Failure("ios_invalid_date")};return date
    }
    private func revision(_ item:EKCalendarItem)->String{iso(item.lastModifiedDate ?? item.creationDate ?? .distantPast)}
    private func reminderRow(_ r:EKReminder)->[String:Any]{
        var row:[String:Any]=["id":r.calendarItemIdentifier,"title":r.title ?? "","completed":r.isCompleted,"listId":r.calendar.calendarIdentifier,"listName":r.calendar.title,"revision":revision(r)]
        if let components=r.dueDateComponents,let due=Calendar.current.date(from:components){row["due"]=iso(due)}
        return row
    }
    private func eventRow(_ r:EKEvent)->[String:Any]{["id":r.eventIdentifier ?? r.calendarItemIdentifier,"title":r.title ?? "","start":iso(r.startDate),"end":iso(r.endDate),"allDay":r.isAllDay,"calendarId":r.calendar.calendarIdentifier,"revision":revision(r),"hasAttendees":!(r.attendees ?? []).isEmpty]}
    private func run(_ tool:String,args:[String:Any],operation:String,expires:Double) async throws -> [String:Any] {
        let action=args["action"] as? String ?? "list",limit=min(50,max(1,args["limit"] as? Int ?? 20))
        switch tool {
        case "ios_reminders":
            let all=await withCheckedContinuation{(c:CheckedContinuation<[EKReminder],Never>) in events.fetchReminders(matching:events.predicateForReminders(in:events.calendars(for:.reminder))){c.resume(returning:$0 ?? [])}}
            if action=="list" || action=="get" {
                let id=args["itemId"] as? String,query=(args["query"] as? String ?? "").lowercased()
                let selected=all.filter{(id==nil || $0.calendarItemIdentifier==id) && (query.isEmpty || ($0.title ?? "").lowercased().contains(query))}
                return ["ok":true,"items":Array(selected.prefix(limit)).map(reminderRow),"truncated":selected.count>limit]
            }
            let r:EKReminder
            if action=="create"{
                r=EKReminder(eventStore:events)
                if let id=args["listId"] as? String{guard let list=events.calendar(withIdentifier:id),list.allowsContentModifications else{throw Failure("ios_list_unavailable")};r.calendar=list}
                else if let list=events.calendars(for:.reminder).first(where:{$0.title=="Haru" && $0.allowsContentModifications}){r.calendar=list}
                else {let list=EKCalendar(for:.reminder,eventStore:events);list.title="Haru";guard let source=events.defaultCalendarForNewReminders()?.source ?? events.sources.first(where:{$0.sourceType == .local}) else{throw Failure("ios_list_unavailable")};list.source=source;try events.saveCalendar(list,commit:true);r.calendar=list}
                r.url=URL(string:"haru://operation/"+operation)
            } else {guard let id=args["itemId"] as? String,let found=all.first(where:{$0.calendarItemIdentifier==id}) else{throw Failure("ios_item_missing")};r=found;if let expected=args["expectedRevision"] as? String,expected != revision(r){throw Failure("ios_stale_item")}}
            let previousTitle=r.title ?? "",serverId=Reminders.shared.serverIdentifier(r.calendarItemIdentifier)
            if r.calendar.title=="Haru"{await Reminders.shared.pauseBridge()}
            guard nowMilliseconds()<expires else{throw Failure("ios_command_expired")}
            if let title=args["title"] as? String{r.title=title};if let notes=args["notes"] as? String{r.notes=notes}
            if let due=args["due"] as? String{r.dueDateComponents=Calendar.current.dateComponents([.year,.month,.day,.hour,.minute],from:try date(due))}
            if action=="complete"{r.isCompleted=true}
            if action=="delete"{try events.remove(r,commit:true)}else{try events.save(r,commit:true)}
            if r.calendar.title=="Haru"{Reminders.shared.holdBridge(r.calendarItemIdentifier)}
            var result:[String:Any]=["ok":true,"title":r.title ?? "","itemId":r.calendarItemIdentifier,"listName":r.calendar.title,"previousTitle":previousTitle]
            result[action=="create" ? "created":action=="update" ? "updated":action=="complete" ? "completed":"deleted"]=true
            if let serverId{result["serverId"]=serverId}
            if let due=r.dueDateComponents {if let y=due.year,let m=due.month,let d=due.day{result["dueDay"]=String(format:"%04d-%02d-%02d",y,m,d)};if let h=due.hour,let m=due.minute{result["dueTime"]=String(format:"%02d:%02d",h,m)}}
            return result
        case "ios_calendar":
            if action=="list" || action=="get" {
                let start=try (args["start"] as? String).map(date) ?? Date(),end=try (args["end"] as? String).map(date) ?? start.addingTimeInterval(7*86400)
                let all: [EKEvent];if let id=args["itemId"] as? String {all=events.event(withIdentifier:id).map{[$0]} ?? []} else {all=events.events(matching:events.predicateForEvents(withStart:start,end:end,calendars:events.calendars(for:.event)))}
                let id=args["itemId"] as? String,query=(args["query"] as? String ?? "").lowercased()
                let selected=all.filter{(id==nil || $0.eventIdentifier==id) && (query.isEmpty || ($0.title ?? "").lowercased().contains(query))}
                return ["ok":true,"items":Array(selected.prefix(limit)).map(eventRow),"truncated":selected.count>limit]
            }
            let r:EKEvent
            if action=="create"{r=EKEvent(eventStore:events);if let id=args["calendarId"] as? String {guard let calendar=events.calendar(withIdentifier:id) else{throw Failure("ios_list_unavailable")};r.calendar=calendar}else{r.calendar=events.defaultCalendarForNewEvents};r.url=URL(string:"haru://operation/"+operation)}
            else {guard let id=args["itemId"] as? String,let found=events.event(withIdentifier:id) else{throw Failure("ios_item_missing")};r=found;if let expected=args["expectedRevision"] as? String,expected != revision(r){throw Failure("ios_stale_item")}}
            guard r.calendar?.allowsContentModifications==true else{throw Failure("ios_readonly_calendar")}
            guard nowMilliseconds()<expires else{throw Failure("ios_command_expired")}
            if let title=args["title"] as? String{r.title=title};if let notes=args["notes"] as? String{r.notes=notes};if let location=args["location"] as? String{r.location=location}
            if let start=args["start"] as? String{r.startDate=try date(start)};if let end=args["end"] as? String{r.endDate=try date(end)};if let allDay=args["allDay"] as? Bool{r.isAllDay=allDay}
            if action=="delete"{try events.remove(r,span:.thisEvent,commit:true)}else{try events.save(r,span:.thisEvent,commit:true)}
            return ["ok":true,action=="create" ? "created":action=="update" ? "updated":"deleted":true,"title":r.title ?? "","itemId":r.eventIdentifier ?? ""]
        case "ios_contacts":
            let query=args["query"] as? String ?? "";guard !query.isEmpty else{throw Failure("ios_contact_query_required")}
            let rows=try contacts.unifiedContacts(matching:CNContact.predicateForContacts(matchingName:query),keysToFetch:[CNContactGivenNameKey as CNKeyDescriptor,CNContactFamilyNameKey as CNKeyDescriptor,CNContactPhoneNumbersKey as CNKeyDescriptor,CNContactEmailAddressesKey as CNKeyDescriptor])
            return ["ok":true,"items":Array(rows.prefix(limit)).map{["id":$0.identifier,"name":$0.givenName+" "+$0.familyName,"phones":$0.phoneNumbers.map{$0.value.stringValue},"emails":$0.emailAddresses.map{($0.value as String)}]},"truncated":rows.count>limit]
        case "ios_health":
            let day=try (args["day"] as? String).map(date) ?? Date(),start=Calendar.current.startOfDay(for:day),end=Calendar.current.date(byAdding:.day,value:1,to:start)!
            let metric=args["metric"] as? String ?? "summary"
            var data:[String:Any]=["ok":true,"day":{let formatter=DateFormatter();formatter.dateFormat="yyyy-MM-dd";formatter.timeZone = .current;return formatter.string(from:start)}(),"steps":NSNull(),"sleepMinutes":NSNull()]
            if metric != "sleep",let steps=try await stepCount(from:start,to:min(end,Date())){data["steps"]=steps}
            if metric != "steps"{let samples=try await healthSamples(HKCategoryType(.sleepAnalysis),from:start.addingTimeInterval(-6*3600),to:min(start.addingTimeInterval(12*3600),Date()));let intervals=samples.compactMap{$0 as? HKCategorySample}.filter{[HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,HKCategoryValueSleepAnalysis.asleepCore.rawValue,HKCategoryValueSleepAnalysis.asleepDeep.rawValue,HKCategoryValueSleepAnalysis.asleepREM.rawValue].contains($0.value)}.map{($0.startDate,$0.endDate)}.sorted{$0.0<$1.0};if !intervals.isEmpty{var total=0.0,last=Date.distantPast;for interval in intervals{total+=max(0,interval.1.timeIntervalSince(max(last,interval.0)));last=max(last,interval.1)};data["sleepMinutes"]=Int(total/60)}}
            return data
        case "ios_location":
            let location=try await PhoneLocation.shared.current(lastOnly:action=="last_reported")
            return ["ok":true,"latitude":location.coordinate.latitude,"longitude":location.coordinate.longitude,"accuracyMeters":location.horizontalAccuracy,"recordedAt":iso(location.timestamp)]
        case "ios_weather":
            var stage="location"
            do {
            let location:CLLocation
            if let place=args["place"] as? String,!place.isEmpty{let rows=try await CLGeocoder().geocodeAddressString(place);guard rows.count==1,let found=rows[0].location else{throw Failure("ios_ambiguous_location")};location=found}
            else {location=try await PhoneLocation.shared.current()}
            stage="forecast"
            let service=WeatherService.shared,weather=try await service.weather(for:location)
            stage="attribution"
            let attribution=try await service.attribution
            weatherMark=attribution.combinedMarkLightURL;weatherLegal=attribution.legalPageURL
            return ["ok":true,"source":"Apple Weather","place":args["place"] as? String ?? "your phone’s reported area","recordedAt":iso(Date()),"current":["condition":String(describing:weather.currentWeather.condition),"temperatureC":weather.currentWeather.temperature.converted(to:.celsius).value],"daily":Array(weather.dailyForecast.forecast.prefix(7)).map{["date":iso($0.date),"lowC":$0.lowTemperature.converted(to:.celsius).value,"highC":$0.highTemperature.converted(to:.celsius).value]},"legalURL":attribution.legalPageURL.absoluteString,"markURL":attribution.combinedMarkLightURL.absoluteString]
            } catch let error as Failure {throw error}
            catch {throw WeatherFailure(stage:stage,error:error)}
        case "ios_maps":
            guard let destination=args["destination"] as? String,!destination.isEmpty else{throw Failure("ios_destination_required")}
            if carPlayActive, let carPlayDirections {
                return try await carPlayDirections(destination, args["mode"] as? String ?? "driving", expires)
            }
            let places=try await CLGeocoder().geocodeAddressString(destination);guard places.count==1 else{throw Failure("ios_ambiguous_location")}
            let item=MKMapItem(placemark:MKPlacemark(placemark:places[0]));let mode=args["mode"] as? String ?? "driving"
            guard nowMilliseconds()<expires,foreground else{throw Failure("ios_foreground_required")}
            let accepted=item.openInMaps(launchOptions:[MKLaunchOptionsDirectionsModeKey:mode=="walking" ? MKLaunchOptionsDirectionsModeWalking:mode=="transit" ? MKLaunchOptionsDirectionsModeTransit:MKLaunchOptionsDirectionsModeDriving])
            return ["ok":accepted,"handoffAccepted":accepted,"navigationStarted":NSNull()]
        case "ios_open":
            let app=args["app"] as? String ?? "",url:URL
            if app=="haru_settings"{url=URL(string:UIApplication.openSettingsURLString)!}
            else {guard app=="browser",let value=args["url"] as? String,let parsed=URL(string:value),["https","http"].contains(parsed.scheme ?? "") else{throw Failure("ios_invalid_url")};url=parsed}
            let accepted=await UIApplication.shared.open(url)
            return ["ok":accepted,"handoffAccepted":accepted,"app":app]
        default:throw Failure("ios_unknown_tool")
        }
    }
    private func stepCount(from:Date,to:Date) async throws -> Double? {
        guard to>from else{return nil}
        return try await withCheckedThrowingContinuation{continuation in
            let predicate=HKQuery.predicateForSamples(withStart:from,end:to)
            let query=HKStatisticsQuery(quantityType:HKQuantityType(.stepCount),quantitySamplePredicate:predicate,options:.cumulativeSum){_,statistics,error in
                if let error{continuation.resume(throwing:error)}else{continuation.resume(returning:statistics?.sumQuantity()?.doubleValue(for:.count()))}
            }
            health.execute(query)
        }
    }
    private func healthSamples(_ type:HKSampleType,from:Date,to:Date) async throws->[HKSample]{
        try await withCheckedThrowingContinuation{c in let query=HKSampleQuery(sampleType:type,predicate:HKQuery.predicateForSamples(withStart:from,end:to,options:[]),limit:HKObjectQueryNoLimit,sortDescriptors:nil){_,samples,error in if let error{c.resume(throwing:error)}else{c.resume(returning:samples ?? [])}};health.execute(query)}
    }
    // Retain diagnostic identifiers, never NSError.userInfo, URLs or account data.
    struct WeatherFailure:LocalizedError {
        let stage:String,domain:String,number:Int
        init(stage:String,error:Error){self.stage=stage;let cause=error as NSError;domain=String(cause.domain.prefix(120));number=cause.code}
        var errorDescription:String?{"Apple Weather failed during \(stage) (\(domain), code \(number))."}
    }
    struct Failure:LocalizedError{let code:String;init(_ code:String){self.code=code};var errorDescription:String?{code}}
}

@MainActor final class PhoneLocation:NSObject,CLLocationManagerDelegate {
    static let shared=PhoneLocation();private let manager=CLLocationManager();private var locationWait:CheckedContinuation<CLLocation,Error>?;private var permissionWait:CheckedContinuation<Void,Error>?
    override init(){super.init();manager.delegate=self}
    func authorise() async throws {if manager.authorizationStatus == .notDetermined {try await withCheckedThrowingContinuation{(c:CheckedContinuation<Void,Error>) in permissionWait=c;manager.requestWhenInUseAuthorization()}};guard manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways else{throw PhoneTools.Failure("ios_permission_required")}}
    func locationManagerDidChangeAuthorization(_ manager:CLLocationManager){guard manager.authorizationStatus != .notDetermined,let pending=permissionWait else{return};permissionWait=nil;if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways{pending.resume()}else{pending.resume(throwing:PhoneTools.Failure("ios_permission_required"))}}
    func current(lastOnly:Bool=false) async throws->CLLocation {
        guard manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways else{throw PhoneTools.Failure("ios_permission_required")}
        if let cached=manager.location,lastOnly || (Date().timeIntervalSince(cached.timestamp)>=0 && Date().timeIntervalSince(cached.timestamp)<60){return cached}
        guard !lastOnly,locationWait==nil else{throw PhoneTools.Failure("ios_location_unavailable")}
        return try await withCheckedThrowingContinuation{c in locationWait=c;manager.requestLocation();Task{try? await Task.sleep(for:.seconds(5));if let waiting=self.locationWait{self.locationWait=nil;waiting.resume(throwing:PhoneTools.Failure("ios_location_timeout"))}}}
    }
    func locationManager(_ manager:CLLocationManager,didUpdateLocations locations:[CLLocation]){guard let wait=locationWait,let location=locations.last else{return};locationWait=nil;wait.resume(returning:location)}
    func locationManager(_ manager:CLLocationManager,didFailWithError error:Error){locationWait?.resume(throwing:error);locationWait=nil}
}
