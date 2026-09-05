#pragma once

#include "imgui.h"

namespace rplayhub {

namespace Theme {
    // macOS Palette
    inline ImVec4 ColorBgWindow        = ImVec4(0.97f, 0.97f, 0.98f, 1.00f); // #F7F7FA
    inline ImVec4 ColorBgSidebar       = ImVec4(0.94f, 0.94f, 0.96f, 1.00f); // #F0F0F5
    inline ImVec4 ColorBgStage         = ImVec4(1.00f, 1.00f, 1.00f, 1.00f); // #FFFFFF
    inline ImVec4 ColorBgInspector     = ImVec4(0.96f, 0.96f, 0.97f, 1.00f); // #F5F5F8
    inline ImVec4 ColorBgCard          = ImVec4(1.00f, 1.00f, 1.00f, 1.00f);
    inline ImVec4 ColorBgCardHover     = ImVec4(0.90f, 0.94f, 1.00f, 0.60f);
    inline ImVec4 ColorBgCardActive    = ImVec4(0.85f, 0.92f, 1.00f, 0.90f);

    inline ImVec4 ColorTextPrimary     = ImVec4(0.12f, 0.12f, 0.14f, 1.00f); // #1E1E24
    inline ImVec4 ColorTextSecondary   = ImVec4(0.50f, 0.50f, 0.54f, 1.00f); // #80808A
    inline ImVec4 ColorTextTertiary    = ImVec4(0.65f, 0.65f, 0.68f, 1.00f);

    inline ImVec4 ColorAccent          = ImVec4(0.00f, 0.48f, 1.00f, 1.00f); // Apple System Blue #007AFF
    inline ImVec4 ColorAccentHover     = ImVec4(0.10f, 0.55f, 1.00f, 1.00f);
    inline ImVec4 ColorAccentActive    = ImVec4(0.00f, 0.40f, 0.85f, 1.00f);

    inline ImVec4 ColorStatusGreen     = ImVec4(0.20f, 0.78f, 0.35f, 1.00f); // #34C759
    inline ImVec4 ColorStatusYellow    = ImVec4(1.00f, 0.80f, 0.00f, 1.00f); // #FFCC00
    inline ImVec4 ColorStatusRed       = ImVec4(1.00f, 0.23f, 0.19f, 1.00f); // #FF3B30

    inline ImVec4 ColorBorder          = ImVec4(0.86f, 0.86f, 0.88f, 0.80f); // #DCDCDE
    inline ImVec4 ColorDivider         = ImVec4(0.88f, 0.88f, 0.90f, 0.70f);

    inline ImVec4 ColorPhoneBezel      = ImVec4(0.08f, 0.08f, 0.09f, 1.00f); // #141417
    inline ImVec4 ColorPhoneCutout     = ImVec4(0.02f, 0.02f, 0.03f, 1.00f);

    inline void applyMacStyle(float scale = 1.0f) {
        ImGuiStyle& style = ImGui::GetStyle();

        // Rounding
        style.WindowRounding    = 10.0f * scale;
        style.ChildRounding     = 8.0f * scale;
        style.FrameRounding     = 6.0f * scale;
        style.PopupRounding     = 8.0f * scale;
        style.ScrollbarRounding = 9.0f * scale;
        style.GrabRounding      = 6.0f * scale;
        style.TabRounding       = 6.0f * scale;

        // Spacing & padding
        style.WindowPadding     = ImVec2(12.0f * scale, 12.0f * scale);
        style.FramePadding      = ImVec2(10.0f * scale, 6.0f * scale);
        style.ItemSpacing       = ImVec2(8.0f * scale, 8.0f * scale);
        style.ItemInnerSpacing  = ImVec2(6.0f * scale, 6.0f * scale);
        style.IndentSpacing     = 20.0f * scale;
        style.ScrollbarSize     = 12.0f * scale;

        // Borders
        style.WindowBorderSize  = 0.0f;
        style.ChildBorderSize   = 1.0f;
        style.PopupBorderSize   = 1.0f;
        style.FrameBorderSize   = 1.0f;
        style.TabBorderSize     = 0.0f;

        // Color map
        ImVec4* colors = style.Colors;
        colors[ImGuiCol_Text]                  = ColorTextPrimary;
        colors[ImGuiCol_TextDisabled]          = ColorTextSecondary;
        colors[ImGuiCol_WindowBg]              = ColorBgWindow;
        colors[ImGuiCol_ChildBg]               = ColorBgStage;
        colors[ImGuiCol_PopupBg]               = ImVec4(1.00f, 1.00f, 1.00f, 1.00f);
        colors[ImGuiCol_Border]                = ColorBorder;
        colors[ImGuiCol_BorderShadow]          = ImVec4(0.00f, 0.00f, 0.00f, 0.00f);
        colors[ImGuiCol_FrameBg]               = ImVec4(1.00f, 1.00f, 1.00f, 1.00f);
        colors[ImGuiCol_FrameBgHovered]        = ImVec4(0.96f, 0.96f, 0.98f, 1.00f);
        colors[ImGuiCol_FrameBgActive]         = ImVec4(0.92f, 0.95f, 1.00f, 1.00f);
        colors[ImGuiCol_TitleBg]               = ColorBgWindow;
        colors[ImGuiCol_TitleBgActive]         = ColorBgWindow;
        colors[ImGuiCol_TitleBgCollapsed]      = ColorBgWindow;
        colors[ImGuiCol_MenuBarBg]             = ColorBgWindow;
        colors[ImGuiCol_ScrollbarBg]           = ImVec4(0.00f, 0.00f, 0.00f, 0.00f);
        colors[ImGuiCol_ScrollbarGrab]         = ImVec4(0.75f, 0.75f, 0.78f, 0.70f);
        colors[ImGuiCol_ScrollbarGrabHovered]  = ImVec4(0.60f, 0.60f, 0.65f, 0.80f);
        colors[ImGuiCol_ScrollbarGrabActive]   = ImVec4(0.45f, 0.45f, 0.50f, 0.90f);
        colors[ImGuiCol_CheckMark]             = ColorAccent;
        colors[ImGuiCol_SliderGrab]            = ColorAccent;
        colors[ImGuiCol_SliderGrabActive]      = ColorAccentActive;
        colors[ImGuiCol_Button]                = ImVec4(0.95f, 0.95f, 0.97f, 1.00f);
        colors[ImGuiCol_ButtonHovered]         = ImVec4(0.90f, 0.93f, 0.98f, 1.00f);
        colors[ImGuiCol_ButtonActive]          = ImVec4(0.85f, 0.90f, 0.98f, 1.00f);
        colors[ImGuiCol_Header]                = ImVec4(0.90f, 0.94f, 1.00f, 0.70f);
        colors[ImGuiCol_HeaderHovered]         = ImVec4(0.88f, 0.93f, 1.00f, 0.90f);
        colors[ImGuiCol_HeaderActive]          = ColorAccent;
        colors[ImGuiCol_Separator]             = ColorDivider;
        colors[ImGuiCol_SeparatorHovered]      = ColorAccentHover;
        colors[ImGuiCol_SeparatorActive]       = ColorAccentActive;
        colors[ImGuiCol_ResizeGrip]            = ImVec4(0.00f, 0.00f, 0.00f, 0.00f);
        colors[ImGuiCol_ResizeGripHovered]     = ImVec4(0.00f, 0.48f, 1.00f, 0.40f);
        colors[ImGuiCol_ResizeGripActive]      = ColorAccent;
        colors[ImGuiCol_Tab]                   = ImVec4(0.92f, 0.92f, 0.94f, 1.00f);
        colors[ImGuiCol_TabHovered]            = ImVec4(0.88f, 0.92f, 0.98f, 1.00f);
        colors[ImGuiCol_TabActive]             = ColorAccent;
        colors[ImGuiCol_TabUnfocused]          = ImVec4(0.92f, 0.92f, 0.94f, 1.00f);
        colors[ImGuiCol_TabUnfocusedActive]    = ImVec4(0.88f, 0.92f, 0.98f, 1.00f);
    }
}

} // namespace rplayhub
