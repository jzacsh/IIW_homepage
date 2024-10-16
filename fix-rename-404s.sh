#!/usr/bin/env bash
#
# Fixes files left behind in the rename of commit 9c2c71d8bc56
declare -r renameGitRef=56adf83ce4fb740552c30039c3d09c2c71d8bc56

###############################################################################
# basic "standard lib"-type things below this line ############################

# Whether string "$1" (haystack) starts with string "$2" (needle).
# taken from https://gitlab.com/jzacsh/yabashlib/-/blob/9abe7f2fae6bcec309580eb431e4504ddd1a7a1c/src/string.sh#L51
function yabashlib.strStartsWith() {
  local haystack="$1" needle="$2"
  local needle_length="${#needle}"
  local haystack_subset="${haystack:0:$needle_length}"
  [[ "$haystack_subset" = "$needle" ]]
}

# Whether tracked files are currently "clean" (no staged nor unstaged).
# adapted from https://gitlab.com/jzacsh/yabashlib/-/blob/9abe7f2fae6bcec309580eb431e4504ddd1a7a1c/src/vcs.sh#L7
function yabashlib.vcs_git_is_clean() (
  [[ "$#" -eq 0 ]] || {
    cd "$1" || printf \
      'cannot inspect git status; failed to CD to\n\t"%s"\n' "$1" >&2
    }
  [[ -z "$(git status --porcelain | sed --expression '/^??/d')" ]];
)


# $1=match
# $2=replacement
# $3=targetFile
function findReplaceInFile() {
  local match="$1" replacement="$2" targetFile="$3"

  local sedExpr; printf -v sedExpr -- \
    's,%s,%s,g' \
    "$match" \
    "$replacement"

  (
    set -x;
    sed --in-place \
      "$sedExpr" \
      "$targetFile"
  ) || {
    printf \
      'ERROR: failed fixing file: %s\n' \
      "$targetFile" >&2
    return 1
  }
}

###############################################################################
# basic business logic below this line ########################################

function gitLib.listRenamesTwoLines() {
  git show "$renameGitRef" |
    grep --extended-regexp '(^rename from\b|^rename to\b)\ ' |
    sed --regexp-extended --expression 's,^rename\ (from|to) ,,g'
}

# $1=origName
# $2=newName
function findReplaceStaleRefs() {
  local origName="$1" newName="$2"
  local staleRefs staleRef staleFilePath sedExpr fixCount=0
  declare -a staleRefs=( "$origName" )
  # custom-hackery because codebase somehow has hard-codings to a path
  # "assets/proceedings/" that doesn't exist at all
  # - dc0665f3407080efe89b6f0870c08875fd6f2f8b
  # - 56adf83ce4fb740552c30039c3d09c2c71d8bc56
  # - for more: git log -p --all --full-history -- assets/proceedings{-iiw,}
  if yabashlib.strStartsWith "$origName" 'assets/proceedings-iiw'; then
    staleRefs+=( "$(echo "$origName" | sed --expression 's,assets/proceedings-iiw/,assets/proceedings/,g')" )
  fi

  while read -r staleFilePath; do
    for staleRef in "${staleRefs[@]}"; do
      findReplaceInFile \
        "$staleRef" \
        "$newName" \
        "$staleFilePath"
    done

    fixCount=$(( fixCount + 1 ))
  done < <(
    {
      for staleRef in "${staleRefs[@]}"; do
        git grep --recursive --files-with-matches "$staleRef"
      done
    } | sort | uniq
  )
  echo "$fixCount"
}

# $1=fullOrigFilePath
function likelyHaveStaleRefsTo() {
  git grep \
    --quiet \
    --recursive \
    --line-number \
    --extended-regexp \
    "$(basename "$1")"
}

yabashlib.vcs_git_is_clean "$PWD" || {
  printf \
    'ABORTING: fix-reporting is minmimal, so your dirty repo will be confusing: please commit/shelf/etc before running...\n' >&2
  exit 1
}

report_renamesFixed=0
while read -r origName; do
  # read one more line
  read -r newName

  likelyHaveStaleRefsTo "$origName" || {
    printf 'SKIPPING rename, likely no content referring to old file: %s\n' "$origName" >&2
    continue
  }

  printf 'DBG fixing stale files for rename:\nfrom: "%s"\n  to: "%s"\n' "$origName" "$newName" >&2
  expectedFixedCount="$(findReplaceStaleRefs "$origName" "$newName")" || {
    printf 'ERROR: FAILED fixing rename:\nfrom: "%s"\n  to: "%s"\n' "$origName" "$newName" >&2
    continue
  }
  printf 'DBG: apparently fixed %s stale files\n' "$expectedFixedCount" >&2
  report_renamesFixed=$(( report_renamesFixed + 1 ))

  echo >&2 # debug prettification
done < <(gitLib.listRenamesTwoLines)

printf \
  'DBG: done hunting for stale refs across %s renames; see `git status` output for details:\n' \
  "$report_renamesFixed" >&2
git status
