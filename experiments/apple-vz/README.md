# experiments/apple-vz

Moved from ryanmaclean/vibecode-webgui@129302a73be9719d213561116319d13ed679fd71 on 2026-10-24
(history not carried).

These are Apple Virtualization.framework and Containerization Swift experiments from
vibecode-webgui. No CI there built or tested them. They are here because smolfire owns
microVM runtime research. They sit in their own commit so the smolfire owner can drop them
without touching `imports/vibecode/`.

Licence: MIT, see `LICENSES/vibecode-webgui-MIT.txt`. Swift dependencies named in the moved
`Package.resolved` files are apple/swift-argument-parser, swift-asn1, swift-crypto, swift-log
(Apache-2.0) and weichsel/ZIPFoundation (MIT).

| Path | Was in vibecode-webgui |
|---|---|
| `swift/containers/` | `swift/` (ContainerManager / PostgreSQLContainer SwiftPM package) |
| `platforms/macos/vz-swift/` | standalone VZ VM, NAT networking config |
| `platforms/macos/postgresql-vm/` | PostgreSQL in a VZ VM |
| `platforms/macos/Sources/` | early VibeCode macOS VM/UI sources |
| `platforms/macos/native-build/` | native macOS build experiment |
| `platforms/macos/apple-container/` | apple/container stack scripts (the v1.0.0-apple-container tag tarball used by the homebrew formula still has its own copy) |
| `platforms/macos/swift/vm-orchestration/`, `platforms/macos/swift/vm/` | VM pool/boot orchestration prototypes |
| `feature-audit/feature-1448-*` | the vibecode jest audit test (and its doc) that read `vz-swift/Sources/VibeCodeVM/NetworkConfig.swift` |

Not moved, because live vibecode code still points at them: `platforms/macos/vm`,
`platforms/macos/vm-assets`, `platforms/macos/swift/lima-launcher` and
`platforms/macos/AppleContainerRuntime`.
