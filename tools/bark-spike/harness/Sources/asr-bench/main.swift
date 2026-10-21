import Darwin
import FluidAudio
import Foundation

// asr-bench <model-dir> <v2|v3|v3-local> <audio-dir> <out.jsonl>
//
// Loads a Parakeet Core ML folder the way Whale does (AsrManager(.default), fresh decoder
// state per file) and writes one JSON line per WAV. Prints load time, transcription time and
// peak memory footprint at the end.
//
// v2 and v3 go through AsrModels.load(from:), which ignores the folder's own name and resolves
// <parent>/<FluidAudio's folder for that version>, downloading the stock model if it's not
// there. v3-local uses AsrModels.loadLocal(from:), which reads exactly the given folder.

func footprintMB() -> (now: Double, peak: Double) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return (0, 0) }
    return (Double(info.phys_footprint) / 1_048_576, Double(info.ledger_phys_footprint_peak) / 1_048_576)
}

let args = CommandLine.arguments
guard args.count == 5 else {
    FileHandle.standardError.write("usage: asr-bench <model-dir> <v2|v3|v3-local> <audio-dir> <out.jsonl>\n".data(using: .utf8)!)
    exit(2)
}
let modelDir = URL(fileURLWithPath: args[1], isDirectory: true)
let version: AsrModelVersion = args[2].hasPrefix("v3") ? .v3 : .v2
let local = args[2] == "v3-local"
let audioDir = URL(fileURLWithPath: args[3], isDirectory: true)
let outURL = URL(fileURLWithPath: args[4])

let t0 = Date()
let models = local
    ? try AsrModels.loadLocal(from: modelDir, version: version)
    : try await AsrModels.load(from: modelDir, version: version)
let manager = AsrManager(config: .default)
try await manager.loadModels(models)
let loadSeconds = Date().timeIntervalSince(t0)
let afterLoad = footprintMB()

let files = try FileManager.default.contentsOfDirectory(at: audioDir, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "wav" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

FileManager.default.createFile(atPath: outURL.path, contents: nil)
let out = try FileHandle(forWritingTo: outURL)
var busy = 0.0
var audioSeconds = 0.0
for file in files {
    var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
    let t = Date()
    let result = try await manager.transcribe(file, decoderState: &state)
    busy += Date().timeIntervalSince(t)
    audioSeconds += result.duration
    let line = try JSONSerialization.data(withJSONObject: [
        "id": file.lastPathComponent,
        "text": result.text.trimmingCharacters(in: .whitespacesAndNewlines),
    ])
    out.write(line + Data([0x0A]))
}
try out.close()

let end = footprintMB()
let summary: [String: Any] = [
    "files": files.count,
    "load_s": (loadSeconds * 100).rounded() / 100,
    "audio_s": audioSeconds.rounded(),
    "transcribe_s": (busy * 100).rounded() / 100,
    "footprint_after_load_mb": afterLoad.now.rounded(),
    "footprint_end_mb": end.now.rounded(),
    "footprint_peak_mb": end.peak.rounded(),
]
print(String(data: try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]), encoding: .utf8)!)
