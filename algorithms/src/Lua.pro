LIBS += -lluajit-5.1

# Happens only when ran with $$fromfile
# i.e. happens only when called from top-level pro file, and it needs only our LIBS
# Do the rest when we're called properly
!isEmpty(OUT_PWD) {
	QT -= gui core

	# Expect that we're in modname/src/
	MODFOLDER = $$clean_path($$_PRO_FILE_PWD_/..)
	TARGET = $$basename(MODFOLDER)

	TEMPLATE = lib
	CONFIG += c++latest
	CONFIG += warn_on
	QMAKE_CXXFLAGS -= -O2
	QMAKE_CXXFLAGS_RELEASE -= -O2
	QMAKE_CXXFLAGS += -O3 -march=native -mtune=native -Werror

	# Set build directory to be in cwd from where qmake was ran
	BUILDDIR = $$OUT_PWD/build_qt
	DESTDIR = $$MODFOLDER
	OBJECTS_DIR = $$BUILDDIR/obj
	MOC_DIR = $$BUILDDIR/moc
	RCC_DIR = $$BUILDDIR/rcc
	UI_DIR = $$BUILDDIR/ui

	SOURCES += $$files($$_PRO_FILE_PWD_/*.cpp, true)
	HEADERS += $$files($$_PRO_FILE_PWD_/*.h, true)
}
