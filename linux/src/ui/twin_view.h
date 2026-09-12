#pragma once

// The 3D device twin: a phone-shaped slab that turns as the real one turns,
// driven by the rotation vector sensor, with the mirror texture-mapped onto
// its face and the back artwork on its back. Drawn with Dear ImGui textured
// quads under a hand-rolled perspective projection: no GL of our own, so it
// works wherever the SDL renderer does (a Pi included).
//
// Orientation math follows the Mac client: what renders is the rotation FROM
// a "facing me" reference pose TO the current pose, taken in the phone's own
// body frame (ref^-1 * q), smoothed adaptively so a still phone does not
// shiver and a fast turn is not laggy.

#include "imgui.h"
#include <SDL2/SDL.h>
#include <array>
#include <string>
#include <vector>

namespace rplayhub {

struct Quat { float x = 0, y = 0, z = 0, w = 1; };

class TwinView {
public:
    // Reference persistence lives in ~/.config/rplayhub-android/twin-facing-me.
    TwinView();

    // Latest device orientation (device -> world), from the sensor channel.
    void setOrientation(const Quat& q, bool have);
    // A foldable: two halves hinged on a vertical axis at the crease. hinge_deg is 180 flat,
    // 0 closed; the sensor pose belongs to the held half (half A, the left one).
    void setFold(bool foldable, float hinge_deg, bool have_hinge);
    // How the moving half's glass is textured: 0 hard cut (as Android draws it), 1 locked (a
    // content plane fixed in the world, sampled along the camera ray), 2 stylized (the
    // SurfaceFlinger-style approximation: an alpha ramp and a seam band on the moving half).
    void setRenderMode(int mode) { render_mode_ = mode; }
    int renderMode() const { return render_mode_; }
    struct Stylized { float a = 0.35f; float w = 0.05f; };   // alpha ramp strength, seam band width (of the half)
    Stylized& stylized() { return stylized_; }
    // Begin capturing a new "facing me" reference: the next ~12 samples are averaged.
    void recenter();
    bool recentering() const { return recenter_requested_; }
    bool hasReference() const { return have_reference_; }

    // Draw into the rect; screen_tex is the live mirror texture (may be null), display size is
    // the device's logical size and orientation quadrants, for aspect and touch mapping.
    void render(ImDrawList* dl, ImVec2 origin, ImVec2 size, ImTextureID screen_tex, ImTextureID back_tex,
                int display_w, int display_h, int rotation, float scale, ImTextureID outer_tex = 0);

    // Map a mouse position to device coordinates via the rotated screen plane. False if the
    // point misses the screen.
    bool hitTest(ImVec2 mouse, int& out_x, int& out_y) const;

private:
    struct Vec3 { float x, y, z; };
    static Vec3 rotate(const Quat& q, Vec3 v);
    static Quat mul(const Quat& a, const Quat& b);
    static Quat inverse(const Quat& q);
    static Quat normalize(const Quat& q);
    static Quat slerp(const Quat& a, const Quat& b, float t);
    ImVec2 project(Vec3 v) const;
    void updatePose();
    void loadReference();
    void saveReference() const;
    static std::string referencePath();

    Quat latest_;
    bool have_latest_ = false;
    Quat reference_;
    bool have_reference_ = false;
    Quat smoothed_;
    bool have_smoothed_ = false;
    bool recenter_requested_ = true;
    std::vector<Quat> reference_samples_;
    Quat pose_;   // the rotation applied to the model
    // Foldable state
    void renderFold(ImDrawList* dl, ImVec2 size, ImTextureID screen_tex, ImTextureID back_tex, ImTextureID outer_tex, float scale);
    bool foldable_ = false;
    float hinge_deg_ = 180.0f;
    bool have_hinge_ = false;
    int render_mode_ = 0;
    Stylized stylized_;
    float half_w_ = 0;   // each half's panel width (the inner display split at the crease)

    // Last frame's projection, for hit testing
    ImVec2 origin_, size_;
    float focal_ = 0, cam_z_ = 3.6f;
    float body_w_ = 0, body_h_ = 0, body_d_ = 0, panel_w_ = 0, panel_h_ = 0;
    int display_w_ = 0, display_h_ = 0, rotation_ = 0;
};

} // namespace rplayhub
