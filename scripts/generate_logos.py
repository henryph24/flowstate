#!/usr/bin/env python3
"""Generate Murmur logo candidates via gemini-3-pro-image (Nano Banana Pro)."""
import base64
import json
import os
import sys
import urllib.request
from concurrent.futures import ThreadPoolExecutor

KEY = os.environ["GEMINI_API_KEY"]
MODEL = "gemini-3-pro-image"
URL = f"https://generativelanguage.googleapis.com/v1beta/models/{MODEL}:generateContent"
OUT = os.path.expanduser("~/murmur/design")
os.makedirs(OUT, exist_ok=True)

STYLE = (
    "Premium minimal brand identity design, flat vector style, studio-grade logo work. "
    "Palette discipline: near-black charcoal background (#101014), soft lilac accent (#B8A7E9), "
    "muted off-white (#ECEAF4). No gradients except one subtle glow, no neon, no 3D bevels, "
    "no clutter, no extra text or watermarks, generous negative space, crisp geometry, "
    "perfectly centered composition."
)

CANDIDATES = {
    "logo-1-m-waveform": (
        "Logo mark for 'Murmur', a macOS voice dictation app. A single continuous thin line "
        "forms a capital letter M whose two peaks read as a soft audio waveform — the murmur "
        "of a voice. Monogram and waveform fused into one reduced, ownable symbol. The line "
        "has rounded terminals and even stroke weight, drawn in soft lilac on near-black. "
        "Below the mark, the wordmark 'murmur' in lowercase, modern geometric sans-serif, "
        "wide letter-spacing, muted off-white, small relative to the mark. " + STYLE
    ),
    "logo-2-wave-to-cursor": (
        "Logo mark for 'Murmur', a speech-to-text app. A horizontal symbol: on the left, three "
        "soft rounded waveform pulses (a quiet voice), which settle rightward into one clean "
        "flat baseline ending in a vertical text-insertion cursor bar. Speech becoming typed "
        "text, told in one continuous line. Soft lilac line on near-black, rounded terminals, "
        "even stroke weight. The wordmark 'murmur' sits beneath in lowercase geometric "
        "sans-serif, wide tracking, muted off-white. " + STYLE
    ),
    "icon-1-pulse-orb": (
        "macOS Big Sur style app icon, rounded-square squircle filling most of the canvas on a "
        "plain dark gray backdrop. Inside the near-black squircle: a quiet sound orb — a small "
        "soft lilac dot at center with two concentric thin pulse rings radiating outward, the "
        "outer ring fading — a murmur radiating softly. Subtle inner glow around the dot only. "
        "Flat, modern, Apple design language, no text anywhere. " + STYLE
    ),
    "icon-2-m-wave-squircle": (
        "macOS Big Sur style app icon, rounded-square squircle filling most of the canvas on a "
        "plain dark gray backdrop. Inside the near-black squircle: a single continuous thin "
        "soft-lilac line forming a capital M whose peaks read as a gentle audio waveform, "
        "rounded terminals, even stroke weight, perfectly centered with generous padding. "
        "A faint lilac glow under the line. Flat, modern, Apple design language, no text "
        "anywhere. " + STYLE
    ),
}


def generate(name: str, prompt: str) -> str:
    body = json.dumps({
        "contents": [{"parts": [{"text": prompt}]}],
        "generationConfig": {
            "responseModalities": ["TEXT", "IMAGE"],
            "imageConfig": {"aspectRatio": "1:1", "imageSize": "2K"},
        },
    }).encode()
    req = urllib.request.Request(
        URL,
        data=body,
        headers={"Content-Type": "application/json", "x-goog-api-key": KEY},
    )
    with urllib.request.urlopen(req, timeout=300) as resp:
        data = json.load(resp)
    parts = data["candidates"][0]["content"]["parts"]
    images = [p["inlineData"]["data"] for p in parts
              if "inlineData" in p and not p.get("thought")]
    if not images:
        return f"{name}: NO IMAGE — {json.dumps(data)[:300]}"
    path = os.path.join(OUT, f"{name}.png")
    with open(path, "wb") as f:
        f.write(base64.b64decode(images[-1]))
    return f"{name}: saved {path} ({os.path.getsize(path) // 1024} KB)"


with ThreadPoolExecutor(max_workers=4) as pool:
    for result in pool.map(lambda kv: generate(*kv), CANDIDATES.items()):
        print(result)
print("done", file=sys.stderr)
