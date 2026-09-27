// On-device lyrics translation for FrozenMusic, with Apple's Translation framework
// (iOS 18+). iOS downloads the language models once (it asks first), after that
// translating works offline. Built as its own dylib by the GitHub Actions workflow
// with Xcode's SDK and injected next to the tweak, which finds it by its ObjC name.

import SwiftUI
import UIKit
import Translation

@objc(FMTranslator)
public final class FMTranslator: NSObject {
    /// YES on iOS 18 and newer
    @objc public static var isSupported: Bool {
        if #available(iOS 18.0, *) {
            return true
        }
        return false
    }

    /// Translates `texts` (same order back). `source`: language code or nil (detected).
    /// Needs a view controller that's on screen: iOS shows its download prompt there.
    /// completion(translations, nil) or (nil, error message), on the main queue.
    @MainActor
    @objc(translateTexts:source:target:parent:completion:)
    public static func translate(_ texts: [String], source: String?, target: String, parent: UIViewController,
                                 completion: @escaping ([String]?, String?) -> Void) {
        guard #available(iOS 18.0, *) else {
            completion(nil, "On-device translation needs iOS 18")
            return
        }
        FMTranslationHost.run(texts: texts, source: source, target: target, parent: parent, completion: completion)
    }
}

@available(iOS 18.0, *)
private struct FMTranslationView: View {
    let configuration: TranslationSession.Configuration
    let texts: [String]
    let finish: ([String]?, String?) -> Void
    @State private var active: TranslationSession.Configuration?

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(active) { session in
                do {
                    let requests = texts.enumerated().map {
                        TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
                    }
                    let responses = try await session.translations(from: requests)
                    var result = Array(repeating: "", count: texts.count)
                    for response in responses {
                        if let identifier = response.clientIdentifier, let index = Int(identifier), index >= 0, index < result.count {
                            result[index] = response.targetText
                        }
                    }
                    finish(result, nil)
                } catch {
                    finish(nil, error.localizedDescription)
                }
            }
            .onAppear {
                active = configuration
            }
    }
}

@available(iOS 18.0, *)
private enum FMTranslationHost {
    @MainActor
    static func run(texts: [String], source: String?, target: String, parent: UIViewController,
                    completion: @escaping ([String]?, String?) -> Void) {
        let sourceLanguage = source.map { Locale.Language(identifier: $0) }
        let configuration = TranslationSession.Configuration(source: sourceLanguage, target: Locale.Language(identifier: target))

        var host: UIViewController?
        var done = false
        let finish: ([String]?, String?) -> Void = { result, error in
            DispatchQueue.main.async {
                if done {
                    return
                }
                done = true
                host?.willMove(toParent: nil)
                host?.view.removeFromSuperview()
                host?.removeFromParent()
                host = nil
                completion(result, error)
            }
        }

        // Invisible SwiftUI host: .translationTask only runs inside the view hierarchy
        let controller = UIHostingController(rootView: FMTranslationView(configuration: configuration, texts: texts, finish: finish))
        controller.view.backgroundColor = .clear
        controller.view.isUserInteractionEnabled = false
        controller.view.alpha = 0.01
        controller.view.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        parent.addChild(controller)
        parent.view.addSubview(controller.view)
        controller.didMove(toParent: parent)
        host = controller

        // Download prompt ignored / nothing happening: give up after 3 minutes
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) {
            finish(nil, "Translation timed out")
        }
    }
}
