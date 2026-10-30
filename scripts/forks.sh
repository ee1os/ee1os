# Sourced by track-upstream.sh, verify-tree.sh and approve.sh.
# tree path : repo name, for every project we change
FORKS=(build/make:platform_build
       frameworks/base:platform_frameworks_base
       packages/apps/Settings:platform_packages_apps_Settings
       packages/apps/SetupWizard2:platform_packages_apps_SetupWizard2
       packages/apps/Updater:platform_packages_apps_Updater
       system/sepolicy:platform_system_sepolicy)

# git without user or system config and without replace objects: the same output on every machine
xgit() { GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_NO_REPLACE_OBJECTS=1 git "$@"; }

# patch_id <dir> <commit>: what a commit changes, independent of its parent's SHA. Whitespace
# counts (--verbatim) and binary files go in whole (--binary --full-index); renames are shown as
# delete + add. Prints nothing for an empty commit.
patch_id() {
    xgit -C "$1" show --format= --no-ext-diff --no-textconv --no-color --no-renames --binary \
        --full-index --diff-algorithm=myers --src-prefix=a/ --dst-prefix=b/ "$2" \
        | xgit patch-id --verbatim | cut -d' ' -f1
}

# module_hash <dir>: one hash over a generated vendor module: every path with its type, mode and
# link target, then every file's content
module_hash() {
    (cd "$1" && { find . -printf '%y %m %p %l\n' | LC_ALL=C sort
                  find . -type f -print0 | LC_ALL=C sort -z | xargs -0r sha256sum; } | sha256sum | cut -d' ' -f1)
}
