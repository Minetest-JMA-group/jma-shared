#!/bin/bash

if [ -z "$1" ]; then
	echo "Provide C++ (Qt) source project folder path as argument"
	exit 1
fi

if [ "$1" == "--help" ]; then
	echo "In the first argument, provide path to your project directory where .cpp files are located"
	echo "Following arguments are passed to g++"
	echo 'The resulting object file is placed in a parent directory of the project folder and RPATH is set correctly, relative to $ORIGIN'
	echo "Example: ./compile.sh ../algorithms/src/ -lqminetest"
	exit 0
fi

if [ ! -d "$1" ]; then
	echo "Argument is not a directory path."
	echo "Provide C++ (Qt) source project folder path as argument"
	exit 1
fi

libspath="$(dirname "$(realpath "$0")")"
if [ $(basename "$libspath") != "libs" ]; then
	echo "This script must be placed in the 'libs' folder, with rest of the custom .so files."
	exit 1
fi

if [ -d "/usr/include/aarch64-linux-gnu/qt6" ]; then
	QtPrefix="/usr/include/aarch64-linux-gnu/qt6"
fi

if [ -d "/usr/include/x86-64-linux-gnu/qt6" ]; then
	QtPrefix="/usr/include/x86-64-linux-gnu/qt6"
fi

if [ -d "/usr/include/qt6" ]; then
	QtPrefix="/usr/include/qt6"
fi

g++ "$1"/*.cpp -o "$1"/../mylibrary.so -fPIC -lluajit-5.1 -std=c++23 -Wall -Wextra -lQt6Core -lQt6Network -lQt6Sql -O3 \
-I"$QtPrefix" -I"$QtPrefix/QtCore" -I"$QtPrefix/QtNetwork" -I"$QtPrefix/QtSql" \
-shared -I/usr/include/luajit-2.1/ -I"$libspath/QMinetest/" \
-Wl,-rpath,'$ORIGIN/'"$(realpath --relative-to="$1/.." "$libspath")" -L"$libspath"/ $3
