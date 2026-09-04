#!/bin/sh
set -eu

manifest=${1:?manifest path required}
artifact=${2:?artifact path required}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

jq -cS . "$manifest" > "$tmp/manifest.canonical.json"
expected_hash=$(jq -r .artifactSha256 "$tmp/manifest.canonical.json")
expected_size=$(jq -r .artifactSize "$tmp/manifest.canonical.json")
test "$(shasum -a 256 "$artifact" | cut -d ' ' -f 1)" = "$expected_hash"
test "$(wc -c < "$artifact" | tr -d ' ')" = "$expected_size"

openssl ecparam -name prime256v1 -genkey -noout -out "$tmp/private.pem"
openssl ec -in "$tmp/private.pem" -pubout -out "$tmp/public.pem" 2>/dev/null
openssl dgst -sha256 -sign "$tmp/private.pem" -out "$tmp/manifest.sig" "$tmp/manifest.canonical.json"
openssl dgst -sha256 -verify "$tmp/public.pem" -signature "$tmp/manifest.sig" "$tmp/manifest.canonical.json"

cp "$artifact" "$tmp/corrupt.so"
printf x >> "$tmp/corrupt.so"
test "$(shasum -a 256 "$tmp/corrupt.so" | cut -d ' ' -f 1)" != "$expected_hash"
