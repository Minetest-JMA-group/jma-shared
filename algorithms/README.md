## Settings

- `secure.c_mods=mod1,mod2,...` - Additional mods (besides those in `secure.trusted_mods`) allowed to use `algorithms.load_library()` and `algorithms.require()`
- `algorithms.verbose=true|false` - Whether to display errors during load time. Disable if you know what doesn't work and are fine with it, e.g. if you intentionally run algorithms without C++ part and/or without it being listed in secure.trusted_mods. Default: true

## API reference
_Functions marked with (C++) depend on the C++ module of this mod. If you can access them, you will find a dummy implementation in their place to avoid crashes. The dummy implementation will just return failure on every call._

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

### Insecure Environment API

- string, string, integer `ie_env.execute(argv: table)` (C++) - Execute program argv[1] with arguments argv and return the strings captured on stdout and stderr in that order, and the program's exit code
