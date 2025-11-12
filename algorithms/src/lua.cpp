// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2023 Marko Petrović
#include <luajit-2.1/lua.hpp>
#include <errno.h>
#include <signal.h>
#include <string.h> // strerror, strsignal
#include <string>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>

static char **build_argv(lua_State *L, int table_index)
{
	if (table_index < 0)
		table_index = lua_gettop(L) + table_index + 1;
	size_t len = lua_objlen(L, table_index);
	if (!len)
		return NULL;
	char **argv = new char*[len+1];
	argv[len] = NULL;

	// Iterate over the table
	for (size_t i = 1; i <= len; i++) {
		lua_rawgeti(L, table_index, i);
		if (!lua_isstring(L, -1)) {
			delete[] argv;
			return NULL;
		}
		argv[i-1] = (char*) lua_tostring(L, -1);
	}
	return argv;
}

void read_into_string(int fd, std::string *str)
{
	char buf[1024];
	ssize_t ret;

	while ((ret = read(fd, buf, 1024))) {
		if (ret < 0)
			break;
		str->append(buf, ret);
	}
	close(fd);
}

// Return stdout,stderr,exit_code
// Arguments: argv table
int execute(lua_State *L)
{
	char **argv;
	if (lua_gettop(L) == 0 || !lua_istable(L, 1) || !(argv = build_argv(L, 1))) {
		lua_pushstring(L, "");
		lua_pushstring(L, "Invalid call arguments");
		lua_pushinteger(L, EINVAL);
		return 3;
	}
	int stdout_pipefd[2];
	int stderr_pipefd[2];
	pid_t pid;
	if (pipe(stdout_pipefd) || pipe(stderr_pipefd) || (pid = fork()) < 0) {
		int saved_errno = errno;
		lua_pushstring(L, "");
		lua_pushstring(L, strerror(saved_errno));
		lua_pushinteger(L, saved_errno);
		delete[] argv;
		return 3;
	}
	if (pid == 0) {
		close(stdout_pipefd[0]);
		close(stderr_pipefd[0]);
		// We don't want exit() as that would call various stuff from the inherited current process' memory
		if (dup2(stdout_pipefd[1], 1) < 1 || dup2(stderr_pipefd[1], 2) < 1)
			syscall(SYS_exit_group, errno);
		close(stdout_pipefd[1]);
		close(stderr_pipefd[1]);
		execvp(argv[0], argv);
		syscall(SYS_exit_group, errno);
	}
	close(stdout_pipefd[1]);
	close(stderr_pipefd[1]);
	std::string stdout_str, stderr_str;
	std::thread t1(read_into_string, stdout_pipefd[0], &stdout_str);
	read_into_string(stderr_pipefd[0], &stderr_str);
	siginfo_t info;
	int ret = waitid(P_PID, pid, &info, WEXITED);
	if (ret < 0) {
		info.si_status = errno;
		stderr_str += "[algorithms] waitid: ";
		stderr_str += strerror(info.si_status);
	}
	else {
		if (info.si_code == CLD_KILLED || info.si_code == CLD_DUMPED) {
			if (!stderr_str.empty() && stderr_str.back() != '\n')
				stderr_str += "\n";
			stderr_str += "Killed by signal ";
			stderr_str += strsignal(info.si_status);
			if (info.si_code == CLD_DUMPED)
				stderr_str += "\nCore dumped";
		}
	}
	t1.join();
	lua_pushstring(L, stdout_str.c_str());
	lua_pushstring(L, stderr_str.c_str());
	lua_pushinteger(L, info.si_status);
	delete[] argv;
	return 3;
}

extern "C" int luaopen_mylibrary(lua_State *L)
{
	lua_getglobal(L, "algorithms");
	lua_pushcfunction(L, execute);
	lua_setfield(L, -2, "execute");
	lua_pop(L, 1);
	return 0;
}
