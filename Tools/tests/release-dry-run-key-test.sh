#!/bin/bash
# Exercise only disposable key files. No Keychain lookup or release entrypoint.
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
scratch="$(mktemp -d /private/tmp/release-dry-run-key-test.XXXXXXXX)"
trap 'rm -rf "$scratch"' EXIT
public_key="$(swift "$script_dir/../lib/release-dry-run-key.swift" "$scratch/key")"
[[ "$(stat -f '%Lp' "$scratch/key")" == 600 ]]
# Verify that the emitted public key and private seed form a signing pair.
cat > "$scratch/check.swift" <<'SWIFT'
import CryptoKit
import Foundation
let seed = Data(base64Encoded: try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8))!
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: CommandLine.arguments[2])!)
let message = Data("release dry run".utf8)
let signature = try key.signature(for: message)
precondition(publicKey.isValidSignature(signature, for: message))
precondition(!publicKey.isValidSignature(signature, for: Data("changed".utf8)))
SWIFT
swift "$scratch/check.swift" "$scratch/key" "$public_key"
second_public_key="$(swift "$script_dir/../lib/release-dry-run-key.swift" "$scratch/second-key")"
[[ "$public_key" != "$second_public_key" ]]
echo 'release dry-run keys: private file, matching signature, tamper rejection, fresh key passed'
