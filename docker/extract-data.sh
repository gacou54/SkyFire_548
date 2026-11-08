#!/usr/bin/env bash
#
# This file is part of Project SkyFire https://www.projectskyfire.org.
# See COPYRIGHT file for Copyright information
#
# Extracts server data from a 5.4.8 client mounted at $CLIENT_DIR into
# $DATA_DIR. Steps: any of "maps" (dbc + maps), "vmaps", "mmaps".
# Default: maps vmaps. mmaps take hours and are only needed with
# mmap.enablePathFinding = 1.
#
#   skyfire-extract-data [maps] [vmaps] [mmaps]

set -euo pipefail

CLIENT_DIR=${CLIENT_DIR:-/client}
DATA_DIR=${DATA_DIR:-/opt/skyfire/data}
steps=("$@")
(( ${#steps[@]} )) || steps=(maps vmaps)

if [[ ! -d $CLIENT_DIR/Data ]]; then
    echo "No WoW client found: $CLIENT_DIR/Data does not exist." >&2
    echo "Set WOW_CLIENT_DIR to the client folder (the one containing Data/)." >&2
    exit 1
fi

mkdir -p "$DATA_DIR"
cd "$DATA_DIR"

for step in "${steps[@]}"; do
    case $step in
        maps)
            echo "==> Extracting dbc and maps"
            mapextractor -i "$CLIENT_DIR" -o "$DATA_DIR"
            ;;
        vmaps)
            echo "==> Extracting and assembling vmaps"
            vmap4extractor -d "$CLIENT_DIR"
            mkdir -p vmaps
            vmap4assembler Buildings vmaps
            rm -rf Buildings
            ;;
        mmaps)
            echo "==> Generating mmaps"
            mkdir -p mmaps
            mmaps_generator --threads "${MMAPS_THREADS:-$(nproc)}"
            ;;
        *)
            echo "Unknown step: $step (expected maps, vmaps or mmaps)" >&2
            exit 1
            ;;
    esac
done

echo "==> Done. Contents of $DATA_DIR:"
ls "$DATA_DIR"
