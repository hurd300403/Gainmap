//  macOS reference-render CLI for the S1 cross-GPU probe.
//  Usage: refrender <src.jpg> <out.f16>
import Foundation

let args = CommandLine.arguments
guard args.count == 3, let jpeg = FileManager.default.contents(atPath: args[1]) else {
    FileHandle.standardError.write(Data("usage: refrender <src.jpg> <out.f16>\n".utf8))
    exit(2)
}
guard let r = SpikeRender.renderF16(jpegData: jpeg) else {
    FileHandle.standardError.write(Data("render failed\n".utf8))
    exit(1)
}
try! r.data.write(to: URL(fileURLWithPath: args[2]))
print("ref: \(r.width)x\(r.height)  \(r.data.count) bytes")
