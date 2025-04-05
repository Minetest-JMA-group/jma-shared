QT -= gui

# Expect that we're in modname/src/
MODFOLDER = $$clean_path($$_PRO_FILE_PWD_/..)
TARGET = $$basename(MODFOLDER)

TEMPLATE = lib
CONFIG += c++23
CONFIG += release
CONFIG -= debug
QMAKE_CXXFLAGS_RELEASE += -O3
QMAKE_CXXFLAGS_RELEASE += -march=native
QMAKE_CXXFLAGS_RELEASE += -mtune=native

# You can make your code fail to compile if it uses deprecated APIs.
# In order to do so, uncomment the following line.
DEFINES += QT_DISABLE_DEPRECATED_BEFORE=0x060000    # disables all the APIs deprecated before Qt 6.0.0

# Check if LIBSPATH is set
!isEmpty(LIBSPATH) {
	# Check if it exists and is a directory
	exists($$LIBSPATH) {
		# Check if the last part of the path is 'libs'
		# Take absolute path because the variable might contain something like just ..
		LIBSPATH = $$absolute_path($$LIBSPATH)
		basename = $$basename(LIBSPATH)
		equals(basename, libs) {
			message("Using LIBSPATH: $$LIBSPATH")
		} else {
			error("LIBSPATH does not point to a directory named 'libs' (got: $$basename)")
		}
	} else {
		error("LIBSPATH does not exist: $$LIBSPATH")
	}
} else {
	error("LIBSPATH was not provided.")
}

# Set build directory in /tmp/qmake-TARGET
DESTDIR = /tmp/qmake-$$TARGET
OBJECTS_DIR = $$DESTDIR/obj
MOC_DIR = $$DESTDIR/moc
RCC_DIR = $$DESTDIR/rcc
UI_DIR = $$DESTDIR/ui

target.path = $$MODFOLDER
INSTALLS += target

# Set RPATH relative to $ORIGIN
unix {
	QMAKE_RPATHDIR += $ORIGIN/$$relative_path($$LIBSPATH, ..)
}

INCLUDEPATH += $$LIBSDIR/QMinetest
LIBS += -L$$LIBSPATH -lluajit-5.1
QMAKE_CXXFLAGS += -Wall -Wextra

SOURCES += \
    lua.cpp

HEADERS +=
