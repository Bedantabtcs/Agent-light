import Foundation

public enum AppIdentity {
    public static let bundleIdentifier = "com.bbatchas.agentlight"
    public static let integrationIdentifier = "com.bbatchas.agentlight.hook.v1"
    public static let keychainService = "com.bbatchas.agentlight.tuya"

    public static var applicationSupportDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Agent Light", directoryHint: .isDirectory)
    }

    public static var socketPath: String {
        applicationSupportDirectory.appending(path: "agent-light-v1.sock").path
    }
}
