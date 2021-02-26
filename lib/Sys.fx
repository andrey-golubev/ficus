/*
    This file is a part of ficus language project.
    See ficus/LICENSE for the licensing terms
*/

// Various system services

ccode {
    #include <limits.h>
    #include <stdio.h>
    #include <unistd.h>

    #ifndef PATH_MAX
    #define PATH_MAX 8192
    #endif
}

val argv =
{
    pure nothrow fun argc(): int = ccode { return fx_argc() }
    pure fun argv(i: int): string = ccode { return fx_cstr2str(fx_argv(i), -1, fx_result) }

    [: for i <- 0:argc() {argv(i)} :]
}

val win32 : bool = ccode {
#if defined _WIN32 || defined WINCE
    true
#else
    false
#endif
}

val unix : bool = ccode {
#if defined __linux__ || defined __unix__ || defined __MACH__ || \
    defined __APPLE__ || defined BSD || defined __hpux || \
    defined _AIX || defined __sun
    true
#else
    false
#endif
}

fun appname() = List.hd(argv)
fun arguments() = List.tl(argv)

pure nothrow fun getTickCount(): int64 = ccode { return fx_tickcount() }
pure nothrow fun getTickFrequency(): double = ccode { return fx_tickfreq() }

fun remove(name: string): void = ccode
{
    fx_cstr_t name_;
    int fx_status = fx_str2cstr(name, &name_, 0, 0);
    if (fx_status >= 0) {
        if(remove(name_.data) != 0)
            fx_status = FX_SET_EXN_FAST(FX_EXN_IOError);
        fx_free_cstr(&name_);
    }
    return fx_status;
}

fun rename(name: string, new_name: string): bool = ccode
{
    fx_cstr_t name_, new_name_;
    int fx_status = fx_str2cstr(name, &name_, 0, 0);
    if (fx_status >= 0) {
        fx_status = fx_str2cstr(new_name, &new_name_, 0, 0);
        if (fx_status >= 0) {
            if(rename(name_.data, new_name_.data) != 0)
                fx_status = FX_SET_EXN_FAST(FX_EXN_IOError);
            fx_free_cstr(&new_name_);
        }
        fx_free_cstr(&name_);
    }
    return fx_status;
}

fun getcwd(): string = ccode {
    char buf[PATH_MAX+16];
    char* p = getcwd(buf, PATH_MAX);
    return fx_cstr2str(p, p ? -1 : 0, fx_result);
}

fun command(cmd: string): int = ccode {
    fx_cstr_t cmd_;
    int fx_status = fx_str2cstr(cmd, &cmd_, 0, 0);
    if (fx_status >= 0) {
        *fx_result = system(cmd_.data);
        fx_free_cstr(&cmd_);
    }
    return fx_status;
}
