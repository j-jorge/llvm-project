#!/bin/bash

set -e

concurrency=4
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"; pwd)"
projects=()

for arg in "$@"
do
    case "$arg" in
        --concurrency=*)
            concurrency="${arg#--concurrency=}"
            ;;
        --project=*)
            projects+=("${arg#--project=}")
            ;;
    esac
done

should_build_project() {
    if [ "${#projects[@]}" -eq 0 ]
    then
        return 0
    fi
    
    printf '%s\n' "${projects[@]}" \
        | grep -q "^$1\$"
}

common_cmake_args=(
    "$script_dir/../llvm"
    "-G" "Ninja"
    "-DCMAKE_BUILD_TYPE=Release"
    "-DLLVM_CCACHE_BUILD=ON"
    "-DLLVM_ENABLE_PROJECTS=clang"
    "-DLLVM_TARGETS_TO_BUILD=X86"
)

clang_build_dir_prefix="$script_dir/clang-build"
flavors=("vanilla" "no-small-vector" "no-small-dense-map")
clang_build_arg=("" "-DLLVM_NO_SMALL_VECTOR=ON" "-DLLVM_NO_SMALL_DENSE_MAP=ON")

for ((i=0; i != "${#flavors[@]}"; ++i ))
do
    flavored_build_dir="$clang_build_dir_prefix/${flavors[i]}"

    mkdir -p "$flavored_build_dir"
    cd "$flavored_build_dir"
    
    if [ ! -f "CMakeCache.txt" ]
    then
        cmake "${common_cmake_args[@]}" ${clang_build_arg[i]}
    fi

    if [ ! -f "bin/clang" ]
    then
        ninja
    fi
done

cd "$script_dir"

clone_project() {
    git clone --depth 1 --branch "$2" "$1"
}

build_all_flavors() {
    for flavor in "${flavors[@]}"
    do
        mkdir -p "build-$flavor"
        cd "build-$flavor"

        CC="$clang_build_dir_prefix/$flavor/bin/clang" \
          CXX="$clang_build_dir_prefix/$flavor/bin/clang++" \
          cmake .. "$@"
        
        cd ..
    done

    for flavor in "${flavors[@]}"
    do
        for i in {1..10}
        do
            make clean -C "build-$flavor"
            /usr/bin/time -f "BUILD_COMPLETED: $flavor\t$i\t%e\n" \
                          make -j "$concurrency" -C "build-$flavor" 2>&1
        done
    done
}

extract_measure() {
    grep '^BUILD_COMPLETED' "$1" \
        | cut -d' ' -f2-
}

measure_project() {
    local repository="$1"
    local branch="$2"
    shift 2
    
    local name
    name="$(echo "$repository" | sed 's,.*/\([^/]\+\)\.git,\1,')"
    
    if [ ! -d "$name" ]
    then
        clone_project "$repository" "$branch"
    fi

    cd "$name"
    echo "Building $name"
    build_all_flavors "$@" > ../"$name.log"

    cd ..
    extract_measure "$name".log > "$name-measures.$concurrency.txt"
}

measure_clang() {
    local name=clang

    echo "Building $name"

    local tmp_script
    tmp_script="$(mktemp)"

    echo $tmp_script
    for flavor in "${flavors[@]}"
    do
        (
            find "$script_dir/../llvm/lib" -name "*.cpp" \
                | while read -r source
            do
                if [[ "$source" == */Target/* ]] \
                       && [[ "$source" != */Target/X86/* ]]
                then
                    continue
                fi
                
                echo "$clang_build_dir_prefix/$flavor/bin/clang++ \\"
                echo "    -o /dev/null -c $source \\"
                echo "    -I$script_dir/../llvm/include/ \\"
                echo "    -I$script_dir/../build/include/ \\"
                echo "    -I$script_dir/../build/lib/"
            done
        ) > "$tmp_script"

        /usr/bin/time -f "BUILD_COMPLETED: $flavor\t$i\t%e\n" \
                      sh "$tmp_script" 2>&1
            
    done \
        > "$name".log

    extract_measure "$name".log > "$name-measures.1.txt"

    rm "$tmp_script"
}

if should_build_project "capnproto"
then
    measure_project \
        "https://github.com/capnproto/capnproto.git" \
        "v0.8.0"
fi

if should_build_project "jsoncpp"
then
    measure_project \
        "https://github.com/open-source-parsers/jsoncpp.git" \
        "1.9.4" \
        "-DJSONCPP_WITH_POST_BUILD_UNITTEST=OFF"
fi

if should_build_project "googletest"
then
    measure_project \
        "https://github.com/google/googletest.git" \
        "release-1.10.0"
fi

if should_build_project "clang"
then
    measure_clang
fi
