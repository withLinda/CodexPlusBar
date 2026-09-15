#!/usr/bin/env python3
"""Compare native missing-data labels after a live theme change with a fresh render.

Requires Pillow. Run after rendering --missing-expiry --cycle-theme --output /tmp/theme.png
and a fresh --missing-expiry --light --output /tmp/theme-fresh-light.png.
"""
import argparse
import io
import json
from pathlib import Path

from PIL import Image, ImageCms, ImageChops


def srgb(path):
    image = Image.open(path)
    if not image.info.get("icc_profile"):
        raise ValueError(f"Missing ICC profile: {path}")
    profile = ImageCms.ImageCmsProfile(io.BytesIO(image.info["icc_profile"]))
    return ImageCms.profileToProfile(image, profile, ImageCms.createProfile("sRGB"), outputMode="RGB")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("initial", type=Path)
    parser.add_argument("fresh_light", type=Path)
    args = parser.parse_args()
    initial = srgb(args.initial)
    light = srgb(args.initial.with_name(args.initial.stem + "-light.png"))
    dark_again = srgb(args.initial.with_name(args.initial.stem + "-dark-again.png"))
    fresh = srgb(args.fresh_light)
    if any(image.size != (1000, 680) for image in [initial, light, dark_again, fresh]):
        raise ValueError("Use the default 1000 × 680 manager fixture window.")

    # Label glyphs plus their true underlays; exclude native window chrome and scroll effects.
    regions = {
        "missing expiry, selected": (27, 225, 145, 243),
        "missing expiry, unselected": (27, 337, 145, 355),
        "missing weekly reset": (162, 647, 254, 665),
        "primary capacity": (525, 250, 645, 281),
    }
    results = []
    for transition, actual, expected in [("dark-to-light", light, fresh), ("light-to-dark", dark_again, initial)]:
        for name, region in regions.items():
            difference = ImageChops.difference(actual.crop(region), expected.crop(region))
            maximum = max(upper for _, upper in difference.getextrema())
            results.append({"transition": transition, "region": name, "bounds": region,
                            "maximum_srgb_channel_difference": maximum, "passed": maximum <= 2})
    report = {"passed": all(result["passed"] for result in results), "checks": results}
    print(json.dumps(report, indent=2))
    raise SystemExit(0 if report["passed"] else 1)


if __name__ == "__main__":
    main()
