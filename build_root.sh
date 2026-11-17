#!/bin/bash
# Runs as root inside debian:trixie. Sets up a 'pi' user with the same home path as the Pi,
# then runs the actual build as that user (so baked-in paths match /home/pi/...).
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends \
  sudo git curl wget ca-certificates lsb-release pkg-config file \
  build-essential cmake gcc g++ \
  libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev libffi-dev \
  liblzma-dev tk-dev libncurses-dev xz-utils uuid-dev patchelf

echo "gcc: $(gcc --version | head -1)"; echo "cmake: $(cmake --version | head -1)"

useradd -m -s /bin/bash -d /home/pi pi
echo "pi ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/pi
echo 'Defaults env_keep += "DEBIAN_FRONTEND"' >> /etc/sudoers.d/pi
chmod 440 /etc/sudoers.d/pi

mkdir -p /work/out/logs && chmod -R 777 /work/out
sudo -u pi -H env PYSLAM_COMMIT="$PYSLAM_COMMIT" DEBIAN_FRONTEND=noninteractive \
  bash /work/build_as_pi.sh
