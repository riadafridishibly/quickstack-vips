#!/bin/sh
# Downloads the tarballs in sources.txt into $1 and checks their SHA-256.
set -eu
dir=$1
mkdir -p "$dir"
grep -v '^#' "$(dirname "$0")/sources.txt" | while read -r name _ url sum; do
	curl -fsSL --retry 3 -o "$dir/$name.tar" "$url"
	echo "$sum  $dir/$name.tar" | sha256sum -c -
done
