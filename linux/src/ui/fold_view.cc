#include "fold_view.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdlib>

namespace rplayhub {

void FoldView::setHinge(float degrees, bool have) {
    have_hinge_ = have;
    if (have) target_ = std::clamp(degrees, 0.0f, 180.0f);
}

void FoldView::setState(const std::string& name) {
    state_ = name;
    // Without a hinge sensor the state alone drives the fold, with a timed ease below.
    if (!have_hinge_) target_ = name == "CLOSED" ? 0.0f : name == "HALF_OPENED" ? 100.0f : 180.0f;
}

void FoldView::tick(float dt) {
    if (const char* fake = std::getenv("RPLAYHUB_FAKE_HINGE")) {
        // "1" sweeps closed <-> open; any other number holds that angle (for screenshots)
        fake_t_ += dt;
        const float fixed = static_cast<float>(std::atof(fake));
        target_ = fixed > 1.0f ? std::clamp(fixed, 0.0f, 180.0f) : 90.0f + 90.0f * std::cos(fake_t_ * 0.7f);
        have_hinge_ = true;
        state_ = target_ < 8.0f ? "CLOSED" : "OPENED";
    }
    // The sensor reports in 5 degree steps every ~20 ms: ease toward it so the motion reads
    // as one sweep. Without a sensor the same ease is the whole animation (~0.4 s).
    const float rate = have_hinge_ ? 30.0f : 9.0f;
    shown_ += (target_ - shown_) * std::min(1.0f, dt * rate);
    if (std::fabs(target_ - shown_) < 0.05f) shown_ = target_;
}

namespace {

struct P3 { float x, y, z; };

// Camera on +z at distance cam_z looking at the origin, x right, y up.
ImVec2 project(const P3& p, ImVec2 centre, float focal, float cam_z) {
    float depth = cam_z - p.z;
    if (depth < 0.05f) depth = 0.05f;
    return ImVec2(centre.x + p.x * focal / depth, centre.y - p.y * focal / depth);
}

} // namespace

void FoldView::render(ImDrawList* dl, ImVec2 origin, ImVec2 size, ImTextureID inner_tex, int inner_w, int inner_h,
                      ImTextureID outer_tex, int outer_w, int outer_h, float scale, ImVec2 uv0, ImVec2 uv1) {
    const ImVec2 centre(origin.x + size.x * 0.5f, origin.y + size.y * 0.5f);
    const float bezel_px = 12.0f * scale;

    // Closed: the outer panel, flat, in its own narrow chassis.
    if (closed() && outer_tex && outer_w > 0 && outer_h > 0) {
        const float aspect = static_cast<float>(outer_w) / outer_h;
        float h = size.y - 2.0f * (bezel_px + 8.0f * scale), w = h * aspect;
        if (w > size.x - 2.0f * (bezel_px + 8.0f * scale)) { w = size.x - 2.0f * (bezel_px + 8.0f * scale); h = w / aspect; }
        const ImVec2 tl(centre.x - w * 0.5f, centre.y - h * 0.5f), br(centre.x + w * 0.5f, centre.y + h * 0.5f);
        dl->AddRectFilled(ImVec2(tl.x - bezel_px, tl.y - bezel_px), ImVec2(br.x + bezel_px, br.y + bezel_px), IM_COL32(18, 18, 22, 255), 28.0f * scale);
        dl->AddImageRounded(outer_tex, tl, br, uv0, uv1, IM_COL32_WHITE, 20.0f * scale);
        return;
    }
    if (!inner_tex || inner_w <= 0 || inner_h <= 0) return;

    // The open phone in scene units: width 1 (half a = 0.5 each side of the crease), height
    // by aspect. The flat phone fills the stage like the flat picture does.
    const float aspect = static_cast<float>(inner_w) / inner_h;
    const float margin = bezel_px + 8.0f * scale;
    float fit_h = size.y - 2.0f * margin, fit_w = fit_h * aspect;
    if (fit_w > size.x - 2.0f * margin) { fit_w = size.x - 2.0f * margin; fit_h = fit_w / aspect; }
    const float cam_z = 3.0f;
    const float focal = fit_w * cam_z;          // 1 scene unit = fit_w pixels at the origin plane
    const float a = 0.5f, H = 0.5f / aspect;    // half width, half height
    const float b = bezel_px / fit_w;            // bezel in scene units
    // Each half turns toward the viewer by half the fold: flat at 180, edge-on at 0.
    const float theta = (180.0f - shown_) * 0.5f * 3.14159265f / 180.0f;
    const float c = std::cos(theta), s = std::sin(theta);

    // A point on the flat phone (x in [-a, a], y) folded about the crease x = 0.
    auto fold = [&](float x, float y) -> P3 {
        const float ax = std::fabs(x);
        return P3{ (x < 0 ? -1.0f : 1.0f) * ax * c, y, ax * s };
    };
    auto quad = [&](float x0, float x1, float y0, float y1) {
        ImVec2 p[4] = { project(fold(x0, y1), centre, focal, cam_z), project(fold(x1, y1), centre, focal, cam_z),
                        project(fold(x1, y0), centre, focal, cam_z), project(fold(x0, y0), centre, focal, cam_z) };
        return std::array<ImVec2, 4>{ p[0], p[1], p[2], p[3] };
    };

    // Chassis behind each half (the bezel widens the half by b on its outer three sides)
    for (int half = 0; half < 2; ++half) {
        const float x0 = half == 0 ? -a - b : 0.0f, x1 = half == 0 ? 0.0f : a + b;
        auto q = quad(x0, x1, -H - b, H + b);
        dl->AddQuadFilled(q[0], q[1], q[2], q[3], IM_COL32(18, 18, 22, 255));
    }
    // The picture, in vertical strips so the perspective reads right within each half
    const int strips = 14;
    for (int half = 0; half < 2; ++half) {
        for (int i = 0; i < strips; ++i) {
            const float u0 = (half * strips + i) / static_cast<float>(2 * strips);
            const float u1 = (half * strips + i + 1) / static_cast<float>(2 * strips);
            const float x0 = -a + u0 * 2.0f * a, x1 = -a + u1 * 2.0f * a;
            auto q = quad(x0, x1, -H, H);
            const float tu0 = uv0.x + (uv1.x - uv0.x) * u0, tu1 = uv0.x + (uv1.x - uv0.x) * u1;
            dl->AddImageQuad(inner_tex, q[0], q[1], q[2], q[3], ImVec2(tu0, uv0.y), ImVec2(tu1, uv0.y), ImVec2(tu1, uv1.y), ImVec2(tu0, uv1.y), IM_COL32_WHITE);
        }
    }
    // The crease: a soft dark line that deepens as the phone closes
    {
        auto q = quad(-0.004f, 0.004f, -H, H);
        const int alpha = static_cast<int>(40 + 120 * std::min(1.0f, theta / 1.2f));
        dl->AddQuadFilled(q[0], q[1], q[2], q[3], IM_COL32(0, 0, 0, alpha));
    }
}

} // namespace rplayhub
