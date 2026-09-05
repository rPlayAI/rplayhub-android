#pragma once

// Launcher labels and icons for the Apps tab, read on the device by the agent
// jar's AppLabel entry (rPlayHub's addition to the Studio agent): one
// app_process round trip prints "label<TAB>base64 PNG" per package, resolved
// through PackageManager, so obfuscated and adaptive icons come out right.

#include "adb/adb_client.h"
#include "util/png_decode.h"
#include <string>
#include <vector>

namespace rplayhub {

struct AppEntry {
    std::string id;       // package name
    std::string label;    // launcher label; empty when the device has none
    RgbaImage icon;       // 96x96 when available
};

class AppCatalog {
public:
    // Where a persistent copy of the agent jar lives for tools like AppLabel.
    // The mirroring agent deletes its own copy under /data/local/tmp/.studio
    // once it is running, so it cannot be reused.
    static const char* toolsJarRemote();

    // Push the jar there if it is missing or a different size. Cheap when warm.
    static bool ensureToolsJar(AdbClient& adb, const std::string& serial);

    // Labels and icons for `packages`, in the same order. Entries whose label
    // could not be read carry an empty label and no icon.
    static std::vector<AppEntry> fetch(AdbClient& adb, const std::string& serial,
                                       const std::vector<std::string>& packages);
};

} // namespace rplayhub
