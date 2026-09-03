#pragma once

#include "imgui.h"
#include <string>
#include <functional>
#include <cmath>
#include <algorithm>

namespace rplayhub {

namespace Icons {

// Helper: proportional stroke thickness
inline float getStroke(float size, float base_ratio = 0.09f) {
    return std::max(1.5f, size * base_ratio);
}

// Phone Silhouette
inline void drawPhone(ImDrawList* dl, ImVec2 pos, float size, ImU32 col) {
    float stroke = getStroke(size);
    float w = size * 0.58f;
    float h = size;
    float x = pos.x + (size - w) * 0.5f;
    float y = pos.y;
    dl->AddRect(ImVec2(x, y), ImVec2(x + w, y + h), col, 3.0f, 0, stroke);
    // Speaker notch
    dl->AddLine(ImVec2(x + w * 0.35f, y + 3.0f), ImVec2(x + w * 0.65f, y + 3.0f), col, stroke * 0.8f);
    // Home indicator
    dl->AddLine(ImVec2(x + w * 0.3f, y + h - 3.5f), ImVec2(x + w * 0.7f, y + h - 3.5f), col, stroke * 0.8f);
}

// Plus Icon
inline void drawPlus(ImDrawList* dl, ImVec2 pos, float size, ImU32 col) {
    float stroke = getStroke(size, 0.11f);
    float cx = pos.x + size * 0.5f;
    float cy = pos.y + size * 0.5f;
    float r = size * 0.35f;
    dl->AddLine(ImVec2(cx - r, cy), ImVec2(cx + r, cy), col, stroke);
    dl->AddLine(ImVec2(cx, cy - r), ImVec2(cx, cy + r), col, stroke);
}

// Refresh / Reload Icon
inline void drawRefresh(ImDrawList* dl, ImVec2 pos, float size, ImU32 col) {
    float stroke = getStroke(size);
    float cx = pos.x + size * 0.5f;
    float cy = pos.y + size * 0.5f;
    float r = size * 0.36f;
    // Circular arc
    dl->PathArcTo(ImVec2(cx, cy), r, 0.4f, 5.4f, 20);
    dl->PathStroke(col, 0, stroke);
    // Arrow head
    float ax = cx + r * std::cos(0.4f);
    float ay = cy + r * std::sin(0.4f);
    float arr = size * 0.22f;
    dl->AddTriangleFilled(ImVec2(ax - arr * 0.4f, ay - arr), ImVec2(ax + arr, ay), ImVec2(ax - arr * 0.4f, ay + arr * 0.8f), col);
}

// Search Magnifying Glass
inline void drawSearch(ImDrawList* dl, ImVec2 pos, float size, ImU32 col) {
    float stroke = getStroke(size, 0.10f);
    float cx = pos.x + size * 0.40f;
    float cy = pos.y + size * 0.40f;
    float r = size * 0.28f;
    dl->AddCircle(ImVec2(cx, cy), r, col, 20, stroke);
    // Handle
    float hx1 = cx + r * 0.707f;
    float hy1 = cy + r * 0.707f;
    float hx2 = pos.x + size * 0.90f;
    float hy2 = pos.y + size * 0.90f;
    dl->AddLine(ImVec2(hx1, hy1), ImVec2(hx2, hy2), col, stroke * 1.3f);
}

// Screen / Monitor
inline void drawScreen(ImDrawList* dl, ImVec2 pos, float size, ImU32 col) {
    float stroke = getStroke(size);
    float w = size * 0.9f;
    float h = size * 0.65f;
    float x = pos.x + (size - w) * 0.5f;
    float y = pos.y + 1.0f;
    dl->AddRect(ImVec2(x, y), ImVec2(x + w, y + h), col, 2.5f, 0, stroke);
    // Stand
    float cx = pos.x + size * 0.5f;
    dl->AddLine(ImVec2(cx, y + h), ImVec2(cx, y + h + size * 0.22f), col, stroke);
    dl->AddLine(ImVec2(cx - size * 0.28f, y + h + size * 0.22f), ImVec2(cx + size * 0.28f, y + h + size * 0.22f), col, stroke);
}

// Clipboard / Copy
inline void drawCopy(ImDrawList* dl, ImVec2 pos, float size, ImU32 col) {
    float stroke = getStroke(size);
    float w = size * 0.6f;
    float h = size * 0.75f;
    float x = pos.x + size * 0.15f;
    float y = pos.y + size * 0.15f;
    dl->AddRect(ImVec2(x + 3.5f, y - 2.5f), ImVec2(x + w + 3.5f, y + h - 2.5f), col, 2.0f, 0, stroke * 0.8f);
    dl->AddRectFilled(ImVec2(x, y), ImVec2(x + w, y + h), IM_COL32(255, 255, 255, 245), 2.0f);
    dl->AddRect(ImVec2(x, y), ImVec2(x + w, y + h), col, 2.0f, 0, stroke);
}

// Disconnect / Eject
inline void drawDisconnect(ImDrawList* dl, ImVec2 pos, float size, ImU32 col) {
    float stroke = getStroke(size);
    float cx = pos.x + size * 0.5f;
    float cy = pos.y + size * 0.45f;
    float r = size * 0.35f;
    dl->AddTriangle(ImVec2(cx, cy - r * 0.8f), ImVec2(cx - r, cy + r * 0.6f), ImVec2(cx + r, cy + r * 0.6f), col, stroke);
    dl->AddLine(ImVec2(cx - r, cy + r + 3.0f), ImVec2(cx + r, cy + r + 3.0f), col, stroke * 1.2f);
}

// Camera / Screenshot
inline void drawCamera(ImDrawList* dl, ImVec2 pos, float size, ImU32 col) {
    float stroke = getStroke(size);
    float w = size * 0.88f;
    float h = size * 0.68f;
    float x = pos.x + (size - w) * 0.5f;
    float y = pos.y + size * 0.22f;
    dl->AddRect(ImVec2(x, y), ImVec2(x + w, y + h), col, 2.5f, 0, stroke);
    // Top flash/shutter bump
    dl->AddRectFilled(ImVec2(x + w * 0.25f, y - 3.0f), ImVec2(x + w * 0.55f, y), col, 1.5f);
    // Lens circle
    dl->AddCircle(ImVec2(x + w * 0.5f, y + h * 0.5f), h * 0.32f, col, 20, stroke);
}

// Record (circle with center dot)
inline void drawRecord(ImDrawList* dl, ImVec2 pos, float size, ImU32 col) {
    float stroke = getStroke(size, 0.095f);
    float cx = pos.x + size * 0.5f;
    float cy = pos.y + size * 0.5f;
    float r = size * 0.38f;
    dl->AddCircle(ImVec2(cx, cy), r, col, 24, stroke);
    dl->AddCircleFilled(ImVec2(cx, cy), r * 0.48f, col);
}

// Navigation: Back Arrow (<)
inline void drawBack(ImDrawList* dl, ImVec2 pos, float size, ImU32 col) {
    float stroke = getStroke(size, 0.10f);
    float cx = pos.x + size * 0.48f;
    float cy = pos.y + size * 0.5f;
    float r = size * 0.32f;
    dl->AddLine(ImVec2(cx + r * 0.45f, cy - r), ImVec2(cx - r * 0.45f, cy), col, stroke);
    dl->AddLine(ImVec2(cx - r * 0.45f, cy), ImVec2(cx + r * 0.45f, cy + r), col, stroke);
}

// Navigation: Home Circle (O)
inline void drawHome(ImDrawList* dl, ImVec2 pos, float size, ImU32 col) {
    float stroke = getStroke(size, 0.095f);
    float cx = pos.x + size * 0.5f;
    float cy = pos.y + size * 0.5f;
    float r = size * 0.35f;
    dl->AddCircle(ImVec2(cx, cy), r, col, 24, stroke);
}

// Navigation: Recents Square ([])
inline void drawRecents(ImDrawList* dl, ImVec2 pos, float size, ImU32 col) {
    float stroke = getStroke(size, 0.095f);
    float s = size * 0.65f;
    float x = pos.x + (size - s) * 0.5f;
    float y = pos.y + (size - s) * 0.5f;
    dl->AddRect(ImVec2(x, y), ImVec2(x + s, y + s), col, 4.0f, 0, stroke);
}

// Volume Down (Speaker with 1 sound wave)
inline void drawVolumeDown(ImDrawList* dl, ImVec2 pos, float size, ImU32 col) {
    float stroke = getStroke(size, 0.095f);
    float cx = pos.x + size * 0.35f;
    float cy = pos.y + size * 0.5f;
    float bw = size * 0.16f;
    dl->AddRectFilled(ImVec2(cx - bw, cy - bw * 0.7f), ImVec2(cx, cy + bw * 0.7f), col, 1.0f);
    dl->AddTriangleFilled(ImVec2(cx, cy - bw * 0.7f), ImVec2(cx, cy + bw * 0.7f), ImVec2(cx + bw * 1.4f, cy + bw * 1.6f), col);
    dl->AddTriangleFilled(ImVec2(cx, cy - bw * 0.7f), ImVec2(cx + bw * 1.4f, cy + bw * 1.6f), ImVec2(cx + bw * 1.4f, cy - bw * 1.6f), col);
    // 1 sound wave arc
    dl->PathArcTo(ImVec2(cx + bw * 1.1f, cy), size * 0.28f, -0.65f, 0.65f, 10);
    dl->PathStroke(col, 0, stroke);
}

// Volume Up (Speaker with 2 sound waves)
inline void drawVolumeUp(ImDrawList* dl, ImVec2 pos, float size, ImU32 col) {
    float stroke = getStroke(size, 0.095f);
    float cx = pos.x + size * 0.28f;
    float cy = pos.y + size * 0.5f;
    float bw = size * 0.16f;
    dl->AddRectFilled(ImVec2(cx - bw, cy - bw * 0.7f), ImVec2(cx, cy + bw * 0.7f), col, 1.0f);
    dl->AddTriangleFilled(ImVec2(cx, cy - bw * 0.7f), ImVec2(cx, cy + bw * 0.7f), ImVec2(cx + bw * 1.4f, cy + bw * 1.6f), col);
    dl->AddTriangleFilled(ImVec2(cx, cy - bw * 0.7f), ImVec2(cx + bw * 1.4f, cy + bw * 1.6f), ImVec2(cx + bw * 1.4f, cy - bw * 1.6f), col);
    // 2 sound wave arcs
    dl->PathArcTo(ImVec2(cx + bw * 1.1f, cy), size * 0.28f, -0.65f, 0.65f, 10);
    dl->PathStroke(col, 0, stroke);
    dl->PathArcTo(ImVec2(cx + bw * 1.1f, cy), size * 0.44f, -0.68f, 0.68f, 10);
    dl->PathStroke(col, 0, stroke);
}

// Power Button
inline void drawPower(ImDrawList* dl, ImVec2 pos, float size, ImU32 col) {
    float stroke = getStroke(size, 0.095f);
    float cx = pos.x + size * 0.5f;
    float cy = pos.y + size * 0.52f;
    float r = size * 0.34f;
    dl->PathArcTo(ImVec2(cx, cy), r, -0.95f, 4.09f, 24);
    dl->PathStroke(col, 0, stroke);
    dl->AddLine(ImVec2(cx, cy - r - size * 0.08f), ImVec2(cx, cy - size * 0.04f), col, stroke);
}

// Rotate Screen (Phone with curved arrow at top-left)
inline void drawRotate(ImDrawList* dl, ImVec2 pos, float size, ImU32 col) {
    float stroke = getStroke(size, 0.095f);
    float w = size * 0.54f;
    float h = size * 0.68f;
    float x = pos.x + size * 0.36f;
    float y = pos.y + size * 0.22f;
    dl->AddRect(ImVec2(x, y), ImVec2(x + w, y + h), col, 3.0f, 0, stroke);
    // Curved arrow from top-left curving out and up
    dl->PathArcTo(ImVec2(x, y + size * 0.06f), size * 0.20f, 3.14159f, 4.71238f, 10);
    dl->PathStroke(col, 0, stroke);
    // Arrow head pointing up-right
    float hx = x;
    float hy = y - size * 0.14f;
    float as = size * 0.10f;
    dl->AddLine(ImVec2(hx - as, hy), ImVec2(hx, hy), col, stroke);
    dl->AddLine(ImVec2(hx, hy + as), ImVec2(hx, hy), col, stroke);
}

// Screen Sharing / View Screen Icon (Apple SF Symbol: rectangle.inset.filled.and.person.filled)
inline void drawViewScreen(ImDrawList* dl, ImVec2 pos, float size, ImU32 col, ImU32 bg_col) {
    float stroke = getStroke(size, 0.10f);
    float w = size * 1.12f;
    float h = size * 0.76f;
    float x = pos.x;
    float y = pos.y + (size - h) * 0.5f;
    float r = size * 0.14f;

    // Inset filled screen background
    ImVec4 col_v = ImGui::ColorConvertU32ToFloat4(col);
    ImU32 inset_fill = ImGui::ColorConvertFloat4ToU32(ImVec4(col_v.x, col_v.y, col_v.z, col_v.w * 0.20f));
    dl->AddRectFilled(ImVec2(x + stroke * 0.5f, y + stroke * 0.5f),
                      ImVec2(x + w - stroke * 0.5f, y + h - stroke * 0.5f),
                      inset_fill, r);
    // Outer rounded screen outline
    dl->AddRect(ImVec2(x, y), ImVec2(x + w, y + h), col, r, 0, stroke);

    // Person in bottom right
    float person_cx = x + w * 0.76f;
    float person_cy = y + h * 0.90f;
    float head_r = size * 0.16f;

    // Mask cutout around person (clears screen border behind person)
    float mask_gap = stroke * 0.8f;
    dl->AddCircleFilled(ImVec2(person_cx, person_cy - head_r * 2.1f), head_r + mask_gap, bg_col);
    dl->PathArcTo(ImVec2(person_cx, person_cy - head_r * 0.2f), head_r * 1.85f + mask_gap, -3.14159f, 0.0f, 16);
    dl->PathFillConvex(bg_col);

    // Head
    dl->AddCircleFilled(ImVec2(person_cx, person_cy - head_r * 2.1f), head_r, col);
    // Shoulders
    dl->PathArcTo(ImVec2(person_cx, person_cy - head_r * 0.2f), head_r * 1.85f, -3.14159f, 0.0f, 16);
    dl->PathFillConvex(col);
}

// Sidebar Toggle [|]
inline void drawSidebarToggle(ImDrawList* dl, ImVec2 pos, float size, ImU32 col) {
    float stroke = getStroke(size);
    float w = size * 0.88f;
    float h = size * 0.70f;
    float x = pos.x + (size - w) * 0.5f;
    float y = pos.y + (size - h) * 0.5f;
    dl->AddRect(ImVec2(x, y), ImVec2(x + w, y + h), col, 2.5f, 0, stroke);
    dl->AddLine(ImVec2(x + w * 0.32f, y), ImVec2(x + w * 0.32f, y + h), col, stroke);
}

// List / Filter Menu (≡)
inline void drawListMenu(ImDrawList* dl, ImVec2 pos, float size, ImU32 col) {
    float stroke = getStroke(size, 0.11f);
    float w = size * 0.70f;
    float x = pos.x + (size - w) * 0.5f;
    float cy = pos.y + size * 0.5f;
    float dy = size * 0.24f;
    dl->AddLine(ImVec2(x, cy - dy), ImVec2(x + w, cy - dy), col, stroke);
    dl->AddLine(ImVec2(x, cy), ImVec2(x + w, cy), col, stroke);
    dl->AddLine(ImVec2(x, cy + dy), ImVec2(x + w, cy + dy), col, stroke);
}

// Wake / Sun
inline void drawSun(ImDrawList* dl, ImVec2 pos, float size, ImU32 col) {
    float stroke = getStroke(size);
    float cx = pos.x + size * 0.5f;
    float cy = pos.y + size * 0.5f;
    float r = size * 0.24f;
    dl->AddCircle(ImVec2(cx, cy), r, col, 20, stroke);
    float d1 = r + 2.5f, d2 = r + size * 0.22f;
    dl->AddLine(ImVec2(cx, cy - d1), ImVec2(cx, cy - d2), col, stroke);
    dl->AddLine(ImVec2(cx, cy + d1), ImVec2(cx, cy + d2), col, stroke);
    dl->AddLine(ImVec2(cx - d1, cy), ImVec2(cx - d2, cy), col, stroke);
    dl->AddLine(ImVec2(cx + d1, cy), ImVec2(cx + d2, cy), col, stroke);
}

// Pin
inline void drawPin(ImDrawList* dl, ImVec2 pos, float size, ImU32 col) {
    float stroke = getStroke(size);
    float cx = pos.x + size * 0.5f;
    float cy = pos.y + size * 0.4f;
    dl->AddCircleFilled(ImVec2(cx, cy), size * 0.24f, col);
    dl->AddLine(ImVec2(cx, cy), ImVec2(cx, pos.y + size * 0.88f), col, stroke * 1.2f);
}

// 3D Cube
inline void drawCube(ImDrawList* dl, ImVec2 pos, float size, ImU32 col) {
    float stroke = getStroke(size);
    float cx = pos.x + size * 0.5f;
    float cy = pos.y + size * 0.5f;
    float r = size * 0.36f;
    ImVec2 top(cx, cy - r);
    ImVec2 tr(cx + r * 0.866f, cy - r * 0.5f);
    ImVec2 br(cx + r * 0.866f, cy + r * 0.5f);
    ImVec2 btm(cx, cy + r);
    ImVec2 bl(cx - r * 0.866f, cy + r * 0.5f);
    ImVec2 tl(cx - r * 0.866f, cy - r * 0.5f);
    ImVec2 center(cx, cy);

    dl->AddLine(top, tr, col, stroke);
    dl->AddLine(tr, br, col, stroke);
    dl->AddLine(br, btm, col, stroke);
    dl->AddLine(btm, bl, col, stroke);
    dl->AddLine(bl, tl, col, stroke);
    dl->AddLine(tl, top, col, stroke);
    dl->AddLine(center, top, col, stroke);
    dl->AddLine(center, br, col, stroke);
    dl->AddLine(center, bl, col, stroke);
}

// Window / External Link
inline void drawWindow(ImDrawList* dl, ImVec2 pos, float size, ImU32 col) {
    float stroke = getStroke(size);
    float w = size * 0.72f;
    float h = size * 0.68f;
    float x = pos.x + size * 0.14f;
    float y = pos.y + size * 0.16f;
    dl->AddRect(ImVec2(x, y), ImVec2(x + w, y + h), col, 2.5f, 0, stroke);
    dl->AddLine(ImVec2(x, y + 5.0f), ImVec2(x + w, y + 5.0f), col, stroke * 0.8f);
}

// Settings Sliders
inline void drawSettings(ImDrawList* dl, ImVec2 pos, float size, ImU32 col) {
    float stroke = getStroke(size);
    float x1 = pos.x + size * 0.12f;
    float x2 = pos.x + size * 0.88f;
    float y1 = pos.y + size * 0.32f;
    float y2 = pos.y + size * 0.68f;
    float knob_r = size * 0.15f;
    dl->AddLine(ImVec2(x1, y1), ImVec2(x2, y1), col, stroke);
    dl->AddCircleFilled(ImVec2(x1 + (x2 - x1) * 0.35f, y1), knob_r, col);
    dl->AddLine(ImVec2(x1, y2), ImVec2(x2, y2), col, stroke);
    dl->AddCircleFilled(ImVec2(x1 + (x2 - x1) * 0.70f, y2), knob_r, col);
}

// Logcat / Document Terminal
inline void drawLogcat(ImDrawList* dl, ImVec2 pos, float size, ImU32 col) {
    float stroke = getStroke(size);
    float w = size * 0.68f;
    float h = size * 0.82f;
    float x = pos.x + (size - w) * 0.5f;
    float y = pos.y + size * 0.09f;
    dl->AddRect(ImVec2(x, y), ImVec2(x + w, y + h), col, 2.5f, 0, stroke);
    // Lines
    dl->AddLine(ImVec2(x + 4.0f, y + h * 0.28f), ImVec2(x + w - 4.0f, y + h * 0.28f), col, stroke * 0.8f);
    dl->AddLine(ImVec2(x + 4.0f, y + h * 0.52f), ImVec2(x + w - 6.0f, y + h * 0.52f), col, stroke * 0.8f);
    dl->AddLine(ImVec2(x + 4.0f, y + h * 0.76f), ImVec2(x + w - 8.0f, y + h * 0.76f), col, stroke * 0.8f);
}

// Info Circle (i)
inline void drawInfo(ImDrawList* dl, ImVec2 pos, float size, ImU32 col) {
    float stroke = getStroke(size);
    float cx = pos.x + size * 0.5f;
    float cy = pos.y + size * 0.5f;
    float r = size * 0.42f;
    dl->AddCircle(ImVec2(cx, cy), r, col, 24, stroke);
    dl->AddCircleFilled(ImVec2(cx, cy - r * 0.42f), stroke * 0.9f, col);
    dl->AddLine(ImVec2(cx, cy - r * 0.1f), ImVec2(cx, cy + r * 0.48f), col, stroke * 1.1f);
}

// Folder Icon
inline void drawFolder(ImDrawList* dl, ImVec2 pos, float size, ImU32 col) {
    float w = size * 0.88f;
    float h = size * 0.68f;
    float x = pos.x + (size - w) * 0.5f;
    float y = pos.y + size * 0.2f;
    dl->AddRectFilled(ImVec2(x, y - 3.5f), ImVec2(x + w * 0.45f, y), col, 1.5f);
    dl->AddRectFilled(ImVec2(x, y), ImVec2(x + w, y + h), col, 2.5f);
}

// File Document
inline void drawFile(ImDrawList* dl, ImVec2 pos, float size, ImU32 col) {
    float stroke = getStroke(size);
    float w = size * 0.66f;
    float h = size * 0.84f;
    float x = pos.x + (size - w) * 0.5f;
    float y = pos.y + size * 0.08f;
    dl->AddRect(ImVec2(x, y), ImVec2(x + w, y + h), col, 2.0f, 0, stroke);
    dl->AddLine(ImVec2(x + w - 5.0f, y), ImVec2(x + w, y + 5.0f), col, stroke);
}

// Colorful App Icon Badge
inline void drawAppBadge(ImDrawList* dl, ImVec2 pos, float size, const std::string& app_name, const std::string& pkg_name, ImFont* font = nullptr) {
    uint32_t hash = 5381;
    for (char c : pkg_name) hash = ((hash << 5) + hash) + static_cast<uint8_t>(c);

    static const ImU32 palette[] = {
        IM_COL32(0, 122, 255, 255),   // Blue
        IM_COL32(52, 199, 89, 255),   // Green
        IM_COL32(255, 149, 0, 255),   // Orange
        IM_COL32(175, 82, 222, 255),  // Purple
        IM_COL32(88, 86, 214, 255),   // Indigo
        IM_COL32(255, 45, 85, 255),   // Pink
        IM_COL32(50, 173, 230, 255),  // Cyan
        IM_COL32(255, 59, 48, 255)    // Red
    };

    ImU32 bg_col = palette[hash % (sizeof(palette) / sizeof(palette[0]))];

    if (pkg_name.find("fitbit") != std::string::npos || pkg_name.find("health") != std::string::npos) {
        bg_col = IM_COL32(0, 168, 168, 255);
    } else if (pkg_name.find("youtube") != std::string::npos) {
        bg_col = IM_COL32(255, 0, 0, 255);
    } else if (pkg_name.find("chrome") != std::string::npos) {
        bg_col = IM_COL32(66, 133, 244, 255);
    } else if (pkg_name.find("netflix") != std::string::npos) {
        bg_col = IM_COL32(229, 9, 20, 255);
    }

    dl->AddRectFilled(pos, ImVec2(pos.x + size, pos.y + size), bg_col, size * 0.28f);

    char initial = 'A';
    if (!app_name.empty()) {
        initial = std::toupper(app_name[0]);
    } else if (!pkg_name.empty()) {
        initial = std::toupper(pkg_name[0]);
    }

    char letter_str[2] = { initial, '\0' };
    float font_size = size * 0.58f;
    ImVec2 text_sz = font ? font->CalcTextSizeA(font_size, FLT_MAX, 0.0f, letter_str)
                          : ImGui::CalcTextSize(letter_str);
    float tx = pos.x + (size - text_sz.x) * 0.5f;
    float ty = pos.y + (size - text_sz.y) * 0.5f;
    if (font) {
        dl->AddText(font, font_size, ImVec2(tx, ty), IM_COL32(255, 255, 255, 255), letter_str);
    } else {
        dl->AddText(ImVec2(tx, ty), IM_COL32(255, 255, 255, 255), letter_str);
    }
}

} // namespace Icons

// Helper to render MenuItem with an icon on the left
inline bool MenuItemWithIcon(const char* label, const char* shortcut,
                             std::function<void(ImDrawList*, ImVec2, float, ImU32)> draw_icon,
                             float scale = 1.0f, bool selected = false, bool enabled = true) {
    ImVec2 p = ImGui::GetCursorScreenPos();
    float line_h = ImGui::GetTextLineHeightWithSpacing();
    float icon_size = 18.0f * scale;

    std::string indent_label = "       " + std::string(label);
    bool clicked = ImGui::MenuItem(indent_label.c_str(), shortcut, selected, enabled);

    ImDrawList* dl = ImGui::GetWindowDrawList();
    ImU32 col = enabled ? IM_COL32(70, 70, 75, 255) : IM_COL32(160, 160, 165, 255);
    if (draw_icon) {
        draw_icon(dl, ImVec2(p.x + 8.0f * scale, p.y + (line_h - icon_size) * 0.5f - 1.0f), icon_size, col);
    }
    return clicked;
}

// Helper to render IconButton (button that draws a vector icon in its center)
inline bool IconButton(const char* str_id,
                       std::function<void(ImDrawList*, ImVec2, float, ImU32)> draw_icon,
                       ImVec2 size, const char* tooltip = nullptr, bool active = false) {
    ImVec2 p = ImGui::GetCursorScreenPos();
    if (active) {
        ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.85f, 0.90f, 0.98f, 1.0f));
    }
    bool clicked = ImGui::Button(str_id, size);
    if (active) {
        ImGui::PopStyleColor();
    }

    bool hovered = ImGui::IsItemHovered();
    if (hovered && tooltip) {
        ImGui::SetTooltip("%s", tooltip);
    }

    ImDrawList* dl = ImGui::GetWindowDrawList();
    float icon_size = std::min(size.x, size.y) * 0.62f;
    ImVec2 icon_pos(p.x + (size.x - icon_size) * 0.5f, p.y + (size.y - icon_size) * 0.5f);
    ImU32 col = active ? IM_COL32(0, 122, 255, 255) : (hovered ? IM_COL32(30, 30, 35, 255) : IM_COL32(80, 80, 85, 255));

    if (draw_icon) {
        draw_icon(dl, icon_pos, icon_size, col);
    }
    return clicked;
}

// Helper to render flat, transparent navigation icon button matching macOS bottom bar
inline bool FlatNavButton(const char* str_id,
                          std::function<void(ImDrawList*, ImVec2, float, ImU32)> draw_icon,
                          ImVec2 size, const char* tooltip = nullptr, float scale = 1.0f) {
    ImVec2 p = ImGui::GetCursorScreenPos();
    ImDrawList* dl = ImGui::GetWindowDrawList();

    bool clicked = ImGui::InvisibleButton(str_id, size);
    bool hovered = ImGui::IsItemHovered();
    bool active = ImGui::IsItemActive();

    // Subtle soft gray pill hover background (transparent by default!)
    if (active) {
        dl->AddRectFilled(p, ImVec2(p.x + size.x, p.y + size.y), IM_COL32(220, 220, 225, 255), 7.0f * scale);
    } else if (hovered) {
        dl->AddRectFilled(p, ImVec2(p.x + size.x, p.y + size.y), IM_COL32(236, 236, 240, 230), 7.0f * scale);
    }

    // Default icon color is macOS secondary gray (#8E8E93); hovered is darker (#1C1C1E)
    ImU32 col = active ? IM_COL32(0, 122, 255, 255) :
                (hovered ? IM_COL32(28, 28, 30, 255) : IM_COL32(142, 142, 147, 255));

    float icon_size = std::min(size.x, size.y) * 0.65f;
    ImVec2 icon_pos(p.x + (size.x - icon_size) * 0.5f, p.y + (size.y - icon_size) * 0.5f);
    if (draw_icon) {
        draw_icon(dl, icon_pos, icon_size, col);
    }

    if (hovered && tooltip) {
        ImGui::SetTooltip("%s", tooltip);
    }
    return clicked;
}

} // namespace rplayhub
