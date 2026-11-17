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

# ---------------------------------------------------------------- 0. compiler wrappers (cannot be bypassed)
# Every C/C++ compile goes through these: they DROP any -march/-mtune/-mcpu=native that a script or a
# downloaded CMake project asks for, and always target the Pi 5 CPU. Stripped flags are counted in a log.
mkdir -p /home/pi/bin
for pair in "gcc-pi:/usr/bin/gcc" "g++-pi:/usr/bin/g++"; do
  name=${pair%%:*}; real=${pair#*:}
  cat > /home/pi/bin/$name <<EOF
#!/bin/bash
args=()
for a in "\$@"; do
  case "\$a" in
    -march=native|-mtune=native|-mcpu=native) echo "\$a" >> /work/out/logs/stripped_native_flags.log ;;
    *) args+=("\$a") ;;
  esac
done
exec $real "\${args[@]}" ${PI_CPU}
EOF
  chmod +x /home/pi/bin/$name
done
export CC=/home/pi/bin/gcc-pi CXX=/home/pi/bin/g++-pi
echo 'int main(){return 0;}' > /tmp/t.c && $CC -march=native /tmp/t.c -o /tmp/t && echo "wrapper OK" || die "compiler wrapper broken"

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
# pySLAM's scripts pass WITH_MARCH_NATIVE=ON / GTSAM_BUILD_WITH_MARCH_NATIVE=ON to every CMake build
# (GTSAM even makes -march=native PUBLIC, so it leaks into the core). Turn them off at the source.
grep -rlE "MARCH_NATIVE(=| *: *)ON|MARCH_NATIVE=\"?ON|MARCH_NATIVE ON" . --include=*.sh --include=CMakeLists.txt --include=*.cmake 2>/dev/null \
  | tee /work/out/logs/00_march_native_patched_files.txt \
  | xargs -r sed -i -E 's/(MARCH_NATIVE)=ON/\1=OFF/g; s/(MARCH_NATIVE)="ON"/\1="OFF"/g; s/(option\([A-Z_]*MARCH_NATIVE[^)]*)ON\)/\1OFF)/g'
grep -rnE "MARCH_NATIVE" --include=*.sh . | head -20 || true
export WITH_MARCH_NATIVE=OFF GTSAM_BUILD_WITH_MARCH_NATIVE=OFF
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
CFLAGS="" CXXFLAGS="" CC=/usr/bin/gcc CXX=/usr/bin/g++ pyenv install -s 3.11.9 > $LOG/02_python.log 2>&1 || die "python build failed (see 02_python.log)"
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
echo 'EXTERNAL_OPTIONS="${EXTERNAL_OPTIONS//-DWITH_MARCH_NATIVE=ON/-DWITH_MARCH_NATIVE=OFF} -DWITH_MARCH_NATIVE=OFF -DGTSAM_BUILD_WITH_MARCH_NATIVE=OFF"' >> scripts/tp_gtsam.sh
echo '$SCRIPTS_DIR/install_gtsam.sh $EXTERNAL_OPTIONS' >> scripts/tp_gtsam.sh
# install_gtsam.sh may hard-code the option in its own GTSAM_OPTIONS line
sed -i -E 's/GTSAM_BUILD_WITH_MARCH_NATIVE=ON/GTSAM_BUILD_WITH_MARCH_NATIVE=OFF/g' scripts/install_gtsam.sh
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
  echo; echo "== compiler used by each shipped part (must be the -pi wrappers):"
  : > /work/out/compiler_check_failed.txt
  for c in cpp/core/slam/build cpp/build thirdparty/gtsam_local/build thirdparty/gtsam_factors/build; do
    f=$c/CMakeCache.txt
    if [ -f $f ]; then
      cc=$(grep -E "^CMAKE_CXX_COMPILER:" $f | cut -d= -f2)
      echo "$c -> $cc"
      [[ "$cc" == */g++-pi ]] || echo "$c" >> /work/out/compiler_check_failed.txt
    else
      echo "$c -> (no CMakeCache)"
    fi
  done
  echo; echo "== native flags requested by build files (harmless now, stripped by the wrapper):"
  grep -rlE -- "-march=native|-mcpu=native|-mtune=native" --include=flags.make . 2>/dev/null | grep -vE "/(timing|tests?|examples?)/" | head -20 || true
  echo "stripped at compile time: $(wc -l < /work/out/logs/stripped_native_flags.log 2>/dev/null || echo 0) times"
  echo; echo "== GTSAM public compile options:"; grep -E "GTSAM_COMPILE_OPTIONS_PUBLIC|BUILD_WITH_MARCH_NATIVE" $LOG/05_gtsam.log | head -5
  echo; echo "== shared libs needed by the C++ core:"; ldd cpp/core/slam/lib/cpp_core*.so 2>/dev/null | grep -vE "linux-vdso|ld-linux" | awk '{print $1, $3}' | head -40
  echo; echo "== volumetric:";  ls -la cpp/lib/volumetric*.so 2>&1
  echo; echo "== C++ core:";    ls -la cpp/core/slam/lib 2>&1
  echo; echo "== gtsam_local:"; ls thirdparty/gtsam_local/install/lib 2>&1 | head -20
  echo; echo "== import test (Python side, C++ modules):"
  cd cpp/lib && python -c "import volumetric; print('volumetric import OK')" 2>&1 | tail -2; cd $ROOT
  cd cpp/core/slam/lib 2>/dev/null && python -c "import cpp_core; print('cpp_core import OK')" 2>&1 | tail -12; cd $ROOT
  echo "(cpp_core may fail here only because this minimal env lacks pySLAM's Python deps; the real test is on the Pi)"
  echo; echo "== GTSAM python package (must be the 4.2 build, matching gtsam_factors):"
  python -c "import gtsam, os; print('gtsam', getattr(gtsam,'__version__','?'), os.path.dirname(gtsam.__file__))" 2>&1 | tail -2
  ls -d $VENV/lib/python3.11/site-packages/gtsam* 2>&1
  echo; echo "== gtsam + gtsam_factors together:"
  PYTHONPATH=thirdparty/gtsam_factors/lib python -c "import gtsam, gtsam_factors; print('gtsam + gtsam_factors import OK')" 2>&1 | tail -3
} > $REPORT 2>&1
cat $REPORT

PACK=()
for p in cpp/core/slam/lib thirdparty/gtsam_local/install; do [ -e "$p" ] && PACK+=("home/pi/capstone_files/pyslam/$p"); done
for f in cpp/lib/volumetric*.so; do [ -e "$f" ] && PACK+=("home/pi/capstone_files/pyslam/$f"); done
while IFS= read -r f; do PACK+=("home/pi/capstone_files/pyslam/$f"); done < <(find thirdparty/gtsam_factors -name "*.so*" 2>/dev/null)
# GTSAM 4.2 python package (gtsam, gtsam_unstable + dist-info) so gtsam_factors' pybind types match on the Pi
python -c "import gtsam" 2>/dev/null || { [ -d thirdparty/gtsam_local/build/python ] && pip install -q thirdparty/gtsam_local/build/python > $LOG/08_gtsam_py.log 2>&1; }
PYTHONPATH=thirdparty/gtsam_factors/lib python -c "import gtsam, gtsam_factors" || die "gtsam + gtsam_factors do not import together"
# pack wherever python ACTUALLY loads gtsam / gtsam_unstable from (may be the build tree via a .pth/editable link)
for m in gtsam gtsam_unstable; do
  d=$(python -c "import $m, os; print(os.path.dirname($m.__file__))" 2>/dev/null) || continue
  echo "$m loads from: $d" | tee -a /work/out/build_report.txt
  [ -n "$d" ] && PACK+=("${d#/}")
done
# plus any gtsam-related link/metadata files in site-packages (.pth, egg-link, dist-info, editable finders)
while IFS= read -r f; do PACK+=("${f#/}"); done < <(find $VENV/lib/python3.11/site-packages -maxdepth 1 -iname "*gtsam*" 2>/dev/null)
# and any of OUR libraries those python extensions load (e.g. libgtsam.so.4 from the build tree)
for p in "${PACK[@]}"; do
  find "/$p" -name "*.so*" -type f 2>/dev/null
done | xargs -r ldd 2>/dev/null | awk '/=> \/home\/pi\/capstone_files/ {print $3}' | sort -u | while read -r lib; do
  real=$(readlink -f "$lib"); echo "${lib#/}"; echo "${real#/}"
done > /work/out/extra_libs.txt
while IFS= read -r f; do [ -n "$f" ] && PACK+=("$f"); done < /work/out/extra_libs.txt
echo "extra libs packed:"; cat /work/out/extra_libs.txt
[ ${#PACK[@]} -gt 0 ] || die "nothing built to pack"
printf '%s\n' "${PACK[@]}" | tee /work/out/pack_list.txt
tar -C / -czf /work/out/pyslam_pi_build.tar.gz "${PACK[@]}"
ls -lh /work/out/pyslam_pi_build.tar.gz
# list to a file first: 'tar | grep -q' + pipefail gives a false failure (SIGPIPE when grep exits early)
tar -tzf /work/out/pyslam_pi_build.tar.gz > /work/out/archive_list.txt || die "cannot list archive"
echo "archive entries: $(wc -l < /work/out/archive_list.txt)" | tee -a /work/out/build_report.txt
grep -E "/gtsam/__init__\.py$|gtsam.*\.(pth|egg-link)$|gtsam.*dist-info/?$|gtsam_factors.*\.so" /work/out/archive_list.txt | tee -a /work/out/build_report.txt
grep -qE "/gtsam/__init__\.py$" /work/out/archive_list.txt || die "archive has no gtsam/__init__.py - GTSAM python package not packed"
[ -d cpp/core/slam/lib ] || die "C++ core did not build (see 07_core.log)"
# every shipped .so must resolve all its libraries from paths that exist on the Pi too
# (system libs, or files inside this archive). libpython is provided by the Pi's own python at import time.
: > /work/out/missing_libs.txt
grep -E "\.so(\.[0-9]+)*$" /work/out/archive_list.txt | while read -r so; do
  [ -f "/$so" ] || continue
  ldd "/$so" 2>/dev/null | grep "not found" | grep -v "libpython3" | sed "s#^#$so: #" >> /work/out/missing_libs.txt || true
  ldd "/$so" 2>/dev/null | awk '/=> \/home\/pi\// {print $3}' | while read -r dep; do
    case "$dep" in
      /home/pi/.pyenv/*) continue ;;   # the Pi has the same pyenv python 3.11.9
      /home/pi/capstone_files/pyslam/thirdparty/json/*|/home/pi/capstone_files/pyslam/thirdparty/qhull/*|\
      /home/pi/capstone_files/pyslam/thirdparty/orbslam2_features/*|/home/pi/capstone_files/pyslam/thirdparty/pangolin/*|\
      /home/pi/capstone_files/pyslam/thirdparty/g2o/*|/home/pi/capstone_files/pyslam/thirdparty/pydbow*/*|\
      /home/pi/capstone_files/pyslam/thirdparty/pyibow/*|/home/pi/capstone_files/pyslam/cpp/lib/*)
        continue ;;                    # built on the Pi itself already (same sources, same paths)
    esac
    grep -qxF "${dep#/}" /work/out/archive_list.txt || grep -qxF "$(readlink -f "$dep" | sed 's#^/##')" /work/out/archive_list.txt \
      || echo "$so: needs $dep (not in archive, not on the Pi)" >> /work/out/missing_libs.txt
  done
done
echo "== library check:" | tee -a /work/out/build_report.txt
if [ -s /work/out/missing_libs.txt ]; then cat /work/out/missing_libs.txt | tee -a /work/out/build_report.txt; die "some shipped libraries have unresolved dependencies (see above)"; fi
echo "all shipped libraries resolve (libpython comes from the Pi's python)" | tee -a /work/out/build_report.txt
[ -s /work/out/compiler_check_failed.txt ] && die "these parts were NOT built with the Pi-safe compiler wrapper: $(cat /work/out/compiler_check_failed.txt | tr '\n' ' ')"
echo "Pi-safe: every shipped part was compiled through the wrapper (-mcpu=cortex-a76, no native flags)."
echo "DONE"
