#!/usr/bin/env bash
# Build the fixtures the tapes run against. Deterministic: same bytes every time.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# A 4 MB log for the --progress demo: paced at 300k/s it runs about 14 seconds.
seq 1 120000 | awk '{ printf "%s request_id=%08x status=200 bytes=%d\n", $1, $1 * 2654435761, 512 + ($1 % 4096) }' > big.log

# A tree of varied sizes, for `du -sh tree/* | scroll --sort --human`. Sizes are
# derived from the name, so the ordering is the same on every machine.
names=(node_modules vendor target build dist .cache coverage tmp logs assets
  media fixtures snapshots artifacts sdist wheels bundles chunks sourcemaps
  thumbnails uploads exports backups indexes shards blobs segments manifests
  translations icons fonts audio video docs reports profiles traces dumps
  archives staging)
sizes=(2048 96 12288 320 40 6144 800 24 16384 160 3072 64 1024 480 32768 12
  4096 640 208 8192 48 1536 2560 80 20480 128 384 5120 28 10240 240 1792 56
  7168 960 176 14336 36 2816 448)
for index in "${!names[@]}"; do
  mkdir -p "tree/${names[index]}"
  dd if=/dev/zero of="tree/${names[index]}/data.bin" bs=1024 \
    count="${sizes[index]}" status=none
done

# A log that already has content, so the follow demo shows priming.
"$DEMO_DIR/lib/writer" /dev/stdout 200 100000 > app.log

echo "fixtures in $WORK_DIR"
