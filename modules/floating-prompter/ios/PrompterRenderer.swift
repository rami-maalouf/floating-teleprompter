import CoreMedia
import CoreText
import CoreVideo
import UIKit

// draws the script into video frames. the frame is a wide 3:1 strip that holds
// exactly two rows of text, so the picture in picture window stays short.
final class PrompterRenderer {
  static let canvasSize = CGSize(width: 1200, height: 400)
  static let rowHeight: CGFloat = 200
  private static let sidePadding: CGFloat = 44
  private static let edgeFade: CGFloat = 34
  private static let progressBarHeight: CGFloat = 6

  private struct Row {
    let line: CTLine
    let width: CGFloat
  }

  private var rows: [Row] = []
  private var baselineInRow: CGFloat = 0
  private var pool: CVPixelBufferPool?
  private var formatDescription: CMVideoFormatDescription?
  private let colorSpace = CGColorSpaceCreateDeviceRGB()

  private(set) var wordCount = 0

  var rowCount: Int { rows.count }

  // the scroll distance from the first row at the top to the last row at the top
  var maxOffset: CGFloat { CGFloat(max(rows.count - 1, 0)) * Self.rowHeight }

  func layout(text: String, fontSize: CGFloat) {
    let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: UIColor.white,
    ]
    let maxWidth = Double(Self.canvasSize.width - Self.sidePadding * 2)

    var newRows: [Row] = []
    var words = 0
    for paragraph in text.components(separatedBy: .newlines) {
      let collapsed = paragraph.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
      guard !collapsed.isEmpty else { continue }
      words += collapsed.split(separator: " ").count

      let attributed = NSAttributedString(string: collapsed, attributes: attributes)
      let typesetter = CTTypesetterCreateWithAttributedString(attributed)
      let length = attributed.length
      var start = 0
      while start < length {
        let count = max(CTTypesetterSuggestLineBreak(typesetter, start, maxWidth), 1)
        let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
          - CGFloat(CTLineGetTrailingWhitespaceWidth(line))
        newRows.append(Row(line: line, width: width))
        start += count
      }
    }

    rows = newRows
    wordCount = words
    // center the cap height of the text in its row
    baselineInRow = (Self.rowHeight + font.capHeight) / 2
  }

  // offset is the scroll position in canvas points. progress is 0...1.
  func makeSampleBuffer(offset: CGFloat, progress: CGFloat, time: CMTime) -> CMSampleBuffer? {
    guard let pixelBuffer = makePixelBuffer() else { return nil }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    draw(into: pixelBuffer, offset: offset, progress: progress)
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

    if formatDescription == nil {
      CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescriptionOut: &formatDescription
      )
    }
    guard let formatDescription else { return nil }

    var timing = CMSampleTimingInfo(
      duration: .invalid,
      presentationTimeStamp: time,
      decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: pixelBuffer,
      formatDescription: formatDescription,
      sampleTiming: &timing,
      sampleBufferOut: &sampleBuffer
    )
    guard let sampleBuffer else { return nil }

    // show each frame as soon as it arrives. the scroll position is already in the picture.
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
      CFArrayGetCount(attachments) > 0
    {
      let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
      CFDictionarySetValue(
        dictionary,
        Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
      )
    }
    return sampleBuffer
  }

  private func makePixelBuffer() -> CVPixelBuffer? {
    if pool == nil {
      let attributes: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey: Int(Self.canvasSize.width),
        kCVPixelBufferHeightKey: Int(Self.canvasSize.height),
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true,
      ]
      CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
    }
    guard let pool else { return nil }
    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
    return pixelBuffer
  }

  private func draw(into pixelBuffer: CVPixelBuffer, offset: CGFloat, progress: CGFloat) {
    let size = Self.canvasSize
    guard
      let context = CGContext(
        data: CVPixelBufferGetBaseAddress(pixelBuffer),
        width: Int(size.width),
        height: Int(size.height),
        bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
      )
    else { return }

    context.setFillColor(UIColor.black.cgColor)
    context.fill(CGRect(origin: .zero, size: size))

    // core graphics has its origin at the bottom left, so flip each top-based position
    context.textMatrix = .identity
    let first = max(Int(floor(offset / Self.rowHeight)), 0)
    let last = min(first + 2, rows.count - 1)
    if first <= last {
      for index in first...last {
        let row = rows[index]
        let top = CGFloat(index) * Self.rowHeight - offset
        let baseline = size.height - (top + baselineInRow)
        context.textPosition = CGPoint(x: (size.width - row.width) / 2, y: baseline)
        CTLineDraw(row.line, context)
      }
    }

    drawEdgeFade(in: context, size: size)

    // thin progress bar along the bottom edge
    let barWidth = size.width * min(max(progress, 0), 1)
    context.setFillColor(UIColor(white: 1, alpha: 0.16).cgColor)
    context.fill(CGRect(x: 0, y: 0, width: size.width, height: Self.progressBarHeight))
    context.setFillColor(UIColor(red: 0.30, green: 0.62, blue: 1, alpha: 1).cgColor)
    context.fill(CGRect(x: 0, y: 0, width: barWidth, height: Self.progressBarHeight))
  }

  // soften the rows that enter at the bottom and leave at the top
  private func drawEdgeFade(in context: CGContext, size: CGSize) {
    let colors = [UIColor.black.cgColor, UIColor.black.withAlphaComponent(0).cgColor] as CFArray
    guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) else { return }
    context.drawLinearGradient(
      gradient,
      start: CGPoint(x: 0, y: size.height),
      end: CGPoint(x: 0, y: size.height - Self.edgeFade),
      options: []
    )
    context.drawLinearGradient(
      gradient,
      start: CGPoint(x: 0, y: Self.progressBarHeight),
      end: CGPoint(x: 0, y: Self.progressBarHeight + Self.edgeFade),
      options: []
    )
  }
}
