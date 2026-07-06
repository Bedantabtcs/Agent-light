import CryptoKit
import Foundation

public enum TuyaSigner {
    public static func canonicalString(for request: TuyaSignedRequest) -> String {
        let bodyHash = SHA256.hash(data: request.body)
            .map { String(format: "%02x", $0) }
            .joined()
        return [request.method, bodyHash, "", request.pathAndQuery].joined(separator: "\n")
    }

    public static func signature(
        clientID: String,
        secret: String,
        token: String?,
        timestamp: String,
        nonce: String,
        canonicalString: String
    ) -> String {
        let payload = clientID + (token ?? "") + timestamp + nonce + canonicalString
        let authentication = HMAC<SHA256>.authenticationCode(
            for: Data(payload.utf8),
            using: SymmetricKey(data: Data(secret.utf8))
        )
        return authentication.map { String(format: "%02X", $0) }.joined()
    }

    public static func headers(
        for request: TuyaSignedRequest,
        credentials: TuyaCredentials,
        token: String?,
        timestamp: String,
        nonce: String
    ) -> [String: String] {
        let canonical = canonicalString(for: request)
        let sign = signature(
            clientID: credentials.accessID,
            secret: credentials.accessSecret,
            token: token,
            timestamp: timestamp,
            nonce: nonce,
            canonicalString: canonical
        )
        var headers = [
            "client_id": credentials.accessID,
            "sign": sign,
            "sign_method": "HMAC-SHA256",
            "t": timestamp,
            "nonce": nonce
        ]
        if let token {
            headers["access_token"] = token
        }
        return headers
    }
}
