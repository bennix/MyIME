import Carbon
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("usage: inspect_input_source.swift bundle.identifier\n", stderr)
    exit(2)
}

let bundleID = CommandLine.arguments[1]
let filter = [kTISPropertyBundleID as String: bundleID] as CFDictionary
guard let result = TISCreateInputSourceList(filter, true) else { exit(1) }
let sources = result.takeRetainedValue() as NSArray

func property(_ source: TISInputSource, _ key: CFString) -> Any {
    guard let pointer = TISGetInputSourceProperty(source, key) else { return "<nil>" }
    return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
}

for case let source as TISInputSource in sources {
    print("ID: \(property(source, kTISPropertyInputSourceID))")
    print("Name: \(property(source, kTISPropertyLocalizedName))")
    print("Category: \(property(source, kTISPropertyInputSourceCategory))")
    print("Type: \(property(source, kTISPropertyInputSourceType))")
    print("Mode: \(property(source, kTISPropertyInputModeID))")
    print("Languages: \(property(source, kTISPropertyInputSourceLanguages))")
    print("Enabled: \(property(source, kTISPropertyInputSourceIsEnabled))")
    print("Select capable: \(property(source, kTISPropertyInputSourceIsSelectCapable))")
    print("---")
}

if let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() {
    print("Current: \(property(current, kTISPropertyInputSourceID))")
}
