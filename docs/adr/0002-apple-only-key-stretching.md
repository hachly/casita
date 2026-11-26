# Apple-only key stretching: Secure Enclave plus PBKDF2

Codes must resist forensic extraction, but iOS gives apps no hardware limit on wrong guesses and Apple's only built-in password KDF is PBKDF2. Each code guess runs through a Secure Enclave key (the Sloth design, PoPETs 2024) so guessing can only happen on that phone, then PBKDF2 from CommonCrypto. We do not use scrypt or Argon2: they are stronger against offline GPU guessing, but they are not OS crypto, so `ITSAppUsesNonExemptEncryption` would become YES and France would need an encryption declaration.

## Consequences

- Short codes (6 digits, 3×3 dots) only slow a lab down; the app labels them that way.
- Keys are tied to the phone, so moving to a new phone needs the recovery key.
