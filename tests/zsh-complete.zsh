#!/usr/bin/env zsh
#
# Drives real zsh completion for one command line and prints what the shell
# produced, so the tests can assert on it.
#
#     zsh-complete.zsh fpath <completions-dir> <scratch-dir> '<line>' [tabs]
#     zsh-complete.zsh rc    <zdotdir>                       '<line>' [tabs]
#
# zsh refuses to run a completion function outside a completion context, so the
# only faithful way to exercise `_quarto` is to type into a pseudo-terminal.
#
# The two modes differ in what is trusted to put `_quarto` on `fpath`:
#
#   fpath  A directory handed in here, with a fresh dump. Tests the completion
#          script itself, isolated from how it was installed.
#   rc     Nothing but the `.zshrc` in <zdotdir>, so the shell starts without
#          -f and reads it. Tests that an installed layout actually works,
#          which is the part the fpath mode cannot see.

emulate -L zsh
zmodload zsh/zpty

local mode=$1
local setup line
local -i tabs

case $mode in
  fpath)
    local dir=$2 scratch=$3
    line=$4
    tabs=${5:-1}
    mkdir -p $scratch
    # -f skips every startup file, so this measures the completion script and
    # nothing else.
    boot="zsh -f -i"
    setup="fpath=($dir \$fpath); autoload -Uz compinit; compinit -u -d $scratch/zcompdump; quarto(){ :; }"
    ;;
  rc)
    local zdotdir=$2
    line=$3
    tabs=${4:-1}
    # Exported, not written as a `VAR=value command` prefix: zpty takes a
    # command and its arguments, not a shell command line, so a prefix would be
    # run as the command name. The child inherits this environment instead.
    export ZDOTDIR=$zdotdir HOME=$zdotdir
    # No -f, because reading the .zshrc under test is the whole point. -d drops
    # the global startup files so the result does not depend on what /etc holds
    # on the machine running the test.
    boot="zsh -d -i"
    # Only the stub command, so that a missing `_quarto` shows up as a filename
    # completion rather than as a command that does not exist.
    setup="quarto(){ :; }"
    ;;
  *)
    print -u2 "usage: zsh-complete.zsh fpath|rc ..."
    return 2
    ;;
esac

zpty z $boot
zpty -w z $setup

# Wait for the shell to echo the setup line back before typing anything. Under
# `rc` it is reading a .zshrc and running compinit, sometimes twice, and typing
# into a shell that has not finished starting loses the keystrokes: the drain
# below then returns nothing at all, which reads as a completion that produced
# no candidates. Ten seconds is a ceiling, not a delay; it breaks as soon as the
# echo arrives.
local ready="" chunk
repeat 100; do
  if zpty -rt z chunk 2>/dev/null; then
    ready+=$chunk
    if [[ $ready == *'quarto()'* ]]; then
      break
    fi
  fi
  sleep 0.1
done

zpty -w z ""

local keys=$line
repeat $tabs; do
  keys+=$'\t'
done

zpty -w -n z $keys

# Drain for a fixed four seconds. Exiting early on quiescence was tried and
# reverted: the pseudo-terminal goes quiet between the prompt redraw and the
# completion output, so on a loaded runner the read stopped before the
# candidates arrived. Four seconds of test time is worth the determinism.
local out=""
repeat 40; do
  if zpty -rt z chunk 2>/dev/null; then
    out+=$chunk
  fi
  sleep 0.1
done

zpty -d z

# Strip the escape sequences a terminal would have consumed.
print -r -- ${out//$'\e'\[[0-9;?]#[a-zA-Z]/}
