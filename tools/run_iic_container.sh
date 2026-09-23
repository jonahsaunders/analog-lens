#!/usr/bin/env bash
# Run from any directory; only the project checkout is mounted into the container.
set -euo pipefail
al_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
al_image=${ANALOG_LENS_IIC_IMAGE:-hpretl/iic-osic-tools:2026.08}
al_engine=${CONTAINER_ENGINE:-docker}
command -v "$al_engine" >/dev/null || { echo "Install Docker/Podman, or run tools/validate_iic.py inside IIC." >&2; exit 2; }
mkdir -p "$al_root/build/iic"
"$al_engine" pull "$al_image"
"$al_engine" image inspect "$al_image" > "$al_root/build/iic/image.json"
"$al_engine" run --rm --user "$(id -u):$(id -g)" --entrypoint /bin/bash \
    -e ANALOG_LENS_TEST_TMP=/tmp \
    -v "$al_root:/foss/designs/analog-lens" -w /foss/designs/analog-lens \
    "$al_image" -lc '
        set -e
        if [ -f /etc/profile.d/iic-osic-tools-setup.sh ]; then
            source /etc/profile.d/iic-osic-tools-setup.sh
        else
            source /headless/.bashrc
        fi
        cd /foss/designs/analog-lens
        xvfb-run -a -s "-screen 0 1440x1000x24" python3 tools/validate_iic.py --require-all --output build/iic "$@"
    ' analog-lens "$@"
