#include "app_catalog.h"
#include "session/agent_session.h"
#include "util/base64.h"

#include <iostream>
#include <sstream>
#include <sys/stat.h>

namespace rplayhub {

const char* AppCatalog::toolsJarRemote() {
    return "/data/local/tmp/.rplayhub/screen-sharing-agent.jar";
}

bool AppCatalog::ensureToolsJar(AdbClient& adb, const std::string& serial) {
    std::string dir = AgentSession::findAgentDirectory();
    if (dir.empty()) return false;
    std::string local = dir + "/screen-sharing-agent.jar";
    struct stat st{};
    if (stat(local.c_str(), &st) != 0) return false;

    std::string remote = toolsJarRemote();
    std::string size = adb.shell(serial, "stat -c %s " + remote + " 2>/dev/null");
    while (!size.empty() && (size.back() == '\n' || size.back() == '\r')) size.pop_back();
    if (size == std::to_string(static_cast<long long>(st.st_size))) return true;

    adb.shell(serial, "mkdir -p " + remote.substr(0, remote.rfind('/')));
    if (!adb.pushFile(serial, local, remote, 0644)) {
        std::cerr << "AppCatalog: could not push " << remote << "\n";
        return false;
    }
    return true;
}

std::vector<AppEntry> AppCatalog::fetch(AdbClient& adb, const std::string& serial,
                                        const std::vector<std::string>& packages) {
    std::vector<AppEntry> entries;
    entries.reserve(packages.size());
    for (const auto& id : packages) entries.push_back({id, "", {}});
    if (packages.empty() || !ensureToolsJar(adb, serial)) return entries;

    // Batches keep one command line and its output bounded on devices with hundreds of apps.
    const size_t kBatch = 64;
    for (size_t start = 0; start < packages.size(); start += kBatch) {
        size_t end = std::min(packages.size(), start + kBatch);
        std::ostringstream cmd;
        cmd << "CLASSPATH=" << toolsJarRemote()
            << " app_process / com.android.tools.screensharing.AppLabel";
        for (size_t i = start; i < end; ++i) cmd << " " << packages[i];
        cmd << " 2>/dev/null";

        std::string out = adb.shell(serial, cmd.str());
        // One line per package, in order: "label<TAB>base64png". A label can be blank and the
        // base64 field can be empty; only the trailing newline is dropped, so counts must match.
        std::vector<std::string> lines;
        {
            std::istringstream stream(out);
            std::string line;
            while (std::getline(stream, line)) {
                if (!line.empty() && line.back() == '\r') line.pop_back();
                lines.push_back(line);
            }
        }
        if (lines.size() != end - start) {
            std::cerr << "AppCatalog: expected " << (end - start) << " lines, got " << lines.size() << "\n";
            continue;
        }
        for (size_t i = start; i < end; ++i) {
            const std::string& line = lines[i - start];
            size_t tab = line.find('\t');
            std::string label = tab == std::string::npos ? line : line.substr(0, tab);
            std::string b64 = tab == std::string::npos ? "" : line.substr(tab + 1);
            AppEntry& e = entries[i];
            if (label != e.id) e.label = label;   // the entry echoes the id when there is no label
            if (!b64.empty()) {
                std::vector<uint8_t> png;
                if (base64Decode(b64, png)) e.icon = decodePngToRgba(png.data(), png.size());
            }
        }
    }
    return entries;
}

} // namespace rplayhub
