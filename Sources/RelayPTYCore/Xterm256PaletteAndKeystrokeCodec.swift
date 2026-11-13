import Foundation
import RelayModels

// MARK: - sRGB / Linear Luminance / WCAG 2.1 Color Primitives

public struct RGBATerminalColor: Sendable, Codable, Hashable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    public var a: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public init?(hexString: String) {
        let trimmed = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        switch raw.count {
        case 6:
            guard let value = UInt32(raw, radix: 16) else { return nil }
            self.r = UInt8((value >> 16) & 0xFF)
            self.g = UInt8((value >> 8) & 0xFF)
            self.b = UInt8(value & 0xFF)
            self.a = 255
        case 8:
            guard let value = UInt32(raw, radix: 16) else { return nil }
            self.r = UInt8((value >> 24) & 0xFF)
            self.g = UInt8((value >> 16) & 0xFF)
            self.b = UInt8((value >> 8) & 0xFF)
            self.a = UInt8(value & 0xFF)
        case 3:
            guard let value = UInt16(raw, radix: 16) else { return nil }
            let rn = UInt8((value >> 8) & 0x0F)
            let gn = UInt8((value >> 4) & 0x0F)
            let bn = UInt8(value & 0x0F)
            self.r = (rn << 4) | rn
            self.g = (gn << 4) | gn
            self.b = (bn << 4) | bn
            self.a = 255
        default:
            return nil
        }
    }

    public var hexRGB: String {
        String(format: "#%02X%02X%02X", r, g, b)
    }

    public var hexRGBA: String {
        String(format: "#%02X%02X%02X%02X", r, g, b, a)
    }

    public var cssString: String {
        if a == 255 {
            return hexRGB
        }
        let alpha = Double(a) / 255.0
        return String(format: "rgba(%d, %d, %d, %.3f)", r, g, b, alpha)
    }

    public var normalizedComponents: (r: Double, g: Double, b: Double, a: Double) {
        (
            Double(r) / 255.0,
            Double(g) / 255.0,
            Double(b) / 255.0,
            Double(a) / 255.0
        )
    }

    /// WCAG 2.1 IEC 61966-2-1 relative luminance in `[0.0, 1.0]`.
    public var relativeLuminance: Double {
        let rl = Self.sRGBChannelToLinear(r)
        let gl = Self.sRGBChannelToLinear(g)
        let bl = Self.sRGBChannelToLinear(b)
        return 0.2126 * rl + 0.7152 * gl + 0.0722 * bl
    }

    /// Computes WCAG 2.1 contrast ratio against `other` in `[1.0, 21.0]`.
    public func contrastRatio(against other: RGBATerminalColor) -> Double {
        let l1 = self.relativeLuminance
        let l2 = other.relativeLuminance
        let lighter = max(l1, l2)
        let darker = min(l1, l2)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// Alpha-composites `self` over an opaque `backdrop` color.
    public func composited(over backdrop: RGBATerminalColor) -> RGBATerminalColor {
        if a == 255 { return self }
        if a == 0 { return backdrop }
        let fgA = Double(a) / 255.0
        let invA = 1.0 - fgA
        let outR = UInt8(clamping: Int((Double(r) * fgA + Double(backdrop.r) * invA).rounded()))
        let outG = UInt8(clamping: Int((Double(g) * fgA + Double(backdrop.g) * invA).rounded()))
        let outB = UInt8(clamping: Int((Double(b) * fgA + Double(backdrop.b) * invA).rounded()))
        return RGBATerminalColor(r: outR, g: outG, b: outB, a: 255)
    }

    /// Blends linearly in sRGB space toward `target` by `fraction` in `[0.0, 1.0]`.
    public func interpolated(toward target: RGBATerminalColor, fraction: Double) -> RGBATerminalColor {
        let t = min(1.0, max(0.0, fraction))
        let inv = 1.0 - t
        let nr = UInt8(clamping: Int((Double(r) * inv + Double(target.r) * t).rounded()))
        let ng = UInt8(clamping: Int((Double(g) * inv + Double(target.g) * t).rounded()))
        let nb = UInt8(clamping: Int((Double(b) * inv + Double(target.b) * t).rounded()))
        let na = UInt8(clamping: Int((Double(a) * inv + Double(target.a) * t).rounded()))
        return RGBATerminalColor(r: nr, g: ng, b: nb, a: na)
    }

    /// Converts sRGB to cylindrical `(hue: [0, 360), saturation: [0, 1], lightness: [0, 1])`.
    public func toHSL() -> (hue: Double, saturation: Double, lightness: Double) {
        let rf = Double(r) / 255.0
        let gf = Double(g) / 255.0
        let bf = Double(b) / 255.0

        let maxC = max(rf, gf, bf)
        let minC = min(rf, gf, bf)
        let delta = maxC - minC
        let lightness = 0.5 * (maxC + minC)

        guard delta > 1e-7 else {
            return (0.0, 0.0, lightness)
        }

        let saturation = lightness > 0.5
            ? delta / max(1e-7, (2.0 - maxC - minC))
            : delta / max(1e-7, (maxC + minC))

        let rawHue: Double
        if maxC == rf {
            rawHue = ((gf - bf) / delta).truncatingRemainder(dividingBy: 6.0)
        } else if maxC == gf {
            rawHue = ((bf - rf) / delta) + 2.0
        } else {
            rawHue = ((rf - gf) / delta) + 4.0
        }
        var degrees = rawHue * 60.0
        if degrees < 0.0 {
            degrees += 360.0
        }
        return (degrees, min(1.0, max(0.0, saturation)), min(1.0, max(0.0, lightness)))
    }

    public static func fromHSL(hue: Double, saturation: Double, lightness: Double, alpha: UInt8 = 255) -> RGBATerminalColor {
        let s = min(1.0, max(0.0, saturation))
        let l = min(1.0, max(0.0, lightness))
        if s <= 1e-7 {
            let gray = UInt8(clamping: Int((l * 255.0).rounded()))
            return RGBATerminalColor(r: gray, g: gray, b: gray, a: alpha)
        }

        var hNorm = hue.truncatingRemainder(dividingBy: 360.0)
        if hNorm < 0.0 { hNorm += 360.0 }

        let c = (1.0 - abs(2.0 * l - 1.0)) * s
        let hPrime = hNorm / 60.0
        let x = c * (1.0 - abs(hPrime.truncatingRemainder(dividingBy: 2.0) - 1.0))
        let m = l - 0.5 * c

        let r1: Double
        let g1: Double
        let b1: Double
        switch hPrime {
        case 0.0..<1.0: (r1, g1, b1) = (c, x, 0.0)
        case 1.0..<2.0: (r1, g1, b1) = (x, c, 0.0)
        case 2.0..<3.0: (r1, g1, b1) = (0.0, c, x)
        case 3.0..<4.0: (r1, g1, b1) = (0.0, x, c)
        case 4.0..<5.0: (r1, g1, b1) = (x, 0.0, c)
        default:        (r1, g1, b1) = (c, 0.0, x)
        }

        return RGBATerminalColor(
            r: UInt8(clamping: Int(((r1 + m) * 255.0).rounded())),
            g: UInt8(clamping: Int(((g1 + m) * 255.0).rounded())),
            b: UInt8(clamping: Int(((b1 + m) * 255.0).rounded())),
            a: alpha
        )
    }

    /// Perceptual redmean color distance squared (low-cost approximation to CIE76).
    public func perceptualDistanceSquared(to other: RGBATerminalColor) -> Double {
        let rMean = 0.5 * (Double(r) + Double(other.r))
        let dr = Double(r) - Double(other.r)
        let dg = Double(g) - Double(other.g)
        let db = Double(b) - Double(other.b)
        let wR = 2.0 + rMean / 256.0
        let wG = 4.0
        let wB = 2.0 + (255.0 - rMean) / 256.0
        return wR * dr * dr + wG * dg * dg + wB * db * db
    }

    private static func sRGBChannelToLinear(_ byte: UInt8) -> Double {
        let s = Double(byte) / 255.0
        if s <= 0.04045 {
            return s / 12.92
        }
        return Foundation.pow((s + 0.055) / 1.055, 2.4)
    }

    public static let bauhausDarkWell = RGBATerminalColor(r: 0x18, g: 0x18, b: 0x1B) // #18181B
    public static let bauhausLightPaper = RGBATerminalColor(r: 0xF4, g: 0xF4, b: 0xF5) // #F4F4F5
    public static let bauhausSelection = RGBATerminalColor(r: 0x20, g: 0x5D, b: 0xD1, a: 0x66)
}

// MARK: - Terminal Theme Presets & WCAG Contrast Policy

public enum WCAGContrastTarget: Double, Sendable, Codable, Hashable, CaseIterable {
    case unclamped = 1.0
    case uiGraphicsAA = 3.0
    case normalTextAA = 4.5
    case enhancedAAA = 7.0
}

public struct TerminalPaletteTheme: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let displayName: String
    public let defaultForeground: RGBATerminalColor
    public let defaultBackground: RGBATerminalColor
    public let cursorColor: RGBATerminalColor
    public let cursorTextColor: RGBATerminalColor
    public let selectionBackground: RGBATerminalColor
    public let ansi16: [RGBATerminalColor]

    public init(
        id: String,
        displayName: String,
        defaultForeground: RGBATerminalColor,
        defaultBackground: RGBATerminalColor,
        cursorColor: RGBATerminalColor,
        cursorTextColor: RGBATerminalColor,
        selectionBackground: RGBATerminalColor,
        ansi16: [RGBATerminalColor]
    ) {
        self.id = id
        self.displayName = displayName
        self.defaultForeground = defaultForeground
        self.defaultBackground = defaultBackground
        self.cursorColor = cursorColor
        self.cursorTextColor = cursorTextColor
        self.selectionBackground = selectionBackground
        if ansi16.count == 16 {
            self.ansi16 = ansi16
        } else {
            self.ansi16 = Self.standardXtermANSI16
        }
    }

    /// Standard xterm 16-color base table (`0..15`).
    public static let standardXtermANSI16: [RGBATerminalColor] = [
        RGBATerminalColor(r: 0x00, g: 0x00, b: 0x00), // 0 Black
        RGBATerminalColor(r: 0xCD, g: 0x00, b: 0x00), // 1 Red
        RGBATerminalColor(r: 0x00, g: 0xCD, b: 0x00), // 2 Green
        RGBATerminalColor(r: 0xCD, g: 0xCD, b: 0x00), // 3 Yellow
        RGBATerminalColor(r: 0x00, g: 0x00, b: 0xEE), // 4 Blue
        RGBATerminalColor(r: 0xCD, g: 0x00, b: 0xCD), // 5 Magenta
        RGBATerminalColor(r: 0x00, g: 0xCD, b: 0xCD), // 6 Cyan
        RGBATerminalColor(r: 0xE5, g: 0xE5, b: 0xE5), // 7 White
        RGBATerminalColor(r: 0x7F, g: 0x7F, b: 0x7F), // 8 Bright Black
        RGBATerminalColor(r: 0xFF, g: 0x00, b: 0x00), // 9 Bright Red
        RGBATerminalColor(r: 0x00, g: 0xFF, b: 0x00), // 10 Bright Green
        RGBATerminalColor(r: 0xFF, g: 0xFF, b: 0x00), // 11 Bright Yellow
        RGBATerminalColor(r: 0x5C, g: 0x5C, b: 0xFF), // 12 Bright Blue
        RGBATerminalColor(r: 0xFF, g: 0x00, b: 0xFF), // 13 Bright Magenta
        RGBATerminalColor(r: 0x00, g: 0xFF, b: 0xFF), // 14 Bright Cyan
        RGBATerminalColor(r: 0xFF, g: 0xFF, b: 0xFF)  // 15 Bright White
    ]

    /// RelayIDE Bauhaus Dark `#18181B` Industrial Terminal Theme.
    public static let relayBauhausDark = TerminalPaletteTheme(
        id: "relay-bauhaus-dark",
        displayName: "Relay Bauhaus Dark (#18181B)",
        defaultForeground: .bauhausLightPaper,
        defaultBackground: .bauhausDarkWell,
        cursorColor: RGBATerminalColor(r: 0xDC, g: 0x8F, b: 0x14),
        cursorTextColor: .bauhausDarkWell,
        selectionBackground: .bauhausSelection,
        ansi16: [
            RGBATerminalColor(r: 0x27, g: 0x27, b: 0x2A), // 0 Zinc-800
            RGBATerminalColor(r: 0xDA, g: 0x3C, b: 0x2A), // 1 Bauhaus Vermilion
            RGBATerminalColor(r: 0x18, g: 0x8B, b: 0x5D), // 2 Bauhaus Emerald
            RGBATerminalColor(r: 0xDC, g: 0x8F, b: 0x14), // 3 Bauhaus Ochre
            RGBATerminalColor(r: 0x20, g: 0x5D, b: 0xD1), // 4 Bauhaus Cobalt
            RGBATerminalColor(r: 0xA8, g: 0x55, b: 0xF7), // 5 Violet Signal
            RGBATerminalColor(r: 0x0E, g: 0xA5, b: 0xE9), // 6 Sky Cyan
            RGBATerminalColor(r: 0xD4, g: 0xD4, b: 0xD8), // 7 Zinc-300
            RGBATerminalColor(r: 0x71, g: 0x71, b: 0x7A), // 8 Zinc-500
            RGBATerminalColor(r: 0xF8, g: 0x71, b: 0x71), // 9 Bright Vermilion
            RGBATerminalColor(r: 0x34, g: 0xD3, b: 0x99), // 10 Bright Emerald
            RGBATerminalColor(r: 0xFB, g: 0xBF, b: 0x24), // 11 Bright Ochre
            RGBATerminalColor(r: 0x60, g: 0xA5, b: 0xFA), // 12 Bright Cobalt
            RGBATerminalColor(r: 0xC0, g: 0x84, b: 0xFC), // 13 Bright Violet
            RGBATerminalColor(r: 0x38, g: 0xBD, b: 0xF8), // 14 Bright Cyan
            RGBATerminalColor(r: 0xFA, g: 0xFA, b: 0xFA)  // 15 Pure Zinc-50
        ]
    )

    /// Classic Xterm reference palette on `#18181B` well.
    public static let classicXtermDark = TerminalPaletteTheme(
        id: "classic-xterm-dark",
        displayName: "Classic Xterm 256",
        defaultForeground: RGBATerminalColor(r: 0xE5, g: 0xE5, b: 0xE5),
        defaultBackground: .bauhausDarkWell,
        cursorColor: RGBATerminalColor(r: 0xF4, g: 0xF4, b: 0xF5),
        cursorTextColor: .bauhausDarkWell,
        selectionBackground: RGBATerminalColor(r: 0x3F, g: 0x3F, b: 0x46),
        ansi16: standardXtermANSI16
    )

    /// High-contrast AAA dark theme tailored for dense compiler & test logs.
    public static let highContrastAAA = TerminalPaletteTheme(
        id: "high-contrast-aaa",
        displayName: "High Contrast AAA (#18181B)",
        defaultForeground: RGBATerminalColor(r: 0xFF, g: 0xFF, b: 0xFF),
        defaultBackground: .bauhausDarkWell,
        cursorColor: RGBATerminalColor(r: 0xFF, g: 0xEA, b: 0x00),
        cursorTextColor: RGBATerminalColor(r: 0x00, g: 0x00, b: 0x00),
        selectionBackground: RGBATerminalColor(r: 0x3B, g: 0x82, b: 0xF6, a: 0x80),
        ansi16: [
            RGBATerminalColor(r: 0x3F, g: 0x3F, b: 0x46),
            RGBATerminalColor(r: 0xFF, g: 0x6B, b: 0x6B),
            RGBATerminalColor(r: 0x51, g: 0xCF, b: 0x66),
            RGBATerminalColor(r: 0xFF, g: 0xD4, b: 0x3B),
            RGBATerminalColor(r: 0x74, g: 0xC0, b: 0xFC),
            RGBATerminalColor(r: 0xE5, g: 0x99, b: 0xF7),
            RGBATerminalColor(r: 0x66, g: 0xD9, b: 0xE8),
            RGBATerminalColor(r: 0xF4, g: 0xF4, b: 0xF5),
            RGBATerminalColor(r: 0xA1, g: 0xA1, b: 0xAA),
            RGBATerminalColor(r: 0xFF, g: 0x87, b: 0x87),
            RGBATerminalColor(r: 0x8C, g: 0xE9, b: 0x9A),
            RGBATerminalColor(r: 0xFF, g: 0xE0, b: 0x66),
            RGBATerminalColor(r: 0xA5, g: 0xD8, b: 0xFF),
            RGBATerminalColor(r: 0xEE, g: 0xBE, b: 0xFA),
            RGBATerminalColor(r: 0x99, g: 0xE9, b: 0xF2),
            RGBATerminalColor(r: 0xFF, g: 0xFF, b: 0xFF)
        ]
    )
}

// MARK: - Full 256-Color Xterm Palette, TrueColor Resolver & WCAG Contrast Clamper

public struct ResolvedCellColorPair: Sendable, Codable, Hashable {
    public let foreground: RGBATerminalColor
    public let background: RGBATerminalColor
    public let contrastRatio: Double
    public let wasContrastClamped: Bool

    public init(
        foreground: RGBATerminalColor,
        background: RGBATerminalColor,
        contrastRatio: Double,
        wasContrastClamped: Bool
    ) {
        self.foreground = foreground
        self.background = background
        self.contrastRatio = contrastRatio
        self.wasContrastClamped = wasContrastClamped
    }
}

public struct Xterm256ColorPalette: Sendable, Codable, Hashable {
    /// Exact xterm 6x6x6 color cube axis values (`0, 95, 135, 175, 215, 255`).
    public static let cubeChannelSteps: [UInt8] = [0, 95, 135, 175, 215, 255]

    public let theme: TerminalPaletteTheme
    public let boldBrightensANSI8: Bool
    public let dimAttenuationFactor: Double
    public let minimumContrast: WCAGContrastTarget
    private let fullTable256: [RGBATerminalColor]

    public init(
        theme: TerminalPaletteTheme = .relayBauhausDark,
        boldBrightensANSI8: Bool = true,
        dimAttenuationFactor: Double = 0.64,
        minimumContrast: WCAGContrastTarget = .normalTextAA
    ) {
        self.theme = theme
        self.boldBrightensANSI8 = boldBrightensANSI8
        self.dimAttenuationFactor = min(1.0, max(0.25, dimAttenuationFactor))
        self.minimumContrast = minimumContrast
        self.fullTable256 = Self.build256Table(ansi16: theme.ansi16)
    }

    /// Generates all 256 xterm colors (`0..15` ANSI, `16..231` 6x6x6 cube, `232..255` 24-step grayscale).
    public static func build256Table(ansi16: [RGBATerminalColor] = TerminalPaletteTheme.standardXtermANSI16) -> [RGBATerminalColor] {
        var table: [RGBATerminalColor] = []
        table.reserveCapacity(256)

        // 0..15: System ANSI 16
        let base16 = ansi16.count == 16 ? ansi16 : TerminalPaletteTheme.standardXtermANSI16
        table.append(contentsOf: base16)

        // 16..231: 6 x 6 x 6 RGB Color Cube (`index = 16 + 36*r + 6*g + b`)
        for rIdx in 0..<6 {
            for gIdx in 0..<6 {
                for bIdx in 0..<6 {
                    table.append(
                        RGBATerminalColor(
                            r: cubeChannelSteps[rIdx],
                            g: cubeChannelSteps[gIdx],
                            b: cubeChannelSteps[bIdx]
                        )
                    )
                }
            }
        }

        // 232..255: 24-step Grayscale Ramp (`8, 18, 28, ..., 238`)
        for step in 0..<24 {
            let level = UInt8(8 + step * 10)
            table.append(RGBATerminalColor(r: level, g: level, b: level))
        }

        return table
    }

    /// Direct O(1) lookup of any `0..255` xterm palette index.
    public func color(atPaletteIndex index: UInt8) -> RGBATerminalColor {
        fullTable256[Int(index)]
    }

    /// Returns the entire 256-entry color table.
    public var all256Colors: [RGBATerminalColor] {
        fullTable256
    }

    /// Computes exact `(rCube, gCube, bCube)` coordinates in `0...5` for cube indices `16...231`.
    public static func decodeCubeCoordinates(index: UInt8) -> (r: Int, g: Int, b: Int)? {
        guard index >= 16 && index <= 231 else { return nil }
        let offset = Int(index) - 16
        return (offset / 36, (offset / 6) % 6, offset % 6)
    }

    /// Encodes `(r, g, b)` cube coordinates in `0...5` into an xterm palette index `16...231`.
    public static func encodeCubeIndex(r: Int, g: Int, b: Int) -> UInt8 {
        let rc = min(5, max(0, r))
        let gc = min(5, max(0, g))
        let bc = min(5, max(0, b))
        return UInt8(16 + 36 * rc + 6 * gc + bc)
    }

    /// Resolves any `RelayModels.TerminalColor` value into concrete sRGB.
    public func resolveRawColor(
        _ terminalColor: TerminalColor,
        isForeground: Bool,
        isBold: Bool = false
    ) -> RGBATerminalColor {
        switch terminalColor {
        case .defaultForeground:
            return theme.defaultForeground
        case .defaultBackground:
            return theme.defaultBackground
        case .ansi16(let code):
            var idx = Int(code & 0x0F)
            if isForeground && isBold && boldBrightensANSI8 && idx < 8 {
                idx += 8
            }
            return fullTable256[idx]
        case .palette256(let idx):
            if isForeground && isBold && boldBrightensANSI8 && idx < 8 {
                return fullTable256[Int(idx) + 8]
            }
            return fullTable256[Int(idx)]
        case .trueColor(let r, let g, let b):
            return RGBATerminalColor(r: r, g: g, b: b)
        }
    }

    /// Resolves foreground & background for a `TerminalCell`, honoring `.inverse`, `.dim`, `.hidden`, `.bold`, cursor block inversion, and WCAG contrast clamping against `#18181B` or active cell background.
    public func resolveCellColors(
        for cell: TerminalCell,
        isCursorCell: Bool = false,
        cursorShape: TerminalCursorShape = .block,
        overrideMinimumContrastRatio: Double? = nil
    ) -> ResolvedCellColorPair {
        let attrs = cell.attributes
        let isBold = attrs.contains(.bold)

        var fg = resolveRawColor(cell.foreground, isForeground: true, isBold: isBold)
        var bg = resolveRawColor(cell.background, isForeground: false, isBold: false)

        if attrs.contains(.inverse) {
            swap(&fg, &bg)
        }

        if isCursorCell && cursorShape == .block {
            fg = theme.cursorTextColor
            bg = theme.cursorColor
        }

        if attrs.contains(.hidden) {
            return ResolvedCellColorPair(
                foreground: bg,
                background: bg,
                contrastRatio: 1.0,
                wasContrastClamped: false
            )
        }

        if attrs.contains(.dim) {
            fg = fg.interpolated(toward: bg, fraction: 1.0 - dimAttenuationFactor)
        }

        let initialRatio = fg.contrastRatio(against: bg)
        let targetRatio = overrideMinimumContrastRatio ?? minimumContrast.rawValue

        // Blank whitespace cells never need foreground contrast clamping
        let trimmedGrapheme = cell.grapheme.trimmingCharacters(in: .whitespacesAndNewlines)
        if targetRatio <= 1.0 || trimmedGrapheme.isEmpty || initialRatio >= targetRatio {
            return ResolvedCellColorPair(
                foreground: fg,
                background: bg,
                contrastRatio: initialRatio,
                wasContrastClamped: false
            )
        }

        let clampedFG = Self.clampForegroundContrast(
            foreground: fg,
            againstBackground: bg,
            minimumRatio: targetRatio
        )
        let finalRatio = clampedFG.contrastRatio(against: bg)
        return ResolvedCellColorPair(
            foreground: clampedFG,
            background: bg,
            contrastRatio: finalRatio,
            wasContrastClamped: clampedFG != fg
        )
    }

    /// Clamps `foreground` against dark `#18181B` (or any custom terminal well background) to satisfy WCAG contrast `minimumRatio` while preserving perceptual HSL hue.
    public static func clampForegroundContrast(
        foreground: RGBATerminalColor,
        againstBackground background: RGBATerminalColor = .bauhausDarkWell,
        minimumRatio: Double = 4.5
    ) -> RGBATerminalColor {
        let target = min(21.0, max(1.0, minimumRatio))
        if foreground.contrastRatio(against: background) >= target {
            return foreground
        }

        let bgLum = background.relativeLuminance
        let hsl = foreground.toHSL()

        // Decide whether lightening (for dark wells like #18181B where bgLum ~ 0.009) or darkening yields higher max contrast.
        let whiteContrast = (1.0 + 0.05) / (bgLum + 0.05)
        let blackContrast = (bgLum + 0.05) / 0.05
        let shouldLighten = whiteContrast >= blackContrast

        if shouldLighten {
            var lowL = hsl.lightness
            var highL = 1.0
            var best = RGBATerminalColor(r: 255, g: 255, b: 255, a: foreground.a)
            for _ in 0..<14 {
                let midL = 0.5 * (lowL + highL)
                // Slightly relax saturation only above L=0.88 so deep blues can reach high luminance cleanly
                let adjustedSat = midL > 0.88 ? hsl.saturation * ((1.0 - midL) / 0.12) : hsl.saturation
                let candidate = RGBATerminalColor.fromHSL(
                    hue: hsl.hue,
                    saturation: adjustedSat,
                    lightness: midL,
                    alpha: foreground.a
                )
                if candidate.contrastRatio(against: background) >= target {
                    best = candidate
                    highL = midL
                } else {
                    lowL = midL
                }
            }
            return best
        } else {
            var lowL = 0.0
            var highL = hsl.lightness
            var best = RGBATerminalColor(r: 0, g: 0, b: 0, a: foreground.a)
            for _ in 0..<14 {
                let midL = 0.5 * (lowL + highL)
                let candidate = RGBATerminalColor.fromHSL(
                    hue: hsl.hue,
                    saturation: hsl.saturation,
                    lightness: midL,
                    alpha: foreground.a
                )
                if candidate.contrastRatio(against: background) >= target {
                    best = candidate
                    lowL = midL
                } else {
                    highL = midL
                }
            }
            return best
        }
    }

    /// Quantizes a 24-bit TrueColor RGB value to the closest `16...255` xterm color cube / grayscale ramp entry (or `0...255` when `includeSystemANSI16` is true).
    public func quantizeTrueColorTo256(
        _ rgb: RGBATerminalColor,
        includeSystemANSI16: Bool = false
    ) -> UInt8 {
        let startIdx = includeSystemANSI16 ? 0 : 16
        var bestIdx = startIdx
        var bestDist = Double.greatestFiniteMagnitude
        for idx in startIdx..<256 {
            let d = rgb.perceptualDistanceSquared(to: fullTable256[idx])
            if d < bestDist {
                bestDist = d
                bestIdx = idx
                if d == 0.0 { break }
            }
        }
        return UInt8(bestIdx)
    }

    /// Quantizes any color to the closest ANSI 16 (`0...15`) index.
    public func quantizeToANSI16(_ rgb: RGBATerminalColor) -> UInt8 {
        var bestIdx = 0
        var bestDist = Double.greatestFiniteMagnitude
        for idx in 0..<16 {
            let d = rgb.perceptualDistanceSquared(to: fullTable256[idx])
            if d < bestDist {
                bestDist = d
                bestIdx = idx
            }
        }
        return UInt8(bestIdx)
    }
}

// MARK: - Complete Terminal Input Keystroke, Paste, Focus & SGR 1006 Mouse Codec

public struct TerminalKeyModifiers: OptionSet, Sendable, Codable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let shift   = TerminalKeyModifiers(rawValue: 1 << 0) // +1 -> CSI ;2
    public static let alt     = TerminalKeyModifiers(rawValue: 1 << 1) // +2 -> CSI ;3 (Option)
    public static let control = TerminalKeyModifiers(rawValue: 1 << 2) // +4 -> CSI ;5
    public static let meta    = TerminalKeyModifiers(rawValue: 1 << 3) // +8 -> CSI ;9 (Command/Super)

    /// Xterm CSI modifier parameter (`2` for Shift, `3` for Alt, `4` Shift+Alt, `5` Ctrl, `6` Shift+Ctrl, `7` Alt+Ctrl, `8` Shift+Alt+Ctrl, up to `16` with Meta). Returns `nil` if unmodified.
    public var xtermCSIParameter: Int? {
        guard !isEmpty else { return nil }
        var bits = 0
        if contains(.shift)   { bits |= 1 }
        if contains(.alt)     { bits |= 2 }
        if contains(.control) { bits |= 4 }
        if contains(.meta)    { bits |= 8 }
        return 1 + bits
    }

    /// Modifier bitmask added to SGR 1006 / X10 mouse button codes (`+4` Shift, `+8` Alt/Meta, `+16` Ctrl).
    public var xtermMouseModifierBits: Int {
        var bits = 0
        if contains(.shift) { bits |= 4 }
        if contains(.alt) || contains(.meta) { bits |= 8 }
        if contains(.control) { bits |= 16 }
        return bits
    }
}

public enum TerminalSpecialKey: String, Sendable, Codable, Hashable, CaseIterable {
    case up
    case down
    case right
    case left
    case home
    case end
    case insert
    case delete
    case pageUp
    case pageDown
    case tab
    case backTab
    case enter
    case escape
    case backspace
    case space
    case f1
    case f2
    case f3
    case f4
    case f5
    case f6
    case f7
    case f8
    case f9
    case f10
    case f11
    case f12
    case f13
    case f14
    case f15
    case f16
    case f17
    case f18
    case f19
    case f20
    case keypad0
    case keypad1
    case keypad2
    case keypad3
    case keypad4
    case keypad5
    case keypad6
    case keypad7
    case keypad8
    case keypad9
    case keypadEnter
    case keypadPlus
    case keypadMinus
    case keypadMultiply
    case keypadDivide
    case keypadDecimal
}

public enum TerminalMouseTrackingMode: String, Sendable, Codable, Hashable, CaseIterable {
    case disabled
    case x10ClickOnly           // ?9h
    case vt200PressRelease      // ?1000h
    case buttonEventDrag        // ?1002h
    case anyEventMotion         // ?1003h
}

public enum TerminalMouseEncodingFormat: String, Sendable, Codable, Hashable, CaseIterable {
    case sgr1006                // ?1006h: `\e[<Cb;Cx;CyM` / `m`
    case urxvt1015              // ?1015h: `\e[Cb;Cx;CyM`
    case legacyX10              // `\e[M` + 3 raw bytes (clamped to 223 cols/rows)
}

public enum TerminalMouseButton: Sendable, Codable, Hashable, CaseIterable {
    case left
    case middle
    case right
    case none
    case wheelUp
    case wheelDown
    case wheelLeft
    case wheelRight
    case backButton4
    case forwardButton5

    public var baseSGRButtonCode: Int {
        switch self {
        case .left:           return 0
        case .middle:         return 1
        case .right:          return 2
        case .none:           return 3
        case .wheelUp:        return 64
        case .wheelDown:      return 65
        case .wheelLeft:      return 66
        case .wheelRight:     return 67
        case .backButton4:    return 128
        case .forwardButton5: return 129
        }
    }

    public var isWheelEvent: Bool {
        switch self {
        case .wheelUp, .wheelDown, .wheelLeft, .wheelRight:
            return true
        default:
            return false
        }
    }
}

public enum TerminalMouseEventKind: String, Sendable, Codable, Hashable, CaseIterable {
    case press
    case release
    case drag
    case hoverMotion
    case scroll
}

public struct TerminalMouseEvent: Sendable, Codable, Hashable {
    public let button: TerminalMouseButton
    public let kind: TerminalMouseEventKind
    /// 1-based terminal column (`1...columns`).
    public let column: Int
    /// 1-based terminal row (`1...rows`).
    public let row: Int
    public let modifiers: TerminalKeyModifiers

    public init(
        button: TerminalMouseButton,
        kind: TerminalMouseEventKind,
        column: Int,
        row: Int,
        modifiers: TerminalKeyModifiers = []
    ) {
        self.button = button
        self.kind = kind
        self.column = max(1, column)
        self.row = max(1, row)
        self.modifiers = modifiers
    }
}

public struct TerminalEncoderModeState: Sendable, Codable, Hashable {
    /// DECCKM (`?1h`): When true, unmodified arrows emit `\eOA`..`\eOD` instead of `\e[A`..`\e[D`.
    public var applicationCursorKeys: Bool
    /// DECKPAM (`\e=` vs `\e>`): When true, numeric keypad emits SS3 sequences.
    public var applicationKeypad: Bool
    /// DECSET 2004 (`?2004h`): Wraps pasted text in `\e[200~ ... \e[201~`.
    public var bracketedPasteEnabled: Bool
    /// DECSET 1004 (`?1004h`): Emits `\e[I` and `\e[O` on terminal focus changes.
    public var focusReportingEnabled: Bool
    /// LNM (`20h`): Enter key sends `\r\n` instead of `\r`.
    public var lineFeedNewlineMode: Bool
    /// Xterm `altSendsEscape`: Prefixes Alt+key sequences with `ESC` (`0x1B`).
    public var altSendsEscape: Bool
    /// DECBKM: Backspace key sends `0x7F` (DEL) when true, or `0x08` (`^H`) when false.
    public var backspaceSendsDEL: Bool
    public var mouseTrackingMode: TerminalMouseTrackingMode
    public var mouseEncodingFormat: TerminalMouseEncodingFormat

    public init(
        applicationCursorKeys: Bool = false,
        applicationKeypad: Bool = false,
        bracketedPasteEnabled: Bool = false,
        focusReportingEnabled: Bool = false,
        lineFeedNewlineMode: Bool = false,
        altSendsEscape: Bool = true,
        backspaceSendsDEL: Bool = true,
        mouseTrackingMode: TerminalMouseTrackingMode = .disabled,
        mouseEncodingFormat: TerminalMouseEncodingFormat = .sgr1006
    ) {
        self.applicationCursorKeys = applicationCursorKeys
        self.applicationKeypad = applicationKeypad
        self.bracketedPasteEnabled = bracketedPasteEnabled
        self.focusReportingEnabled = focusReportingEnabled
        self.lineFeedNewlineMode = lineFeedNewlineMode
        self.altSendsEscape = altSendsEscape
        self.backspaceSendsDEL = backspaceSendsDEL
        self.mouseTrackingMode = mouseTrackingMode
        self.mouseEncodingFormat = mouseEncodingFormat
    }
}

public enum DecodedTerminalInputEvent: Sendable, Codable, Hashable {
    case printableText(String)
    case controlCharacter(byte: UInt8, caretNotation: String)
    case specialKey(key: TerminalSpecialKey, modifiers: TerminalKeyModifiers)
    case bracketedPaste(String)
    case focusChanged(isFocused: Bool)
    case mouse(TerminalMouseEvent)
    case unknownEscapeSequence(String)
}

public struct TerminalKeystrokeCodec: Sendable {
    public init() {}

    // MARK: - Control Character & Printable UTF-8 Encoding

    /// Encodes a printable string or single character with `Ctrl` / `Alt` / `Shift` / `Meta` modifiers.
    public func encodeTextKeystroke(
        _ text: String,
        modifiers: TerminalKeyModifiers = [],
        mode: TerminalEncoderModeState = TerminalEncoderModeState()
    ) -> Data {
        guard !text.isEmpty else { return Data() }

        // Single-character Ctrl chord (`^@` 0x00 .. `^_` 0x1F, `^?` 0x7F)
        if modifiers.contains(.control), text.count == 1, let firstScalar = text.unicodeScalars.first {
            if let ctrlByte = Self.controlByte(forScalar: firstScalar) {
                var out = Data()
                if modifiers.contains(.alt) && mode.altSendsEscape {
                    out.append(0x1B)
                }
                out.append(ctrlByte)
                return out
            }
        }

        var out = Data()
        if modifiers.contains(.alt) && mode.altSendsEscape {
            out.append(0x1B)
        }
        out.append(contentsOf: text.utf8)
        return out
    }

    /// Maps ASCII scalars under `Ctrl` (`^C` -> `0x03`, `^D` -> `0x04`, `^L` -> `0x0C`, `^Z` -> `0x1A`, etc.).
    public static func controlByte(forScalar scalar: UnicodeScalar) -> UInt8? {
        let v = scalar.value
        switch v {
        case 0x40, 0x20, 0x32: // `@`, Space, `2` -> NUL
            return 0x00
        case 0x41...0x5A:      // `A`..`Z` -> 0x01..0x1A
            return UInt8(v - 0x40)
        case 0x61...0x7A:      // `a`..`z` -> 0x01..0x1A
            return UInt8(v - 0x60)
        case 0x5B, 0x33:       // `[`, `3` -> ESC (0x1B)
            return 0x1B
        case 0x5C, 0x34:       // `\`, `4` -> FS (0x1C)
            return 0x1C
        case 0x5D, 0x35:       // `]`, `5` -> GS (0x1D)
            return 0x1D
        case 0x5E, 0x36:       // `^`, `6` -> RS (0x1E)
            return 0x1E
        case 0x5F, 0x2F, 0x37: // `_`, `/`, `7` -> US (0x1F)
            return 0x1F
        case 0x3F, 0x38:       // `?`, `8` -> DEL (0x7F)
            return 0x7F
        default:
            return nil
        }
    }

    /// Formats a C0/DEL control byte in traditional caret notation (`0x03` -> `"^C"`).
    public static func caretNotation(forControlByte byte: UInt8) -> String? {
        if byte <= 0x1F {
            let ch = Character(UnicodeScalar(UInt32(byte) + 0x40)!)
            return "^\(ch)"
        }
        if byte == 0x7F {
            return "^?"
        }
        return nil
    }

    // MARK: - Special Key Encoding (Cursor, Function F1-F20, Navigation, Keypad)

    public func encodeSpecialKey(
        _ key: TerminalSpecialKey,
        modifiers: TerminalKeyModifiers = [],
        mode: TerminalEncoderModeState = TerminalEncoderModeState()
    ) -> Data {
        switch key {
        case .up:
            return encodeCursorOrSS3Key(finalChar: "A", modifiers: modifiers, useSS3WhenUnmodified: mode.applicationCursorKeys)
        case .down:
            return encodeCursorOrSS3Key(finalChar: "B", modifiers: modifiers, useSS3WhenUnmodified: mode.applicationCursorKeys)
        case .right:
            return encodeCursorOrSS3Key(finalChar: "C", modifiers: modifiers, useSS3WhenUnmodified: mode.applicationCursorKeys)
        case .left:
            return encodeCursorOrSS3Key(finalChar: "D", modifiers: modifiers, useSS3WhenUnmodified: mode.applicationCursorKeys)
        case .home:
            return encodeCursorOrSS3Key(finalChar: "H", modifiers: modifiers, useSS3WhenUnmodified: mode.applicationCursorKeys)
        case .end:
            return encodeCursorOrSS3Key(finalChar: "F", modifiers: modifiers, useSS3WhenUnmodified: mode.applicationCursorKeys)

        case .insert:
            return encodeTildeKey(code: 2, modifiers: modifiers)
        case .delete:
            return encodeTildeKey(code: 3, modifiers: modifiers)
        case .pageUp:
            return encodeTildeKey(code: 5, modifiers: modifiers)
        case .pageDown:
            return encodeTildeKey(code: 6, modifiers: modifiers)

        case .tab:
            if modifiers.contains(.shift) {
                return Data("\u{1B}[Z".utf8)
            }
            var out = Data()
            if modifiers.contains(.alt) && mode.altSendsEscape {
                out.append(0x1B)
            }
            out.append(0x09)
            return out

        case .backTab:
            return Data("\u{1B}[Z".utf8)

        case .enter:
            var out = Data()
            if modifiers.contains(.alt) && mode.altSendsEscape {
                out.append(0x1B)
            }
            out.append(0x0D)
            if mode.lineFeedNewlineMode {
                out.append(0x0A)
            }
            return out

        case .escape:
            if modifiers.contains(.alt) && mode.altSendsEscape {
                return Data([0x1B, 0x1B])
            }
            return Data([0x1B])

        case .backspace:
            var out = Data()
            if modifiers.contains(.alt) && mode.altSendsEscape {
                out.append(0x1B)
            }
            if modifiers.contains(.control) {
                out.append(mode.backspaceSendsDEL ? 0x08 : 0x7F)
            } else {
                out.append(mode.backspaceSendsDEL ? 0x7F : 0x08)
            }
            return out

        case .space:
            if modifiers.contains(.control) {
                var out = Data()
                if modifiers.contains(.alt) && mode.altSendsEscape {
                    out.append(0x1B)
                }
                out.append(0x00)
                return out
            }
            return encodeTextKeystroke(" ", modifiers: modifiers, mode: mode)

        // F1-F4 use SS3 `\eOP`..`\eOS` when unmodified and CSI `\e[1;<mod>P`..`S` when modified
        case .f1:
            return encodeCursorOrSS3Key(finalChar: "P", modifiers: modifiers, useSS3WhenUnmodified: true)
        case .f2:
            return encodeCursorOrSS3Key(finalChar: "Q", modifiers: modifiers, useSS3WhenUnmodified: true)
        case .f3:
            return encodeCursorOrSS3Key(finalChar: "R", modifiers: modifiers, useSS3WhenUnmodified: true)
        case .f4:
            return encodeCursorOrSS3Key(finalChar: "S", modifiers: modifiers, useSS3WhenUnmodified: true)

        // F5-F20 use standard VT/xterm tilde codes (skipping 16 and 22 per DEC VT220 hardware gaps)
        case .f5:  return encodeTildeKey(code: 15, modifiers: modifiers)
        case .f6:  return encodeTildeKey(code: 17, modifiers: modifiers)
        case .f7:  return encodeTildeKey(code: 18, modifiers: modifiers)
        case .f8:  return encodeTildeKey(code: 19, modifiers: modifiers)
        case .f9:  return encodeTildeKey(code: 20, modifiers: modifiers)
        case .f10: return encodeTildeKey(code: 21, modifiers: modifiers)
        case .f11: return encodeTildeKey(code: 23, modifiers: modifiers)
        case .f12: return encodeTildeKey(code: 24, modifiers: modifiers)
        case .f13: return encodeTildeKey(code: 25, modifiers: modifiers)
        case .f14: return encodeTildeKey(code: 26, modifiers: modifiers)
        case .f15: return encodeTildeKey(code: 28, modifiers: modifiers)
        case .f16: return encodeTildeKey(code: 29, modifiers: modifiers)
        case .f17: return encodeTildeKey(code: 31, modifiers: modifiers)
        case .f18: return encodeTildeKey(code: 32, modifiers: modifiers)
        case .f19: return encodeTildeKey(code: 33, modifiers: modifiers)
        case .f20: return encodeTildeKey(code: 34, modifiers: modifiers)

        // Application vs Numeric Keypad (`DECKPAM` / `DECKPNM`)
        case .keypad0:        return encodeKeypad(normal: "0", appSS3: "p", applicationMode: mode.applicationKeypad)
        case .keypad1:        return encodeKeypad(normal: "1", appSS3: "q", applicationMode: mode.applicationKeypad)
        case .keypad2:        return encodeKeypad(normal: "2", appSS3: "r", applicationMode: mode.applicationKeypad)
        case .keypad3:        return encodeKeypad(normal: "3", appSS3: "s", applicationMode: mode.applicationKeypad)
        case .keypad4:        return encodeKeypad(normal: "4", appSS3: "t", applicationMode: mode.applicationKeypad)
        case .keypad5:        return encodeKeypad(normal: "5", appSS3: "u", applicationMode: mode.applicationKeypad)
        case .keypad6:        return encodeKeypad(normal: "6", appSS3: "v", applicationMode: mode.applicationKeypad)
        case .keypad7:        return encodeKeypad(normal: "7", appSS3: "w", applicationMode: mode.applicationKeypad)
        case .keypad8:        return encodeKeypad(normal: "8", appSS3: "x", applicationMode: mode.applicationKeypad)
        case .keypad9:        return encodeKeypad(normal: "9", appSS3: "y", applicationMode: mode.applicationKeypad)
        case .keypadEnter:    return encodeKeypad(normal: "\r", appSS3: "M", applicationMode: mode.applicationKeypad)
        case .keypadPlus:     return encodeKeypad(normal: "+", appSS3: "k", applicationMode: mode.applicationKeypad)
        case .keypadMinus:    return encodeKeypad(normal: "-", appSS3: "m", applicationMode: mode.applicationKeypad)
        case .keypadMultiply: return encodeKeypad(normal: "*", appSS3: "j", applicationMode: mode.applicationKeypad)
        case .keypadDivide:   return encodeKeypad(normal: "/", appSS3: "o", applicationMode: mode.applicationKeypad)
        case .keypadDecimal:  return encodeKeypad(normal: ".", appSS3: "n", applicationMode: mode.applicationKeypad)
        }
    }

    // MARK: - Bracketed Paste, Focus In/Out & SGR 1006 Mouse Tracking

    /// Encodes pasted text with optional `\e[200~ ... \e[201~` bracketing and anti-injection sanitization.
    public func encodeBracketedPaste(
        _ rawText: String,
        bracketedPasteEnabled: Bool = true,
        normalizeCRLFToCR: Bool = true,
        sanitizeNestedEndMarkers: Bool = true
    ) -> Data {
        var payload = rawText
        if sanitizeNestedEndMarkers {
            // Neutralize malicious pasted `\e[201~` or CSI C1 `0x9B` sequences that could break out of paste mode early
            payload = payload
                .replacingOccurrences(of: "\u{1B}[201~", with: "")
                .replacingOccurrences(of: "\u{1B}[200~", with: "")
                .replacingOccurrences(of: "\u{009B}201~", with: "")
        }
        if normalizeCRLFToCR {
            payload = payload.replacingOccurrences(of: "\r\n", with: "\r")
        }
        if bracketedPasteEnabled {
            return Data("\u{1B}[200~\(payload)\u{1B}[201~".utf8)
        }
        return Data(payload.utf8)
    }

    /// Encodes DECSET 1004 terminal focus change (`\e[I` Focus In, `\e[O` Focus Out).
    public func encodeFocusEvent(isFocused: Bool, focusReportingEnabled: Bool = true) -> Data {
        guard focusReportingEnabled else { return Data() }
        return Data((isFocused ? "\u{1B}[I" : "\u{1B}[O").utf8)
    }

    /// Encodes mouse interactions in SGR 1006 (`\e[<btn;col;rowM`/`m`), URXVT 1015, or Legacy X10 format.
    public func encodeMouseEvent(
        _ event: TerminalMouseEvent,
        mode: TerminalEncoderModeState = TerminalEncoderModeState(
            mouseTrackingMode: .anyEventMotion,
            mouseEncodingFormat: .sgr1006
        )
    ) -> Data {
        guard isMouseEventPermitted(event, trackingMode: mode.mouseTrackingMode) else {
            return Data()
        }

        var cb = event.button.baseSGRButtonCode + event.modifiers.xtermMouseModifierBits
        if event.kind == .drag || event.kind == .hoverMotion {
            cb += 32
        }

        let col = max(1, event.column)
        let row = max(1, event.row)

        switch mode.mouseEncodingFormat {
        case .sgr1006:
            let finalChar = (event.kind == .release) ? "m" : "M"
            return Data("\u{1B}[<\(cb);\(col);\(row)\(finalChar)".utf8)

        case .urxvt1015:
            let urxvtBtn = (event.kind == .release) ? (3 + event.modifiers.xtermMouseModifierBits) : cb
            return Data("\u{1B}[\(urxvtBtn + 32);\(col);\(row)M".utf8)

        case .legacyX10:
            // Legacy X10 encodes `32 + value` into single bytes, capping coordinates at `223` (255 - 32)
            let x10Btn = (event.kind == .release && !event.button.isWheelEvent)
                ? (3 + event.modifiers.xtermMouseModifierBits)
                : cb
            let b0 = UInt8(clamping: 32 + x10Btn)
            let b1 = UInt8(clamping: 32 + min(223, col))
            let b2 = UInt8(clamping: 32 + min(223, row))
            return Data([0x1B, 0x5B, 0x4D, b0, b1, b2])
        }
    }

    // MARK: - Symmetric Input Stream Decoder (for Replay, Inspection & Testing)

    /// Parses raw PTY stdin bytes back into structured `DecodedTerminalInputEvent` records.
    public func decodeInputStream(_ data: Data) -> [DecodedTerminalInputEvent] {
        let bytes = Array(data)
        var events: [DecodedTerminalInputEvent] = []
        var idx = 0

        while idx < bytes.count {
            let b = bytes[idx]

            if b == 0x1B {
                if let parsed = parseEscapeSequence(bytes: bytes, startIndex: idx) {
                    events.append(parsed.event)
                    idx = parsed.nextIndex
                    continue
                } else {
                    events.append(.specialKey(key: .escape, modifiers: []))
                    idx += 1
                    continue
                }
            }

            if b == 0x0D {
                events.append(.specialKey(key: .enter, modifiers: []))
                if idx + 1 < bytes.count && bytes[idx + 1] == 0x0A {
                    idx += 2
                } else {
                    idx += 1
                }
                continue
            }

            if b == 0x09 {
                events.append(.specialKey(key: .tab, modifiers: []))
                idx += 1
                continue
            }

            if b == 0x7F {
                events.append(.specialKey(key: .backspace, modifiers: []))
                idx += 1
                continue
            }

            if b < 0x20 {
                let caret = Self.caretNotation(forControlByte: b) ?? String(format: "0x%02X", b)
                events.append(.controlCharacter(byte: b, caretNotation: caret))
                idx += 1
                continue
            }

            // Coalesce contiguous printable UTF-8 bytes
            let textStart = idx
            while idx < bytes.count {
                let cur = bytes[idx]
                if cur == 0x1B || cur < 0x20 || cur == 0x7F {
                    break
                }
                idx += 1
            }
            let text = String(decoding: bytes[textStart..<idx], as: UTF8.self)
            events.append(.printableText(text))
        }

        return events
    }

    // MARK: - Private Encoding & Decoding Helpers

    private func encodeCursorOrSS3Key(
        finalChar: Character,
        modifiers: TerminalKeyModifiers,
        useSS3WhenUnmodified: Bool
    ) -> Data {
        if let modParam = modifiers.xtermCSIParameter {
            return Data("\u{1B}[1;\(modParam)\(finalChar)".utf8)
        }
        let prefix = useSS3WhenUnmodified ? "\u{1B}O" : "\u{1B}["
        return Data("\(prefix)\(finalChar)".utf8)
    }

    private func encodeTildeKey(code: Int, modifiers: TerminalKeyModifiers) -> Data {
        if let modParam = modifiers.xtermCSIParameter {
            return Data("\u{1B}[\(code);\(modParam)~".utf8)
        }
        return Data("\u{1B}[\(code)~".utf8)
    }

    private func encodeKeypad(normal: String, appSS3: Character, applicationMode: Bool) -> Data {
        if applicationMode {
            return Data("\u{1B}O\(appSS3)".utf8)
        }
        return Data(normal.utf8)
    }

    private func isMouseEventPermitted(
        _ event: TerminalMouseEvent,
        trackingMode: TerminalMouseTrackingMode
    ) -> Bool {
        switch trackingMode {
        case .disabled:
            return false
        case .x10ClickOnly:
            return event.kind == .press
        case .vt200PressRelease:
            return event.kind == .press || event.kind == .release || event.kind == .scroll
        case .buttonEventDrag:
            return event.kind != .hoverMotion
        case .anyEventMotion:
            return true
        }
    }

    private func parseEscapeSequence(
        bytes: [UInt8],
        startIndex: Int
    ) -> (event: DecodedTerminalInputEvent, nextIndex: Int)? {
        guard startIndex + 1 < bytes.count else { return nil }
        let second = bytes[startIndex + 1]

        // SS3 (`ESC O <final>`)
        if second == 0x4F, startIndex + 2 < bytes.count {
            let finalByte = bytes[startIndex + 2]
            if let key = Self.specialKeyForSS3FinalByte(finalByte) {
                return (.specialKey(key: key, modifiers: []), startIndex + 3)
            }
        }

        // CSI (`ESC [ ...`)
        if second == 0x5B {
            // Check Bracketed Paste `\e[200~ ... \e[201~`
            let pasteStart = Array("\u{1B}[200~".utf8)
            let pasteEnd = Array("\u{1B}[201~".utf8)
            if startIndex + pasteStart.count <= bytes.count,
               Array(bytes[startIndex..<(startIndex + pasteStart.count)]) == pasteStart {
                let bodyStart = startIndex + pasteStart.count
                if let endRange = findSubsequence(pasteEnd, in: bytes, from: bodyStart) {
                    let pastedText = String(decoding: bytes[bodyStart..<endRange], as: UTF8.self)
                    return (.bracketedPaste(pastedText), endRange + pasteEnd.count)
                }
            }

            // Focus In / Focus Out
            if startIndex + 2 < bytes.count {
                if bytes[startIndex + 2] == 0x49 { // `I`
                    return (.focusChanged(isFocused: true), startIndex + 3)
                }
                if bytes[startIndex + 2] == 0x4F { // `O`
                    return (.focusChanged(isFocused: false), startIndex + 3)
                }
                if bytes[startIndex + 2] == 0x5A { // `Z` BackTab
                    return (.specialKey(key: .backTab, modifiers: [.shift]), startIndex + 3)
                }
            }

            // Scan general CSI sequence up to final byte `0x40...0x7E`
            var scan = startIndex + 2
            while scan < bytes.count && (bytes[scan] < 0x40 || bytes[scan] > 0x7E) {
                scan += 1
            }
            guard scan < bytes.count else { return nil }
            let finalByte = bytes[scan]
            let paramStr = String(decoding: bytes[(startIndex + 2)..<scan], as: UTF8.self)

            // SGR 1006 Mouse `\e[<Cb;Cx;CyM` or `m`
            if paramStr.hasPrefix("<") && (finalByte == 0x4D || finalByte == 0x6D) {
                let parts = paramStr.dropFirst().split(separator: ";").compactMap { Int($0) }
                if parts.count == 3 {
                    let cb = parts[0]
                    let cx = parts[1]
                    let cy = parts[2]
                    let decodedMouse = Self.decodeSGRMouse(cb: cb, col: cx, row: cy, isRelease: finalByte == 0x6D)
                    return (.mouse(decodedMouse), scan + 1)
                }
            }

            if let (key, mods) = Self.decodeCSISpecialKey(paramStr: paramStr, finalByte: finalByte) {
                return (.specialKey(key: key, modifiers: mods), scan + 1)
            }

            let rawSeq = String(decoding: bytes[startIndex...scan], as: UTF8.self)
            return (.unknownEscapeSequence(rawSeq), scan + 1)
        }

        // Alt + printable ASCII (`ESC <char>`)
        if second >= 0x20 && second < 0x7F {
            let ch = String(UnicodeScalar(second))
            if ch == " " {
                return (.specialKey(key: .space, modifiers: [.alt]), startIndex + 2)
            }
            return (.printableText("\u{1B}\(ch)"), startIndex + 2)
        }

        return nil
    }

    private func findSubsequence(_ needle: [UInt8], in haystack: [UInt8], from offset: Int) -> Int? {
        guard !needle.isEmpty, offset + needle.count <= haystack.count else { return nil }
        let limit = haystack.count - needle.count
        var pos = offset
        while pos <= limit {
            if haystack[pos] == needle[0] {
                var matched = true
                for k in 1..<needle.count where haystack[pos + k] != needle[k] {
                    matched = false
                    break
                }
                if matched { return pos }
            }
            pos += 1
        }
        return nil
    }

    private static func specialKeyForSS3FinalByte(_ b: UInt8) -> TerminalSpecialKey? {
        switch b {
        case 0x41: return .up
        case 0x42: return .down
        case 0x43: return .right
        case 0x44: return .left
        case 0x48: return .home
        case 0x46: return .end
        case 0x50: return .f1
        case 0x51: return .f2
        case 0x52: return .f3
        case 0x53: return .f4
        case 0x4D: return .keypadEnter
        default:   return nil
        }
    }

    private static func decodeModifiers(fromCSIParam param: Int) -> TerminalKeyModifiers {
        let bits = max(0, param - 1)
        var mods: TerminalKeyModifiers = []
        if (bits & 1) != 0 { mods.insert(.shift) }
        if (bits & 2) != 0 { mods.insert(.alt) }
        if (bits & 4) != 0 { mods.insert(.control) }
        if (bits & 8) != 0 { mods.insert(.meta) }
        return mods
    }

    private static func decodeCSISpecialKey(
        paramStr: String,
        finalByte: UInt8
    ) -> (TerminalSpecialKey, TerminalKeyModifiers)? {
        let parts = paramStr.isEmpty ? [] : paramStr.split(separator: ";").compactMap { Int($0) }
        let mods = parts.count >= 2 ? decodeModifiers(fromCSIParam: parts[1]) : []

        if finalByte == 0x7E, let code = parts.first { // `~`
            let key: TerminalSpecialKey?
            switch code {
            case 1, 7: key = .home
            case 2:    key = .insert
            case 3:    key = .delete
            case 4, 8: key = .end
            case 5:    key = .pageUp
            case 6:    key = .pageDown
            case 15:   key = .f5
            case 17:   key = .f6
            case 18:   key = .f7
            case 19:   key = .f8
            case 20:   key = .f9
            case 21:   key = .f10
            case 23:   key = .f11
            case 24:   key = .f12
            case 25:   key = .f13
            case 26:   key = .f14
            case 28:   key = .f15
            case 29:   key = .f16
            case 31:   key = .f17
            case 32:   key = .f18
            case 33:   key = .f19
            case 34:   key = .f20
            default:   key = nil
            }
            if let k = key { return (k, mods) }
            return nil
        }

        if let k = specialKeyForSS3FinalByte(finalByte) {
            return (k, mods)
        }
        return nil
    }

    private static func decodeSGRMouse(
        cb: Int,
        col: Int,
        row: Int,
        isRelease: Bool
    ) -> TerminalMouseEvent {
        var mods: TerminalKeyModifiers = []
        if (cb & 4) != 0  { mods.insert(.shift) }
        if (cb & 8) != 0  { mods.insert(.alt) }
        if (cb & 16) != 0 { mods.insert(.control) }

        let isMotion = (cb & 32) != 0
        let isWheel = (cb & 64) != 0
        let isExtButton = (cb & 128) != 0
        let lowBits = cb & 0b11

        let button: TerminalMouseButton
        if isExtButton {
            button = (lowBits == 0) ? .backButton4 : .forwardButton5
        } else if isWheel {
            switch lowBits {
            case 0:  button = .wheelUp
            case 1:  button = .wheelDown
            case 2:  button = .wheelLeft
            default: button = .wheelRight
            }
        } else {
            switch lowBits {
            case 0:  button = .left
            case 1:  button = .middle
            case 2:  button = .right
            default: button = .none
            }
        }

        let kind: TerminalMouseEventKind
        if isWheel {
            kind = .scroll
        } else if isRelease {
            kind = .release
        } else if isMotion {
            kind = (button == .none) ? .hoverMotion : .drag
        } else {
            kind = .press
        }

        return TerminalMouseEvent(
            button: button,
            kind: kind,
            column: col,
            row: row,
            modifiers: mods
        )
    }
}
