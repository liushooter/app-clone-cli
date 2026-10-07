import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct PreparedIcon: Sendable {
  public let data: Data
  public let sha256: String

  init(data: Data) {
    self.data = data
    self.sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

public struct IconBuilder: Sendable {
  public init() {}

  public func prepare(_ source: URL, token: CancellationToken) throws
    -> PreparedIcon
  {
    try token.check()
    let source = source.resolvingSymlinksInPath()
    try BundleFiles.requireRegular(source)
    let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size > 0, size <= 20 * 1024 * 1024 else {
      throw CloneFailure("invalid_icon", L10n.text(.iconSize))
    }
    let ext = source.pathExtension.lowercased()
    guard ["png", "jpg", "jpeg", "icns"].contains(ext) else {
      throw CloneFailure("invalid_icon", L10n.text(.iconFormat))
    }
    let data = try Data(contentsOf: source)
    if ext == "icns" {
      try validateICNS(data)
      return PreparedIcon(data: data)
    }
    guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
      let sourceType = CGImageSourceGetType(imageSource),
      [UTType.png.identifier, UTType.jpeg.identifier].contains(sourceType as String),
      let image = CGImageSourceCreateThumbnailAtIndex(
        imageSource, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: 1024,
        ] as CFDictionary)
    else {
      throw CloneFailure("invalid_icon", L10n.text(.iconDecode))
    }
    let output = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        output, UTType.icns.identifier as CFString, 10, nil)
    else { throw CloneFailure("icon_render_failed", L10n.text(.iconEncoder)) }
    for points in [16, 32, 128, 256, 512] {
      for scale in [1, 2] {
        try token.check()
        let rendered = try render(image, size: points * scale)
        CGImageDestinationAddImage(
          destination, rendered,
          [
            kCGImagePropertyDPIWidth: scale * 72,
            kCGImagePropertyDPIHeight: scale * 72,
          ] as CFDictionary)
      }
    }
    guard CGImageDestinationFinalize(destination) else {
      throw CloneFailure("icon_render_failed", L10n.text(.iconEncode))
    }
    try token.check()
    let result = output as Data
    try validateICNS(result)
    return PreparedIcon(data: result)
  }

  func validateICNS(_ data: Data) throws {
    guard data.count >= 8, data.prefix(4) == Data("icns".utf8),
      data[4..<8].reduce(0, { ($0 << 8) | Int($1) }) == data.count,
      let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetCount(imageSource) > 0,
      CGImageSourceCreateImageAtIndex(imageSource, 0, nil) != nil
    else {
      throw CloneFailure("invalid_icon", L10n.text(.iconInvalid))
    }
  }

  private func render(_ image: CGImage, size: Int) throws -> CGImage {
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: size * 4, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else {
      throw CloneFailure("icon_render_failed", L10n.text(.iconCanvas))
    }
    let scale = min(CGFloat(size) / CGFloat(image.width), CGFloat(size) / CGFloat(image.height))
    let width = CGFloat(image.width) * scale
    let height = CGFloat(image.height) * scale
    context.interpolationQuality = .high
    context.draw(
      image,
      in: CGRect(
        x: (CGFloat(size) - width) / 2,
        y: (CGFloat(size) - height) / 2,
        width: width, height: height))
    guard let rendered = context.makeImage() else {
      throw CloneFailure("icon_render_failed", L10n.text(.iconImageEncode))
    }
    return rendered
  }

  func install(_ icon: PreparedIcon, into app: URL) throws {
    let resources = app.appendingPathComponent("Contents/Resources")
    if BundleFiles.exists(resources) {
      try BundleFiles.requireRegular(resources, directory: true)
    } else {
      try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: false)
    }
    let destination = resources.appendingPathComponent(BundleFiles.customIcon)
    if BundleFiles.exists(destination) { try BundleFiles.requireRegular(destination) }
    try icon.data.write(to: destination, options: .atomic)
    var plist = try BundleFiles.readPlist(BundleFiles.plistURL(app))
    plist["CFBundleIconFile"] = BundleFiles.customIcon
    plist.removeValue(forKey: "CFBundleIconName")
    try BundleFiles.writePlist(plist, to: BundleFiles.plistURL(app))
    // A localized icon key must not override the replacement.
    let children = try FileManager.default.contentsOfDirectory(
      at: resources, includingPropertiesForKeys: nil)
    for directory in children where directory.pathExtension == "lproj" {
      let strings = directory.appendingPathComponent("InfoPlist.strings")
      if BundleFiles.exists(strings) {
        try BundleFiles.requireRegular(directory, directory: true)
        var localized = try BundleFiles.readPlist(strings)
        localized.removeValue(forKey: "CFBundleIconFile")
        localized.removeValue(forKey: "CFBundleIconName")
        try BundleFiles.writePlist(localized, to: strings)
      }
    }
  }
}
