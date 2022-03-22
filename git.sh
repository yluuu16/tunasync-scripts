#!/bin/bash
if [[ -z "$TUNASYNC_UPSTREAM_URL" ]];then
  echo "Please set the TUNASYNC_UPSTREAM_URL"
  exit 1
fi

if [[ ! -z "$RECURSIVE" ]];then
  echo "Sync in a recursive mode"
fi

TMPDIR=${TMPDIR:-"/tmp"}

depth=0

function echon() {
  echo depth $depth $@
}

function repo_init() {
  local upstream=$1
  local working_dir=$2
  git clone --mirror "$upstream" "$working_dir"
}

function update_linux_git() {
  local upstream=$1
  local working_dir=$2
  cd "$working_dir"
  echon "==== SYNC $upstream START ===="
  git remote set-url origin "$upstream"
  /usr/bin/timeout -s INT 3600 git remote -v update -p
  local ret=$?
  [[ $ret -ne 0 ]] && echon "git update failed with rc=$ret"
  local head=$(git remote show origin | awk '/HEAD branch:/ {print $NF}')
  [[ -n "$head" ]] && echo "ref: refs/heads/$head" > HEAD
  objs=$(find objects -type f | wc -l)
  [[ "$objs" -gt 8 ]] && git repack -a -b -d
  sz=$(git count-objects -v|grep -Po '(?<=size-pack: )\d+')
  total_size=$(($total_size+1024*$sz))
  echon "==== SYNC $upstream DONE ===="
  return $ret
}

function git_sync() {
  local upstream=$1
  local working_dir=$2
  if [[ ! -f "$working_dir/HEAD" ]]; then
    echon "Initializing $upstream mirror"
    repo_init $1 $2
    return $?
  fi
  update_linux_git $1 $2
}

function checkout_repo() {
  local repo_dir="$1"
  local work_tree="$2"
  echon "Checkout $repo_dir to $work_tree"
  rm -rf $work_tree
  git clone "$repo_dir" --single-branch "$work_tree"
  local ret=$?
  if [[ $ret -ne 0 ]]; then
    echon "git clone failed with rc=$ret"
    return $ret
  fi

  local repo_dir_no_git=${repo_dir%%.git}
  local gitmodules="$work_tree/.gitmodules"
  if [[ -f "$gitmodules" ]]; then
    local paths_str=$(cat $gitmodules | grep path | cut -d '=' -f 2 | sed 's/^[[:blank:]]*//')
    local urls_str=$(cat $gitmodules | grep url | cut -d '=' -f 2 | sed 's/^[[:blank:]]*//')
    local -a paths
    local -a urls
    readarray -t paths <<<"$paths_str"
    readarray -t urls <<<"$urls_str"
    local -i i
    for ((i=0;i<${#paths[@]};i++)); do
      local git_path=$repo_dir_no_git/${paths[$i]}.git
      mkdir -p $git_path
      git_sync_recursive ${urls[$i]} $git_path
    done
  fi
}

function git_sync_recursive() {
  depth=$(($depth+1))
  local upstream=$1
  local working_dir=$2
  git_sync $1 $2
  local ret=$?
  if [[ $ret -ne 0 ]]; then
    echon "git sync failed with rc=$ret"
    return $ret
  fi

  if [[ ! -z "$RECURSIVE" ]]; then
    working_dir_name=$(basename $2)
    working_dir_name_no_git=${working_dir_name%%.git}
    checkout_repo $working_dir $TMPDIR/$working_dir_name_no_git
  fi
  depth=$(($depth-1))
}

git_sync_recursive $TUNASYNC_UPSTREAM_URL $TUNASYNC_WORKING_DIR

echo "Total size is" $(numfmt --to=iec $total_size)
