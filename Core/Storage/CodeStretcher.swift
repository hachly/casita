import CommonCrypto
import CryptoKit
import Foundation
import Security

/// Turns a code into a key slowly enough that guessing is expensive.
///
/// On a device, every guess has to go through a key that lives in the
/// Secure Enclave and never leaves the phone, so guessing can only happen on
/// that phone (the Sloth design, PoPETs 2024). PBKDF2 on top covers the case
/// where someone extracts the wrapped key material anyway.
protocol CodeStretcher: Sendable {
    func stretch(code: String, salt: Data) throws -> SymmetricKey
}

extension CodeStretcher where Self == SecureEnclaveStretcher {
    /// The Secure Enclave stretcher on devices, PBKDF2 alone in the simulator
    /// (which has no Secure Enclave).
    static var `default`: any CodeStretcher {
        if SecureEnclave.isAvailable {
            return SecureEnclaveStretcher(rounds: SecureEnclaveStretcher.defaultRounds, iterations: 600_000)
        }
        return PBKDF2Stretcher(iterations: 600_000)
    }
}

/// PBKDF2-HMAC-SHA256 from CommonCrypto. Apple-provided, so export compliance
/// stays simple; also the simulator stand-in.
struct PBKDF2Stretcher: CodeStretcher {
    var iterations: UInt32

    func stretch(code: String, salt: Data) throws -> SymmetricKey {
        SymmetricKey(data: pbkdf2(Data(code.utf8), salt: salt, iterations: iterations))
    }
}

/// Each guess costs `rounds` ECDH operations inside the Secure Enclave,
/// then PBKDF2.
struct SecureEnclaveStretcher: CodeStretcher {
    /// Fixed for every file: changing it would change every key. On an
    /// iPhone 15 Pro Max one guess takes about 0.5 s; the slowest supported
    /// iPhone must stay under the 1 s floor every attempt is padded to, or a
    /// right code would take longer than a wrong one. `calibratedRounds` only
    /// measures, for that device check.
    static let defaultRounds = 60
    private static let keychainAccount = "com.hachly.casita.stretch-key"

    var rounds: Int
    var iterations: UInt32

    func stretch(code: String, salt: Data) throws -> SymmetricKey {
        let enclaveKey = try Self.loadOrCreateEnclaveKey()
        let seed = SymmetricKey(data: pbkdf2(Data(code.utf8), salt: salt, iterations: 10_000))
        var transcript = Data()
        for round in 0..<rounds {
            let peer = try Self.publicKey(seed: seed, round: round)
            let shared = try enclaveKey.sharedSecretFromKeyAgreement(with: peer)
            shared.withUnsafeBytes { transcript.append(contentsOf: $0) }
        }
        return SymmetricKey(data: pbkdf2(transcript, salt: salt, iterations: iterations))
    }

    /// How many rounds make one guess take about `target` on this device.
    /// Device only: the simulator has no Secure Enclave.
    static func calibratedRounds(target: Duration = .milliseconds(500)) throws -> Int {
        let key = try loadOrCreateEnclaveKey()
        let seed = SymmetricKey(size: .bits256)
        let clock = ContinuousClock()
        let sample = 5
        let elapsed = try clock.measure {
            for round in 0..<sample {
                _ = try key.sharedSecretFromKeyAgreement(with: try publicKey(seed: seed, round: round))
            }
        }
        let perRound = elapsed / sample
        return max(10, Int(target / perRound))
    }

    /// A P-256 public key derived from the code, different every round.
    private static func publicKey(seed: SymmetricKey, round: Int) throws -> P256.KeyAgreement.PublicKey {
        for attempt in 0..<16 {
            let scalar = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: seed,
                info: Data("casita.sloth.\(round).\(attempt)".utf8),
                outputByteCount: 32
            )
            let raw = scalar.withUnsafeBytes { Data($0) }
            if let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: raw) {
                return key.publicKey
            }
        }
        throw StorageError.stretchFailed
    }

    private static func loadOrCreateEnclaveKey() throws -> SecureEnclave.P256.KeyAgreement.PrivateKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrAccessGroup as String: AppGroup.id,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data {
            return try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: data)
        }
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .privateKeyUsage, nil
        ) else { throw StorageError.stretchFailed }
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrAccessGroup as String: AppGroup.id,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: key.dataRepresentation,
        ]
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw StorageError.stretchFailed }
        return key
    }
}

func pbkdf2(_ password: Data, salt: Data, iterations: UInt32, length: Int = 32) -> Data {
    var output = Data(count: length)
    let status = output.withUnsafeMutableBytes { out in
        password.withUnsafeBytes { pass in
            salt.withUnsafeBytes { salt in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pass.baseAddress?.assumingMemoryBound(to: Int8.self), pass.count,
                    salt.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                    out.baseAddress?.assumingMemoryBound(to: UInt8.self), length
                )
            }
        }
    }
    precondition(status == kCCSuccess, "PBKDF2 failed: \(status)")
    return output
}
