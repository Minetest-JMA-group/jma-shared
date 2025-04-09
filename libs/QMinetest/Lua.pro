QT -= gui

# Expect that we're in modname/src/
MODFOLDER = $$clean_path($$_PRO_FILE_PWD_/..)
TARGET = $$basename(_PRO_FILE_PWD_)

TEMPLATE = lib
CONFIG += c++latest
CONFIG += warn_on
QMAKE_CXXFLAGS += -O3
QMAKE_CXXFLAGS += -march=native
QMAKE_CXXFLAGS += -mtune=native

# You can make your code fail to compile if it uses deprecated APIs.
# In order to do so, uncomment the following line.
DEFINES += QT_DISABLE_DEPRECATED_BEFORE=0x060000    # disables all the APIs deprecated before Qt 6.0.0

# Happens only when ran with $$fromfile
isEmpty(OUT_PWD) {
	OUT_PWD = $$(PWD)
}
# Handle LIBSPATH
isEmpty(LIBSPATH) {
	LIBSPATH = $$(LIBSPATH)
}
!isEmpty(LIBSPATH) {
	# Check if it exists and is a directory
	LIBSPATH = $$absolute_path($$LIBSPATH, $$OUT_PWD)
	exists($$LIBSPATH) {
		# Check if the last part of the path is 'libs'
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
	MYHOME = $$(HOME)
	isEmpty(MYHOME) {
		error("LIBSPATH was not provided and HOME environment variable not set.")
	}
	JMA_REPO_CANDIDATES = $$files($$MYHOME/.minetest/*"jma-"*, true)
	for(jma_repo, JMA_REPO_CANDIDATES) {
		LIBSPATH = $$files($$jma_repo/*libs, true)
		!isEmpty(LIBSPATH) {
			break()
		}
	}
	isEmpty(LIBSPATH) {
		error("LIBSPATH was not provided and search for it in $HOME/.minetest failed")
	}
	warning("LIBSPATH was not provided. Using auto-obtained $$LIBSPATH")
}

# Set build directory to be in cwd from where qmake was ran
BUILDDIR = $$OUT_PWD/build_qt
DESTDIR = $$MODFOLDER
OBJECTS_DIR = $$BUILDDIR/obj
MOC_DIR = $$BUILDDIR/moc
RCC_DIR = $$BUILDDIR/rcc
UI_DIR = $$BUILDDIR/ui

# Set RPATH relative to $ORIGIN
unix {
	QMAKE_RPATHDIR += $ORIGIN/$$relative_path($$LIBSPATH, ..)
}

INCLUDEPATH += $$LIBSPATH/QMinetest
LIBS += -L$$LIBSPATH -lluajit-5.1

SOURCES += \
    debug.cpp \
    minetest.cpp \
    player.cpp \
    qlog.cpp \
    qtinit.cpp \
    storage.cpp

HEADERS += \
    minetest.h \
    player.h \
    storage.h
