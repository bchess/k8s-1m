#!/bin/bash
set -e

CSV="regions.csv"
IMAGES=("100k_kubelet.png" "100k_kwok.png")

# Skip the header and read each line
tail -n +2 "$CSV" | while IFS=, read -r name x y width height; do
  for src in "${IMAGES[@]}"; do
    base=$(basename "$src" .png)
    out="${name}_${base}.png"
    label="${base#100k_}"
    magick "$src" -crop "${width}x${height}+$x+$y" +repage \
        -gravity north -fill white -pointsize 24 \
          -annotate +0+5 "$label" "$out"
    echo "Created $out"
  done
done
