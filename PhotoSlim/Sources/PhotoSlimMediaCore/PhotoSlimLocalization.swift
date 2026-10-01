import Foundation

/// A localized message whose interpolation values stay separate from its key.
/// Values such as filenames are never treated as format strings or translated.
public struct PhotoSlimMessage: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    public let key: String
    public let arguments: [String]

    public init(stringLiteral value: String) {
        key = value
        arguments = []
    }

    public init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key
        arguments = stringInterpolation.arguments
    }

    public struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [String] = []

        public init(literalCapacity: Int, interpolationCount: Int) {
            key.reserveCapacity(literalCapacity)
            arguments.reserveCapacity(interpolationCount)
        }

        public mutating func appendLiteral(_ literal: String) { key += literal }

        public mutating func appendInterpolation<T>(_ value: T) {
            arguments.append(String(describing: value))
            key += "{\(arguments.count)}"
        }

        public mutating func appendInterpolation(_ value: Double, specifier: String) {
            appendInterpolation(String(format: specifier, value))
        }
    }
}

public enum PhotoSlimLocalization {
    public static var resourceBundle: Bundle {
        #if SWIFT_PACKAGE
        if let url = Bundle.main.url(forResource: "PhotoSlim_PhotoSlimMediaCore", withExtension: "bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return .module
        #else
        return .main
        #endif
    }

    /// Use the device's app language, with English for unsupported languages.
    public static func string(
        _ message: PhotoSlimMessage,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> String {
        let language = Bundle.preferredLocalizations(
            from: ["en", "zh-Hans"], forPreferences: preferredLanguages
        ).first ?? "en"
        let bundle = resourceBundle.path(forResource: language, ofType: "lproj")
            .flatMap(Bundle.init(path:)) ?? resourceBundle
        let template = bundle.localizedString(forKey: message.key, value: nil, table: nil)
        return interpolate(template, arguments: message.arguments)
    }

    /// Replace tokens in the original template in one pass; an argument containing
    /// another token, a percent sign, or a backslash remains literal user data.
    static func interpolate(_ template: String, arguments: [String]) -> String {
        let matches = tokenExpression.matches(in: template, range: NSRange(template.startIndex..., in: template))
        var result = template
        for match in matches.reversed() {
            guard let token = Range(match.range(at: 1), in: template),
                  let index = Int(template[token]), arguments.indices.contains(index - 1),
                  let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: arguments[index - 1])
        }
        return result
    }

    private static let tokenExpression = try! NSRegularExpression(pattern: #"\{([1-9][0-9]*)\}"#)
}

public func L10n(_ message: PhotoSlimMessage) -> String {
    PhotoSlimLocalization.string(message)
}
