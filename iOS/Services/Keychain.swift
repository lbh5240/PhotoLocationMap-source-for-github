import Foundation
import Security
import ZoraCore

enum Keychain {
    private static let service = "app.zora.camera.credentials"
    static func saveValue<T: Encodable>(_ value: T, id: String) throws {
        let data = try JSONEncoder().encode(value)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id]
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        let status = update == errSecItemNotFound ? SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) : update
        guard status == errSecSuccess else { throw ZoraError.unsupported("钥匙串保存失败 \(status)") }
    }
    static func loadValue<T: Decodable>(_ type: T.Type, id: String) throws -> T {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: id, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { throw ZoraError.disconnected }
        return try JSONDecoder().decode(type, from: data)
    }
    static func delete(id: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id] as CFDictionary)
    }
    static func save(_ credential: NASCredential, id: String) throws {
        let data = try JSONEncoder().encode(Stored(username: credential.username, secret: credential.secret, token: credential.token))
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id]
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        let status = update == errSecItemNotFound ? SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) : update
        guard status == errSecSuccess else { throw ZoraError.unsupported("钥匙串保存失败 \(status)") }
    }
    static func load(id: String) throws -> NASCredential {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: id, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { throw ZoraError.unsupported("请先保存 NAS 凭据") }
        let stored = try JSONDecoder().decode(Stored.self, from: data)
        return NASCredential(username: stored.username, secret: stored.secret, token: stored.token)
    }
    private struct Stored: Codable { let username: String, secret: String, token: String? }
}
