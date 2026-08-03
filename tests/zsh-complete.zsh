#!/usr/bin/env zsh
#
# Drives real zsh completion for one command line and prints what the shell
# produced, so the functional tests can assert on it.
#
#     zsh-complete.zsh <completions-dir> <scratch-dir> '<line to complete>' [tabs]
#
# zsh refuses to run a completion function outside a completion context, so the
# only faithful way to exercise `_quarto` is to type into a pseudo-terminal.

emulate -L zsh
zmodload zsh/zpty

local dir=$1 scratch=$2 line=$3
local -i tabs=${4:-1}

mkdir -p $scratch

zpty z "PS1='<PROMPT>' zsh -f -i"
zpty -w z "fpath=($dir \$fpath); autoload -Uz compinit; compinit -u -d $scratch/zcompdump; quarto(){ :; }"
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
local out="" chunk
repeat 40; do
  if zpty -rt z chunk 2>/dev/null; then
    out+=$chunk
  fi
  sleep 0.1
done

zpty -d z

# Strip the escape sequences a terminal would have consumed.
print -r -- ${out//$'\e'\[[0-9;?]#[a-zA-Z]/}
