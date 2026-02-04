## Settings

- `secure.c_mods=mod1,mod2,...` - Additional mods (besides those in `secure.trusted_mods`) allowed to use `algorithms.load_library()` and `algorithms.require()`
- `algorithms.verbose=true|false` - Whether to display errors during load time. Disable if you know what doesn't work and are fine with it, e.g. if you intentionally run algorithms without C++ part and/or without it being listed in secure.trusted_mods. Default: true

## API reference
_Functions marked with (C++) depend on the C++ module of this mod. Functions marked with (OSname) depend on that operating system. If you can access them in an unsupported environment, you will find a dummy implementation in their place to avoid crashes. The dummy implementation will just return failure on every call._

- boolean `algorithms.load_library(libpath: string)` - load library at the path libpath relative to the mod folder, or (default) `lib<modname>.[so|dll]` in the calling mod folder. Return true if successful. Must be called during load time.
- library `algorithms.require(libname: string)` - A wrapper around ie.require that handles nested require calls. Should be used instead of ie.require directly. Must be called during load time.
- boolean `algorithms.table_contains(t: indexed_table, value)` - return true if value exists in indexed table t, and false otherwise
- number `algorithms.parse_time(t: string)` - convert the time expression (e.g. 5h) to seconds. return 0 for invalid input.
- string `algorithms.time_to_string(sec: number)` - Convert time in seconds to an approximate human-readable string. E.g. 140sec -> "2 minutes"
- indexed_table `algorithms.nGram(string: string, window_size: number)` - Split the string into nGrams of size window_size
- indexed_table `algorithms.createMatrix(n: number, m: number)` -  Create a zero-filled matrix of integers with dimensions n x m
- string `algorithms.matostr(matrix: indexed_table)` - Convert a matrix to a human-readable string, aligning columns and rows
- string `algorithms.lcs(string1: string, string2: string)` - Find Longest Common Subsequence (LCS) between string1 and string2
- boolean, [key] `algorithms.hasCommonKey(tbl1: table, tbl2: table)` - -- Check if two tables have a common key and what it is. Return the key if found.
- customType `algorithms.getconfig(key: string, default: customType, [optional] modstorage)` - Return the object serialized under "key" in modstorage, or `default` if the object doesn't exist. modstorage is either passed as parameter, or obtained with algorithms.get_mod_storage(). If called after load time, modstorage must be supplied.
- modstorage `algorithms.get_mod_storage()` - Return a modstorage userobject and saves it inside algorithms mod so that it doesn't have to be passed as parameter later. Must be called during mod load time.
- table `algorithms.request_insecure_environment()` - Return a table with privileged functions if the mod is listed in secure.trusted_mods, otherwise return nil
- string `algorithms.os` - A variable containing the operating system name
- table `algorithms.bit` - Exported LuaJIT bit module for bitwise operations
- table `algorithms.get_xattr_storage()` (Linux) - Call during load time to get a table of "safe" xattr functions. They treat world_path/modname as root and allow operations only under that directory tree. Other than the difference in path interpretation, the API is the same as for their insecure counterparts.
- number `algorithms.XATTR_CREATE` - constant used with setxattr(2)
- number `algorithms.XATTR_REPLACE` - constant used with setxattr(2)
- table `algorithms.errno` - _Exists only_ on Linux! A table mapping error names to error codes. E.g. algorithms.errno.EPERM = 1

### Insecure Environment API

- string, string, integer `ie_env.execute(argv: table)` (C++) - Execute program argv[1] with arguments argv and return the strings captured on stdout and stderr in that order, and the program's exit code.
- err (string or nil), errno (number or nil) `ie_env.setxattr(path: string, name: string, value: string or nil, flags (optional): integer or nil)` (Linux) - Wrapper around setxattr(2) if value is string. Remove extended attribute if value is nil (flags are ignored then).
- value (string or nil), err (string or nil), errno (number or nil) `ie_env.getxattr(path: string, name: string)` (Linux) - Wrapper around getxattr(2).
- err (string or nil), errno (number or nil) `ie_env.mkfifo(path: string, mode: integer)` (Linux) - Wrapper around mkfifo(2).
- data (string or nil (on EOF or error)), err (string or nil), errno (number or nil) `ie_env.read(fd: integer, size: integer)` (Linux) - Wrapper around read(2). Returns empty string for zero-size read. Returns nil, nil, nil on EOF.
- bytes_written (number or nil), err (string or nil), errno (number or nil) `ie_env.write(fd: integer, buf: string)` (Linux) - Wrapper around write(2). Returns 0 for zero-length buffer.
- result (number or nil), err (string or nil), errno (number or nil) `ie_env.fcntl(fd: integer, op: integer, ...)` (Linux) - Wrapper around fcntl(2). Accepts 0, 1, or 2 additional integer arguments. Use `algorithms.fcntl.*` for command constants.
- err (string or nil), errno (number or nil) `ie_env.signal(signum: integer, action: sighandler_t)` (Linux) - Wrapper around signal(2). Only accepts SIG_DFL or SIG_IGN as action. Use `algorithms.signal.*` for SIG_DFL, SIG_IGN, and SIG_ERR constants.
- new fd (number or nil), err (string or nil), errno (number or nil) `ie_env.open(path: string, flags: integer, mode (optional): integer)` (Linux) - Wrapper around open(2). Accepts optional mode argument for O_CREAT.
- err (string or nil), errno (number or nil) `ie_env.close(fd: integer)` (Linux) - Wrapper around close(2).
- err (string or nil), errno (number or nil) `ie_env.unlink(path: string)` (Linux) - Wrapper around unlink(2).

**Constants:** `algorithms.errno.*`, `algorithms.signal.*`, and `algorithms.fcntl.*` are available for error numbers, signal actions, and fcntl commands respectively.
