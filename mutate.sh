#!/usr/bin/env bash
# ============================================================================
# mutate.sh -- mutation testing for the conv_top verification environment
# ----------------------------------------------------------------------------
# A green testbench proves nothing until it can go red.  This script injects a
# known bug into the RTL one at a time, runs the full testbench, and confirms
# the testbench notices.  The original file is restored after every mutant
# (and on Ctrl-C, via the EXIT trap).
#
# Usage:
#   ./mutate.sh                # full regression per mutant (200 seeds)
#   SEEDS=25 ./mutate.sh       # faster sweep
#
# A mutant is CAUGHT if the run does not end with "ALL TESTS PASSED".
# COMPILE-FAIL is reported separately: the compiler rejecting a mutant is not
# evidence that the testbench would have detected it.
# ============================================================================
set -u

RTL="cnn_pkg.sv mem.sv mac_unit.sv input_unit.sv compute_unit.sv output_unit.sv conv_top.sv"
TB="tb_conv_top.sv"
SEEDS="${SEEDS:-200}"

cd "$(dirname "$0")" || exit 1

# Icarus is normally on PATH; fall back to the local install if it is not.
if ! command -v iverilog >/dev/null 2>&1; then
  export PATH="$PATH:/c/Users/kushk/Downloads/Installers & Software/Dev Tools/iverilog/bin"
fi
command -v iverilog >/dev/null 2>&1 || { echo "iverilog not found on PATH"; exit 1; }

caught=0; escaped=0; invalid=0; cfail=0; total=0
ESCAPED_LIST=""

restore_all() {
  for f in *.sv.mutbak; do
    [ -e "$f" ] && mv -f "$f" "${f%.mutbak}"
  done
  return 0
}
trap restore_all EXIT INT TERM

# run_mutant <id> <file> <description> <sed-expr>...
run_mutant() {
  local id="$1" file="$2" desc="$3"
  shift 3
  total=$((total + 1))

  cp "$file" "$file.mutbak"
  sed "$@" "$file.mutbak" > "$file"

  printf '\n[%s] %s\n' "$id" "$desc"
  printf '     file: %s\n' "$file"

  # The RTL is checked out with CRLF line endings and sed writes LF, so a plain
  # cmp reports "different" for every mutant even when the pattern never matched.
  # Compare with --strip-trailing-cr so a typo'd expression is actually caught
  # instead of being silently reported as a valid mutant.
  if diff -q --strip-trailing-cr "$file.mutbak" "$file" >/dev/null 2>&1; then
    echo "     !! SED DID NOT APPLY -- mutant was never injected, result meaningless"
    invalid=$((invalid + 1))
    mv -f "$file.mutbak" "$file"
    return
  fi
  diff --strip-trailing-cr "$file.mutbak" "$file" | grep '^[<>]' | sed 's/^/     /'

  if ! iverilog -g2012 -o mut.vvp $RTL $TB > mut_compile.log 2>&1; then
    echo "     COMPILE-FAIL -- rejected by the compiler, not detected by the testbench"
    head -3 mut_compile.log | sed 's/^/       /'
    cfail=$((cfail + 1))
    mv -f "$file.mutbak" "$file"
    return
  fi

  vvp mut.vvp +seeds="$SEEDS" > mut_run.log 2>&1

  if grep -q "ALL TESTS PASSED" mut_run.log; then
    echo "     *** ESCAPED *** -- the testbench did not detect this bug"
    ESCAPED_LIST="${ESCAPED_LIST}
       [$id] $desc"
    escaped=$((escaped + 1))
  else
    nfail=$(grep -c '^\[FAIL\]' mut_run.log)
    nseed=$(grep -c 'seed .* FAILED' mut_run.log)
    echo "     CAUGHT -- $nfail failing test(s), $nseed failing random seed(s)"
    grep '^\[FAIL\]' mut_run.log | head -6 | sed 's/^/       /'
    caught=$((caught + 1))
  fi

  mv -f "$file.mutbak" "$file"
}

echo "============================================================"
echo " MUTATION TESTING -- conv_top"
echo " $SEEDS random seeds per mutant"
echo "============================================================"

# --- 1 --------------------------------------------------------------------
run_mutant "M1" input_unit.sv "input_unit: swap out_row and out_col" \
  -e 's|out_row = i / OFM_W|out_row = i % OFM_W|' \
  -e 's|out_col = i % OFM_W|out_col = i / OFM_W|'

# --- 2 --------------------------------------------------------------------
run_mutant "M2" input_unit.sv "input_unit: swap tap_row and tap_col" \
  -e 's|tap_row = k / KS|tap_row = k % KS|' \
  -e 's|tap_col = k % KS|tap_col = k / KS|'

# --- 3 --------------------------------------------------------------------
run_mutant "M3" compute_unit.sv "compute_unit: b_raddr = k*P+j  ->  j*N_TAP+k" \
  -e 's|b_raddr = k \* P + j|b_raddr = j * N_TAP + k|'

# --- 4 --------------------------------------------------------------------
run_mutant "M4" conv_top.sv "conv_top: drop the k==0 qualifier from clear_acc" \
  -e 's|clear_acc = valid_in \&\& (k == 0)|clear_acc = valid_in|'

# --- 5 --------------------------------------------------------------------
run_mutant "M5" conv_top.sv "conv_top: j wrap condition P-1 -> P-2" \
  -e 's|if (j == P-1) begin|if (j == P-2) begin|'

# --- 6 --------------------------------------------------------------------
run_mutant "M6" output_unit.sv "output_unit: write address c_addr_d[LAT-1] -> [LAT-2]" \
  -e 's|\.waddr (c_addr_d\[LAT-1\])|.waddr (c_addr_d[LAT-2])|'

# --- 7 --------------------------------------------------------------------
run_mutant "M7" output_unit.sv "output_unit: write enable final_write -> valid_out" \
  -e 's|\.we *(final_write)|.we    (valid_out)|'

# --- 8 --------------------------------------------------------------------
run_mutant "M8" output_unit.sv "output_unit: address map i*P+j -> j*N_PATCH+i" \
  -e 's|c_addr_now *= i \* P + j|c_addr_now     = j * N_PATCH + i|'

# --- 9 --------------------------------------------------------------------
run_mutant "M9" cnn_pkg.sv "cnn_pkg: ACC_W 20 -> 18 (T5 must catch this)" \
  -e 's|localparam int ACC_W = 20|localparam int ACC_W = 18|'

# --------------------------------------------------------------------------
restore_all
rm -f mut.vvp mut_compile.log mut_run.log

echo ""
echo "============================================================"
echo " MUTATION SUMMARY"
echo "   mutants injected : $total"
echo "   caught           : $caught"
echo "   escaped          : $escaped"
echo "   compile-fail     : $cfail"
echo "   invalid (no-op)  : $invalid"
if [ "$escaped" -eq 0 ] && [ "$invalid" -eq 0 ] && [ "$cfail" -eq 0 ]; then
  echo "   VERDICT          : *** ALL MUTANTS CAUGHT ***"
else
  echo "   VERDICT          : *** REVIEW NEEDED ***"
  [ -n "$ESCAPED_LIST" ] && echo "   escaped mutants:$ESCAPED_LIST"
fi
echo "============================================================"

# Prove the RTL is byte-identical to what we started with.
if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
  if [ -z "$(git status --porcelain -- $RTL)" ]; then
    echo " RTL restored: clean (git reports no changes to any RTL file)"
  else
    echo " !! RTL NOT RESTORED -- git reports modifications:"
    git status --porcelain -- $RTL
    exit 1
  fi
fi

exit 0
