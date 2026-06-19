#!/bin/sh
# Extract downloaded site-*/site.tar.gz artifacts into _site/.
# Fails if no tarballs are found under artifacts/.

set -eu

mkdir -p _site

echo "=== Downloaded artifacts ==="
if [ ! -d artifacts ]; then
    echo "No artifacts directory." >&2
    exit 1
fi
find artifacts -maxdepth 3 -print

echo "=== Extracting ==="
count=0
while IFS= read -r t; do
    echo "Extracting $t"
    tar -C _site -xzf "$t"
    count=$((count + 1))
done <<HEREDOC
$(find artifacts -name 'site.tar.gz' -type f)
HEREDOC

if [ "$count" -eq 0 ]; then
    echo "No site.tar.gz found in artifacts" >&2
    exit 1
fi

echo "=== Result ==="
find _site -maxdepth 2 -print
