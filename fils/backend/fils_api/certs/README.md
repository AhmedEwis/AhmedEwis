Place `AppleRootCA-G3.cer` here (run `scripts/fetch_apple_root.sh`). It could not be downloaded in the
build environment (apple.com blocked by network policy), so billing verification returns
`503 billing_not_configured` until it is installed. It is a public certificate, safe to commit.
