#  zsh-llm-correct.plugin.zsh
#  Auto-suggest a fix from a local Ollama model when a command fails.
#  Streams the suggestion as `{fixed command} ?` and lets the user accept
#  with <Enter>/y, or reject with anything else.
#
#  Configurable via env vars (set in ~/.zshrc BEFORE plugins=(...) line):
#    ZSH_LLM_CORRECT_OLLAMA_URL    default: http://localhost:11434
#    ZSH_LLM_CORRECT_MODEL         default: qwen2.5:7b
#    ZSH_LLM_CORRECT_DISABLE       set to 1 to silence without unloading
#    ZSH_LLM_CORRECT_MIN_LEN       ignore commands shorter than N chars (default 2)
#    ZSH_LLM_CORRECT_HISTORY_LIMIT recent commands to remember (default 5, 0 = off)
#    ZSH_LLM_CORRECT_OUTPUT_LIMIT  max chars per captured output snippet (default 256)
#    ZSH_LLM_CORRECT_CONTEXT_LIMIT total context byte budget, ~4 bytes/token (default 4096)
#    ZSH_LLM_CORRECT_CAPTURE_OUTPUT 1 to enable session-wide stderr capture (default 0)

: ${ZSH_LLM_CORRECT_OLLAMA_URL:=http://localhost:11434}
: ${ZSH_LLM_CORRECT_MODEL:=qwen2.5:7b}
: ${ZSH_LLM_CORRECT_MIN_LEN:=2}
: ${ZSH_LLM_CORRECT_PATH_LIMIT:=80}
: ${ZSH_LLM_CORRECT_FN_LIMIT:=60}
: ${ZSH_LLM_CORRECT_AL_LIMIT:=60}
: ${ZSH_LLM_CORRECT_HISTORY_LIMIT:=0}    # 0 = OFF (default). Try 3-5 with bigger models.
: ${ZSH_LLM_CORRECT_OUTPUT_LIMIT:=256}   # max chars per captured stderr snippet
: ${ZSH_LLM_CORRECT_CONTEXT_LIMIT:=4096} # total context byte budget (~1024 tokens)
: ${ZSH_LLM_CORRECT_CAPTURE_OUTPUT:=1}   # 1 = ON. Captures stderr of failed cmds for the model.
: ${ZSH_LLM_CORRECT_DEBUG:=0}            # 1 = print prompt + raw response for troubleshooting

# Why the conversational features default OFF:
#   In testing with qwen2.5:7b, providing recent shell history as context
#   regressed many cases. The model would copy tokens from history into the
#   fix (e.g., `gss` after `split foo.tar.gz -b 40M` became
#   `gs split foo.tar.gz -b 40M`). Even an explicit "do not copy from this"
#   instruction in the prompt was unreliable. Larger models (qwen2.5:14b
#   or qwen2.5:32b, both via `ollama pull`) handle the extra context much
#   more sanely. If you have the VRAM, set ZSH_LLM_CORRECT_MODEL=qwen2.5:14b
#   alongside ZSH_LLM_CORRECT_HISTORY_LIMIT=5 to enable history-aware fixes.

typeset -g  _zsh_llm_correct_last_cmd=""
typeset -ga _zsh_llm_correct_history          # recent "exit_code\tcmd" entries
typeset -g  _zsh_llm_correct_stderr_log=""    # path to per-session stderr tee log

# Detect OS once at plugin load. The model defaults to GNU coreutils syntax
# (`ps --sort=`, `sed -i ''`) which fails on BSD/macOS. Telling the model
# which utility flavor is installed lets it pick the right flags.
typeset -g _zsh_llm_correct_os_info=""
{
  local _uname_s="$(uname -s 2>/dev/null)"
  case "$_uname_s" in
    Darwin) _zsh_llm_correct_os_info="Darwin (macOS) — BSD utilities. Use BSD flags: 'ps -A -r' to sort by CPU (NOT 'ps --sort=-pcpu'), 'sed -i ''' for in-place edit (NOT 'sed -i'), 'find -E' for ERE, 'tar' supports -z/-j but not GNU long options." ;;
    Linux)  _zsh_llm_correct_os_info="Linux — GNU coreutils. Use long options freely (--sort=, --color=, etc.)." ;;
    *BSD)   _zsh_llm_correct_os_info="$_uname_s — BSD utilities (no GNU long options)." ;;
    *)      _zsh_llm_correct_os_info="$_uname_s" ;;
  esac
}

# ---- session-wide stderr capture (opt-in) -----------------------------------
# When ZSH_LLM_CORRECT_CAPTURE_OUTPUT=1 we duplicate the shell's stderr through
# a tee that appends to a tempfile. Each `preexec` truncates the file so what
# remains is just the most recent command's stderr. We never read more than
# ZSH_LLM_CORRECT_OUTPUT_LIMIT bytes back into context.
#
# Caveats: this is a session-global redirect. tty programs (vim, less, ssh
# password prompts) keep working because tee passes through, but ANSI
# escapes and progress bars can pollute the log slightly. We strip ANSI
# before sending to the model.
_zsh_llm_correct_init_capture() {
  [[ "$ZSH_LLM_CORRECT_CAPTURE_OUTPUT" != "1" ]] && return
  [[ -n "$_zsh_llm_correct_stderr_log" ]] && return     # already initialized
  _zsh_llm_correct_stderr_log="$(mktemp -t zsh-llm-correct-stderr.XXXXXX 2>/dev/null)" || return
  exec 2> >(tee -a "$_zsh_llm_correct_stderr_log" >&2)
  zshexit_functions+=(_zsh_llm_correct_cleanup)
}
_zsh_llm_correct_cleanup() {
  [[ -n "$_zsh_llm_correct_stderr_log" && -f "$_zsh_llm_correct_stderr_log" ]] && \
    rm -f "$_zsh_llm_correct_stderr_log"
}

_zsh_llm_correct_preexec() {
  _zsh_llm_correct_last_cmd="$1"
  # Reset the stderr log so it only holds THIS command's output.
  if [[ -n "$_zsh_llm_correct_stderr_log" && -f "$_zsh_llm_correct_stderr_log" ]]; then
    : > "$_zsh_llm_correct_stderr_log"
  fi
}

_zsh_llm_correct_precmd() {
  local exit_code=$?
  local cmd="$_zsh_llm_correct_last_cmd"
  _zsh_llm_correct_last_cmd=""

  # Always record the recent command (regardless of exit), so the next
  # failure has a few lines of context to reference. Using $'\t' as a
  # safe delimiter — exit codes are integers, never contain tabs.
  if [[ -n "$cmd" && $ZSH_LLM_CORRECT_HISTORY_LIMIT -gt 0 ]]; then
    _zsh_llm_correct_history+=( "${exit_code}"$'\t'"${cmd}" )
    while (( ${#_zsh_llm_correct_history} > ZSH_LLM_CORRECT_HISTORY_LIMIT )); do
      shift _zsh_llm_correct_history
    done
  fi

  [[ -n "$ZSH_LLM_CORRECT_DISABLE" ]] && return
  (( exit_code == 0 )) && return
  [[ -z "$cmd" ]] && return
  (( ${#cmd} < ZSH_LLM_CORRECT_MIN_LEN )) && return

  # Skip user-interrupted / signal exits — those aren't typos.
  case $exit_code in
    130|131|137|143|146|148) return ;;
  esac

  # Skip our own helper invocations and obvious non-typos.
  case "$cmd" in
    llm-fix*|cd|ls|pwd|clear|exit|logout) return ;;
  esac

  _zsh_llm_correct_suggest "$cmd" "$exit_code"
}

_zsh_llm_correct_dl_candidates() {
  # Rank EVERY known command (PATH execs + aliases + functions) by
  # Damerau-Levenshtein distance to the failed token, return the closest
  # few names. This is what catches typos like `ddust -> dust` where the
  # intended command shares no prefix with what the user typed.
  #
  # Args: $1 = typo, $2 = max distance (default 3), $3 = top N (default 8)
  emulate -L zsh
  local typo="$1"
  local max_dist="${2:-3}"
  local top_n="${3:-8}"
  (( ${#typo} == 0 )) && return

  rehash 2>/dev/null
  local -a candidates fn_list
  fn_list=( ${(k)functions} )
  fn_list=( ${fn_list:#_*} )
  fn_list=( ${fn_list:#-*} )
  fn_list=( ${fn_list:#llm-fix} )
  fn_list=( ${fn_list:#add-zsh-hook} )
  candidates=( ${(ko)commands} ${(k)aliases} $fn_list )
  candidates=( ${(u)candidates} )            # dedupe
  candidates=( ${candidates:#${typo}} )      # skip exact match

  print -l -- $candidates | awk -v typo="$typo" -v max="$max_dist" '
    function dl(a, b,   la, lb, diff, i, j, cost, d) {
      la = length(a); lb = length(b)
      if (la == 0) return lb; if (lb == 0) return la
      # Cheap pre-filter: if length difference already exceeds max, skip
      # the full DP. Saves real time when scanning thousands of names.
      diff = (la > lb) ? la - lb : lb - la
      if (diff > max) return max + 1
      for (i = 0; i <= la; i++) d[i, 0] = i
      for (j = 0; j <= lb; j++) d[0, j] = j
      for (i = 1; i <= la; i++)
        for (j = 1; j <= lb; j++) {
          cost = (substr(a, i, 1) == substr(b, j, 1)) ? 0 : 1
          d[i, j] = d[i-1, j] + 1
          if (d[i, j-1] + 1 < d[i, j]) d[i, j] = d[i, j-1] + 1
          if (d[i-1, j-1] + cost < d[i, j]) d[i, j] = d[i-1, j-1] + cost
          if (i > 1 && j > 1 \
              && substr(a, i, 1)   == substr(b, j-1, 1) \
              && substr(a, i-1, 1) == substr(b, j, 1)) {
            if (d[i-2, j-2] + cost < d[i, j]) d[i, j] = d[i-2, j-2] + cost
          }
        }
      return d[la, lb]
    }
    { d = dl(typo, $1); if (d <= max) printf "%d %s\n", d, $1 }
  ' | sort -n -k1,1 -k2,2 | head -n "$top_n"
}

_zsh_llm_correct_build_context() {
  # Surface user-specific commands the model can't know from training:
  #   • aliases & functions whose names share a 2-char prefix with the typo
  #   • PATH executables whose names contain the typo as a substring —
  #     ONLY when the typo doesn't resolve at all (command-not-found case).
  #     If the command exists, dumping similar names tempts the model to
  #     rename it (`split` -> `split_file`) instead of fixing the args.
  # We deliberately do NOT dump every PATH command starting with the typo's
  # first letter — that wall of text drowns signal in small local models.
  emulate -L zsh
  local first="$1"
  local cmd_exists="$2"   # "1" if `first` resolves, empty otherwise
  (( ${#first} == 0 )) && { print -r -- ""; return }

  local prefix
  if (( ${#first} >= 2 )); then prefix="${first[1,2]}"; else prefix="${first[1]}"; fi

  local ctx=""
  local -a names

  # Aliases — names only. Showing `name=value` made the model "expand" the
  # alias inline (`gp orign main` -> `gp push origin main`).
  names=( ${(M)${(k)aliases}:#${prefix}*} )
  if (( ${#names} > 0 )); then
    ctx+="User-defined aliases (use the alias NAME, do not expand): ${(j: :)names[1,$ZSH_LLM_CORRECT_AL_LIMIT]}
"
  fi

  # Functions — names only; skip private (_foo) and autoload noise.
  local -a fn_list
  fn_list=( ${(k)functions} )
  fn_list=( ${fn_list:#_*} )
  fn_list=( ${fn_list:#-*} )
  fn_list=( ${fn_list:#llm-fix} )
  fn_list=( ${fn_list:#add-zsh-hook} )
  fn_list=( ${(M)fn_list:#${prefix}*} )
  if (( ${#fn_list} > 0 )); then
    ctx+="User-defined functions: ${(j: :)fn_list[1,$ZSH_LLM_CORRECT_FN_LIMIT]}
"
  fi

  # Edit-distance ranked candidates — only for NOT-FOUND. Replaces the
  # old substring-match approach which missed transposition typos like
  # `ddust -> dust` (no shared substring beyond `d`). The model gets the
  # actual closest commands ranked by how few character edits separate
  # them from what was typed, and uses the (d=N) annotation to weight
  # confidence: d=1 is almost certainly the intended command.
  if [[ -z "$cmd_exists" && ${#first} -ge 2 ]]; then
    # Short typos pull in lots of unrelated short commands at higher
    # distance — scale the threshold to the typo length.
    local max_d=3
    (( ${#first} <= 2 )) && max_d=1
    (( ${#first} == 3 )) && max_d=2
    local dl_lines
    dl_lines=$(_zsh_llm_correct_dl_candidates "$first" "$max_d" 8)
    if [[ -n "$dl_lines" ]]; then
      local dl_block=""
      local dline d name
      while IFS= read -r dline; do
        d="${dline%% *}"; name="${dline#* }"
        dl_block+=" ${name}(d=${d})"
      done <<< "$dl_lines"
      ctx+="Closest commands by edit distance to '${first}':${dl_block}
"
    fi
  fi

  [[ -n "$ctx" ]] && ctx="Environment context. The 'Closest commands' list is sorted by Damerau-Levenshtein distance — d=1 means a single-edit difference (almost certainly the intended command); higher d is less likely. Prefer low-d candidates over inventing a fix from training.
${ctx}
"
  print -r -- "$ctx"
}

_zsh_llm_correct_looks_like_nl() {
  # Heuristic: distinguish a natural-language description ("show me cpu
  # time", "tlp for cpu time") from a typo'd command ("gti stauts").
  # We say it's NL if the input has ≥3 words AND contains one of these
  # common English filler words. Typo'd commands rarely include them.
  emulate -L zsh
  local cmd="$1"
  local -a words=( ${(z)cmd} )
  (( ${#words} < 3 )) && return 1
  local w
  for w in "${words[@]}"; do
    case "${w:l}" in
      # Articles, prepositions, pronouns, question words — words that
      # are essentially never command names or arguments. We deliberately
      # don't include verbs like 'find/show/list/make' because those ARE
      # real commands and would cause false NL detection.
      a|an|the|for|with|to|by|from|in|on|of|at|\
      that|which|and|or|but|than|\
      my|this|its|it|me|us|you|your|their|\
      how|what|when|where|why|who|whose|\
      is|are|was|were|been|being|all|some)
        return 0 ;;
    esac
  done
  return 1
}

_zsh_llm_correct_suggest() {
  emulate -L zsh
  local cmd="$1" exit_code="$2"

  if ! command -v curl >/dev/null 2>&1; then
    print -u2 -- "zsh-llm-correct: curl not found"; return
  fi
  if ! command -v jq >/dev/null 2>&1; then
    print -u2 -- "zsh-llm-correct: jq not found (brew install jq)"; return
  fi

  local first="${cmd%% *}"
  local cmd_exists=""
  whence -- "$first" >/dev/null 2>&1 && cmd_exists=1

  # Pick a mode:
  #   NL   = the input is a natural-language description, not a typo
  #          ("show me cpu time", "tlp for cpu time"). Translate to a
  #          shell command. Only triggers when the first token doesn't
  #          resolve AND the input has English filler words.
  #   typo = original behaviour: EXISTS-branch fixes args, NOT-FOUND-
  #          branch renames to a closest match.
  local mode=typo
  if [[ -z "$cmd_exists" ]] && _zsh_llm_correct_looks_like_nl "$cmd"; then
    mode=nl
  fi

  local sys
  if [[ "$mode" == "nl" ]]; then
    sys='/no_think You translate natural-language shell-task descriptions into a single shell command line. The user typed a description of what they want to do, not a command. Output the appropriate command using common Unix tools (top, ps, df, du, find, grep, ls, awk, lsof, curl, etc.). Prefer short common forms.

Reply with ONLY ONE line: the shell command.
No prose, no quotes, no backticks, no markdown, no explanation, no leading $.

Examples:
[NL] tlp for cpu time
top -o cpu
[NL] show me cpu usage
ps -A -o pid,user,%cpu,command -r
[NL] list files by size
ls -lhS
[NL] how big is this folder
du -sh .
[NL] find all png files
find . -name "*.png"
[NL] how much disk free
df -h
[NL] processes using port 8080
lsof -i :8080
[NL] my external ip
curl -s ifconfig.me
[NL] what is my ip
curl -s ifconfig.me
[NL] count lines in file.txt
wc -l file.txt
[NL] who is using port 5432
lsof -i :5432
[NL] kill that process on port 8080
lsof -ti :8080 | xargs kill'
  else
  # Terse system prompt + few-shot — forces single-line output.
  # Two failure modes are distinguished:
  #   • COMMAND-NOT-FOUND: the first token doesn't resolve. The fix is
  #     usually to rename it to a similar real command. Context surfaces
  #     similarly-named PATH bins / aliases / functions.
  #   • COMMAND-EXISTS, runtime/usage error: the first token IS a real
  #     command. The fix is in the arguments — model must NOT rename it.
  # `/no_think` is honored by Qwen-family thinking models; ignored otherwise.
  sys='/no_think You fix broken shell commands. You may receive:
- a context block listing user-defined commands (use them when relevant)
- recent shell history (FOR INTENT ONLY — do not copy tokens from it into your fix unless they are clearly the intended command name)
- captured stderr from the failed command
- a hint saying whether the first token of the failed command exists
- the failed command itself with its exit code

Rules:
- If the hint says EXISTS, the command name is correct. Reorder or repair the EXISTING arguments only. Do NOT introduce new flags, options, filenames, or arguments that were not in the original input. Do NOT rename the command. If you cannot improve the command without adding things, output the input unchanged.
- If the hint says NOT-FOUND, ALWAYS suggest the most likely intended command — make a best guess from typo patterns, the context block, and your knowledge of common Unix tools. The host validates the resulting command exists before showing it to the user, so it is fine to attempt a fix even when uncertain. Prefer short, minimal fixes over verbose ones.

Reply with ONLY ONE line: the corrected single-line shell command.
No prose, no quotes, no backticks, no markdown, no explanation, no leading $.

Examples:
[NOT-FOUND] Failed (exit=127): gti stauts
git status
[NOT-FOUND] Failed (exit=127): sl -la
ls -la
[NOT-FOUND] Failed (exit=2): grp foo file.txt
grep foo file.txt
[NOT-FOUND] Failed (exit=127): ddust
du -sh
[NOT-FOUND] Failed (exit=127): pythn -V
python -V
[NOT-FOUND] Failed (exit=127): cler
clear
[EXISTS] Failed (exit=1): split file.tar.gz -b 40M
split -b 40M file.tar.gz
[EXISTS] Failed (exit=2): grep "foo
grep "foo" file.txt'
  fi

  local context
  context=$(_zsh_llm_correct_build_context "$first" "$cmd_exists")

  # Recent shell history — the last few commands (excluding the failure
  # itself, which we'll print explicitly). Helps the model see intent
  # ("user just ran cd /opt/papers; ls *.tar.gz; then split ...").
  local history_block=""
  if (( ${#_zsh_llm_correct_history} > 1 )); then
    history_block+="Recent shell history (FOR INTENT ONLY — do not copy tokens into the fix):
"
    local entry code c
    # Skip the most recent entry (it IS the failed command).
    for entry in "${_zsh_llm_correct_history[@]:0:-1}"; do
      code="${entry%%$'\t'*}"
      c="${entry#*$'\t'}"
      history_block+="  \$ ${c} (exit ${code})
"
    done
  fi

  # Captured stderr of the failed command (only if opt-in capture is on).
  # Strip ANSI escape codes and tail to OUTPUT_LIMIT bytes.
  local stderr_block=""
  if [[ -n "$_zsh_llm_correct_stderr_log" && -s "$_zsh_llm_correct_stderr_log" ]]; then
    local stderr_text
    stderr_text=$(LC_ALL=C sed $'s/\x1b\\[[0-9;]*[a-zA-Z]//g' "$_zsh_llm_correct_stderr_log" 2>/dev/null \
                  | tail -c "$ZSH_LLM_CORRECT_OUTPUT_LIMIT")
    if [[ -n "$stderr_text" ]]; then
      stderr_block="Captured stderr of the failed command (last ${ZSH_LLM_CORRECT_OUTPUT_LIMIT} chars):
${stderr_text}
"
    fi
  fi

  # Build the failure-line that ends the user prompt. NL mode bypasses
  # the EXISTS/NOT-FOUND hint structure — the model is translating intent,
  # not fixing a broken command.
  local hint_and_failure
  if [[ "$mode" == "nl" ]]; then
    hint_and_failure="[NL] ${cmd}"
  else
    local hint
    if [[ -n "$cmd_exists" ]]; then
      hint="[EXISTS] The command '${first}' resolves on this shell — the failure is a usage/syntax/argument error. Keep the command name; fix only the arguments."
    else
      hint="[NOT-FOUND] The command '${first}' does not resolve — suggest the most likely intended command (the host validates before offering it)."
    fi
    hint_and_failure="${hint}
Failed (exit=${exit_code}): ${cmd}"
  fi

  # Apply the total context byte budget. The trailing hint+failure block
  # is mandatory; only the optional front blocks (env context, recent
  # history, captured stderr) get trimmed. Trim from the head — the most
  # recent / most relevant lines live near the bottom.
  local front="${context}${history_block}${stderr_block}"
  local budget=$ZSH_LLM_CORRECT_CONTEXT_LIMIT
  if (( ${#front} > budget )); then
    front="...[truncated]
${front[$(( ${#front} - budget + 16 )),-1]}"
  fi

  # Command substitution strips trailing newlines from $context, so glue
  # an explicit newline between the front blocks and the hint line —
  # otherwise the model sees them on the same line as the hint.
  local user
  if [[ -n "$front" ]]; then
    user="${front%$'\n'}"$'\n'"${hint_and_failure}"
  else
    user="${hint_and_failure}"
  fi
  # Prepend OS info to every prompt so the model picks the right utility
  # flavor (BSD vs GNU). Cheap, ~100 chars.
  if [[ -n "$_zsh_llm_correct_os_info" ]]; then
    user="[OS] ${_zsh_llm_correct_os_info}
${user}"
  fi

  local payload
  payload=$(jq -n \
    --arg model  "$ZSH_LLM_CORRECT_MODEL" \
    --arg sys    "$sys" \
    --arg prompt "$user" \
    '{model:$model, system:$sys, prompt:$prompt, stream:true, think:false,
      options:{temperature:0, num_predict:80, stop:["\n"]}}')

  if [[ "$ZSH_LLM_CORRECT_DEBUG" == "1" ]]; then
    print -ru2 -- $'\033[2m--- llm-correct debug ---'
    print -ru2 -- "model:  $ZSH_LLM_CORRECT_MODEL"
    print -ru2 -- "prompt:"
    print -ru2 -- "$user"
    print -ru2 -- $'--- end ---\033[0m'
  fi

  printf '\033[2m💡 \033[0m'

  local fixed="" line chunk
  # Read NDJSON stream; print each token as it arrives.
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    chunk=$(print -r -- "$line" | jq -r '.response // empty' 2>/dev/null)
    if [[ -n "$chunk" ]]; then
      printf '%s' "$chunk"
      fixed+="$chunk"
    fi
  done < <(curl -sNS --max-time 30 \
              -X POST "$ZSH_LLM_CORRECT_OLLAMA_URL/api/generate" \
              -H 'Content-Type: application/json' \
              -d "$payload" 2>/dev/null)

  # Trim outer whitespace.
  fixed="${fixed##[[:space:]]##}"
  fixed="${fixed%%[[:space:]]##}"

  # Strip wrapping quotes/backticks ONLY when both ends match — otherwise we
  # would chop a legitimate trailing quote (e.g. `find . -name "*.png"`)
  # and leave an unmatched-quote eval error.
  local first="${fixed[1]}" last="${fixed[-1]}"
  if [[ ${#fixed} -ge 2 && "$first" == "$last" ]]; then
    case "$first" in
      '"'|"'"|'`') fixed="${fixed[2,-2]}" ;;
    esac
  fi

  # Bail-out paths — wipe the streamed line so we don't leave a half-prompt.
  if [[ -z "$fixed" ]]; then
    printf '\r\033[K\033[2m(no suggestion)\033[0m\n'
    return
  fi
  if [[ "$fixed" == "NOFIX" ]]; then
    printf '\r\033[K\033[2m(no fix)\033[0m\n'
    return
  fi
  # Don't pester when the model just echoes the same command back.
  if [[ "$fixed" == "$cmd" ]]; then
    printf '\r\033[K\033[2m(unchanged — no fix)\033[0m\n'
    return
  fi

  # Safety net: validate the suggested command actually resolves on this
  # shell. Catches hallucinations like `hi -> hiatus` or `hit -> hii`
  # where the model invents a command name that doesn't exist anywhere.
  # We check the FIRST real command word (skipping VAR=value assignments
  # and common wrappers like sudo/env/time so they don't fool the check).
  local -a fix_tokens=( ${(z)fixed} )
  local fix_head=""
  local t
  for t in $fix_tokens; do
    t="${t##\(}"; t="${t##\{}"           # strip subshell/group openers
    case "$t" in
      "")                                          continue ;;
      *=*)                                         continue ;; # FOO=bar
      sudo|doas|env|time|nohup|exec|command|builtin) continue ;;
      *) fix_head="$t"; break ;;
    esac
  done
  if [[ -n "$fix_head" ]] && ! whence -- "$fix_head" >/dev/null 2>&1; then
    printf '\r\033[K\033[2m(unknown command: %s — dismissed)\033[0m\n' "$fix_head"
    return
  fi

  printf ' \033[1m?\033[0m [Y/n] '
  local answer
  read -k 1 answer
  printf '\n'
  case "$answer" in
    $'\n'|y|Y)
      print -s -- "$fixed"   # push to history so ↑ works
      eval "$fixed"
      ;;
    *) ;;
  esac
}

# Manual trigger: `llm-fix some failing command`
llm-fix() {
  local cmd="$*"
  [[ -z "$cmd" ]] && { print -u2 -- "usage: llm-fix <command>"; return 2 }
  _zsh_llm_correct_suggest "$cmd" 1
}

autoload -U add-zsh-hook
add-zsh-hook preexec _zsh_llm_correct_preexec
add-zsh-hook precmd  _zsh_llm_correct_precmd
_zsh_llm_correct_init_capture
