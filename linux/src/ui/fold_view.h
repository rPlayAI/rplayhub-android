#pragma once
// The fold transition for a foldable phone: the inner picture drawn as two halves hinged at
// the crease, each turned toward the viewer by half the fold angle under a perspective
// projection, with the chassis around them. Fed by the hinge-angle sensor when the agent
// streams it, else by the device state with a timed ease. When the phone is closed the
// outer panel's live picture takes over, flat.
#include "imgui.h"
#include <string>

namespace rplayhub {

class FoldView {
public:
    // Per frame: the hinge angle in degrees (0 closed .. 180 flat) if known, the device state.
    void setHinge(float degrees, bool have);
    void setState(const std::string& name);   // CLOSED, HALF_OPENED, OPENED, ...
    // RPLAYHUB_FAKE_HINGE=1 sweeps the angle up and down for development without a phone.
    void tick(float dt);
    // True while the fold is drawn instead of the flat picture (the phone is not flat).
    bool active() const { return shown_ < 176.0f; }
    // True when the phone is closed enough that the outer panel is what a viewer sees.
    bool closed() const { return shown_ < 8.0f; }
    float angle() const { return shown_; }
    // Draw into the stage rect: inner_tex is the (last) inner-panel picture, outer_tex the
    // outer panel's live picture (either may be null). Returns the screen-space rect the
    // flat picture would occupy, for touch mapping.
    void render(ImDrawList* dl, ImVec2 origin, ImVec2 size, ImTextureID inner_tex, int inner_w, int inner_h,
                ImTextureID outer_tex, int outer_w, int outer_h, float scale, ImVec2 uv0, ImVec2 uv1);

private:
    float target_ = 180.0f;
    float shown_ = 180.0f;
    bool have_hinge_ = false;
    std::string state_ = "OPENED";
    float fake_t_ = 0.0f;
};

} // namespace rplayhub
