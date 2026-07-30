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
# ----------------------------------------------------------------------------
# WHY THIS SCRIPT DETECTS ITS TARGETS INSTEAD OF HARDCODING FILENAMES
#
# The design side maintains two microarchitectures:
#
#   1-MAC   input_unit.sv     + compute_unit.sv       (branch main)
#   4-MAC   input_unit_opt.sv + compute_unit_4mac.v   (branch final)
#
# Both sets of files can be sitting in the tree at the same time -- main
# currently carries all four -- so the presence of a file proves nothing about
# what is actually being built.  The configuration is therefore detected from
# the module names conv_top.sv actually instantiates, and each mutant is
# expressed as a (file, pattern) pair per variant.
#
# Where a bug has no counterpart in the other variant it is reported N/A, not
# invalid and not caught.  M5 is the example: it breaks the j filter counter,
# and the 4-MAC build unrolls j away entirely, so there is no j counter to
# break.  Calling that "caught" would be a lie and calling it "invalid" would
# imply the script is broken.
#
# ----------------------------------------------------------------------------
# OUTCOMES
#   CAUGHT        the testbench detected the injected bug            (good)
#   ESCAPED       the bug was injected and the testbench passed      (bad: gap)
#   N/A           this bug does not exist in the current variant     (expected)
#   INVALID       the pattern matched nothing -- mutant never injected
#   COMPILE-FAIL  the compiler rejected it, so the testbench never got a say
# ============================================================================
set -u

TB="tb_conv_top.sv"
SEEDS="${SEEDS:-200}"

cd "$(dirname "$0")" || exit 1

# Icarus is normally on PATH; fall back to the local install if it is not.
if ! command -v iverilog >/dev/null 2>&1; then
  export PATH="$PATH:/c/Users/kushk/Downloads/Installers & Software/Dev Tools/iverilog/bin"
fi
command -v iverilog >/dev/null 2>&1 || { echo "iverilog not found on PATH"; exit 1; }

caught=0; escaped=0; invalid=0; cfail=0; na=0; total=0
ESCAPED_LIST=""
INVALID_LIST=""

restore_all() {
  for f in *.mutbak; do
    [ -e "$f" ] && mv -f "$f" "${f%.mutbak}"
  done
  return 0
}
trap restore_all EXIT INT TERM

# ---------------------------------------------------------------------------
# Configuration detection
# ---------------------------------------------------------------------------
detect_config() {
  if grep -qE '^[[:space:]]*input_unit_opt[[:space:]]' conv_top.sv; then
    IN_VARIANT="opt";  IN_FILE="input_unit_opt.sv"
  elif grep -qE '^[[:space:]]*input_unit[[:space:]]' conv_top.sv; then
    IN_VARIANT="base"; IN_FILE="input_unit.sv"
  else
    echo "FATAL: cannot tell which input unit conv_top.sv instantiates"; exit 1
  fi

  if grep -qE '^[[:space:]]*compute_unit_4mac[[:space:]]' conv_top.sv; then
    CU_VARIANT="4mac"; CU_FILE="compute_unit_4mac.v"
  elif grep -qE '^[[:space:]]*compute_unit[[:space:]]' conv_top.sv; then
    CU_VARIANT="base"; CU_FILE="compute_unit.sv"
  else
    echo "FATAL: cannot tell which compute unit conv_top.sv instantiates"; exit 1
  fi

  # output_unit has two internal shapes: the 1-MAC one pipelines a full result
  # address (c_addr_d), the 4-MAC one pipelines only the patch index and walks
  # the four filters on write (patch_i_d / wr_addr).
  if grep -q 'patch_i_d' output_unit.sv; then
    OU_VARIANT="4mac"
  else
    OU_VARIANT="base"
  fi

  # A j filter counter only exists when the filter loop has not been unrolled.
  if grep -qE 'j == P-1' conv_top.sv; then HAS_J="yes"; else HAS_J="no"; fi

  RTL="cnn_pkg.sv mem.sv mac_unit.sv $IN_FILE $CU_FILE output_unit.sv conv_top.sv"

  for f in $RTL $TB; do
    [ -f "$f" ] || { echo "FATAL: detected file '$f' does not exist"; exit 1; }
  done
}

# ---------------------------------------------------------------------------
# Guard self-test
# ---------------------------------------------------------------------------
# TB-4 in BUGS.md was this guard being structurally dead: the repo has CRLF
# endings and sed writes LF, so `cmp -s` reported every file as changed and a
# pattern that matched nothing was silently accepted as a real mutant.  If that
# regresses, every CAUGHT below becomes meaningless, so the guard is re-verified
# in both directions on every run and the script refuses to continue if it is
# not working.
guard_selftest() {
  local f="cnn_pkg.sv" ok=1
  echo "--- Guard self-test (must fire before any result can be trusted) ---"

  cp "$f" "$f.mutbak"

  # Negative direction: a pattern matching nothing must read as "no change".
  sed -e 's|PATTERN_THAT_INTENTIONALLY_MATCHES_NOTHING|zzz|' "$f.mutbak" > "$f"
  if diff -q --strip-trailing-cr "$f.mutbak" "$f" >/dev/null 2>&1; then
    echo "    non-matching pattern -> correctly reported as no-op    [OK]"
  else
    echo "    non-matching pattern -> reported as a real mutation    [BROKEN]"
    ok=0
  fi

  # Positive direction: a pattern that does match must read as "changed".
  sed -e 's|localparam int ACC_W = 20|localparam int ACC_W = 19|' "$f.mutbak" > "$f"
  if diff -q --strip-trailing-cr "$f.mutbak" "$f" >/dev/null 2>&1; then
    echo "    real mutation        -> reported as no-op              [BROKEN]"
    ok=0
  else
    echo "    real mutation        -> correctly reported as changed  [OK]"
  fi

  mv -f "$f.mutbak" "$f"

  if [ "$ok" -ne 1 ]; then
    echo ""
    echo "FATAL: the did-not-apply guard is not working. Every CAUGHT result"
    echo "       this script could print would be untrustworthy. Aborting."
    exit 1
  fi
  echo ""
}

# ---------------------------------------------------------------------------
# run_mutant <id> <file> <description> <sed-expr>...
# ---------------------------------------------------------------------------
run_mutant() {
  local id="$1" file="$2" desc="$3"
  shift 3
  total=$((total + 1))

  printf '\n[%s] %s\n' "$id" "$desc"
  printf '     file: %s\n' "$file"

  cp "$file" "$file.mutbak"
  sed "$@" "$file.mutbak" > "$file"

  # CRLF-safe comparison -- see guard_selftest above.
  if diff -q --strip-trailing-cr "$file.mutbak" "$file" >/dev/null 2>&1; then
    echo "     INVALID -- pattern matched nothing, mutant never injected"
    invalid=$((invalid + 1))
    INVALID_LIST="${INVALID_LIST}
       [$id] $desc"
    mv -f "$file.mutbak" "$file"
    return
  fi
  diff --strip-trailing-cr "$file.mutbak" "$file" | grep '^[<>]' | sed 's/^/       /'

  if ! iverilog -g2012 -o mut.vvp $RTL $TB > mut_compile.log 2>&1; then
    echo "     COMPILE-FAIL -- rejected by the compiler, not detected by the testbench"
    grep -m3 -i 'error' mut_compile.log | sed 's/^/       /'
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
    grep '^\[FAIL\]' mut_run.log | head -4 | sed 's/^/       /'
    caught=$((caught + 1))
  fi

  mv -f "$file.mutbak" "$file"
}

skip_mutant() {
  local id="$1" desc="$2" why="$3"
  total=$((total + 1))
  na=$((na + 1))
  printf '\n[%s] %s\n' "$id" "$desc"
  printf '     N/A -- %s\n' "$why"
}

# ===========================================================================
detect_config

echo "============================================================"
echo " MUTATION TESTING -- conv_top"
echo "------------------------------------------------------------"
echo " detected configuration (from conv_top.sv instantiations):"
echo "   input unit   : $IN_FILE   [$IN_VARIANT]"
echo "   compute unit : $CU_FILE   [$CU_VARIANT]"
echo "   output unit  : output_unit.sv   [$OU_VARIANT]"
echo "   j counter    : $HAS_J"
echo "   build order  : $RTL"
echo "   seeds/mutant : $SEEDS"
echo "============================================================"
echo ""

guard_selftest

# --- M1 : swap the output row / column of the patch ------------------------
case "$IN_VARIANT" in
  base)
    # Double-buffered loader: the output position is next_row/next_col.
    run_mutant "M1" "$IN_FILE" "input_unit: swap output row/col in the window address" \
      -e 's|(next_row + load_count / KS) \* IFM_W|(next_col + load_count / KS) * IFM_W|' \
      -e 's|+ (next_col + load_count % KS);|+ (next_row + load_count % KS);|' ;;
  opt)
    # input_unit_opt takes out_row/out_col as inputs, so the equivalent bug
    # lives at the driver in conv_top.
    run_mutant "M1" "conv_top.sv" "conv_top: swap out_row/out_col driving input_unit_opt" \
      -e 's|out_row *= i / OFM_W|out_row = i % OFM_W|' \
      -e 's|out_col *= i % OFM_W|out_col = i / OFM_W|' ;;
esac

# --- M2 : swap the kernel tap row / column ---------------------------------
case "$IN_VARIANT" in
  base)
    run_mutant "M2" "$IN_FILE" "input_unit: swap tap row/col in the window address" \
      -e 's|(next_row + load_count / KS) \* IFM_W|(next_row + load_count % KS) * IFM_W|' \
      -e 's|+ (next_col + load_count % KS);|+ (next_col + load_count / KS);|' ;;
  opt)
    run_mutant "M2" "$IN_FILE" "input_unit_opt: swap tap_row/tap_col" \
      -e 's|tap_row = k / KS|tap_row = k % KS|' \
      -e 's|tap_col = k % KS|tap_col = k / KS|' ;;
esac

# --- M3 : transpose the weight address -------------------------------------
case "$CU_VARIANT" in
  base)
    run_mutant "M3" "$CU_FILE" "compute_unit: b_raddr k*P+j -> j*N_TAP+k" \
      -e 's|b_raddr = k \* P + j|b_raddr = j * N_TAP + k|' ;;
  4mac)
    # No j port; the per-MAC weight fetch indexes memB[(k*P)+f] instead.
    run_mutant "M3" "$CU_FILE" "compute_unit_4mac: weight index (k*P)+f -> (f*N_TAP)+k" \
      -e 's|memB\[(k \* P) + f\]|memB[(f * N_TAP) + k]|' ;;
esac

# --- M4 : accumulator never cleared at the start of a dot product ----------
# Both conv_tops write (k == '0); the quoted literal is why the old pattern,
# which looked for (k == 0), silently matched nothing on current main.
run_mutant "M4" "conv_top.sv" "conv_top: drop the k==0 qualifier from clear_acc" \
  -e "s|clear_acc *= valid_in && (k == '0)|clear_acc = valid_in|"

# --- M5 : filter counter wraps one filter early ----------------------------
if [ "$HAS_J" = "yes" ]; then
  run_mutant "M5" "conv_top.sv" "conv_top: j wrap condition P-1 -> P-2" \
    -e 's|if (j == P-1) begin|if (j == P-2) begin|'
else
  skip_mutant "M5" "conv_top: j wrap condition P-1 -> P-2" \
    "the $CU_VARIANT build unrolls the filter loop, so there is no j counter to break"
fi

# --- M6 : result address pipeline one stage short --------------------------
case "$OU_VARIANT" in
  base)
    run_mutant "M6" "output_unit.sv" "output_unit: write address c_addr_d[LAT-1] -> [LAT-2]" \
      -e 's|\.waddr (c_addr_d\[LAT-1\])|.waddr (c_addr_d[LAT-2])|' ;;
  4mac)
    # NOT patch_i_d[LAT-1] -> [LAT-2]: that one is algebraically equivalent and
    # escapes by construction.  patch_i_d[0] is loaded conditionally
    # (if (final_term_now)) and final_term_now only fires once every N_TAP
    # cycles, while the read happens LAT cycles later -- so for any LAT < N_TAP
    # every stage of patch_i_d holds the same value at the only moment any of
    # them is read.  (That also means patch_i_d is a redundant pipeline in this
    # design; see BUGS.md.)  The LAT alignment that actually does work here is
    # the marker pipeline, which decides when the four accumulators are
    # captured, so that is what a one-stage-short mutation must target.
    run_mutant "M6" "output_unit.sv" "output_unit: capture marker final_term_d[LAT-1] -> [LAT-2]" \
      -e 's|valid_out && final_term_d\[LAT-1\]|valid_out \&\& final_term_d[LAT-2]|' ;;
esac

# --- M7 : write on every retired term instead of only the last -------------
run_mutant "M7" "output_unit.sv" "output_unit: write enable final_write -> valid_out" \
  -e 's|\.we *(final_write)|.we    (valid_out)|'

# --- M8 : transpose the result address map ---------------------------------
case "$OU_VARIANT" in
  base)
    run_mutant "M8" "output_unit.sv" "output_unit: address map i*P+j -> j*N_PATCH+i" \
      -e 's|c_addr_now *= i \* P + j|c_addr_now = j * N_PATCH + i|' ;;
  4mac)
    run_mutant "M8" "output_unit.sv" "output_unit: address map wr_i*P+wr_filt -> wr_filt*N_PATCH+wr_i" \
      -e 's|wr_addr *= wr_i \* P + wr_filt|wr_addr = wr_filt * N_PATCH + wr_i|' ;;
esac

# --- M9 : accumulator two bits too narrow ----------------------------------
run_mutant "M9" "cnn_pkg.sv" "cnn_pkg: ACC_W 20 -> 18 (T5 must catch this)" \
  -e 's|localparam int ACC_W = 20|localparam int ACC_W = 18|'

# ---------------------------------------------------------------------------
restore_all
rm -f mut.vvp mut_compile.log mut_run.log

echo ""
echo "============================================================"
echo " MUTATION SUMMARY   [$IN_VARIANT input / $CU_VARIANT compute / $OU_VARIANT output]"
echo "   mutants considered : $total"
echo "   caught             : $caught"
echo "   escaped            : $escaped"
echo "   not applicable     : $na"
echo "   invalid (no-op)    : $invalid"
echo "   compile-fail       : $cfail"
if [ "$escaped" -eq 0 ] && [ "$invalid" -eq 0 ] && [ "$cfail" -eq 0 ]; then
  echo "   VERDICT            : *** ALL APPLICABLE MUTANTS CAUGHT ***"
else
  echo "   VERDICT            : *** REVIEW NEEDED ***"
  [ -n "$ESCAPED_LIST" ] && echo "   escaped:$ESCAPED_LIST"
  [ -n "$INVALID_LIST" ] && echo "   invalid (pattern needs retargeting):$INVALID_LIST"
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

if [ "$escaped" -ne 0 ] || [ "$invalid" -ne 0 ] || [ "$cfail" -ne 0 ]; then exit 1; fi
exit 0
