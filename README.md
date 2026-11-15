# pyslam-pi-build

Builds the heavy C++ parts of [pySLAM](https://github.com/luigifreda/pyslam) (commit `a4e6a31`) for a
Raspberry Pi 5 running Raspberry Pi OS 13 (Debian trixie, arm64), on a free GitHub ARM64 runner
with more RAM than the Pi:

- pySLAM's GTSAM (`thirdparty/gtsam_local/install`)
- the `volumetric` module (`cpp/lib/volumetric*.so`)
- the C++ SLAM core (`cpp/core/slam/lib`)

Built inside `debian:trixie`, as user `pi`, at the same paths as on the Pi, with `-mcpu=cortex-a76`.
Run: Actions → build-pyslam-for-pi5 → Run workflow. Output: artifact `pyslam-pi-build`.
