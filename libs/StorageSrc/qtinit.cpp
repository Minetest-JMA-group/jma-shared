// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2025 Marko Petrović

#include <minetest.h>
#include <QCoreApplication>
#include <thread>
#include <linux/prctl.h>
#include <sys/prctl.h>
#include <unistd.h>
#include <QtLogging>
#include <QtDebug>

std::thread *t;

void __attribute__((destructor)) cleanup()
{
	QCoreApplication *app = QCoreApplication::instance();
	if (app)
		app->quit();
	if (t) {
		if (t->joinable())
			t->join();
		delete t;
	}
	else
		write(1, "[Warning]: Couldn't delete the Qt thread. Did it exist?\n", 56);

}

void QtMainThread()
{
	char name[] = "luanti";
	char *argv[2] = {name, NULL};
	int argc = 1, ret;

	if (prctl(PR_SET_NAME, "QtLuanti"))
		perror("prctl");
	QCoreApplication app(argc, argv);
	qInfo() << "Created QCoreApplication in thread" << gettid() << "\tStarting Qt event loop...";
	ret = app.exec();
	qInfo() << "QCoreApplication exited with exit status:" << ret;
}

void __attribute__((constructor)) QCore_start()
{
	t = new std::thread(QtMainThread);
}
