// Renders FinderPlus's app icon: a magnifying glass over a Finder-style folder, the lens showing
// enlarged text with one match highlighted, and a plus badge on the rim. Run from the package
// root: `swift Resources/Icon/make-icon.swift`.
// Writes Resources/Icon/AppIcon-1024.png and Resources/Assets.xcassets/AppIcon.appiconset.
//
// Drawn on Apple's macOS icon grid — an 824 pt continuous-corner square centred on a 1024 canvas,
// with room for the standard drop shadow — so it sits at the same size as every other icon in the
// Dock instead of looking oversized or being boxed in by the system.
import AppKit
import SwiftUI

let canvas: CGFloat = 1024
let tile: CGFloat = 824
let corner: CGFloat = 185

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

/// A folder's back panel: a body with a tab on its upper left.
struct FolderBack: Shape {
    func path(in rect: CGRect) -> Path {
        let tabHeight = rect.height * 0.13
        let radius = CGSize(width: 30, height: 30)
        var path = Path()
        path.addRoundedRect(
            in: CGRect(x: rect.minX, y: rect.minY + tabHeight, width: rect.width, height: rect.height - tabHeight),
            cornerSize: radius, style: .continuous)
        path.addRoundedRect(
            in: CGRect(x: rect.minX, y: rect.minY, width: rect.width * 0.4, height: tabHeight * 2.2),
            cornerSize: radius, style: .continuous)
        return path
    }
}

/// Grey bars standing in for lines of text, with an optional highlighted one.
struct TextLines: View {
    let widths: [CGFloat]
    let lineHeight: CGFloat
    let spacing: CGFloat
    var highlighted: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(widths.indices, id: \.self) { index in
                Capsule()
                    .fill(index == highlighted ? Color(hex: 0x2B2F45) : Color(hex: 0xB9C0D4))
                    .frame(width: widths[index], height: lineHeight)
                    .padding(.horizontal, index == highlighted ? lineHeight * 0.5 : 0)
                    .padding(.vertical, index == highlighted ? lineHeight * 0.35 : 0)
                    .background {
                        if index == highlighted {
                            RoundedRectangle(cornerRadius: lineHeight * 0.4, style: .continuous)
                                .fill(Color(hex: 0xFFD60A))
                        }
                    }
                    .padding(.horizontal, index == highlighted ? -lineHeight * 0.5 : 0)
                    .padding(.vertical, index == highlighted ? -lineHeight * 0.35 : 0)
            }
        }
    }
}

struct Icon: View {
    var body: some View {
        ZStack {
            background
            folder.offset(x: -60, y: 110)
            magnifier.offset(x: 88, y: -112)
        }
        .frame(width: canvas, height: canvas)
    }

    // A deep indigo tile, so the light folder and silver glass stand out against it.
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        return ZStack {
            shape.fill(LinearGradient(
                colors: [Color(hex: 0x4B4FD6), Color(hex: 0x3A2E9E), Color(hex: 0x5B2396)],
                startPoint: .top, endPoint: .bottom))
            Circle().fill(Color(hex: 0x7FD4FF, opacity: 0.45))
                .frame(width: 620).blur(radius: 140).offset(x: 190, y: -300)
            Circle().fill(Color(hex: 0xFF6FC8, opacity: 0.28))
                .frame(width: 520).blur(radius: 140).offset(x: -260, y: 320)
            shape.fill(LinearGradient(
                colors: [.white.opacity(0.22), .clear], startPoint: .top, endPoint: .center))
            shape.strokeBorder(LinearGradient(
                colors: [.white.opacity(0.5), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom),
                lineWidth: 5)
        }
        .frame(width: tile, height: tile)
        .clipShape(shape)
        .shadow(color: .black.opacity(0.35), radius: 22, y: 14)
    }

    private var folder: some View {
        let size = CGSize(width: 540, height: 400)
        return ZStack(alignment: .bottom) {
            FolderBack()
                .fill(LinearGradient(colors: [Color(hex: 0x3F9BEF), Color(hex: 0x2270CF)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: size.width, height: size.height)

            // Papers peeking out of the folder.
            paper(lines: [300, 340, 260, 320]).rotationEffect(.degrees(-6)).offset(x: -40, y: -150)
            paper(lines: [320, 280, 340, 240]).rotationEffect(.degrees(4)).offset(x: 30, y: -125)

            // Front panel, lighter, with a bright top edge.
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x8ED0FF), Color(hex: 0x48A4F2)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(alignment: .top) {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.8), .clear],
                                                     startPoint: .top, endPoint: .center), lineWidth: 4)
                }
                .frame(width: size.width, height: size.height * 0.74)
                .shadow(color: Color(hex: 0x0B2A66, opacity: 0.35), radius: 14, y: -4)
        }
        .frame(width: size.width, height: size.height)
        .shadow(color: .black.opacity(0.3), radius: 24, y: 16)
    }

    private func paper(lines: [CGFloat]) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(LinearGradient(colors: [.white, Color(hex: 0xE9EEF7)], startPoint: .top, endPoint: .bottom))
            .frame(width: 420, height: 300)
            .overlay(alignment: .topLeading) {
                TextLines(widths: lines, lineHeight: 14, spacing: 18).padding(.top, 34).padding(.leading, 40)
            }
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }

    private var magnifier: some View {
        let radius: CGFloat = 178
        let rim: CGFloat = 32
        let handleDistance = radius + 96
        return ZStack {
            // Handle and its metal collar, angled down and to the right.
            ZStack {
                Capsule()
                    .fill(LinearGradient(colors: [Color(hex: 0x4A4E5C), Color(hex: 0x1E2029), Color(hex: 0x3A3D48)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: 84, height: 200)
                    .offset(y: 20)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: 0xF4F6FA), Color(hex: 0x9CA3B3), Color(hex: 0xE3E7EE)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: 100, height: 64)
                    .offset(y: -86)
            }
            .rotationEffect(.degrees(-45))
            .offset(x: handleDistance / sqrt(2), y: handleDistance / sqrt(2))
            .shadow(color: .black.opacity(0.35), radius: 16, y: 12)

            // What the lens shows: the page enlarged, one line highlighted as a search match.
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Color(hex: 0xFBFCFF), Color(hex: 0xE6EDF9)], startPoint: .top, endPoint: .bottom)
                TextLines(widths: [230, 280, 170, 250, 210], lineHeight: 30, spacing: 30, highlighted: 2)
                    .padding(.top, 58).padding(.leading, 64)
            }
            .frame(width: radius * 2, height: radius * 2)
            .overlay {
                // Glass: a faint blue cast and a curved reflection upper left.
                Circle().fill(RadialGradient(colors: [.clear, Color(hex: 0x7FB6FF, opacity: 0.14)],
                                             center: .center, startRadius: radius * 0.4, endRadius: radius))
                Ellipse().fill(.white.opacity(0.38))
                    .frame(width: radius * 0.9, height: radius * 0.42)
                    .rotationEffect(.degrees(-35))
                    .offset(x: -radius * 0.38, y: -radius * 0.5)
                    .blur(radius: 10)
            }
            .clipShape(Circle())

            // Metal rim with a bevel: bright outer edge, dark inner edge.
            Circle()
                .strokeBorder(AngularGradient(
                    colors: [Color(hex: 0xFFFFFF), Color(hex: 0xA7AEBD), Color(hex: 0xECEFF5),
                             Color(hex: 0x7D8494), Color(hex: 0xFFFFFF)],
                    center: .center, angle: .degrees(-45)), lineWidth: rim)
                .frame(width: radius * 2 + rim, height: radius * 2 + rim)
            Circle()
                .strokeBorder(Color.black.opacity(0.25), lineWidth: 3)
                .frame(width: radius * 2 - 2, height: radius * 2 - 2)

            plusBadge.offset(x: radius * 0.78, y: -radius * 0.78)
        }
        .shadow(color: .black.opacity(0.35), radius: 26, x: 6, y: 18)
    }

    private var plusBadge: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Color(hex: 0x5BE584), Color(hex: 0x1FAE4D)],
                                     startPoint: .top, endPoint: .bottom))
            Circle().strokeBorder(.white, lineWidth: 10)
            ZStack {
                Capsule().frame(width: 76, height: 22)
                Capsule().frame(width: 22, height: 76)
            }
            .foregroundStyle(.white)
        }
        .frame(width: 150, height: 150)
        .shadow(color: .black.opacity(0.3), radius: 10, y: 6)
    }
}

@MainActor
func render() throws {
    let renderer = ImageRenderer(content: Icon())
    renderer.scale = 1
    guard let cgImage = renderer.cgImage else { throw CocoaError(.fileWriteUnknown) }
    let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])!
    try png.write(to: URL(filePath: "Resources/Icon/AppIcon-1024.png"))
}

try MainActor.assumeIsolated { try render() }

// An asset catalog, compiled by build.sh with actool into Assets.car (what the Dock reads on
// macOS 26+, via CFBundleIconName) and AppIcon.icns (for anything older). A bare .icns alone
// showed as the blank placeholder in the Dock while Finder drew it fine.
let appIconSet = URL(filePath: "Resources/Assets.xcassets/AppIcon.appiconset")
try? FileManager.default.removeItem(at: appIconSet)
try FileManager.default.createDirectory(at: appIconSet, withIntermediateDirectories: true)
try Data(#"{ "info" : { "author" : "xcode", "version" : 1 } }"#.utf8)
    .write(to: URL(filePath: "Resources/Assets.xcassets/Contents.json"))
var entries: [String] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
        let sips = Process()
        sips.executableURL = URL(filePath: "/usr/bin/sips")
        sips.arguments = ["-z", "\(size * scale)", "\(size * scale)", "Resources/Icon/AppIcon-1024.png",
                          "--out", appIconSet.appending(path: name).path]
        sips.standardOutput = FileHandle.nullDevice
        try sips.run()
        sips.waitUntilExit()
        entries.append(#"{ "idiom" : "mac", "size" : "\#(size)x\#(size)", "scale" : "\#(scale)x", "filename" : "\#(name)" }"#)
    }
}
try Data(("{ \"images\" : [\n  " + entries.joined(separator: ",\n  ")
          + "\n], \"info\" : { \"author\" : \"xcode\", \"version\" : 1 } }\n").utf8)
    .write(to: appIconSet.appending(path: "Contents.json"))
print("Wrote Resources/Assets.xcassets/AppIcon.appiconset")
