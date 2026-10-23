#!/usr/bin/env python3
"""Builds AerialSwap's Liquid Glass app icon.

Two video boxes, tilted 45 degrees, sit in the top-left (old video) and bottom-right (new video)
corners. Nothing draws an arrow: the gap between the boxes is the shaft, the box ends are the barbs,
and the icon's own top-right and bottom-left corners are the tips.

    python3 Tools/make_icon.py            write Resources/AppIcon.icon, then compile it
    python3 Tools/make_icon.py --compile  only compile (keeps tweaks made in Icon Composer)

Compiling needs Xcode (actool). It writes Resources/Assets.car (Liquid Glass icon) and
Resources/AppIcon.icns (fallback); both are committed so build.sh works without Xcode.
"""
import json, math, os, subprocess, sys, tempfile

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
ICON = os.path.join(ROOT, "Resources", "AppIcon.icon")
XCODE = "/Applications/Xcode.app/Contents/Developer"

# Icon Composer canvas: 1024 x 1024, the whole canvas is the icon shape.
GAP = 124        # width of the arrow shaft between the boxes
HALF = 373       # half the box length along the diagonal; the rest of the diagonal is the arrow heads
DEPTH = 900      # boxes run off the icon edge
RADIUS = 75
PLAY = 124       # play symbol width across its base
C = math.sqrt(0.5)


def visible_center(side):
    """Centre of the largest circle inside the visible part of a box (side -1: top-left, 1: bottom-right).

    It lies on the corner diagonal, at distance d from the icon centre where the gap edge
    (d - GAP/2 away) and the icon's two straight edges (512 - d/sqrt(2) away) are equally far.
    """
    d = (512 + GAP / 2) / (1 + C)
    return 512 + side * C * d, 512 + side * C * d


def box(side):
    y = 512 + GAP / 2 if side > 0 else 512 - GAP / 2 - DEPTH
    return (f'<rect transform="rotate(-45 512 512)" x="{512 - HALF}" y="{y}" width="{2 * HALF}" '
            f'height="{DEPTH}" rx="{RADIUS}" fill="#FFFFFF"/>')


def play(side):
    """Play symbol tilted with its box, centred on the visible box; both point up-right."""
    cx, cy = visible_center(side)
    length = PLAY * 1.2   # longer than wide, so the tip still reads when tilted
    # Optical centre: halfway between the triangle's centroid and the middle of its length.
    tip, base = length * 7 / 12, -length * 5 / 12
    tilt = lambda along, across: (cx + C * along + C * across, cy - C * along + C * across)
    pts = [tilt(tip, 0), tilt(base, -PLAY / 2), tilt(base, PLAY / 2)]
    d = "M " + " L ".join(f"{x:.1f} {y:.1f}" for x, y in pts) + " Z"
    return f'<path d="{d}" fill="#FFFFFF" stroke="#FFFFFF" stroke-width="14" stroke-linejoin="round"/>'


def layer(name, opacity):
    return {"image-name": name + ".svg", "name": name, "glass": True, "opacity": opacity}


def write_icon():
    os.makedirs(os.path.join(ICON, "Assets"), exist_ok=True)
    art = {"old-box": box(-1), "old-play": play(-1), "new-box": box(1), "new-play": play(1)}
    for name, inner in art.items():
        with open(os.path.join(ICON, "Assets", name + ".svg"), "w") as f:
            f.write(f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" '
                    f'viewBox="0 0 1024 1024">{inner}</svg>\n')
    doc = {
        "fill": {
            "linear-gradient": ["display-p3:0.24,0.44,1.00,1.00", "display-p3:0.11,0.17,0.42,1.00"],
            "orientation": {"start": {"x": 0.5, "y": 0.0}, "stop": {"x": 0.5, "y": 1.0}},
        },
        "groups": [
            {
                "name": "New video",
                "layers": [layer("new-play", 1.0), layer("new-box", 0.55)],
                "shadow": {"kind": "neutral", "opacity": 0.5},
                "translucency": {"enabled": True, "value": 0.35},
                "specular": True,
                "lighting": "individual",
            },
            {
                "name": "Old video",
                "layers": [layer("old-play", 0.7), layer("old-box", 0.3)],
                "shadow": {"kind": "neutral", "opacity": 0.3},
                "translucency": {"enabled": True, "value": 0.6},
                "specular": True,
                "lighting": "individual",
            },
        ],
        "supported-platforms": {"squares": ["macOS"]},
    }
    with open(os.path.join(ICON, "icon.json"), "w") as f:
        json.dump(doc, f, indent=2)
        f.write("\n")
    print("Wrote", os.path.relpath(ICON, ROOT))


def compile_icon():
    if not os.path.isdir(XCODE):
        sys.exit("Compiling needs Xcode at /Applications/Xcode.app (for actool).")
    out = os.path.join(ROOT, "Resources")
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(["xcrun", "actool", ICON, "--compile", out, "--platform", "macosx",
                        "--minimum-deployment-target", "27.0", "--app-icon", "AppIcon",
                        "--output-partial-info-plist", os.path.join(tmp, "partial.plist")],
                       env={**os.environ, "DEVELOPER_DIR": XCODE}, check=True, stdout=subprocess.DEVNULL)
    print("Compiled Resources/Assets.car and Resources/AppIcon.icns")


if __name__ == "__main__":
    if "--compile" not in sys.argv[1:]:
        write_icon()
    compile_icon()
