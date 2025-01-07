#!/bin/bash

if [ -z "$1" ]; then
	echo "Provide C++ (Qt) source project folder path as argument"
	exit 1
fi

if [ "$1" == "--help" ]; then
	echo "In first argument, provide path to your project directory where .cpp files are located"
	echo "In second argument, provide path to the libs folder. This argument is ignored if the script is running from this folder"
	echo "Following arguments are passed to g++"
	echo 'The resulting object file is placed in a parent directory of the project folder and RPATH is set correctly, relative to $ORIGIN'
	echo "Example: ./compile.sh ../algorithms/src/ . -lstorage"
	exit 0
fi

if [ ! -d "$1" ]; then
	echo "Argument is not a directory path."
	echo "Provide C++ (Qt) source project folder path as argument"
	exit 1
fi

libspath="$PWD"
if [ $(basename "$PWD") != "libs" ]; then
	if [ -z "$2" ] || [ ! -d "$2" ] || [ "$(basename "$2")" != "libs" ]; then
		echo "This script must be run from the 'libs' folder, or if not, the second argument must explicitly point to the 'libs' folder."
		exit 1
	fi
	libspath="$2"
fi

g++ "$1"/*.cpp -o "$1"/../mylibrary.so -fPIC -lluajit-5.1 -lQt5Core -O2 \
-I/usr/include/aarch64-linux-gnu/qt5 -I/usr/include/aarch64-linux-gnu/qt5/QtCore -shared -I/usr/include/luajit-2.1/ -I"$libspath/StorageSrc/" \
-Wl,-rpath,'$ORIGIN/'"$(realpath --relative-to="$1/.." "$libspath")" -L"$libspath"/ $3
