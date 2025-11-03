// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2023 Marko Petrović
#include <core.h>

QLog::QLog(minetest *functions) : QTextStream(&assembledString), functions(functions) {}
QLog::QLog(minetest *functions, const char *caller) : QTextStream(&assembledString), functions(functions), caller(caller) {}
QLog::~QLog()
{
	flush();
	if (assembledString == "")
		return;
	if (caller)
		functions->chat_send_player(caller, assembledString.toUtf8().constData());
	else
		functions->log_message("warning", assembledString.toUtf8().constData());
}
