import AppKit
import CoreGraphics
import ScreenCaptureKit

public enum WindowCaptureError: Error, CustomStringConvertible {
    case windowNotFound
    public var description: String {
        switch self {
        case .windowNotFound: return "The window is no longer on screen."
        }
    }
}

public struct OnScreenWindow {
    public let id: CGWindowID
    public let pid: pid_t
    public let bounds: CGRect
}

public enum WindowCapture {
    public static func hasPermission() -> Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    public static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// Normal-level on-screen windows, front to back.
    /// Owner pid and bounds are available without Screen Recording permission.
    public static func orderedWindows() -> [OnScreenWindow] {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
        var out: [OnScreenWindow] = []
        for w in info {
            guard (w[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let num = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bd as CFDictionary),
                  rect.width >= 40, rect.height >= 40 else { continue }
            if let alpha = (w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, alpha <= 0 { continue }
            out.append(OnScreenWindow(id: num, pid: pid, bounds: rect))
        }
        return out
    }

    /// Captures one window (even if partly covered), scaled so the long edge is <= maxEdge pixels.
    public static func capture(windowID: CGWindowID, maxEdge: Int) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let win = content.windows.first(where: { $0.windowID == windowID }) else {
            throw WindowCaptureError.windowNotFound
        }
        let filter = SCContentFilter(desktopIndependentWindow: win)
        let scale = CGFloat(filter.pointPixelScale)
        var w = filter.contentRect.width * scale
        var h = filter.contentRect.height * scale
        let longEdge = max(w, h)
        if maxEdge > 0, longEdge > CGFloat(maxEdge) {
            let f = CGFloat(maxEdge) / longEdge
            w *= f
            h *= f
        }
        let cfg = SCStreamConfiguration()
        cfg.width = max(1, Int(w.rounded()))
        cfg.height = max(1, Int(h.rounded()))
        cfg.showsCursor = false
        cfg.ignoreShadowsSingleWindow = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }

    /// Downscale so the long edge is <= maxEdge pixels (no-op if already smaller).
    public static func scaled(_ image: CGImage, maxEdge: Int) -> CGImage {
        let longEdge = max(image.width, image.height)
        guard maxEdge > 0, longEdge > maxEdge else { return image }
        let f = CGFloat(maxEdge) / CGFloat(longEdge)
        let w = max(1, Int((CGFloat(image.width) * f).rounded()))
        let h = max(1, Int((CGFloat(image.height) * f).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    public static func pngData(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// Smaller payload for MCP tool results.
    public static func jpegData(fromImageAt path: String, quality: Double = 0.8) -> Data? {
        guard let data = FileManager.default.contents(atPath: path),
              let rep = NSBitmapImageRep(data: data) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}
