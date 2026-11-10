import AppKit
import BetterTileCore
@testable import BetterTileMacOS
@main struct GlyphProcess {
 @MainActor static func main() async throws {
  _ = NSApplication.shared
  let mode=CommandLine.arguments[1],out=URL(fileURLWithPath:CommandLine.arguments[3],isDirectory:true)
  try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
  let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
  if mode=="canonical" {
   let value=try JSONDecoder().decode(GlyphMaskStore.Manifest.self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2])))
   try encoder.encode(value).write(to:out.appendingPathComponent("manifest.json"));return
  }
  if mode=="manifest" {
   let (manifest,files)=try await GlyphMaskReference.generate(acceptStoredMember:true, refreshing:.menuGlass)
   try encoder.encode(manifest).write(to:out.appendingPathComponent("manifest.json"))
   for (name,data) in files {try data.write(to:out.appendingPathComponent(name))}
   return
  }
  let dark=CommandLine.arguments[2]=="dark"
  var records:[[String:Any]]=[]
  for action in WindowAction.allCases {for scale in [1.0,2.0] {
   let key=GlyphMaskStore.key(set:.menuGlass,id:action.rawValue,pointSize:20,scale:scale,appearance:dark ? .dark:.light)
   let samples=try GlyphMaskReference.sample(key) {try GlyphMaskReference.render(set:.menuGlass,slot:.init(command:.windowAction(action)),pointSize:20,scale:scale,dark:dark)}
   var outputs:[[String:Any]]=[]
   for (bytes,count) in samples.outputs {
    let w=samples.image.width,h=samples.image.height
    let bitmap=CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:w*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue),provider:CGDataProvider(data:bytes as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
    let (entry,png)=try GlyphMaskReference.encode(bitmap)
    let digest=GlyphMaskReference.sha(bytes);try bytes.write(to:out.appendingPathComponent(digest+".rgba"));try png.write(to:out.appendingPathComponent(entry.file))
    let peak = stride(from:3,to:bytes.count,by:4).map { bytes[$0] }.max()!
    let black = stride(from:0,to:bytes.count,by:4).allSatisfy { bytes[$0]==0 && bytes[$0+1]==0 && bytes[$0+2]==0 }
    let row: [String: Any] = ["sha256":digest,"count":count,"png":entry.file,"width":w,"height":h,"peakAlpha":Int(peak),"black":black]
    outputs.append(row)
   }
   records.append(["key":key,"outputs":outputs])
  }}
  let result:[String:Any]=["pid":ProcessInfo.processInfo.processIdentifier,"appearance":dark ? "dark":"light","records":records]
  try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("samples.json"))
 }
}
