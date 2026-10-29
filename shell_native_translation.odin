#+build linux
package main

import "core:strings"
import libc "core:c/libc"
import posix "core:sys/posix"

// gettext is part of the glibc already used by the native Linux executable.
// Keep translation in this process, using the shell's variables even when
// those variables have not been exported to external commands.
foreign import native_shell_translation_lib "system:c"
foreign native_shell_translation_lib {
    @(link_name="dgettext") native_shell_dgettext :: proc(domain,message:cstring)->cstring ---
    @(link_name="bindtextdomain") native_shell_bindtextdomain :: proc(domain,directory:cstring)->cstring ---
}

native_shell_translate :: proc(shell:^Native_Shell,text:string)->(string,bool) {
    domain,_:=native_shell_value_get(shell,"TEXTDOMAIN")
    if domain=="" {return strings.clone(text),false}
    language,_:=native_shell_value_get(shell,"LC_ALL")
    if language=="" {language,_=native_shell_value_get(shell,"LC_MESSAGES")}
    if language=="" {language,_=native_shell_value_get(shell,"LANG")}
    if language=="" {language="C"}
    if language=="C"||language=="POSIX"||strings.has_prefix(language,"C.") {return strings.clone(text),false}

    previous_messages:=strings.clone(string(libc.setlocale(.MESSAGES,nil)))
    previous_ctype:=strings.clone(string(libc.setlocale(.CTYPE,nil)))
    previous_environment: [2]struct {name,value:string,exists:bool}
    for name,index in ([]string{"LANGUAGE","LOCPATH"}) {
        previous_environment[index].name=name
        if old:=posix.getenv(strings.clone_to_cstring(name));old!=nil {
            previous_environment[index].exists=true
            previous_environment[index].value=strings.clone(string(old))
        }
        if value,exists:=native_shell_value_get(shell,name);exists {
            _=posix.setenv(strings.clone_to_cstring(name),strings.clone_to_cstring(value),true)
        } else {_=posix.unsetenv(strings.clone_to_cstring(name))}
    }
    defer {
        for item in previous_environment {
            if item.exists {_=posix.setenv(strings.clone_to_cstring(item.name),strings.clone_to_cstring(item.value),true)}
            else {_=posix.unsetenv(strings.clone_to_cstring(item.name))}
            delete(item.value)
        }
        _=libc.setlocale(.MESSAGES,strings.clone_to_cstring(previous_messages))
        _=libc.setlocale(.CTYPE,strings.clone_to_cstring(previous_ctype))
        delete(previous_messages);delete(previous_ctype)
    }
    // An unavailable locale cannot select a catalog. Do not accidentally use
    // whichever unrelated locale the embedding process happened to have.
    if libc.setlocale(.MESSAGES,strings.clone_to_cstring(language))==nil {return strings.clone(text),false}
    ctype,_:=native_shell_value_get(shell,"LC_ALL")
    if ctype=="" {ctype,_=native_shell_value_get(shell,"LC_CTYPE")}
    if ctype=="" {ctype,_=native_shell_value_get(shell,"LANG")}
    if ctype=="" {ctype="C"}
    _=libc.setlocale(.CTYPE,strings.clone_to_cstring(ctype))

    cdomain:=strings.clone_to_cstring(domain)
    directory,_:=native_shell_value_get(shell,"TEXTDOMAINDIR")
    previous_directory:="";bound:=false
    if directory!="" {
        if old:=native_shell_bindtextdomain(cdomain,nil);old!=nil {previous_directory=strings.clone(string(old))}
        bound=native_shell_bindtextdomain(cdomain,strings.clone_to_cstring(directory))!=nil
    }
    defer {
        if bound&&previous_directory!="" {_=native_shell_bindtextdomain(cdomain,strings.clone_to_cstring(previous_directory))}
        delete(previous_directory)
    }
    translated:=native_shell_dgettext(cdomain,strings.clone_to_cstring(text))
    if translated==nil {return strings.clone(text),false}
    result:=strings.clone(string(translated))
    return result,result!=text
}
