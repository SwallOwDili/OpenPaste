import AppKit

/// The menu-bar mark: a solid single-colour "P" drawn from vector path data, so it stays crisp at 1x and 2x and follows the
/// light/dark menu bar as a template image.
///
/// `pathData` is the `d` attribute of `Assets/OpenPaste-menu-template.svg` (18 × 18, y pointing down, even-odd fill, so the
/// counter of the P is a hole). Keep the two in sync when the artwork changes.
enum MenuBarMark {
    static let size = NSSize(width: 18, height: 18)
    static let pathData = "M5.45 1.25H12.65C14.88 1.25 16.50 2.92 16.50 5.10C16.50 7.13 15.85 8.91 14.87 9.75C13.82 10.59 11.42 10.90 8.45 10.90H6.62C6.17 10.90 6.00 11.15 6.00 11.64V14.92C6.00 16.00 5.24 16.75 4.17 16.75H3.41C2.24 16.75 1.50 16.00 1.50 14.92V5.08C1.50 2.91 3.26 1.25 5.45 1.25ZM5.49 4.00C4.79 4.00 4.34 4.47 4.34 5.13V6.83C4.34 7.49 4.75 7.88 5.43 7.88H12.98C13.68 7.88 14.12 7.45 14.12 6.83V5.13C14.12 4.47 13.62 4.00 12.94 4.00H5.49Z"

    /// Parses the absolute `M`, `H`, `V`, `C` and `Z` commands the template uses into a path with even-odd filling.
    static func parse(_ data: String) -> NSBezierPath {
        let path = NSBezierPath()
        path.windingRule = .evenOdd
        var command: Character = " "
        var args: [CGFloat] = []
        func apply() {
            switch command {
            case "M" where args.count >= 2: path.move(to: NSPoint(x: args[0], y: args[1]))
            case "H" where args.count >= 1: path.line(to: NSPoint(x: args[0], y: path.currentPoint.y))
            case "V" where args.count >= 1: path.line(to: NSPoint(x: path.currentPoint.x, y: args[0]))
            case "C" where args.count >= 6:
                path.curve(to: NSPoint(x: args[4], y: args[5]),
                           controlPoint1: NSPoint(x: args[0], y: args[1]),
                           controlPoint2: NSPoint(x: args[2], y: args[3]))
            case "Z": path.close()
            default: break
            }
        }
        var number = ""
        for character in data + " " {
            if character.isNumber || character == "." || (character == "-" && number.isEmpty) { number.append(character); continue }
            if !number.isEmpty { args.append(CGFloat(Double(number) ?? 0)); number = "" }
            if character.isLetter { apply(); command = character; args = [] }
        }
        apply()
        return path
    }

    private static let shape = parse(pathData)

    static func image() -> NSImage {
        // Flipped, so the SVG's y-down coordinates are used as they are.
        let image = NSImage(size: size, flipped: true) { _ in
            NSColor.black.setFill()
            shape.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "OpenPaste"
        return image
    }
}
