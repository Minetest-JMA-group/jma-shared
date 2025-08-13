// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2025 Marko Petrović
#include <luajit-2.1/lua.hpp>
#include <minetest.h>
#include <storage.h>
#include <QRegularExpression>
#include <QJsonArray>
#include <QJsonDocument>
#include <QByteArray>
#include <QFile>
#include <QStringList>
#include <QString>
#include <QStringBuilder>
#include <cstring>
#include <QJsonParseError>
#include <QJsonValue>
#include <QTextStream>
#include <forward_list>
#define ENFORCING 1
#define PERMISSIVE 0
#define COMPATIBILITY

static minetest m;
static uint max_len = 1024, mode = ENFORCING;
static QString modpath, lastreg, lastregwl;
static std::forward_list<QRegularExpression> whitelist;
static std::forward_list<QRegularExpression> blacklist;
static const char *caller = nullptr;
#define qLog QLog(&m, caller)

#ifndef COMPATIBILITY
#define to_valid_json(...)
#else
static void to_valid_json(QByteArray &list)
{
	char& last = list.back();
	if (last == '}')
		last = ']';
	if (!strncmp(list.constData(), "return ", 7))
		list.slice(7);
	char &first = list.front();
	if (first == '{')
		first = '[';
}
#endif

static QStringList reglist_to_patterns(const std::forward_list<QRegularExpression> &list)
{
	QStringList string_list;

	for (const QRegularExpression &reg : list)
		string_list.append(reg.pattern());

	return string_list;
}

static int patterns_to_reglist(std::forward_list<QRegularExpression> &list, const QStringList &string_list)
{
	list.clear();
	int i = 0;
	for (const QString &item : string_list) {
		QRegularExpression reg(item, QRegularExpression::CaseInsensitiveOption | QRegularExpression::UseUnicodePropertiesOption);
		if (!reg.isValid()) {
			qLog << "filter: Regex error: " << reg.errorString() << "\nSkipping invalid regex: " << item;
			continue;
		}
		i++;
		list.push_front(reg);
	}
	return i;
}

static QStringList load_string_list(const storage &s, const QString &list_name)
{
	QStringList string_list;
	if (s.contains(list_name)) {
		QByteArray list = s.get_string(list_name);
		if (list.isEmpty())
			return QStringList();
		to_valid_json(list);
		QJsonParseError err;
		QJsonDocument doc = QJsonDocument::fromJson(list, &err);
		if (doc.isNull()) {
			qLog << "filter's " << list_name << " present in modstorage, but failed to parse. Error: " << err.errorString();
			qLog << "Loading " << list_name << " from file...";
			goto load_file;
		}
		if (!doc.isArray()) {
			qLog << "filter's " << list_name << " present in modstorage, but not an array. Loading " << list_name << " from file...";
			goto load_file;
		}
		QJsonArray array = doc.array();
		for (const QJsonValue &item : array) {
			if (item.isString())
				string_list.append(item.toString());
			else
				qLog << "Found non-string element in filter's " << list_name;
		}
		return string_list;
	}
load_file:
	QFile f(modpath + "/" + list_name);
	if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) {
		qLog << "Error opening filter's " << list_name << " file. Using empty " << list_name;
		return QStringList();
	}
	QTextStream in(&f);
	return in.readAll().split("\n", Qt::SkipEmptyParts);
}

static void save_regex_list(const std::forward_list<QRegularExpression> &list, const QString &list_name)
{
	QStringList string_list = reglist_to_patterns(list);
	QJsonDocument doc(QJsonArray::fromStringList(string_list));
	m.get_mod_storage();
	storage s(m.L);
	s.set_string(list_name, doc.toJson().constData());
	m.pop_modstorage();
}

static bool export_regex_list(const std::forward_list<QRegularExpression> &list, const QString &list_name)
{
	QStringList string_list = reglist_to_patterns(list);
	QFile f(modpath + "/" + list_name);
	if (!f.open(QIODevice::WriteOnly | QIODevice::Text)) {
		qLog << "Error opening filter's " << list_name << " file.";
		return false;
	}
	QTextStream out(&f);
	for (const QString &pattern : string_list) {
		out << pattern << "\n";
	}
	return true;
}

static bool check_args(const char *function_name, lua_State *L, const int max_elem_num, const char *expected_elem_name)
{
	int elem_num = lua_gettop(L);

	if (!elem_num) {
		qLog << "filter: " << function_name << " called with 0 arguments. Expected at least " << expected_elem_name;
		return false;
	}
	if (!lua_isstring(L, 1)) {
		qLog << "filter: " << function_name << " called with a non-string first argument. Expected to get " << expected_elem_name;
		return false;
	}
	if (elem_num > max_elem_num)
		qLog << "filter: " << function_name << " got an unexpected number of arguments: " << elem_num << " (expected: " << max_elem_num << ")";

	return true;
}

/* Args: list_name: string, caller: string or nil
 * Return: void
 */
int export_regex(lua_State *L)
{
	if (!check_args("export_regex", L, 2, "list_name"))
		return 0;
	const char *list_name = lua_tostring(L, 1);
	if (lua_gettop(L) > 1) {
		if (lua_isstring(L, 2))
			caller = lua_tostring(L, 2);
		else
			qLog << "filter: export_regex got a non-string caller name";
	}

	if (!strcmp(list_name, "whitelist"))
		export_regex_list(whitelist, list_name);
	else if (!strcmp(list_name, "blacklist"))
		export_regex_list(blacklist, list_name);
	else
		qLog << "filter: Tried to export a non-existent list: " << list_name;

	caller = nullptr;
	return 0;
}

/* Args: token: string
 * Return: boolean
 */
int is_message_too_long(lua_State *L)
{
	if (!check_args("is_message_too_long", L, 1, "token"))
		return 0;
	QString token = lua_tostring(L, 1);
	if (token.size() > max_len) {
		lua_pushboolean(L, true);
		return 1;
	}
	lua_pushboolean(L, false);
	return 1;
}

/* Args: token: string
 * Return: boolean
 */
int is_blacklisted(lua_State *L)
{
	if (!check_args("is_blacklisted", L, 1, "token"))
		return 0;
	QString token = lua_tostring(L, 1);
	bool res = false;

	for (const QRegularExpression &reg : blacklist) {
		if (reg.match(token).hasMatch()) {
			res = true;
			lastreg = reg.pattern();
			break;
		}
	}
	lua_pushboolean(L, res);
	return 1;
}

/* Args: token: string
 * Return: boolean
 */
int is_whitelisted(lua_State *L)
{
	if (!check_args("is_whitelisted", L, 1, "token"))
		return 0;
	QString token = lua_tostring(L, 1);
	bool res = false;

	for (const QRegularExpression &reg : whitelist) {
		if (reg.match(token).hasMatch()) {
			res = true;
			lastregwl = reg.pattern();
			break;
		}
	}
	lua_pushboolean(L, res);
	return 1;
}

int get_mode(lua_State *L)
{
	lua_pushinteger(L, mode);
	return 1;
}

int get_lastreg(lua_State *L)
{
	lua_pushstring(L, lastreg.toUtf8().constData());
	return 1;
}

int get_lastregwl(lua_State *L)
{
	lua_pushstring(L, lastregwl.toUtf8().constData());
	return 1;
}

static void register_functions(lua_State* L)
{
	lua_getglobal(L, "filter");
	if (!lua_istable(L, -1)) {
		lua_pushstring(L, "filter not a table?");
		lua_error(L);
	}

	lua_pushcfunction(L, is_whitelisted);
	lua_setfield(L, -2, "is_whitelisted");

	lua_pushcfunction(L, is_blacklisted);
	lua_setfield(L, -2, "is_blacklisted");

	lua_pushcfunction(L, is_message_too_long);
	lua_setfield(L, -2, "is_message_too_long");

	lua_pushcfunction(L, export_regex);
	lua_setfield(L, -2, "export_regex");

	lua_pushcfunction(L, get_mode);
	lua_setfield(L, -2, "get_mode");

	lua_pushcfunction(L, get_lastreg);
	lua_setfield(L, -2, "get_lastreg");

	lua_pushcfunction(L, get_lastregwl);
	lua_setfield(L, -2, "get_lastregwl");

	lua_setglobal(L, "filter");
}

static void store_conf(const char *key, int val)
{
	m.get_mod_storage();
	storage s(m.L);
	s.set_int(key, val);
	m.pop_modstorage();
}

static struct cmd_ret filter_console(const char *name, QString param)
{
	QStringList params = param.split(" ", Qt::SkipEmptyParts);

	if (params.isEmpty())
		return {false, "Usage: /filter <command> <args>\nCheck /filter help"};

	if (params[0] == "export") {
		if (params.size() != 2 || (params[1] != "blacklist" && params[1] != "whitelist"))
			return {false, "Usage: /filter export [ blacklist | whitelist ]"};

		auto& list = (params[1].toLower() == "blacklist") ? blacklist : whitelist;
		if (export_regex_list(list, params[1])) {
			qLog << "filter: " << name << " exported " << params[1] << " to file";
			return {true, params[1] + " exported successfully to file"};
		}
		return {false, "Error opening filter's " % params[1] % " file."};
	}

	if (params[0] == "getenforce") {
		if (mode)
			return {true, "Enforcing"};
		else
			return {true, "Permissive"};
	}

	if (params[0] == "get_max_len") {
		return {true, QByteArray::number(max_len)};
	}

	if (params[0] == "setenforce") {
		if (params.size() == 2) {
			QString param = params[1].toLower();

			struct ModeEntry {
				QStringList values;
				uint mode;
				QMyByteArray name;
			};
			const QVector<ModeEntry> modeMap = {
			        {{"1", "enforcing"}, ENFORCING, "Enforcing"},
			        {{"0", "permissive"}, PERMISSIVE, "Permissive"}
			};

			for (const auto& entry : modeMap)
			if (entry.values.contains(param)) {
				if (mode == entry.mode)
					return {false, "Filter mode already set to " + entry.name};
				mode = entry.mode;
				store_conf("mode", entry.mode);
				qLog << "filter: " << name << " set mode to " << entry.name;
				return {true, "New filter mode: " + entry.name};
			}
		}
		return {false, "Usage: /filter setenforce [ Enforcing | Permissive | 1 | 0 ]"};
	}

	if (params[0] == "set_max_len") {
		if (params.size() != 2)
			return {false, "Usage: /filter set_max_len <max_len: number>"};
		bool ok;
		uint max_len_changed = params[1].toUInt(&ok);
		if (!ok)
			return {false, "Usage: /filter set_max_len <max_len: number>"};
		if (max_len == max_len_changed)
			return {false, "Maximum message length was already " + QByteArray::number(max_len)};
		max_len = max_len_changed;
		store_conf("max_len", max_len);

		qLog << "filter: " << name << " set max_len to " << max_len;
		return {true, "Maximum message length changed"};
	}

	if (params[0] == "help") {
		return {true, R"(The filter works by matching regex patterns from lists with each message to try and find the match.
If match is found in blacklist, the message is blocked.
It passes if no match is found in blacklist, or if a match is found in whitelist (in which case the blacklist isn't even checked)

List of possible commands:
export <list_name>: Export given list to a file in mod folder
getenforce: Get the current filter mode
get_max_len: Get currently set maximum message length
setenforce <mode>: Set new filter mode
set_max_len <max_len>: Set new maximum message length
help: Print this help menu
dump: Dump current blacklist to chat
dumpwl: Dump current whitelist to chat
last: Get the regex pattern that was last matched from blacklist
lastwl: Get the regex pattern that was last matched from whitelist
reload: Reload blacklist from file in mod folder
reloadwl: Reload whitelist from file in mod folder
addwl <regex>: Add regex to whitelist
rmwl <regex>: Remove regex from whitelist
add <regex>: Add regex to blacklist
rm <regex>: Remove regex frmo blacklist)"};
	}
	struct ListEntry {
		QString name;
		std::forward_list<QRegularExpression> &list;
		QString &lastreg;
	};
	const QVector<ListEntry> listMap = {
	        {"blacklist", blacklist, lastreg},
	        {"whitelist", whitelist, lastregwl}
	};
	bool should_run = true;
	int li;

	if (params[0] == "dump") li = 0;
	else if (params[0] == "dumpwl") li = 1;
	else should_run = false;
	if (should_run) {
		QString res = listMap[li].name + " contents:\n";
		for (const QRegularExpression &reg : listMap[li].list)
			res += QStringLiteral("\"") % reg.pattern() % QStringLiteral("\"\n");
		res.chop(1);
		return {true, res.toUtf8()};
	}
	should_run = true;

	if (params[0] == "last") li = 0;
	else if (params[0] == "lastwl") li = 1;
	else should_run = false;
	if (should_run) {
		if (lastreg.isEmpty())
			return {false, "No " % listMap[li].name % " regex was matched since server startup."};
		return {true, "Last blacklist regex: " + listMap[li].lastreg};
	}
	should_run = true;

	if (params[0] == "reload") li = 0;
	else if (params[0] == "reloadwl") li = 1;
	else should_run = false;
	if (should_run) {
		caller = name;
		m.get_mod_storage();
		storage s(m.L);
		s.set_string(listMap[li].name, "");
		qLog << "Modstorage " << listMap[li].name << " erased";
		QStringList string_list = load_string_list(s, listMap[li].name);
		qLog << "Loaded " << patterns_to_reglist(listMap[li].list, string_list) << " entries";
		m.pop_modstorage();
		caller = nullptr;
		qLog << "filter: " << name << " reloaded " << listMap[li].name << " from file";
		return {true, ""};
	}
	should_run = true;

	if (params[0] == "add") li = 0;
	else if (params[0] == "addwl") li = 1;
	else should_run = false;
	if (should_run) {
		if (params.size() != 2)
			return {false, "Usage: /filter add|addwl <regex>"};
		QRegularExpression reg(params[1], QRegularExpression::CaseInsensitiveOption | QRegularExpression::UseUnicodePropertiesOption);
		if (!reg.isValid())
			return {false, "Invalid regex: " + reg.errorString()};
		listMap[li].list.push_front(reg);
		save_regex_list(listMap[li].list, listMap[li].name);
		qLog << "filter: " << name << " added \'" << params[1] << "\' to " << listMap[li].name;
		return {true, "Added \'" % params[1] % "\' to " % listMap[li].name};
	}
	should_run = true;

	if (params[0] == "rm") li = 0;
	else if (params[0] == "rmwl") li = 1;
	else should_run = false;
	if (should_run) {
		if (params.size() != 2)
			return {false, "Usage: /filter rm|rmwl <regex>"};
		auto count = listMap[li].list.remove_if([&params](QRegularExpression &reg){ return reg.pattern() == params[1]; });
		if (count != 0)
			save_regex_list(listMap[li].list, listMap[li].name);
		qLog << "filter: " << name << " removed \'" << params[1] << "\' from " << listMap[li].name << ". Affected " << count << " entries";
		return {true, "Removed " % QString::number(count) % " entries from " % listMap[li].name};
	}

	return {false, "Unknown command. Usage: /filter <command> <args>\nCheck /filter help"};
}

extern "C" int luaopen_mylibrary(lua_State *L)
{
	m.set_state(L);

	modpath = m.get_modpath(m.get_current_modname());
	m.get_mod_storage();
	storage s(L);
	if (s.contains("mode"))
		mode = s.get_int("mode");
	if (s.contains("max_len"))
		max_len = s.get_int("max_len");

#ifdef COMPATIBILITY
	if (s.contains("maxLen")) {
		max_len = s.get_int("maxLen");
		s.set_string("maxLen", "");
		s.set_int("max_len", max_len);
	}
	if (s.contains("words")) {
		QByteArray blacklist = s.get_string("words");
		s.set_string("words", "");
		s.set_string("blacklist", blacklist.constData());
	}
#endif

	QStringList string_whitelist = load_string_list(s, "whitelist");
	QStringList string_blacklist = load_string_list(s, "blacklist");
	m.pop_modstorage();

	qLog << "Loaded " << patterns_to_reglist(blacklist, string_blacklist) << " blacklist entries";
	qLog << "Loaded " << patterns_to_reglist(whitelist, string_whitelist) << " whitelist entries";
	register_functions(L);
	m.register_chatcommand("filter", QStringList("filtering"), "filter management console", "<command> <args>", filter_console);

	return 0;
}
