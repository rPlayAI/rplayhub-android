#include "twin_view.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <fstream>
#include <sys/stat.h>

namespace rplayhub {

TwinView::TwinView() {
    loadReference();
    if (have_reference_) recenter_requested_ = false;
}

// ---- quaternion helpers (x, y, z, w) ----
TwinView::Vec3 TwinView::rotate(const Quat& q, Vec3 v) {
    // v' = v + 2*cross(q.xyz, cross(q.xyz, v) + q.w*v)
    float tx = 2 * (q.y * v.z - q.z * v.y);
    float ty = 2 * (q.z * v.x - q.x * v.z);
    float tz = 2 * (q.x * v.y - q.y * v.x);
    return { v.x + q.w * tx + (q.y * tz - q.z * ty),
             v.y + q.w * ty + (q.z * tx - q.x * tz),
             v.z + q.w * tz + (q.x * ty - q.y * tx) };
}
Quat TwinView::mul(const Quat& a, const Quat& b) {
    return { a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
             a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
             a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
             a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z };
}
Quat TwinView::inverse(const Quat& q) { return { -q.x, -q.y, -q.z, q.w }; }
Quat TwinView::normalize(const Quat& q) {
    float l = std::sqrt(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w);
    if (l < 1e-6f) return {0, 0, 0, 1};
    return { q.x / l, q.y / l, q.z / l, q.w / l };
}
Quat TwinView::slerp(const Quat& a, const Quat& bin, float t) {
    Quat b = bin;
    float dot = a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w;
    if (dot < 0) { b = { -b.x, -b.y, -b.z, -b.w }; dot = -dot; }
    if (dot > 0.9995f) {
        return normalize({ a.x + t * (b.x - a.x), a.y + t * (b.y - a.y), a.z + t * (b.z - a.z), a.w + t * (b.w - a.w) });
    }
    float theta = std::acos(dot);
    float s = std::sin(theta);
    float wa = std::sin((1 - t) * theta) / s, wb = std::sin(t * theta) / s;
    return { wa * a.x + wb * b.x, wa * a.y + wb * b.y, wa * a.z + wb * b.z, wa * a.w + wb * b.w };
}

void TwinView::setOrientation(const Quat& q, bool have) {
    latest_ = q;
    have_latest_ = have;
}

void TwinView::recenter() {
    recenter_requested_ = true;
    reference_samples_.clear();
}

std::string TwinView::referencePath() {
    const char* home = std::getenv("HOME");
    std::string dir = std::string(home ? home : ".") + "/.config/rplayhub-android";
    ::mkdir((std::string(home ? home : ".") + "/.config").c_str(), 0755);
    ::mkdir(dir.c_str(), 0755);
    return dir + "/twin-facing-me";
}

void TwinView::loadReference() {
    std::ifstream in(referencePath());
    Quat q;
    if (in >> q.x >> q.y >> q.z >> q.w) {
        reference_ = normalize(q);
        have_reference_ = true;
    }
}

void TwinView::saveReference() const {
    std::ofstream out(referencePath());
    out << reference_.x << " " << reference_.y << " " << reference_.z << " " << reference_.w << "\n";
}

void TwinView::updatePose() {
    if (!have_latest_) return;
    const Quat q = latest_;
    if (recenter_requested_) {
        // Average a short burst rather than trust one packet: a hand is never perfectly still.
        if (reference_samples_.empty() ||
            (reference_samples_[0].x * q.x + reference_samples_[0].y * q.y + reference_samples_[0].z * q.z + reference_samples_[0].w * q.w) >= 0) {
            reference_samples_.push_back(q);
        } else {
            reference_samples_.push_back({ -q.x, -q.y, -q.z, -q.w });   // q and -q are one rotation
        }
        if (reference_samples_.size() >= 12) {
            Quat acc;
            acc.w = 0;
            for (const auto& s : reference_samples_) { acc.x += s.x; acc.y += s.y; acc.z += s.z; acc.w += s.w; }
            reference_ = normalize(acc);
            have_reference_ = true;
            saveReference();
            reference_samples_.clear();
            recenter_requested_ = false;
            have_smoothed_ = false;
        }
        return;   // hold the current pose until the reference settles
    }
    const Quat ref = have_reference_ ? reference_ : q;
    // Body-frame delta: ref^-1 * q. At the reference the twin is face-on; a real rotation of the
    // phone shows as the same rotation of the twin, gravity honest.
    Quat target = normalize(mul(inverse(ref), q));
    if (have_smoothed_) {
        float dot = std::min(1.0f, std::fabs(smoothed_.x * target.x + smoothed_.y * target.y + smoothed_.z * target.z + smoothed_.w * target.w));
        float step_deg = 2 * std::acos(dot) * 180.0f / 3.14159265f;
        // Deadband under ~0.35 deg kills the sensor's dither on a still phone; above it the blend
        // scales with the movement so a fast turn is immediate.
        float alpha = step_deg < 0.35f ? 0.02f : std::clamp(0.10f + step_deg * 0.30f, 0.10f, 0.9f);
        smoothed_ = slerp(smoothed_, target, alpha);
    } else {
        smoothed_ = target;
        have_smoothed_ = true;
    }
    pose_ = smoothed_;
}

ImVec2 TwinView::project(Vec3 v) const {
    // Camera on +z looking at the origin; x right, y up.
    float z = cam_z_ - v.z;
    if (z < 0.05f) z = 0.05f;
    float sx = origin_.x + size_.x * 0.5f + v.x * focal_ / z;
    float sy = origin_.y + size_.y * 0.5f - v.y * focal_ / z;
    return ImVec2(sx, sy);
}

void TwinView::render(ImDrawList* dl, ImVec2 origin, ImVec2 size, ImTextureID screen_tex, ImTextureID back_tex,
                      int display_w, int display_h, int rotation, float scale) {
    updatePose();
    origin_ = origin;
    size_ = size;
    display_w_ = display_w;
    display_h_ = display_h;
    rotation_ = rotation;

    // Model in the phone's screen axes: x right, y up (top), z out of the screen toward the viewer.
    int rw = (rotation % 2 == 1) ? display_h : display_w;
    int rh = (rotation % 2 == 1) ? display_w : display_h;
    float aspect = (rw > 0 && rh > 0) ? static_cast<float>(rw) / rh : 9.0f / 19.5f;
    body_h_ = 1.5f;
    panel_h_ = body_h_;
    panel_w_ = body_h_ * aspect;
    body_w_ = panel_w_ * 1.06f;       // a slim bezel beyond the panel
    body_d_ = body_w_ * 0.10f;
    // Fit: the body's diagonal must fit the rect at the camera distance.
    float diag = std::sqrt(body_w_ * body_w_ + body_h_ * body_h_);
    focal_ = std::min(size.x, size.y) * 0.82f * cam_z_ / diag;

    const Quat R = pose_;
    auto tf = [&](float x, float y, float z) { return rotate(R, {x, y, z}); };
    auto depth = [&](const std::vector<Vec3>& pts) {
        float d = 0;
        for (auto& p : pts) d += p.z;
        return d / pts.size();
    };
    auto facing = [&](const std::vector<Vec3>& pts) {   // true when the face's outward normal points at the viewer
        Vec3 a = pts[0], b = pts[1], c = pts[2];
        float ux = b.x - a.x, uy = b.y - a.y, uz = b.z - a.z;
        float vx = c.x - a.x, vy = c.y - a.y, vz = c.z - a.z;
        float nz = ux * vy - uy * vx;   // z of the cross product; camera looks down -z
        // Perspective: compare against the vector from the face to the camera.
        float nx = uy * vz - uz * vy, ny = uz * vx - ux * vz;
        float cx = 0 - a.x, cy = 0 - a.y, cz = cam_z_ - a.z;
        return nx * cx + ny * cy + nz * cz > 0;
    };

    // Rounded-rectangle outline of a face in its own plane (counter-clockwise seen from +normal).
    auto rounded = [&](float w, float h, float r, int segs) {
        std::vector<std::pair<float, float>> pts;
        const float cx[4] = { w / 2 - r, -w / 2 + r, -w / 2 + r, w / 2 - r };
        const float cy[4] = { h / 2 - r, h / 2 - r, -h / 2 + r, -h / 2 + r };
        for (int c = 0; c < 4; ++c) {
            for (int i = 0; i <= segs; ++i) {
                float a = (c * 90.0f + i * 90.0f / segs) * 3.14159265f / 180.0f;
                pts.push_back({ cx[c] + r * std::cos(a), cy[c] + r * std::sin(a) });
            }
        }
        return pts;
    };

    struct Face { std::vector<Vec3> pts; ImU32 col; float depth; int kind; };   // kind: 0 body, 1 screen, 2 back
    std::vector<Face> faces;
    const float hw = body_w_ / 2, hh = body_h_ / 2, hd = body_d_ / 2;
    const float corner = body_w_ * 0.09f;
    auto outline = rounded(body_w_, body_h_, corner, 6);

    // Front and back faces of the body (rounded), and the side wall as a strip of quads.
    {
        std::vector<Vec3> front, back;
        for (auto& p : outline) { front.push_back(tf(p.first, p.second, hd)); back.push_back(tf(p.first, p.second, -hd)); }
        std::reverse(back.begin(), back.end());
        faces.push_back({ front, IM_COL32(34, 34, 38, 255), depth(front), 0 });
        faces.push_back({ back, IM_COL32(28, 28, 32, 255), depth(back), 2 });
        for (size_t i = 0; i < outline.size(); ++i) {
            auto a = outline[i], b = outline[(i + 1) % outline.size()];
            std::vector<Vec3> quad = { tf(a.first, a.second, hd), tf(a.first, a.second, -hd),
                                       tf(b.first, b.second, -hd), tf(b.first, b.second, hd) };
            // Side shading from the wall's direction
            float nx = b.second - a.second, ny = -(b.first - a.first);
            Vec3 n = rotate(R, { nx, ny, 0 });
            float l = std::sqrt(n.x * n.x + n.y * n.y + n.z * n.z);
            float lit = l > 0 ? 0.5f + 0.5f * std::max(0.0f, (n.x * 0.3f + n.y * 0.6f + n.z * 0.74f) / l) : 0.5f;
            int c = static_cast<int>(40 + 60 * lit);
            faces.push_back({ quad, IM_COL32(c, c, c + 4, 255), depth(quad), 0 });
        }
    }
    std::sort(faces.begin(), faces.end(), [](const Face& a, const Face& b) { return a.depth < b.depth; });   // far first

    // Soft backdrop shadow
    {
        ImVec2 c = project({ 0, -hh - 0.05f, 0 });
        dl->AddEllipseFilled(ImVec2(c.x, c.y + 10 * scale), ImVec2(size.x * 0.28f, size.y * 0.04f), IM_COL32(0, 0, 0, 60));
    }

    std::vector<ImVec2> poly;
    for (const Face& f : faces) {
        if (!facing(f.pts)) continue;
        poly.clear();
        for (auto& p : f.pts) poly.push_back(project(p));
        dl->AddConvexPolyFilled(poly.data(), static_cast<int>(poly.size()), f.col);

        if (f.kind == 2 && back_tex) {
            // Back artwork on the back face, as a grid of affine quads (seen from behind: mirror u).
            const int gx = 6, gy = 12;
            for (int j = 0; j < gy; ++j) for (int i = 0; i < gx; ++i) {
                float x0 = -hw + body_w_ * i / gx, x1 = -hw + body_w_ * (i + 1) / gx;
                float y0 = hh - body_h_ * j / gy, y1 = hh - body_h_ * (j + 1) / gy;
                ImVec2 a = project(tf(x0, y0, -hd - 0.002f)), b = project(tf(x1, y0, -hd - 0.002f));
                ImVec2 c = project(tf(x1, y1, -hd - 0.002f)), d = project(tf(x0, y1, -hd - 0.002f));
                float u0 = 1.0f - static_cast<float>(i) / gx, u1 = 1.0f - static_cast<float>(i + 1) / gx;
                float v0 = static_cast<float>(j) / gy, v1 = static_cast<float>(j + 1) / gy;
                dl->AddImageQuad(back_tex, a, b, c, d, ImVec2(u0, v0), ImVec2(u1, v0), ImVec2(u1, v1), ImVec2(u0, v1));
            }
        }
        if (f.kind == 0 && f.pts.size() == outline.size()) {
            // The screen floats a hair in front of the body: a grid of affine-textured quads.
            const int gx = 8, gy = 16;
            const float pw = panel_w_ / 2, ph = panel_h_ / 2, z = hd + 0.003f;
            for (int j = 0; j < gy; ++j) for (int i = 0; i < gx; ++i) {
                float x0 = -pw + panel_w_ * i / gx, x1 = -pw + panel_w_ * (i + 1) / gx;
                float y0 = ph - panel_h_ * j / gy, y1 = ph - panel_h_ * (j + 1) / gy;
                ImVec2 a = project(tf(x0, y0, z)), b = project(tf(x1, y0, z));
                ImVec2 c = project(tf(x1, y1, z)), d = project(tf(x0, y1, z));
                float u0 = static_cast<float>(i) / gx, u1 = static_cast<float>(i + 1) / gx;
                float v0 = static_cast<float>(j) / gy, v1 = static_cast<float>(j + 1) / gy;
                if (screen_tex) dl->AddImageQuad(screen_tex, a, b, c, d, ImVec2(u0, v0), ImVec2(u1, v0), ImVec2(u1, v1), ImVec2(u0, v1));
                else dl->AddQuadFilled(a, b, c, d, IM_COL32(0, 0, 0, 255));
            }
        }
    }
}

// Unproject the mouse ray and intersect it with the (rotated) screen plane.
bool TwinView::hitTest(ImVec2 mouse, int& out_x, int& out_y) const {
    if (focal_ <= 0 || display_w_ <= 0 || display_h_ <= 0) return false;
    // Ray from the camera (0, 0, cam_z) through the pixel.
    float dx = (mouse.x - (origin_.x + size_.x * 0.5f)) / focal_;
    float dy = -(mouse.y - (origin_.y + size_.y * 0.5f)) / focal_;
    Vec3 o = { 0, 0, cam_z_ }, d = { dx, dy, -1 };
    // Plane: point p0 = R*(0,0,hd), normal n = R*(0,0,1)
    const float hd = body_d_ / 2;
    Vec3 p0 = rotate(pose_, { 0, 0, hd });
    Vec3 n = rotate(pose_, { 0, 0, 1 });
    float denom = n.x * d.x + n.y * d.y + n.z * d.z;
    if (std::fabs(denom) < 1e-6f) return false;
    float t = (n.x * (p0.x - o.x) + n.y * (p0.y - o.y) + n.z * (p0.z - o.z)) / denom;
    if (t <= 0) return false;
    Vec3 hit = { o.x + d.x * t, o.y + d.y * t, o.z + d.z * t };
    // Back into the phone's frame
    Vec3 local = rotate(inverse(pose_), { hit.x - p0.x, hit.y - p0.y, hit.z - p0.z });
    float u = local.x / panel_w_ + 0.5f, v = 0.5f - local.y / panel_h_;
    if (u < 0 || u > 1 || v < 0 || v > 1) return false;
    // The frame is already rotated by the agent; map like the flat mirror does.
    float nx = u, ny = v;
    switch (rotation_) {
        case 1: nx = 1.0f - v; ny = u; break;
        case 2: nx = 1.0f - u; ny = 1.0f - v; break;
        case 3: nx = v; ny = 1.0f - u; break;
        default: break;
    }
    out_x = static_cast<int>(nx * display_w_);
    out_y = static_cast<int>(ny * display_h_);
    return true;
}

} // namespace rplayhub
