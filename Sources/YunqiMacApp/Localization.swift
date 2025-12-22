import Foundation

/// Simple localization helper for SwiftPM resources.
///
/// Uses `Bundle.module` so strings live alongside the `YunqiMacApp` target.
///
/// Note: SwiftPM currently emits localization folder names like `zh-hans.lproj`.
/// Foundation's preferred localization matching can fail for `zh-Hans-CN`.
/// We resolve this explicitly to ensure Simplified Chinese is picked on Chinese systems.

private let _yunqiLocalizedBundle: Bundle = {
    // Available localizations in the module resource bundle (e.g. "en", "zh-hans").
    let available = Set(Bundle.module.localizations.map { $0.lowercased() })

    func bundleForLocalization(_ id: String) -> Bundle? {
        let key = id.lowercased()
        guard available.contains(key) else { return nil }
        guard let path = Bundle.module.path(forResource: key, ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }

    // Prefer the first user language.
    let preferred = (Locale.preferredLanguages.first ?? "en").lowercased()

    // Map Chinese variants to SwiftPM's `zh-hans` folder.
    if preferred.hasPrefix("zh-hans") || preferred.hasPrefix("zh-cn") || preferred.hasPrefix("zh-sg") || preferred.hasPrefix("zh") {
        if let b = bundleForLocalization("zh-hans") { return b }
    }

    // Fallback to English.
    if let b = bundleForLocalization("en") { return b }
    return Bundle.module
}()

@inline(__always)
func L(_ key: String, value: String? = nil) -> String {
    _yunqiLocalizedBundle.localizedString(forKey: key, value: value ?? key, table: nil)
}

@inline(__always)
func Lf(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), arguments: args)
}
