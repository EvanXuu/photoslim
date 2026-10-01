import Foundation
import PhotoSlimMediaCore
import XCTest

final class LocalizationTests: XCTestCase {
    func testEnglishAndChineseAndUnsupportedLanguageFallback() {
        XCTAssertEqual(PhotoSlimLocalization.string("照片图库", preferredLanguages: ["en-GB"]), "Photo Library")
        XCTAssertEqual(PhotoSlimLocalization.string("照片图库", preferredLanguages: ["zh-Hans-CN"]), "照片图库")
        XCTAssertEqual(PhotoSlimLocalization.string("照片图库", preferredLanguages: ["fr-FR"]), "Photo Library")
        XCTAssertEqual(PhotoSlimLocalization.string("照片图库", preferredLanguages: []), "Photo Library")
    }

    func testInterpolationNeverTranslatesOrReinterpretsUserData() {
        let filename = #"家庭 100% {2} \😀.jpg"#
        XCTAssertEqual(
            PhotoSlimLocalization.string("正在压缩 \(filename)", preferredLanguages: ["en"]),
            "Compressing \(filename)"
        )
        XCTAssertEqual(
            PhotoSlimLocalization.string("空间不足，已取消 \(3) 个项目；新项目未加入。", preferredLanguages: ["en"]),
            "Not enough space. Removed 3 items from the selection; no new items were added."
        )
        XCTAssertEqual(
            PhotoSlimLocalization.string("实际只节省 \(7)%，低于设置的 \(8)%。", preferredLanguages: ["en"]),
            "Saved only 7%, below your 8% minimum."
        )
        XCTAssertEqual(
            PhotoSlimLocalization.string("\(1.25, specifier: "%.1f") 秒", preferredLanguages: ["en"]),
            "1.2 seconds"
        )
    }

    func testEveryCatalogKeyAndInterpolationIsTranslated() throws {
        let english = try catalog("en")
        let chinese = try catalog("zh-Hans")
        XCTAssertGreaterThan(english.count, 600)
        XCTAssertEqual(Set(english.keys), Set(chinese.keys))
        let tokens = try NSRegularExpression(pattern: #"\{[1-9][0-9]*\}"#)
        func placeholders(_ string: String) -> [String] {
            tokens.matches(in: string, range: NSRange(string.startIndex..., in: string))
                .map { (string as NSString).substring(with: $0.range) }.sorted()
        }
        for (key, value) in english {
            XCTAssertFalse(value.isEmpty, key)
            XCTAssertNil(value.range(of: #"\p{Han}"#, options: .regularExpression), key)
            XCTAssertEqual(placeholders(key), placeholders(value), key)
            XCTAssertEqual(placeholders(key), placeholders(chinese[key]!), key)
        }
    }

    private func catalog(_ language: String) throws -> [String: String] {
        let url = try XCTUnwrap(PhotoSlimLocalization.resourceBundle.url(
            forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language
        ))
        return try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: url), format: nil
        ) as? [String: String])
    }
}
