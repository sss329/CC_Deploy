#!/usr/bin/env bash
if [ -t 0 ];
then
    terminal_size=$(stty size)
else
    terminal_size="50 80"
fi

columns="${terminal_size#* }"

function print_line()
{
    size=${#1}
    padding=$(($((columns - size))/2))
    printf '%*s' "${COLUMNS:-$padding}" ''
    printf '%s' "$1"
    printf '%*s\n' "${COLUMNS:-$padding}" ''
}

__SEPARATOR=$(printf '%*s\n' "${COLUMNS:-$columns}" '' | tr ' ' -)

function print_header() {
    echo -e "${__SEPARATOR}"
    print_line "Couchbase Installer v0.0.1"
    echo -e "${__SEPARATOR}"
}

function print_help() {
    print_line "this is all the help you get."
    print_line "https://github.com/couchbase-partners/marketplace-scripts/blob/main/readme.md"
}