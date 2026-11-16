#!/bin/sh
# Runs the kit in $1 on the images in $2: each must load and convert to
# WebP, and formats left out of the build must be absent.
set -eu
kit=$1
images=$2
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

"$kit/bin/vips" --version
for f in "$images"/*; do
	"$kit/bin/vips" thumbnail "$f" "$out/t.webp" 64
	echo "$(basename "$f"): $("$kit/bin/vipsheader" "$out/t.webp")"
done
if "$kit/bin/vips" -l foreign | grep -E 'svgload|pdfload|tiffload|magickload|jxlload'; then
	echo "unexpected loaders" >&2
	exit 1
fi
echo ok
