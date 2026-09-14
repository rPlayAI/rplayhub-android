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
    const float bezel_px = 10.0f * scale;   // matches the flat mirror's bezel

    // No separate "closed" layout: jumping into one popped the picture to a different size at
    // the end of the fold. The cross-fade below brings the outer panel up to full opacity on the
    // flat half as the phone shuts, so the same model carries all the way closed.
    if (!inner_tex || inner_w <= 0 || inner_h <= 0) return;

    // The open phone in scene units: width 1 (half a = 0.5 each side of the crease), height
    // by aspect. The flat phone fills the stage like the flat picture does.
    const float aspect = static_cast<float>(inner_w) / inner_h;
    const float margin = bezel_px + 3.0f * scale;   // matches the flat mirror's air
    float fit_h = size.y - 2.0f * margin, fit_w = fit_h * aspect;
    if (fit_w > size.x - 2.0f * margin) { fit_w = size.x - 2.0f * margin; fit_h = fit_w / aspect; }
    const float cam_z = 3.0f;
    const float focal = fit_w * cam_z;          // 1 scene unit = fit_w pixels at the origin plane
    const float a = 0.5f, H = 0.5f / aspect;    // half width, half height
    const float b = bezel_px / fit_w;            // bezel in scene units
    // Only the left half swings; the right half stays flat and square to the viewer, the way a
    // book lies with one cover on the table. Folding both halves symmetrically looks tidy on
    // paper but collapses to an edge-on line at the end, which is no picture at all; this way
    // there is a full panel to read at every angle and the closed phone is a flat panel.
    const float phi = (180.0f - shown_) * 3.14159265f / 180.0f;   // 0 flat, pi fully closed
    const float c = std::cos(phi), s = std::sin(phi);
    // Swinging one half alone would walk the picture to the right, so slide the model back by
    // half of what the left panel gives up.
    const float shift = -a * (1.0f - std::max(c, 0.0f)) * 0.5f;

    // A point on the flat phone (x in [-a, a], y), the left half turned about the crease x = 0.
    auto fold = [&](float x, float y) -> P3 {
        if (x >= 0.0f) return P3{ x + shift, y, 0.0f };
        const float d = -x;                       // distance from the crease
        return P3{ -d * c + shift, y, d * s };
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
    // The picture, in vertical strips so the perspective reads right within each half.
    // Once the stream has moved to the outer panel the inner frame we kept is already blanked —
    // Android turns the inner screen off on the way shut — so the flat half shows the live outer
    // picture instead. One inner half and the outer panel are within a couple of percent of the
    // same aspect, so it lands on the half without visible distortion.
    const bool have_outer_frame = (outer_tex != 0 && outer_w > 0 && outer_h > 0);
    // Nothing here switches on a threshold: a panel at a glancing angle thins out the way real
    // glass does, and the outer picture arrives as a cross-fade. Both ride the fold angle, so
    // the whole handover is continuous with the hinge.
    auto smoothstep = [](float e0, float e1, float x) {
        const float t = std::clamp((x - e0) / (e1 - e0), 0.0f, 1.0f);
        return t * t * (3.0f - 2.0f * t);
    };
    // The inner screen is on the inside of the swinging half, so it fades away as that half
    // turns edge-on and is gone by the time we are looking at its back.
    const float swing_alpha = smoothstep(-0.08f, 0.34f, c);
    // From about half fold to nearly shut (hinge 90 down to 40 degrees) the outer screen comes
    // up, and it is always showing something: the live outer stream once the device hands it
    // over, otherwise the last outer frame we kept, and failing both - the first fold of a
    // session - the middle of the inner screen, which is roughly what the cover display shows
    // anyway. Waiting for the real stream leaves the screen dark for most of the move.
    const float outer_alpha = smoothstep(1.50f, 2.50f, phi);

    const int strips = 14;
    // pass 0 draws each half's own picture, pass 1 lays the outer picture over the flat half.
    for (int pass = 0; pass < 2; ++pass) {
        for (int half = 0; half < 2; ++half) {
            const bool use_outer = (pass == 1);
            if (use_outer && (half == 0 || outer_alpha <= 0.004f)) continue;
            float alpha = (half == 0) ? swing_alpha : 1.0f;
            if (use_outer) alpha = outer_alpha;
            if (alpha <= 0.004f) continue;
            const ImU32 tint = IM_COL32(255, 255, 255, static_cast<int>(255.0f * alpha));
            for (int i = 0; i < strips; ++i) {
                const float u0 = (half * strips + i) / static_cast<float>(2 * strips);
                const float u1 = (half * strips + i + 1) / static_cast<float>(2 * strips);
                const float x0 = -a + u0 * 2.0f * a, x1 = -a + u1 * 2.0f * a;
                auto q = quad(x0, x1, -H, H);
                // The outer picture spans this half on its own, so rescale u into [0, 1] across
                // it. Standing in for it with the inner picture instead, take the middle half:
                // the cover display is about half as wide as the inner one and shows the same
                // screen, so the content reads as carrying over rather than jumping.
                float t0 = u0, t1 = u1;
                if (use_outer) {
                    t0 = (u0 - 0.5f) * 2.0f;
                    t1 = (u1 - 0.5f) * 2.0f;
                    if (!have_outer_frame) { t0 = 0.25f + t0 * 0.5f; t1 = 0.25f + t1 * 0.5f; }
                }
                const float tu0 = uv0.x + (uv1.x - uv0.x) * t0, tu1 = uv0.x + (uv1.x - uv0.x) * t1;
                dl->AddImageQuad(use_outer && have_outer_frame ? outer_tex : inner_tex, q[0], q[1], q[2], q[3],
                                 ImVec2(tu0, uv0.y), ImVec2(tu1, uv0.y), ImVec2(tu1, uv1.y), ImVec2(tu0, uv1.y), tint);
            }
        }
    }
    // The crease: a soft dark line that deepens as the phone closes
    {
        auto q = quad(-0.004f, 0.004f, -H, H);
        const int alpha = static_cast<int>(40 + 120 * std::min(1.0f, phi / 2.4f));
        dl->AddQuadFilled(q[0], q[1], q[2], q[3], IM_COL32(0, 0, 0, alpha));
    }
}

} // namespace rplayhub
