#!/bin/sh
# Point the Flutter web entry files at a content-hashed URL so a browser that
# cached an older main.dart.js or icon font fetches this build.
set -eu
dist=${1:?usage: stamp-web.sh DIST_DIR}
build_id=$(sha256sum "$dist/main.dart.js" | cut -c1-12)
sed -i "s|flutter_bootstrap\\.js|flutter_bootstrap.js?v=$build_id|" "$dist/index.html"
sed -i "s|main\\.dart\\.js|main.dart.js?v=$build_id|g" "$dist/flutter_bootstrap.js"
sed -i "s|MaterialIcons-Regular\\.otf|MaterialIcons-Regular.otf?v=$build_id|" "$dist/assets/FontManifest.json"
echo "stamped web bundle $build_id"
