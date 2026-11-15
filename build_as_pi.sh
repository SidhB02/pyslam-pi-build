#!/bin/bash
# Runs as user 'pi' (home /home/pi) inside debian:trixie on an ARM64 runner.
# Builds the parts that ran out of memory on the Pi: pySLAM's GTSAM, the 'volumetric'
# module and the C++ SLAM core, at the SAME paths as on the Pi, then packs only those.
set -uxo pipefail
LOG=/work/out/logs; mkdir -p $LOG
ROOT=/home/pi/capstone_files/pyslam
VENV=/home/pi/.python/venvs/pyslam
PI_CPU="-mcpu=cortex-a76"        # Raspberry Pi 5 CPU. Never use -march=native here (runner CPU has SVE2; Pi would crash).
step(){ echo; echo "================ $* ================"; }
die(){ echo "FATAL: $*"; exit 1; }

# ---------------------------------------------------------------- 1. pySLAM source (same commit as the Pi)
step "clone pySLAM ${PYSLAM_COMMIT}"
mkdir -p /home/pi/capstone_files && cd /home/pi/capstone_files
git init -q pyslam && cd pyslam
git remote add origin https://github.com/luigifreda/pyslam.git
git fetch -q --depth 1 origin "$PYSLAM_COMMIT" || die "cannot fetch commit"
git checkout -q FETCH_HEAD
git log -1 --oneline

# Make every build target the Pi 5 CPU and use fewer parallel jobs
step "patch build flags for Pi 5 CPU"
grep -rlE -- "-march=native|-mtune=native" --include=CMakeLists.txt --include=*.cmake --include=*.sh . 2>/dev/null \
  | xargs -r sed -i -E "s/-march=native/${PI_CPU}/g; s/-mtune=native//g"
grep -rlE 'make -j ?\$\(nproc\)' --include=*.sh . | xargs -r sed -i -E 's/make -j ?\$\(nproc\)/make -j3/g'
sed -i -E 's/make -j ?4\b/make -j2/' cpp/build.sh
export CFLAGS="${PI_CPU}" CXXFLAGS="${PI_CPU}"
export MAKEFLAGS="-j3" CMAKE_BUILD_PARALLEL_LEVEL=3 WITH_PYTHON_INTERP_CHECK=ON

# ---------------------------------------------------------------- 2. system packages (same script as on the Pi)
step "system packages"
./scripts/install_system_packages.sh > $LOG/01_system_packages.log 2>&1 || echo "WARN: some packages failed (embree3 is expected)"
sudo apt-get install -y libembree-dev >> $LOG/01_system_packages.log 2>&1 || true

# ---------------------------------------------------------------- 3. Python 3.11.9 via pyenv + venv at the Pi's path
step "python 3.11.9 (pyenv)"
git clone -q --depth 1 https://github.com/pyenv/pyenv.git /home/pi/.pyenv
export PYENV_ROOT=/home/pi/.pyenv PATH=/home/pi/.pyenv/bin:$PATH
CFLAGS="" CXXFLAGS="" pyenv install -s 3.11.9 > $LOG/02_python.log 2>&1 || die "python build failed (see 02_python.log)"
mkdir -p /home/pi/.python/venvs
/home/pi/.pyenv/versions/3.11.9/bin/python -m venv $VENV
source $VENV/bin/activate
python --version
pip install -q --upgrade pip setuptools wheel
pip install -q "numpy==1.26.4" "pybind11==2.13.1" pyparsing > $LOG/03_pip.log 2>&1 || die "pip failed"

# ---------------------------------------------------------------- 4. thirdparty (same trimmed set as on the Pi) + GTSAM
step "thirdparty: json, qhull, orbslam2_features, pangolin, g2o, dbow, ibow"
head -146 scripts/install_thirdparty.sh > scripts/install_thirdparty_min.sh
bash scripts/install_thirdparty_min.sh > $LOG/04_thirdparty.log 2>&1 || echo "WARN: thirdparty returned non-zero"
grep -nE "error:|Error [0-9]|FAILED" $LOG/04_thirdparty.log | head -20 || true

step "GTSAM (pySLAM's own version)"
# header of install_thirdparty.sh (sets EXTERNAL_OPTIONS etc.) + the gtsam call only
awk '/Configuring and building thirdparty\//{exit} {print}' scripts/install_thirdparty.sh > scripts/tp_gtsam.sh
echo '$SCRIPTS_DIR/install_gtsam.sh $EXTERNAL_OPTIONS' >> scripts/tp_gtsam.sh
bash scripts/tp_gtsam.sh > $LOG/05_gtsam.log 2>&1 || echo "WARN: gtsam returned non-zero"
grep -nE "error:|FAILED|Killed" $LOG/05_gtsam.log | head -20 || true
ls thirdparty/gtsam_local/install/lib 2>/dev/null | head || echo "NO gtsam_local/install"

# ---------------------------------------------------------------- 5. cpp/ modules (incl. volumetric) + C++ core
step "cpp modules (volumetric)"
bash scripts/install_cpp.sh > $LOG/06_cpp.log 2>&1 || echo "WARN: install_cpp returned non-zero"
grep -nE "error:|Killed|FAILED" $LOG/06_cpp.log | head -20 || true

step "C++ SLAM core"
bash build_cpp_core.sh > $LOG/07_core.log 2>&1 || echo "WARN: core returned non-zero"
grep -nE "error:|Killed|FAILED" $LOG/07_core.log | head -30 || true

# ---------------------------------------------------------------- 6. verify + pack only what the Pi is missing
step "verify"
REPORT=/work/out/build_report.txt
{
  echo "pySLAM commit: $(git rev-parse HEAD)"
  echo "built: $(date -u)  | $(gcc --version | head -1) | $(python --version)"
  echo; echo "== native-CPU flags left in build files (must be empty):"
  grep -rlE -- "-march=native|-mcpu=native" --include=flags.make . 2>/dev/null | head || true
  echo; echo "== volumetric:";  ls -la cpp/lib/volumetric*.so 2>&1
  echo; echo "== C++ core:";    ls -la cpp/core/slam/lib 2>&1
  echo; echo "== gtsam_local:"; ls thirdparty/gtsam_local/install/lib 2>&1 | head -20
  echo; echo "== import test (Python side, C++ modules):"
  cd cpp/lib && python -c "import volumetric; print('volumetric import OK')" 2>&1 | tail -2; cd $ROOT
  cd cpp/core/slam/lib 2>/dev/null && python -c "import cpp_core; print('cpp_core import OK')" 2>&1 | tail -2; cd $ROOT
} > $REPORT 2>&1
cat $REPORT

PACK=()
for p in cpp/core/slam/lib thirdparty/gtsam_local/install; do [ -e "$p" ] && PACK+=("home/pi/capstone_files/pyslam/$p"); done
for f in cpp/lib/volumetric*.so; do [ -e "$f" ] && PACK+=("home/pi/capstone_files/pyslam/$f"); done
while IFS= read -r f; do PACK+=("home/pi/capstone_files/pyslam/$f"); done < <(find thirdparty/gtsam_factors -name "*.so*" 2>/dev/null)
[ ${#PACK[@]} -gt 0 ] || die "nothing built to pack"
printf '%s\n' "${PACK[@]}" | tee /work/out/pack_list.txt
tar -C / -czf /work/out/pyslam_pi_build.tar.gz "${PACK[@]}"
ls -lh /work/out/pyslam_pi_build.tar.gz
[ -d cpp/core/slam/lib ] || die "C++ core did not build (see 07_core.log)"
echo "DONE"
