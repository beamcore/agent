# Codex Prompt for Premiere Pro MCP — Beamcore Motion Ad

You are controlling Adobe Premiere Pro through MCP. Build a polished 30-second motion ad for Beamcore Agent using this source pack and the user’s original video `IMG_0900.MOV`.

## Goal
Create a clean, high-speed developer ad. Use the bike POV footage as the motion base. Use the Beamcore graphics as overlays. The ad must sell:
- `99% CACHE HIT` as the main campaign hook.
- Beamcore as an open-source terminal coding agent.
- Eeva: one execution layer / one tool, not a large toolbox.
- Distributed BEAM nodes / mesh networking.
- Live runtime attach.
- Memory, provider routing, sub-agents, Telegram/Discord gateway as fast feature hits.

Important: the 99% cache-hit claim is supplied by the project owner. Do not present it as a README quote unless benchmark proof is added.

## Inputs
Use the original `IMG_0900.MOV` as V1. It is a 4K bike POV clip, about 46.67 seconds. Use these assets from the pack:
- `assets/png/overlay_speed_lines_transparent_1080p.png`
- `assets/png/overlay_terminal_eeva_transparent_1080p.png`
- `assets/png/overlay_cache_hit_99_transparent_1080p.png`
- `assets/png/overlay_mesh_nodes_transparent_1080p.png`
- `assets/png/feature_one_tool_lower_third_1080p.png`
- `assets/png/feature_runtime_attach_lower_third_1080p.png`
- `assets/png/card_providers.png`
- `assets/png/card_memory.png`
- `assets/png/card_mesh.png`
- `assets/png/card_gateway.png`
- `assets/png/overlay_cta_transparent_1080p.png`
- `assets/png/beamcore_wordmark_transparent.png`
- SFX from `/sfx`.

## Sequence Settings
Create sequence `BEAMCORE_AD_16x9_30s`:
- 3840x2160 if using original MOV, otherwise 1920x1080 is acceptable for preview.
- 30 fps.
- Duration: 30 seconds.
- Audio: 48 kHz.

## Style Rules
- Clean terminal-tech. No generic AI stock visuals, robot heads, floating brains, hologram hands, random circuit boards, or excessive neon.
- Keep overlays readable over the bright road. Add a dark translucent plate behind native text if needed.
- Use fast but readable motion: 6-12 frame transitions, smooth ease out/ease in.
- Use modern sans text, near-white text, cyan/violet/green accents.
- The ad must work muted.

## Edit Timeline

### 00:00–00:02 — Problem Hook
V1: Bike POV starts, scale to fill. Add a slight zoom-in from 100% to 104%.
V2: `overlay_speed_lines_transparent_1080p.png`, opacity 0% → 55% in 10 frames, then down to 20%.
V4 native text, center-left: `Your coding agent is leaking context.`
SFX: `whoosh_short.wav` at 00:00:06.

### 00:02–00:05 — Brand Entry
Add `beamcore_wordmark_transparent.png` top-left.
Text: `Beamcore keeps the hot path hot.`
SFX: `node_click.wav` at 00:02:00.

### 00:05–00:09 — Eeva / One Tool
Add `overlay_terminal_eeva_transparent_1080p.png` centered and scaled to 4K sequence if needed.
Animate scale 96% → 100%, opacity 0% → 100% in 10 frames.
Native text:
`One tool: Eeva executes Elixir.`
`No wrapper zoo. No tool-call noise.`
SFX: `cache_ping.wav` at 00:06:06.

### 00:09–00:13 — Collapse Tool Calls
Add `feature_one_tool_lower_third_1080p.png`.
Native text upper-right: `10 tool calls → 1 runtime step`
SFX: `whoosh_short.wav` at 00:09:00.

### 00:13–00:17 — Main Claim
Add `overlay_cache_hit_99_transparent_1080p.png` large/centered.
Native text or overlay must read clearly: `99% CACHE HIT`.
Add small bottom-right disclaimer at 55% opacity: `project claim — replace with benchmark if needed`.
SFX: `bass_hit.wav` at 00:13:06, `cache_ping.wav` at 00:15:00.

### 00:17–00:21 — Distributed Mesh
Add `overlay_mesh_nodes_transparent_1080p.png`.
Native text bottom-left:
`Every instance is a distributed BEAM node.`
`Agents discover peers automatically.`
SFX: `node_click.wav` at 00:18:00, 00:18:15, 00:19:00.

### 00:21–00:24 — Live Attach
Add `feature_runtime_attach_lower_third_1080p.png`.
Native text upper-right:
`Attach to a live app runtime.`
`Inspect processes, modules and state in place.`
SFX: `whoosh_short.wav` at 00:21:00.

### 00:24–00:27 — Feature Burst
Create a 2x2 card grid using:
- `card_memory.png`
- `card_providers.png`
- `card_mesh.png`
- `card_gateway.png`
Stagger each card by 4 frames.
Text center-top: `Memory. Providers. Sub-agents. Messaging gateway.`
SFX: `cache_ping.wav` at 00:24:12.

### 00:27–00:30 — CTA
Add a black solid over footage at 55% opacity.
Add `overlay_cta_transparent_1080p.png` centered.
Ensure the URL is readable: `github.com/beamcore/agent`.
SFX: `bass_hit.wav` at 00:27:00.
Fade to black in the last 10 frames.

## Color / Effects
- Lumetri on footage: lower highlights slightly, mild contrast, cool shadows.
- Keep original bike audio muted or around -22 dB.
- SFX should peak around -6 dB.
- Export `beamcore_ad_16x9_4k_master.mp4` and `beamcore_ad_16x9_preview_1080p.mp4`.

## QA Checklist
- 99% cache-hit card is readable for at least 2.5 seconds.
- URL is readable on mobile.
- Text is not hidden by the handlebar.
- No “AI slop” imagery.
- Ad still works without sound.
