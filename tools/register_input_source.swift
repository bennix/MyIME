import Carbon
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("usage: register_input_source.swift /path/to/InputMethod.app\n", stderr)
    exit(2)
}

let bundleURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true) as CFURL
let status = TISRegisterInputSource(bundleURL)
guard status == noErr else {
    fputs("TISRegisterInputSource failed with status \(status)\n", stderr)
    exit(1)
}

guard let identifier = Bundle(url: bundleURL as URL)?.bundleIdentifier else {
    fputs("registered bundle has no identifier\n", stderr)
    exit(1)
}
var filters = [[kTISPropertyBundleID as String: identifier] as CFDictionary]
var modeFilters: [CFDictionary] = []
if let modes = Bundle(url: bundleURL as URL)?.object(forInfoDictionaryKey: "ComponentInputModeDict") as? [String: Any],
   let modeList = modes["tsInputModeListKey"] as? [String: Any] {
    modeFilters = modeList.keys.map {
        [kTISPropertyInputSourceID as String: $0] as CFDictionary
    }
    filters.append(contentsOf: modeFilters)
}

var enabledCount = 0
for filter in modeFilters {
    guard let result = TISCreateInputSourceList(filter, true) else { continue }
    for case let source as TISInputSource in result.takeRetainedValue() as NSArray {
        if TISEnableInputSource(source) == noErr { enabledCount += 1 }
    }
}

let registeredCount = filters.reduce(into: 0) { count, filter in
    if let result = TISCreateInputSourceList(filter, true) {
        let sources = result.takeRetainedValue() as NSArray
        count += sources.count
    }
}
guard registeredCount > 0 else {
    fputs("macOS did not enumerate the registered input source\n", stderr)
    exit(1)
}
print("Registered \(identifier) with \(registeredCount) source record(s); enabled \(enabledCount) input mode(s).")
