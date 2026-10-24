import CarPlay
import ObjectiveC
import UIKit
import XCTest
@testable import Haru

/// What the car makes of Haru's voice card, without a car: CarPlay's own view (the simulator's
/// CarPlaySupport framework) is handed each state and drawn to PNG files at car-screen sizes in
/// both appearances. Does nothing unless HARU_CARPLAY_PREVIEW names a folder; run it with
/// scripts/carplay-preview.sh. It goes by class names that are not API, so an iOS release can
/// break it; sizes are points (an 800 by 480 pixel car is usually 400 by 240 points).
/// It exists because the card was designed blind (2026-10-24, after redde's experience of two
/// rounds that looked wrong on a car).
@MainActor
final class CarPlayPreviewTests: XCTestCase {
    func testDrawTheVoiceCard() async throws {
        guard let folder = ProcessInfo.processInfo.environment["HARU_CARPLAY_PREVIEW"] else {
            throw XCTSkip("HARU_CARPLAY_PREVIEW names no folder")
        }
        guard #available(iOS 26.4, *) else { throw XCTSkip("Haru's car scene needs iOS 26.4") }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let sizes = [CGSize(width: 400, height: 240), CGSize(width: 640, height: 360), CGSize(width: 800, height: 480)]
        let car = HaruCarPlayScene()
        // Every state alone on its own template, plus the two the Navigate button changes.
        var screens = (Array(CarScreen.idle).sorted() + CarScreen.live).map { ($0, false) }
        screens += [("ready", true), ("listening", true)]
        for (identifier, route) in screens {
            let layout = CarScreen.layout(showing: identifier, hasRoute: route, current: nil)
            let state = try XCTUnwrap(car.makeTemplate(layout, first: identifier).voiceControlStates.first)
            XCTAssertEqual(state.identifier, identifier)
            let template = CPVoiceControlTemplate(voiceControlStates: [state])
            car.setBar(of: template, for: identifier, hasRoute: route)
            for size in sizes {
                for style in [UIUserInterfaceStyle.dark, .light] {
                    guard let controller = Self.carView(of: template) else {
                        XCTFail("CarPlay's own voice view could not be made on this iOS; the preview needs updating")
                        return
                    }
                    let window = UIWindow(windowScene: scene)
                    // Below the phone's own bars, which would otherwise take a share of the height.
                    window.frame = CGRect(x: 0, y: 150, width: size.width, height: size.height)
                    window.backgroundColor = style == .dark ? .black : .white
                    window.traitOverrides.userInterfaceIdiom = .carPlay
                    window.traitOverrides.userInterfaceStyle = style
                    let bar = UINavigationController(rootViewController: controller)
                    bar.additionalSafeAreaInsets = UIEdgeInsets(top: -window.safeAreaInsets.top, left: 0, bottom: -window.safeAreaInsets.bottom, right: 0)
                    window.rootViewController = bar
                    window.isHidden = false
                    window.layoutIfNeeded()
                    try await Task.sleep(for: .milliseconds(600))
                    window.layoutIfNeeded()
                    let picture = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                    }
                    let name = "voice-\(identifier)\(route ? "-route" : "")-\(Int(size.width))x\(Int(size.height))-\(style == .dark ? "dark" : "light").png"
                    try XCTUnwrap(picture.pngData()).write(to: URL(fileURLWithPath: folder).appending(path: name))
                    window.isHidden = true
                    window.rootViewController = nil
                }
            }
        }
    }

    /// CarPlay's voice template view controller holding `template`, by its private name.
    private static func carView(of template: CPVoiceControlTemplate) -> UIViewController? {
        guard dlopen("/System/Library/PrivateFrameworks/CarPlaySupport.framework/CarPlaySupport", RTLD_NOW) != nil,
              let cls = NSClassFromString("CPSVoiceTemplateViewController") else { return nil }
        let sel = NSSelectorFromString("initWithVoiceTemplate:templateDelegate:templateEnvironment:")
        guard cls.instancesRespond(to: sel), let imp = class_getMethodImplementation(cls, sel),
              let raw = (cls as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() else { return nil }
        typealias Make = @convention(c) (AnyObject, Selector, AnyObject, AnyObject?, AnyObject?) -> Unmanaged<AnyObject>?
        return unsafeBitCast(imp, to: Make.self)(raw, sel, template, nil, nil)?.takeRetainedValue() as? UIViewController
    }
}
