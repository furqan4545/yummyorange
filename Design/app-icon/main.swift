import Foundation

// make-icon <out.iconset> [<preview.png>]: writes the shipped icon (direction B, Bloom) as an .iconset, and
// optionally its 1024 px art as a PNG.
let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: make-icon <out.iconset> [<preview.png>]\n".data(using: .utf8)!)
    exit(2)
}
writeIconset(.bloom, to: URL(fileURLWithPath: args[1], isDirectory: true))
if args.count > 2 { writePNG(render(.bloom, px: 1024), URL(fileURLWithPath: args[2])) }
