# Security and secrets policy

NativeXiangqi v1 has no runtime network entitlement and never downloads executable
code, Pikafish, NNUE assets, source archives, or build dependencies during an Xcode
build or archive.

Do not commit signing identities, certificates, private keys, access tokens, Apple
Developer credentials, notary profiles, provisioning profiles, paid assets, user
records, diagnostics, or developer-specific absolute paths. Use the macOS Keychain and
CI secret stores for credentials. Device authorization is preferred for GitHub; never
paste access tokens or one-time device codes into issues, logs, prompts, or commits.

If a secret is committed, stop distribution, revoke or rotate it at the provider,
remove it from active history through a separately reviewed security change, and record
the incident without reproducing the credential. Report vulnerabilities privately to
the repository owner until a dedicated disclosure channel exists.
