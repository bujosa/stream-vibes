# Security and local data

Do not commit credentials, connection URLs, local preferences, device inventories,
or screenshots containing private data. Report vulnerabilities privately through
GitHub private vulnerability reporting; never include live secrets in public issues.

## Credential storage

Credentials entered in the app are stored in the macOS login Keychain using
non-synchronizing, device-only items. Existing credentials in UserDefaults are
migrated on launch. Plaintext preferences are removed only after a successful
Keychain write and read-back verification. If Keychain is unavailable, migration
keeps the previous value and reports an error; unlock Keychain and reopen the app.

A locally installed app's preferences and Keychain items are separate from the
source checkout and must never be included in a release. A database password or
API key previously committed to any repository must be revoked by its owner;
removing it from the current source does not revoke it or remove older copies.

## StreamVibes boundaries

The PostgreSQL connection URL is a credential and is stored in Keychain, too.
The app connects directly to the user's database using TLS 1.2+ with full
certificate and hostname verification. An explicit `sslrootcert` URL parameter
can select a CA certificate for a self-hosted server without changing OS trust.
Plaintext/unverified TLS modes are rejected. Use credentials scoped to a
dedicated shared catalog; the user switcher is
not a database authorization boundary. Movie metadata requests go to the selected
provider. OMDb and TMDB are optional and require your own keys in Settings → AI.
No provider key is bundled. AI requests send their supplied catalog/chat context
to the configured provider; local CLI providers follow their own configuration.
