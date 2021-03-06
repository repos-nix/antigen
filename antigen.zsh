#!/bin/zsh

# Each line in this string has the following entries separated by a space
# character.
# <repo-url>, <plugin-location>, <bundle-type>, <has-local-clone>
# FIXME: Is not kept local by zsh!
local _ANTIGEN_BUNDLE_RECORD=""

# Syntaxes
#   antigen-bundle <url> [<loc>=/]
# Keyword only arguments:
#   branch - The branch of the repo to use for this bundle.
antigen-bundle () {

    # Bundle spec arguments' default values.
    local url="$ANTIGEN_DEFAULT_REPO_URL"
    local loc=/
    local branch=
    local no_local_clone=false
    local btype=plugin

    # Parse the given arguments. (Will overwrite the above values).
    eval "$(-antigen-parse-args \
            'url?, loc? ; branch:?, no-local-clone?, btype:?' \
            "$@")"

    # Check if url is just the plugin name. Super short syntax.
    if [[ "$url" != */* ]]; then
        loc="plugins/$url"
        url="$ANTIGEN_DEFAULT_REPO_URL"
    fi

    # Resolve the url.
    url="$(-antigen-resolve-bundle-url "$url")"

    # Add the branch information to the url.
    if [[ ! -z $branch ]]; then
        url="$url|$branch"
    fi

    # The `make_local_clone` variable better represents whether there should be
    # a local clone made. For cloning to be avoided, firstly, the `$url` should
    # be an absolute local path and `$branch` should be empty. In addition to
    # these two conditions, either the `--no-local-clone` option should be
    # given, or `$url` should not a git repo.
    local make_local_clone=true
    if [[ $url == /* && -z $branch &&
            ( $no_local_clone == true || ! -d $url/.git ) ]]; then
        make_local_clone=false
    fi

    # Add it to the record.
    _ANTIGEN_BUNDLE_RECORD="$_ANTIGEN_BUNDLE_RECORD\n$url $loc $btype"
    _ANTIGEN_BUNDLE_RECORD="$_ANTIGEN_BUNDLE_RECORD $make_local_clone"

    # Ensure a clone exists for this repo, if needed.
    if $make_local_clone; then
        -antigen-ensure-repo "$url"
    fi

    # Load the plugin.
    -antigen-load "$url" "$loc" "$btype" "$make_local_clone"

}

-antigen-resolve-bundle-url () {
    # Given an acceptable short/full form of a bundle's repo url, this function
    # echoes the full form of the repo's clone url.

    local url="$1"

    # Expand short github url syntax: `username/reponame`.
    if [[ $url != git://* &&
            $url != https://* &&
            $url != /* &&
            $url != git@github.com:*/*
            ]]; then
        url="https://github.com/${url%.git}.git"
    fi

    echo "$url"
}

antigen-bundles () {
    # Bulk add many bundles at one go. Empty lines and lines starting with a `#`
    # are ignored. Everything else is given to `antigen-bundle` as is, no
    # quoting rules applied.

    local line

    grep -v '^\s*$\|^#' | while read line; do
        # Using `eval` so that we can use the shell-style quoting in each line
        # piped to `antigen-bundles`.
        eval "antigen-bundle $line"
    done
}

antigen-update () {
    # Update your bundles, i.e., `git pull` in all the plugin repos.

    date > $ADOTDIR/revert-info

    -antigen-echo-record |
        awk '{print $1}' |
        sort -u |
        while read url; do
            echo "**** Pulling $url"
            (dir="$(-antigen-get-clone-dir "$url")"
                echo -n "$dir:"
                cd "$dir"
                git rev-parse HEAD) >> $ADOTDIR/revert-info
            -antigen-ensure-repo "$url" --update --verbose
            echo
        done
}

antigen-revert () {
    if ! [[ -f $ADOTDIR/revert-info ]]; then
        echo 'No revert information available. Cannot revert.' >&2
    fi

    cat $ADOTDIR/revert-info | sed '1!p' | while read line; do
        dir="$(echo "$line" | cut -d: -f1)"
        git --git-dir="$dir/.git" --work-tree="$dir" \
            checkout "$(echo "$line" | cut -d: -f2)" 2> /dev/null
    done

    echo "Reverted to state before running -update on $(
            cat $ADOTDIR/revert-info | sed -n 1p)."
}

-antigen-get-clone-dir () {
    # Takes a repo url and gives out the path that this url needs to be cloned
    # to. Doesn't actually clone anything.
    echo -n $ADOTDIR/repos/
    echo "$1" | sed \
        -e 's./.-SLASH-.g' \
        -e 's.:.-COLON-.g' \
        -e 's.|.-PIPE-.g'
}

-antigen-get-clone-url () {
    # Takes a repo's clone dir and gives out the repo's original url that was
    # used to create the given directory path.
    echo "$1" | sed \
        -e "s:^$ADOTDIR/repos/::" \
        -e 's.-SLASH-./.g' \
        -e 's.-COLON-.:.g' \
        -e 's.-PIPE-.|.g'
}

-antigen-ensure-repo () {

    # Ensure that a clone exists for the given repo url and branch. If the first
    # argument is `--update` and if a clone already exists for the given repo
    # and branch, it is pull-ed, i.e., updated.

    # Argument defaults.
    # The url. No sane default for this, so just empty.
    local url=
    # Check if we have to update.
    local update=false
    # Verbose output.
    local verbose=false

    eval "$(-antigen-parse-args 'url ; update?, verbose?' "$@")"
    shift $#

    # Get the clone's directory as per the given repo url and branch.
    local clone_dir="$(-antigen-get-clone-dir $url)"

    # A temporary function wrapping the `git` command with repeated arguments.
    --plugin-git () {
        eval git --git-dir=$clone_dir/.git --work-tree=$clone_dir "$@"
    }

    # Clone if it doesn't already exist.
    if [[ ! -d $clone_dir ]]; then
        git clone "${url%|*}" "$clone_dir"
    elif $update; then
        # Save current revision.
        local old_rev="$(--plugin-git rev-parse HEAD)"
        # Pull changes if update requested.
        --plugin-git pull
        # Get the new revision.
        local new_rev="$(--plugin-git rev-parse HEAD)"
    fi

    # If its a specific branch that we want, checkout that branch.
    if [[ $url == *\|* ]]; then
        local current_branch=${$(--plugin-git symbolic-ref HEAD)##refs/heads/}
        local requested_branch="${url#*|}"
        # Only do the checkout when we are not already on the branch.
        [[ $requested_branch != $current_branch ]] &&
            --plugin-git checkout $requested_branch
    fi

    if ! [[ -z $old_rev || $old_rev == $new_rev ]]; then
        echo Updated from ${old_rev:0:7} to ${new_rev:0:7}.
        if $verbose; then
            --plugin-git log --oneline --reverse --no-merges --stat '@{1}..'
        fi
    fi

    # Remove the temporary git wrapper function.
    unfunction -- --plugin-git

}

-antigen-load () {

    local url="$1"
    local loc="$2"
    local btype="$3"
    local make_local_clone="$4"

    # The full location where the plugin is located.
    local location
    if $make_local_clone; then
        location="$(-antigen-get-clone-dir "$url")/$loc"
    else
        location="$url"
    fi

    if [[ $btype == theme ]]; then

        # Of course, if its a theme, the location would point to the script
        # file.
        source "$location"

    else

        # Source the plugin script.
        # FIXME: I don't know. Looks very very ugly. Needs a better
        # implementation once tests are ready.
        local script_loc="$(ls "$location" | grep -m1 '\.plugin\.zsh$')"

        if [[ -f $script_loc ]]; then
            # If we have a `*.plugin.zsh`, source it.
            source "$script_loc"

        elif [[ ! -z "$(ls "$location" | grep -m1 '\.zsh$')" ]]; then
            # If there is no `*.plugin.zsh` file, source *all* the `*.zsh`
            # files.
            for script ($location/*.zsh(N)) source "$script"

        elif [[ ! -z "$(ls "$location" | grep -m1 '\.sh$')" ]]; then
            # If there are no `*.zsh` files either, we look for and source any
            # `*.sh` files instead.
            for script ($location/*.sh(N)) source "$script"

        fi

        # Add to $fpath, for completion(s).
        fpath=($location $fpath)

    fi

}

antigen-cleanup () {

    # Cleanup unused repositories.

    local force=false
    if [[ $1 == --force ]]; then
        force=true
    fi

    if [[ ! -d "$ADOTDIR/repos" || -z "$(ls "$ADOTDIR/repos/")" ]]; then
        echo "You don't have any bundles."
        return 0
    fi

    # Find directores in ADOTDIR/repos, that are not in the bundles record.
    local unused_clones="$(comm -13 \
        <(-antigen-echo-record |
            awk '$4 == "true" {print $1}' |
            while read line; do
                -antigen-get-clone-dir "$line"
            done |
            sort -u) \
        <(ls -d "$ADOTDIR/repos/"* | sort -u))"

    if [[ -z $unused_clones ]]; then
        echo "You don't have any unidentified bundles."
        return 0
    fi

    echo 'You have clones for the following repos, but are not used.'
    echo "$unused_clones" |
        while read line; do
            -antigen-get-clone-url "$line"
        done |
        sed -e 's/^/  /' -e 's/|/, branch /'

    if $force || (echo -n '\nDelete them all? [y/N] '; read -q); then
        echo
        echo
        echo "$unused_clones" | while read line; do
            echo -n "Deleting clone for $(-antigen-get-clone-url "$line")..."
            rm -rf "$line"
            echo ' done.'
        done
    else
        echo
        echo Nothing deleted.
    fi
}

antigen-lib () {
    antigen-bundle --loc=lib
}

antigen-theme () {
    local name="${1:-robbyrussell}"
    antigen-bundle --loc=themes/$name.zsh-theme --btype=theme
}

antigen-apply () {
    # Initialize completion.
    # TODO: Only load completions if there are any changes to the bundle
    # repositories.
    compinit -i
}

antigen-list () {
    # List all currently installed bundles.
    if [[ -z "$_ANTIGEN_BUNDLE_RECORD" ]]; then
        echo "You don't have any bundles." >&2
        return 1
    else
        -antigen-echo-record | sort -u
    fi
}

antigen-help () {
    cat <<EOF
Antigen is a plugin management system for zsh. It makes it easy to grab awesome
shell scripts and utilities, put up on github. For further details and complete
documentation, visit the project's page at 'http://antigen.sharats.me'.
EOF
}

# A syntax sugar to avoid the `-` when calling antigen commands. With this
# function, you can write `antigen-bundle` as `antigen bundle` and so on.
antigen () {
    local cmd="$1"
    shift
    "antigen-$cmd" "$@"
}

-antigen-parse-args () {
    # An argument parsing functionality to parse arguments the *antigen* way :).
    # Takes one first argument (called spec), which dictates how to parse and
    # the rest of the arguments are parsed. Outputs a piece of valid shell code
    # that can be passed to `eval` inside a function which creates the arguments
    # and their values as local variables. Suggested use is to set the defaults
    # to all arguments first and then eval the output of this function.

    # Spec: Only long argument supported. No support for parsing short options.
    # The spec must have two sections, separated by a `;`.
    #       '<positional-arguments>;<keyword-only-arguments>'
    # Positional arguments are passed as just values, like `command a b`.
    # Keyword arguments are passed as a `--name=value` pair, like `command
    # --arg1=a --arg2=b`.

    # Each argument in the spec is separated by a `,`. Each keyword argument can
    # end in a `:` to specifiy that this argument wants a value, otherwise it
    # doesn't take a value. (The value in the output when the keyword argument
    # doesn't have a `:` is `true`).

    # Arguments in either section can end with a `?` (should come after `:`, if
    # both are present), means optional. FIXME: Not yet implemented.

    # See the test file, tests/arg-parser.t for (working) examples.

    local spec="$1"
    shift

    # Sanitize the spec
    spec="$(echo "$spec" | tr '\n' ' ' | sed 's/[[:space:]]//g')"

    local code=''

    --add-var () {
        test -z "$code" || code="$code\n"
        code="${code}local $1='$2'"
    }

    local positional_args="$(echo "$spec" | cut -d\; -f1)"
    local positional_args_count="$(echo $positional_args |
            awk -F, '{print NF}')"

    # Set spec values based on the positional arguments.
    local i=1
    while ! [[ -z $1 || $1 == --* ]]; do

        if (( $i > $positional_args_count )); then
            echo "Only $positional_args_count positional arguments allowed." >&2
            echo "Found at least one more: '$1'" >&2
            return
        fi

        local name_spec="$(echo "$positional_args" | cut -d, -f$i)"
        local name="${${name_spec%\?}%:}"
        local value="$1"

        if echo "$code" | grep -qm1 "^local $name="; then
            echo "Argument '$name' repeated with the value '$value'". >&2
            return
        fi

        --add-var $name "$value"

        shift
        i=$(($i + 1))
    done

    local keyword_args="$(
            # Positional arguments can double up as keyword arguments too.
            echo "$positional_args" | tr , '\n' |
                while read line; do
                    if [[ $line == *\? ]]; then
                        echo "${line%?}:?"
                    else
                        echo "$line:"
                    fi
                done

            # Specified keyword arguments.
            echo "$spec" | cut -d\; -f2 | tr , '\n'
            )"
    local keyword_args_count="$(echo $keyword_args | awk -F, '{print NF}')"

    # Set spec values from keyword arguments, if any. The remaining arguments
    # are all assumed to be keyword arguments.
    while [[ $1 == --* ]]; do
        # Remove the `--` at the start.
        local arg="${1#--}"

        # Get the argument name and value.
        if [[ $arg != *=* ]]; then
            local name="$arg"
            local value=''
        else
            local name="${arg%\=*}"
            local value="${arg#*=}"
        fi

        if echo "$code" | grep -qm1 "^local $name="; then
            echo "Argument '$name' repeated with the value '$value'". >&2
            return
        fi

        # The specification for this argument, used for validations.
        local arg_line="$(echo "$keyword_args" | grep -m1 "^$name:\??\?")"

        # Validate argument and value.
        if [[ -z $arg_line ]]; then
            # This argument is not known to us.
            echo "Unknown argument '$name'." >&2
            return

        elif (echo "$arg_line" | grep -qm1 ':') && [[ -z $value ]]; then
            # This argument needs a value, but is not provided.
            echo "Required argument for '$name' not provided." >&2
            return

        elif (echo "$arg_line" | grep -vqm1 ':') && [[ ! -z $value ]]; then
            # This argument doesn't need a value, but is provided.
            echo "No argument required for '$name', but provided '$value'." >&2
            return

        fi

        if [[ -z $value ]]; then
            value=true
        fi

        --add-var "${name//-/_}" "$value"
        shift
    done

    echo "$code"

    unfunction -- --add-var

}

# Echo the bundle specs as in the record. The first line is not echoed since it
# is a blank line.
-antigen-echo-record () {
    echo "$_ANTIGEN_BUNDLE_RECORD" | sed -n '1!p'
}

-antigen-env-setup () {
    # Pre-startup initializations.
    -set-default ANTIGEN_DEFAULT_REPO_URL \
        https://github.com/robbyrussell/oh-my-zsh.git
    -set-default ADOTDIR $HOME/.antigen

    # Load the compinit module.
    autoload -U compinit

    # Without the following, `compdef` function is not defined.
    compinit -i
}

# Same as `export $1=$2`, but will only happen if the name specified by `$1` is
# not already set.
-set-default () {
    local arg_name="$1"
    local arg_value="$2"
    eval "test -z \"\$$arg_name\" && export $arg_name='$arg_value'"
}

-antigen-env-setup
