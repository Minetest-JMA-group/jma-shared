## Settings

- secure.c_mods=mod1,mod2,... - Mods allowed to use algorithms.load_library()

## API reference

- number `algorithms.countCaps(string: string)` - Count capital letters in the string. Supports different scripts. (C++)
- string `algorithms.lower(string: string)` - Turn the string to all-lowercase. Supports different scripts. (C++)
- string `algorithms.upper(string: string)` - Turn the string to all-uppercase. Supports different scripts. (C++)
- boolean `algorithms.load_library(libpath: string)` - load library at the path libpath relative to the mod folder, or (default) mylibrary.so in the calling mod folder. Return true if successful.
- boolean `algorithms.table_contains(t: indexed_table, value)` - return true if value exists in indexed table t, and false otherwise
- number `algorithms.parse_time(t: string)` - convert the time expression (e.g. 5h) to seconds. return 0 for invalid input.
- string `algorithms.time_to_string(sec: number)` - Convert time in seconds to an approximate human-readable string. E.g. 140sec -> "2 minutes"
- indexed_table `algorithms.nGram(string: string, window_size: number)` - Split the string into nGrams of size window_size
- indexed_table `algorithms.createMatrix(n: number, m: number)` -  Create a zero-filled matrix of integers with dimensions n x m
- string `algorithms.matostr(matrix: indexed_table)` - Convert a matrix to a human-readable string, aligning columns and rows
- string `algorithms.lcs(string1: string, string2: string)` - Find Longest Common Substring (LCS) between string1 and string2
- boolean, [key] `algorithms.hasCommonKey(tbl1: table, tbl2: table` - -- Check if two tables have a common key and what it is. Return the key if found.
- customType `algorithms.getconfig(key: string, default: customType, [optional] modstorage)` - Return the object serialized under "key" in modstorage, or `default` if the object doesn't exist. modstorage is either passed as parameter, or obtained with algorithms.get_mod_storage()
- modstorage `algorithms.get_mod_storage()` - Return a modstorage userobject and saves it inside algorithms mod so that it doesn't have to be passed as parameter later. Must be called during mod load time.
