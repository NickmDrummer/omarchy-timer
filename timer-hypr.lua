-- Timer (nickmdrummer.timer) — real blur for the popup and floating window.
--
-- Layer-shell surfaces are transparent except for the card: without
-- `ignore_alpha`, blur applies to the WHOLE surface (on the popup,
-- which is fullscreen, that blurs the entire desktop; on the floating
-- window, it bleeds out of the rounded corners as a 90-degree square).
-- With the threshold, only card pixels (alpha ~0.34-0.42) trigger blur.
--
-- Install: one line at the end of ~/.config/hypr/hyprland.lua:
--
--   dofile(os.getenv("HOME") .. "/.config/omarchy/plugins/nickmdrummer.timer/timer-hypr.lua")
--
-- then `hyprctl reload`.

-- Popup: blur only on the card + no compositor animation
-- (the transition is owned by QML, like all other panels).
hl.layer_rule({
  match = { namespace = "nickmdrummer-timer-popup" },
  blur = true,
  ignore_alpha = 0.3,
  no_anim = true,
  animation = "none",
})

-- Floating window: blur only on the card (transparent corners ignored).
hl.layer_rule({
  match = { namespace = "nickmdrummer-timer-float" },
  blur = true,
  ignore_alpha = 0.3,
})
