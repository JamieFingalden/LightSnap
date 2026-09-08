import XCTest
import CoreGraphics
import ImageIO
@testable import CaptureCore

final class CaptureCoreTests: XCTestCase {
    private func page(width: Int = 160, height: Int = 1600) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value = UInt8(((y / 3 * 73 + x / 5 * 131) ^ (y / 11 * 43 + x * 7)) % 220 + 20)
                let index = (y * width + x) * 4
                pixels[index] = value
                pixels[index + 1] = UInt8((y * 7 + x * 3) % 256)
                pixels[index + 2] = UInt8(y % 256)
                pixels[index + 3] = 255
            }
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: ImageCodec.colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private func pixels(_ image: CGImage) throws -> Data {
        let context = try ImageCodec.context(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: context.data!, count: image.width * image.height * 4)
    }

    func testScrollOffsetAndUnchanged() throws {
        let page = page()
        let first = try GrayFrame(image: page.cropping(to: CGRect(x: 0, y: 0, width: 160, height: 500))!)
        XCTAssertEqual(ScrollMatcher.match(previous: first, current: first), .unchanged)
        for offset in [1, 17, 93, 187, 380] {
            let next = try GrayFrame(image: page.cropping(to: CGRect(x: 0, y: offset, width: 160, height: 500))!)
            XCTAssertEqual(ScrollMatcher.match(previous: first, current: next), .append(offset), "偏移 \(offset) 应精确匹配")
        }
        let reverse = try GrayFrame(image: page.cropping(to: CGRect(x: 0, y: 93, width: 160, height: 500))!)
        XCTAssertEqual(ScrollMatcher.match(previous: reverse, current: first), .uncertain)
    }

    func testNoOverlapAndInvalidInputAreRejected() throws {
        let page = page()
        let first = try GrayFrame(image: page.cropping(to: CGRect(x: 0, y: 0, width: 160, height: 500))!)
        let unrelated = try GrayFrame(image: page.cropping(to: CGRect(x: 0, y: 900, width: 160, height: 500))!)
        XCTAssertEqual(ScrollMatcher.match(previous: first, current: unrelated), .uncertain)
        XCTAssertEqual(ScrollMatcher.match(previous: first, current: GrayFrame(pixels: [], width: 160, height: 500)), .uncertain)
    }

    func testRepeatedRowsAreNotSilentlyJoined() {
        let width = 160
        let height = 500
        let previous = GrayFrame(pixels: (0..<(width * height)).map { UInt8((($0 / width) % 20) * 12) }, width: width, height: height)
        let next = GrayFrame(pixels: (0..<(width * height)).map { UInt8(((($0 / width) + 7) % 20) * 12) }, width: width, height: height)
        XCTAssertEqual(ScrollMatcher.match(previous: previous, current: next), .uncertain)
    }

    func testTiledExportPreservesPixelsAndCleansUp() throws {
        let source = page(width: 96, height: 600)
        var document: ImageDocument? = try ImageDocument(width: 96)
        try document!.append(source.cropping(to: CGRect(x: 0, y: 0, width: 96, height: 250))!)
        try document!.append(source.cropping(to: CGRect(x: 0, y: 250, width: 96, height: 350))!)
        let tile = document!.tiles[0].url
        XCTAssertEqual(document!.height, 600)
        let rendered = try document!.render(annotations: [])
        XCTAssertEqual(try pixels(rendered), try pixels(source), "分块合成不得上下颠倒或遗漏像素")
        document = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: tile.path))
    }

    func testAnnotationHitAndExportPosition() throws {
        let annotation = Annotation(kind: .rectangle, start: CGPoint(x: 20, y: 20), end: CGPoint(x: 80, y: 70),
                                    color: CGColor(colorSpace: ImageCodec.colorSpace, components: [1, 0, 0, 1])!, lineWidth: 4)
        XCTAssertTrue(annotation.contains(CGPoint(x: 20, y: 40), tolerance: 3))
        XCTAssertFalse(annotation.contains(CGPoint(x: 50, y: 45), tolerance: 3))
        let document = try ImageDocument(width: 100)
        try document.append(page(width: 100, height: 200))
        let output = try document.render(annotations: [annotation])
        let data = try pixels(output)
        let index = (40 * 100 + 20) * 4
        XCTAssertEqual(data[index], 255)
        XCTAssertEqual(data[index + 1], 0)
    }

    func testPixelBudgetRejectsOversizedContext() {
        XCTAssertThrowsError(try ImageCodec.context(width: 3000, height: 30000))
        XCTAssertThrowsError(try ImageDocument(width: 0))
    }

    func testPNGEncodingPreservesPixels() throws {
        let image = page(width: 96, height: 180)
        let data = try ImageCodec.pngData(image)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(try pixels(decoded), try pixels(image), "普通复制与贴图复制必须保留原始像素")
    }
}
