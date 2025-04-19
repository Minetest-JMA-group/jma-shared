// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2023 Marko Petrović
#include <minetest.h>
#include <storage.h>
#include <QString>
#include <QStringList>
#include <QJsonDocument>
#include <QJsonObject>
#include <QByteArray>

minetest m;
int capsSpace = 2, capsMax = 2;
QJsonObject *whitelist = nullptr;
const char *caller = nullptr;
#define qLog QLog(&m, caller)

int parse(lua_State* L)
{
	if (lua_gettop(L) < 2 || !lua_isstring(L, 2)) {
		lua_pushstring(L, "");
		return 1;
	}
	QString text(lua_tostring(L, 2));
	QStringList words = text.split(' ', Qt::SkipEmptyParts);
	text.clear();

	// Iterate over the words
	int currCapsSpace = capsSpace + 1;
	for (QString& word : words) {
		if (m.get_player_by_name(word)) {
			lua_pop(L, 1);
			text += word + " ";
			continue;
		}
		QString lw = word.toLower();
		if (whitelist->contains(lw)) {
			text += word + " ";
			continue;
		}
		if (currCapsSpace < capsSpace) {
			if (lw == word)
				currCapsSpace++;
			else
				currCapsSpace = 0;
			text += lw + " ";
			continue;
		}
		if (lw == word)
			currCapsSpace++;
		else
			currCapsSpace = 0;

		int countCaps = 0;
		for (int i = 0; i < word.size(); i++) {
			if (word[i].isUpper()) {
				if (++countCaps > capsMax)
					word[i] = word[i].toLower();
			}
		}
		text += word + " ";
	}

	lua_pushstring(L, text.toUtf8().data());
	return 1;
}

struct cmd_ret set_capsSpace(const char *name, const QString &param)
{
	bool success;
	int capsSpaceTry = param.toInt(&success);
	caller = name;
	if (!success) {
		qLog << "capsSpace is currently at value: " << QByteArray::number(capsSpace) <<
		        "\nYou have to enter a valid number to change it";
		caller = nullptr;
		return {false, ""};
	}
	capsSpace = capsSpaceTry;

	m.get_mod_storage();
	storage s(m.L);
	s.set_int("capsSpace", capsSpace);
	m.pop_modstorage();
	qLog << "capsSpace set to: " << QByteArray::number(capsSpace);
	caller = nullptr;
	return {true, ""};
}

struct cmd_ret set_capsMax(const char *name, const QString &param)
{
	bool success;
	int capsMaxTry = param.toInt(&success);
	caller = name;
	if (!success) {
		qLog << "capsMax is currently at value: " << QByteArray::number(capsMax) <<
		        "\nYou have to enter a valid number to change it";
		caller = nullptr;
		return {false, ""};
	}
	capsMax = capsMaxTry;

	m.get_mod_storage();
	storage s(m.L);
	s.set_int("capsMax", capsMax);
	m.pop_modstorage();
	qLog << "capsMax set to: " << QByteArray::number(capsMax);
	caller = nullptr;
	return {true, ""};
}

struct cmd_ret add_to_wl(const char *name, QString &param)
{
	Q_UNUSED(name)
	if (param.isEmpty())
		return {false, "You can't add empty word to the whitelist..."};
	param = param.toLower();
	whitelist->insert(param, QJsonValue(true));
	QJsonDocument doc(*whitelist);
	m.get_mod_storage();
	storage s(m.L);
	s.set_string("whitelist", doc.toJson().data());
	m.pop_modstorage();
	caller = name;
	qLog << "Added to whitelist: " << param;
	caller = nullptr;
	return {true, ""};
}

struct cmd_ret dump_wl(const char *name, const QString &param)
{
	Q_UNUSED(param)
	caller = name;
	qLog << "Dumping filter_caps whitelist...";
	for (const QString &word : whitelist->keys()) {
		qLog << word;
	}
	caller = nullptr;
	return {true, ""};
}

struct cmd_ret remove_from_wl(const char *name, QString &param)
{
	caller = name;
	param = param.toLower();
	if (whitelist->take(param) == QJsonValue::Undefined) {
		qLog << "Word \"" << param << "\" hasn't existed in the whitelist";
		caller = nullptr;
		return {false, ""};
	}
	QJsonDocument doc(*whitelist);
	m.get_mod_storage();
	storage s(m.L);
	s.set_string("whitelist", doc.toJson().data());
	m.pop_modstorage();
	qLog << "Word \"" << param << "\" removed from the whitelist";
	caller = nullptr;
	return {true, ""};
}

struct cmd_ret filter_caps_console(const char *name, const QString &param)
{
	QStringList tokens = param.split(' ', Qt::SkipEmptyParts);
	QString arg;
	if (tokens.size() == 0)
		goto end;
	if (tokens.size() >= 2)
		arg = tokens[1];
	if (tokens[0] == "add")
		return add_to_wl(name, arg);
	if (tokens[0] == "rm")
		return remove_from_wl(name, arg);
	if (tokens[0] == "dump")
		return dump_wl(name, arg);
	if (tokens[0] == "capsMax")
		return set_capsMax(name, arg);
	if (tokens[0] == "capsSpace")
		return set_capsSpace(name, arg);
end:
	m.chat_send_player(name, "Invalid usage. Usage: filter_caps <command> [arg]");
	m.chat_send_player(name, "capsSpace <int>: Set the minimal number of words between two capitalized words");
	m.chat_send_player(name, "capsMax <int>: Set the maximal number of capital letters in one word");
	m.chat_send_player(name, "dump: Print the current whitelist content");
	m.chat_send_player(name, "add <word>: Add new word to the whitelist");
	m.chat_send_player(name, "rm <word>: Remove word from the whitelist");
	return {false, ""};
}

void dealloc_mem()
{
	if (whitelist)
		delete whitelist;
}

extern "C" int luaopen_mylibrary(lua_State* L)
{
	m.set_state(L);
	m.get_mod_storage();
	storage s(L);
	capsSpace = s.get_int("capsSpace");
	capsMax = s.get_int("capsMax");
	QJsonParseError err;
	QJsonDocument doc = QJsonDocument::fromJson(s.get_string("whitelist"), &err);
	if (err.error != QJsonParseError::NoError) {
		m.log_message("error", "[filter_caps]: " + err.errorString());
		m.log_message("error", "[filter_caps]: Could not load whitelist. Using empty whitelist");
		whitelist = new QJsonObject();
	}
	else {
		whitelist = new QJsonObject(doc.object());
	}
	m.pop_modstorage();

	m.register_chatcommand("filter_caps", QStringList("filtering"), "filter_caps console",
	                       "<command> [arg]", filter_caps_console);
	m.register_on_shutdown(dealloc_mem);

	lua_newtable(L);
	lua_pushcfunction(L, parse);
	lua_setfield(L, -2, "parse");
	lua_setglobal(L, "filter_caps");

	return 0;
}
