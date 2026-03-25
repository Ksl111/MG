#!/bin/bash
###############################################################################
# check_dependencies.sh
# Проверка всех зависимостей для запуска MadGraph5 с моделью GldGrv_UFO
###############################################################################

set -euo pipefail

MG5_DIR="/afs/cern.ch/user/k/kslizhev/public/MG5_aMC_v2_9_24"
OUTPUT_DIR="/eos/user/k/kslizhev/MC_code/SUSY+GRV_diagrams"
MODEL_NAME="GldGrv_UFO"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ERRORS=0
WARNINGS=0

ok()   { echo -e "  [${GREEN}OK${NC}] $1"; }
warn() { echo -e "  [${YELLOW}WARN${NC}] $1"; ((WARNINGS++)); }
fail() { echo -e "  [${RED}FAIL${NC}] $1"; ((ERRORS++)); }

echo "============================================="
echo " MadGraph5 + GldGrv_UFO Dependency Check"
echo "============================================="
echo ""

# --- 1. Python ---
echo ">> Python"
if command -v python3 &>/dev/null; then
    PY_VER=$(python3 --version 2>&1)
    ok "python3 found: $PY_VER"
    # Check minimum version (3.7+)
    PY_MINOR=$(python3 -c "import sys; print(sys.version_info.minor)")
    if [ "$PY_MINOR" -ge 7 ]; then
        ok "Python version >= 3.7"
    else
        fail "Python version < 3.7 (MadGraph5 v2.9+ requires >= 3.7)"
    fi
elif command -v python &>/dev/null; then
    PY_VER=$(python --version 2>&1)
    warn "Only 'python' found (not python3): $PY_VER"
else
    fail "Python not found"
fi

# --- 2. Required Python modules ---
echo ""
echo ">> Python modules"
for mod in six numpy; do
    if python3 -c "import $mod" 2>/dev/null; then
        ok "$mod"
    else
        fail "$mod not installed (pip install $mod)"
    fi
done

# Optional but useful
for mod in matplotlib scipy; do
    if python3 -c "import $mod" 2>/dev/null; then
        ok "$mod (optional)"
    else
        warn "$mod not installed (optional, needed for plotting/analysis)"
    fi
done

# --- 3. Fortran compiler ---
echo ""
echo ">> Fortran compiler"
if command -v gfortran &>/dev/null; then
    FC_VER=$(gfortran --version | head -1)
    ok "gfortran found: $FC_VER"
elif command -v f77 &>/dev/null; then
    ok "f77 found"
else
    fail "No Fortran compiler found (gfortran required)"
fi

# --- 4. C++ compiler ---
echo ""
echo ">> C++ compiler"
if command -v g++ &>/dev/null; then
    CXX_VER=$(g++ --version | head -1)
    ok "g++ found: $CXX_VER"
else
    fail "g++ not found"
fi

# --- 5. Make ---
echo ""
echo ">> Build tools"
if command -v make &>/dev/null; then
    ok "make found"
else
    fail "make not found"
fi

if command -v automake &>/dev/null; then
    ok "automake found"
else
    warn "automake not found (may be needed for some packages)"
fi

# --- 6. MadGraph5 directory ---
echo ""
echo ">> MadGraph5 installation"
if [ -d "$MG5_DIR" ]; then
    ok "MG5 directory exists: $MG5_DIR"
else
    fail "MG5 directory not found: $MG5_DIR"
fi

MG5_BIN="$MG5_DIR/bin/mg5_aMC"
if [ -f "$MG5_BIN" ]; then
    ok "mg5_aMC executable found"
else
    fail "mg5_aMC executable not found at $MG5_BIN"
fi

# --- 7. UFO Model ---
echo ""
echo ">> UFO Model: $MODEL_NAME"
MODEL_PATH="$MG5_DIR/models/$MODEL_NAME"
if [ -d "$MODEL_PATH" ]; then
    ok "Model directory found: $MODEL_PATH"
    # Check key model files
    for f in particles.py parameters.py couplings.py lorentz.py vertices.py; do
        if [ -f "$MODEL_PATH/$f" ]; then
            ok "  $f"
        else
            fail "  $f missing in model"
        fi
    done
else
    fail "Model directory not found: $MODEL_PATH"
    echo "     Available models:"
    ls "$MG5_DIR/models/" 2>/dev/null | head -20 || echo "     (cannot list models)"
fi

# --- 8. Output directory ---
echo ""
echo ">> Output directory"
if [ -d "$OUTPUT_DIR" ]; then
    ok "Output directory exists: $OUTPUT_DIR"
else
    warn "Output directory does not exist: $OUTPUT_DIR"
    echo "     Will attempt to create it..."
    if mkdir -p "$OUTPUT_DIR" 2>/dev/null; then
        ok "Created output directory"
    else
        fail "Cannot create output directory (check EOS permissions/mount)"
    fi
fi

# Check write access
if [ -d "$OUTPUT_DIR" ]; then
    if touch "$OUTPUT_DIR/.write_test" 2>/dev/null; then
        rm -f "$OUTPUT_DIR/.write_test"
        ok "Write access to output directory confirmed"
    else
        fail "No write access to $OUTPUT_DIR"
    fi
fi

# --- 9. AFS/EOS access ---
echo ""
echo ">> Storage systems"
if command -v kinit &>/dev/null; then
    ok "kinit (Kerberos) available"
else
    warn "kinit not found (may need Kerberos for AFS/EOS)"
fi

if command -v eos &>/dev/null; then
    ok "EOS client available"
else
    warn "EOS client not found (direct EOS path access may still work via FUSE)"
fi

if [ -d "/afs" ]; then
    ok "/afs is mounted"
else
    warn "/afs is not mounted"
fi

if [ -d "/eos" ]; then
    ok "/eos is mounted"
else
    warn "/eos is not mounted"
fi

# --- 10. System resources ---
echo ""
echo ">> System resources"
TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}')
if [ -n "$TOTAL_MEM_KB" ]; then
    TOTAL_MEM_GB=$((TOTAL_MEM_KB / 1024 / 1024))
    if [ "$TOTAL_MEM_GB" -ge 4 ]; then
        ok "RAM: ${TOTAL_MEM_GB} GB (>= 4 GB recommended)"
    else
        warn "RAM: ${TOTAL_MEM_GB} GB (< 4 GB, cascade decays may be slow)"
    fi
fi

NCPU=$(nproc 2>/dev/null || echo "unknown")
if [ "$NCPU" != "unknown" ]; then
    ok "CPU cores: $NCPU"
else
    warn "Cannot determine CPU count"
fi

DISK_FREE=$(df -BG "$OUTPUT_DIR" 2>/dev/null | tail -1 | awk '{print $4}' | tr -d 'G')
if [ -n "$DISK_FREE" ] && [ "$DISK_FREE" -gt 0 ] 2>/dev/null; then
    if [ "$DISK_FREE" -ge 10 ]; then
        ok "Free disk space: ${DISK_FREE} GB"
    else
        warn "Free disk space: ${DISK_FREE} GB (recommend >= 10 GB)"
    fi
fi

# --- 11. Optional tools ---
echo ""
echo ">> Optional tools"
for tool in lhapdf wget curl gnuplot dot; do
    if command -v "$tool" &>/dev/null; then
        ok "$tool"
    else
        warn "$tool not found (optional)"
    fi
done

# Check LHAPDF
if command -v lhapdf-config &>/dev/null; then
    LHAPDF_VER=$(lhapdf-config --version 2>/dev/null)
    ok "LHAPDF: $LHAPDF_VER"
elif [ -f "$MG5_DIR/HEPTools/lhapdf6_py3/bin/lhapdf-config" ]; then
    ok "LHAPDF bundled with MG5"
else
    warn "LHAPDF not found (MG5 will use internal PDFs)"
fi

# --- Summary ---
echo ""
echo "============================================="
echo " Summary"
echo "============================================="
echo -e " Errors:   ${RED}${ERRORS}${NC}"
echo -e " Warnings: ${YELLOW}${WARNINGS}${NC}"
echo ""

if [ "$ERRORS" -eq 0 ]; then
    echo -e "${GREEN}All critical dependencies satisfied.${NC}"
    echo "You can proceed with running MadGraph5."
    exit 0
else
    echo -e "${RED}There are $ERRORS critical errors. Fix them before running MadGraph5.${NC}"
    exit 1
fi
