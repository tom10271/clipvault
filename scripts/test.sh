#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
frameworks="$(xcode-select -p)/Library/Developer/Frameworks"
if [ -d "$frameworks/Testing.framework" ]; then
    swift test --disable-xctest -Xswiftc -F -Xswiftc "$frameworks" -Xlinker -F -Xlinker "$frameworks" -Xlinker -rpath -Xlinker "$frameworks" -Xlinker -rpath -Xlinker "$frameworks/../usr/lib"
else
    swift test
fi
