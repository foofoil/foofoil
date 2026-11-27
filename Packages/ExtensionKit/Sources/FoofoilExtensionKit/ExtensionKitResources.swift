@_exported import FoofoilExtensionABI
import Foundation

public enum ExtensionKitResources {
    public static var manifestSchema: URL? {
        Bundle.module.url(forResource: "ExtensionManifest.schema", withExtension: "json")
    }

    public static func fixture(named name: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
    }
}
