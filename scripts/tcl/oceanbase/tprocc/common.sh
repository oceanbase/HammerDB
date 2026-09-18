#!/usr/bin/env bash

ob_tprocc_init() {
    local script_dir=$1
    local env_file=${OB_ENV_FILE:-$script_dir/oceanbase.env}

    if [[ ! -f "$env_file" ]]; then
        echo "Missing $env_file. Copy oceanbase.env.example to oceanbase.env and edit it." >&2
        return 1
    fi

    set -a
    source "$env_file"
    set +a

    export TMP=$script_dir/results
    export TMPDIR=$TMP
    mkdir -p "$TMP"

    local search_dir=$script_dir
    while [[ "$search_dir" != / ]]; do
        if [[ -x "$search_dir/hammerdbcli" ]]; then
            HAMMERDBCLI=$search_dir/hammerdbcli
            export HAMMERDBCLI
            return 0
        fi
        search_dir=$(dirname -- "$search_dir")
    done

    echo "Cannot find hammerdbcli above $script_dir" >&2
    return 1
}
