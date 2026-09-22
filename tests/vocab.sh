#!/usr/bin/env bash
# tests/vocab.sh — part of the smoke tier. Sourced by ../smoke-test.sh, which owns the
# CLI; this file only defines functions. Split out of the single 1,350-line
# smoke-test.sh (2026-09-22) so each tier is readable on its own — the
# external assessment's last open item. Shared helpers: tests/lib.sh.
# The verify VOCABULARY — used by both the dry tier (which asserts every
# runbook id resolves) and by verify itself. One owner, so they cannot drift.

# ── scenario id -> verify tokens ────────────────────────────────────────────
# THE single owner of this mapping. The runbook prints "-> verify S4" and this
# turns it into tokens, so the two vocabularies that used to be translated by
# hand (F item 4) can no longer drift: there is one thing to type, and the
# expansion is echoed at run time so it is never a black box.
# Exit 1 = a known id with nothing to audit; exit 2 = not an id at all.
scenario_tokens() {
  case "${1,,}" in
    s2|s3|s12|s13) echo "plain full" ;;
    s4)            echo "plain full desktop" ;;
    s5)            echo "plain full rootless" ;;
    s6)            echo "copy full" ;;
    s7|s9)         echo "golden-clone full" ;;
    s8)            echo "golden-clone full desktop" ;;
    s10)           echo "installsh" ;;
    s11)           echo "minimal plain" ;;
    s14)           echo "minimal plain rootless" ;;
    s15)           echo "plain full headless" ;;
    s1)            return 1 ;;   # lint+dry tier — there is no box end-state to audit
    *)             return 2 ;;
  esac
}

# Enforce the composition rules `scenarios` documents (F item 5). A rule that is
# only written down is a rule that silently does not hold — and the failure mode
# here is nasty: `verify full minimal` would print a wall of red for the wrong
# reason (each token correctly asserting the negation of the other) and read as a
# regression rather than as operator error.
_tok_has() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }

verify_validate() {
  local list="$*" conflict=""
  _tok_has plain "$list"     && _tok_has copy "$list" \
    && conflict="plain + copy — a box's dotfiles are symlinks or real files, not both"
  _tok_has plain "$list"     && _tok_has golden-clone "$list" \
    && conflict="plain + golden-clone — golden-clone implies copy mode"
  _tok_has full "$list"      && _tok_has minimal "$list" \
    && conflict="full + minimal — one asserts the GUI toolchain is present, the other that it is absent"
  _tok_has installsh "$list" && { _tok_has full "$list" || _tok_has minimal "$list" \
                                  || _tok_has golden-clone "$list"; } \
    && conflict="installsh + a provision profile — installsh REPLACES the core audit because install.sh has a different contract"
  _tok_has headless "$list"  && _tok_has desktop "$list" \
    && conflict="headless + desktop — headless asserts every GUI install is absent, desktop asserts GNOME is configured"
  [ -z "$conflict" ] && return 0
  echo "contradictory verify tokens: $conflict" >&2
  echo "see the vocabulary at the end of: bash smoke-test.sh scenarios" >&2
  exit 2
}
