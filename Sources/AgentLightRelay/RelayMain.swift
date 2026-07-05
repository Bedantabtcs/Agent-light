import AgentLightCore
import AgentLightProtocol
import Foundation

@main
enum RelayMain {
    static func main() {
        do {
            let input = try readInput()
            let envelope = try RelayInputSanitizer.makeEnvelope(
                arguments: CommandLine.arguments,
                input: input,
                nowMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000)
            )
            let encodedEnvelope = try JSONEncoder().encode(envelope)
            guard encodedEnvelope.count <= 4_096 else {
                exit(EXIT_SUCCESS)
            }
            try UnixDatagramSender.send(encodedEnvelope, to: AppIdentity.socketPath)
        } catch {
            exit(EXIT_SUCCESS)
        }
        exit(EXIT_SUCCESS)
    }

    private static func readInput() throws -> Data {
        let maximumReadBytes = RelayInputSanitizer.maximumInputBytes + 1
        var input = Data()

        while input.count < maximumReadBytes {
            let remainingByteCount = maximumReadBytes - input.count
            guard
                let chunk = try FileHandle.standardInput.read(upToCount: remainingByteCount),
                !chunk.isEmpty
            else {
                break
            }
            input.append(chunk)
        }
        return input
    }
}
