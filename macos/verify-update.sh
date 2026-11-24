#!/bin/sh
# Says whether a file carries a signature made with an update key: the
# check every installed copy makes before it takes an update, done here
# with a few lines of CryptoKit and none of Sparkle's tools. release.sh and
# publish.sh use it, so that a release signed with any other key than the
# one in the app is caught before it is out.
#
# Usage: macos/verify-update.sh <public-key> <signature> <file>
#   public-key   the key's public half, base64 (SUPublicEDKey)
#   signature    the file's EdDSA signature, base64 (sparkle:edSignature)
#
# Prints "valid" and exits 0. Otherwise prints "INVALID" (the signature is
# not this key's signature of this file) or "unreadable" (one of the three
# could not be read) and exits 1.
set -eu

if [ $# -ne 3 ]; then
    echo "usage: macos/verify-update.sh <public-key> <signature> <file>" >&2
    exit 2
fi

VERDICT=$(
    swift - "$1" "$2" "$3" <<'SWIFT' 2>/dev/null || true
import CryptoKit
import Foundation
let arguments = CommandLine.arguments
guard arguments.count == 4,
      let keyData = Data(base64Encoded: arguments[1]),
      let signature = Data(base64Encoded: arguments[2]), !signature.isEmpty,
      let archive = FileManager.default.contents(atPath: arguments[3]),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
    print("unreadable")
    exit(1)
}
print(key.isValidSignature(signature, for: archive) ? "valid" : "INVALID")
SWIFT
)
echo "${VERDICT:-unreadable}"
[ "$VERDICT" = valid ]
