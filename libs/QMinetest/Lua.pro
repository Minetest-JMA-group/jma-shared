QT -= gui

TEMPLATE = lib

CONFIG += c++17
QMAKE_CXXFLAGS_RELEASE += -O2

# You can make your code fail to compile if it uses deprecated APIs.
# In order to do so, uncomment the following line.
#DEFINES += QT_DISABLE_DEPRECATED_BEFORE=0x060000    # disables all the APIs deprecated before Qt 6.0.0

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

# Default rules for deployment.
unix {
    target.path = $$[QT_INSTALL_PLUGINS]/generic
}
!isEmpty(target.path): INSTALLS += target

unix|win32: LIBS += -lluajit-5.1
INCLUDEPATH += .
