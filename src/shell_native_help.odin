#+build linux
package main

import "core:fmt"
import "core:strings"
import posix "core:sys/posix"

// Stable native help metadata; no external shell is consulted at runtime.
Native_Shell_Help_Topic :: struct {name,synopsis,description:string}
native_shell_help_topic_data := [?]Native_Shell_Help_Topic{
        {"!","! PIPELINE","Execute PIPELINE, which can be a simple command, and negate PIPELINE's"},
        {"%","job_spec [&]","Resume job in foreground."},
        {"(( ... ))","(( expression ))","Evaluate arithmetic expression."},
        {".",". [-p path] filename [arguments]","Execute commands from a file in the current shell."},
        {":",":","Null command."},
        {"[","[ arg... ]","Evaluate conditional expression."},
        {"[[ ... ]]","[[ expression ]]","Execute conditional command."},
        {"alias","alias [-p] [name[=value] ... ]","Define or display aliases."},
        {"bg","bg [job_spec ...]","Move jobs to the background."},
        {"bind","bind [-lpsvPSVX] [-m keymap] [-f filename] [-q name] [-u name] [-r keyseq] [-x keyseq:shell-command] [keyseq:readline-function or readline-command]","Set Readline key bindings and variables."},
        {"break","break [n]","Exit for, while, or until loops."},
        {"builtin","builtin [shell-builtin [arg ...]]","Execute shell builtins."},
        {"caller","caller [expr]","Return the context of the current subroutine call."},
        {"case","case WORD in [PATTERN [| PATTERN]...) COMMANDS ;;]... esac","Execute commands based on pattern matching."},
        {"cd","cd [-L|[-P [-e]]] [-@] [dir]","Change the shell working directory."},
        {"clear","clear","Clear the terminal display."},
        {"command","command [-pVv] command [arg ...]","Execute a simple command or display information about commands."},
        {"compgen","compgen [-V varname] [-abcdefgjksuv] [-o option] [-A action] [-G globpat] [-W wordlist] [-F function] [-C command] [-X filterpat] [-P prefix] [-S suffix] [word]","Display possible completions depending on the options."},
        {"complete","complete [-abcdefgjksuv] [-pr] [-DEI] [-o option] [-A action] [-G globpat] [-W wordlist] [-F function] [-C command] [-X filterpat] [-P prefix] [-S suffix] [name ...]","Specify how arguments are to be completed by Readline."},
        {"compopt","compopt [-o|+o option] [-DEI] [name ...]","Modify or display completion options."},
        {"continue","continue [n]","Resume for, while, or until loops."},
        {"coproc","coproc [NAME] command [redirections]","Create a coprocess named NAME."},
        {"declare","declare [-aAfFgiIlnrtux] [name[=value] ...] or declare -p [-aAfFilnrtux] [name ...]","Set variable values and attributes."},
        {"dirs","dirs [-clpv] [+N] [-N]","Display directory stack."},
        {"disown","disown [-h] [-ar] [jobspec ... | pid ...]","Remove jobs from current shell."},
        {"echo","echo [-neE] [arg ...]","Write arguments to the standard output."},
        {"enable","enable [-a] [-dnps] [-f filename] [name ...]","Enable and disable shell builtins."},
        {"eval","eval [arg ...]","Execute arguments as a shell command."},
        {"exec","exec [-cl] [-a name] [command [argument ...]] [redirection ...]","Replace the shell with the given command."},
        {"exit","exit [n]","Exit the shell."},
        {"export","export [-fn] [name[=value] ...] or export -p [-f]","Set export attribute for shell variables."},
        {"false","false","Return an unsuccessful result."},
        {"fc","fc [-e ename] [-lnr] [first] [last] or fc -s [pat=rep] [command]","Display or execute commands from the history list."},
        {"fg","fg [job_spec]","Move job to the foreground."},
        {"for","for NAME [in WORDS ... ] ; do COMMANDS; done","Execute commands for each member in a list."},
        {"for ((","for (( exp1; exp2; exp3 )); do COMMANDS; done","Arithmetic for loop."},
        {"function","function name { COMMANDS ; } or name () { COMMANDS ; }","Define shell function."},
        {"getopts","getopts optstring name [arg ...]","Parse option arguments."},
        {"hash","hash [-lr] [-p pathname] [-dt] [name ...]","Remember or display program locations."},
        {"help","help [-dms] [pattern ...]","Display information about builtin commands."},
        {"history","history [-c] [-d offset] [n] or history -anrw [filename] or history -ps arg [arg...]","Display or manipulate the history list."},
        {"if","if COMMANDS; then COMMANDS; [ elif COMMANDS; then COMMANDS; ]... [ else COMMANDS; ] fi","Execute commands based on conditional."},
        {"jobs","jobs [-lnprs] [jobspec ...] or jobs -x command [args]","Display status of jobs."},
        {"kill","kill [-s sigspec | -n signum | -sigspec] pid | jobspec ... or kill -l [sigspec]","Send a signal to a job."},
        {"let","let arg [arg ...]","Evaluate arithmetic expressions."},
        {"local","local [option] name[=value] ...","Define local variables."},
        {"logout","logout [n]","Exit a login shell."},
        {"mapfile","mapfile [-d delim] [-n count] [-O origin] [-s count] [-t] [-u fd] [-C callback] [-c quantum] [array]","Read lines from the standard input into an indexed array variable."},
        {"popd","popd [-n] [+N | -N]","Remove directories from stack."},
        {"printf","printf [-v var] format [arguments]","Formats and prints ARGUMENTS under control of the FORMAT."},
        {"pushd","pushd [-n] [+N | -N | dir]","Add directories to stack."},
        {"pwd","pwd [-LP]","Print the name of the current working directory."},
        {"read","read [-Eers] [-a array] [-d delim] [-i text] [-n nchars] [-N nchars] [-p prompt] [-t timeout] [-u fd] [name ...]","Read a line from the standard input and split it into fields."},
        {"readarray","readarray [-d delim] [-n count] [-O origin] [-s count] [-t] [-u fd] [-C callback] [-c quantum] [array]","Read lines from a file into an array variable."},
        {"readonly","readonly [-aAf] [name[=value] ...] or readonly -p","Mark shell variables as unchangeable."},
        {"return","return [n]","Return from a shell function."},
        {"select","select NAME [in WORDS ... ;] do COMMANDS; done","Select words from a list and execute commands."},
        {"set","set [-abefhkmnptuvxBCEHPT] [-o option-name] [--] [-] [arg ...]","Set or unset values of shell options and positional parameters."},
        {"shift","shift [n]","Shift positional parameters."},
        {"shopt","shopt [-pqsu] [-o] [optname ...]","Set and unset shell options."},
        {"source","source [-p path] filename [arguments]","Execute commands from a file in the current shell."},
        {"suspend","suspend [-f]","Suspend shell execution."},
        {"test","test [expr]","Evaluate conditional expression."},
        {"time","time [-p] pipeline","Report time consumed by pipeline's execution."},
        {"times","times","Display process times."},
        {"trap","trap [-Plp] [[action] signal_spec ...]","Trap signals and other events."},
        {"true","true","Return a successful result."},
        {"tview","tview filename","Open a document or media file in the embedded viewer."},
        {"type","type [-afptP] name [name ...]","Display information about command type."},
        {"typeset","typeset [-aAfFgiIlnrtux] name[=value] ... or typeset -p [-aAfFilnrtux] [name ...]","Set variable values and attributes."},
        {"ulimit","ulimit [-SHabcdefiklmnpqrstuvxPRT] [limit]","Modify shell resource limits."},
        {"umask","umask [-p] [-S] [mode]","Display or set file mode mask."},
        {"unalias","unalias [-a] name [name ...]","Remove each NAME from the list of defined aliases."},
        {"unset","unset [-f] [-v] [-n] [name ...]","Unset values and attributes of shell variables and functions."},
        {"until","until COMMANDS; do COMMANDS-2; done","Execute commands as long as a test does not succeed."},
        {"variables","variables - Names and meanings of some shell variables","Common shell variable names and usage."},
        {"wait","wait [-fn] [-p var] [id ...]","Wait for job completion and return exit status."},
        {"while","while COMMANDS; do COMMANDS-2; done","Execute commands as long as a test succeeds."},
        {"{ ... }","{ COMMANDS ; }","Group commands as a unit."},
}
native_shell_help_topics :: proc()->[]Native_Shell_Help_Topic {return native_shell_help_topic_data[:]}

native_shell_help_detail :: proc(topic:Native_Shell_Help_Topic)->string {
    switch topic.name {
    case "help":return "Specify one or more topic names, prefixes, or shell patterns.\nOptions: -d prints descriptions; -s prints synopses; -m prints manual sections.\nReturns zero when any requested topic matches, one when none match, and two for an invalid option."
    case "read":return "Read standard input into NAME variables, splitting fields using IFS.\n-r preserves backslashes; -a assigns an indexed array; -d selects a delimiter.\n-n reads up to a character count; -N reads exactly that many characters.\n-p supplies a prompt; -i supplies initial text; -e/-E enable editing.\n-s hides terminal input; -t sets a timeout; -u selects an input descriptor.\nReturns nonzero at end of input, on timeout, or when an assignment fails."
    case "set":return "With no arguments, print shell variables. Use - or + to enable or disable options.\n-o NAME changes a named option; -o lists settings and +o prints reusable commands.\n-- ends option processing and replaces the positional parameters with the remaining arguments."
    case "shopt":return "Enable (-s), disable (-u), or query (-q) named shell options.\n-p prints reusable commands; -o selects the set -o option namespace.\nWithout option names, list options. A failed query or unknown option returns nonzero."
    case "source",".":return "Read FILENAME in the current shell, optionally replacing positional parameters while it runs.\n-p PATH searches the supplied colon-separated path. Otherwise sourcepath controls PATH lookup.\nReturns the final command status, or a nonzero status when the file cannot be read."
    case "declare","typeset","local":return "Create or display variables and attributes. -a/-A select indexed/associative arrays;\n-i selects arithmetic assignment; -n creates a name reference; -r makes a value readonly;\n-x exports it; -l/-u convert letter case. -p displays declarations, -f/-F functions.\nLocal declarations belong to the active function; -g changes a global binding;\n-I inherits an outer variable's value and attributes. local - saves function-local shell options."
    case "complete","compgen","compopt":return "Select completion actions with -A, words with -W, a glob with -G, a function with -F,\nor a command with -C. -P/-S add a prefix/suffix; -X filters results.\n-o selects completion options. complete stores specifications; compgen prints candidates;\ncompopt modifies the active or named completion specification."
    case "trap":return "Install ACTION for the named signals or EXIT, DEBUG, RETURN, and ERR events.\nAn empty action ignores a signal; - restores its default behavior.\n-l lists signal names; -p prints definitions; -P queries trap actions."
    case "printf":return "Print FORMAT using the supplied arguments, repeating it as needed.\n-v VAR stores the result in a shell variable instead of writing it.\n%b interprets backslash escapes, %q prints shell-quoted text, and %(FORMAT)T formats time."
    case "wait":return "Wait for the supplied process or job identifiers, or all jobs when none are supplied.\n-n waits for the next selected child; -p VAR stores its identifier; -f waits for termination.\nReturns the waited child's status, or nonzero when no matching child exists."
    case "variables":return "Shell parameters include $0, $1... and $@/$*; $? is the previous status, $$ the shell PID,\n$! the latest asynchronous PID, $# the argument count, and $- the option letters.\nPATH selects command search directories; HOME and CDPATH affect directory changes.\nIFS controls splitting. PS1/PS2/PS4 and PROMPT_COMMAND control prompts and tracing.\nBASH_SOURCE, FUNCNAME, BASH_LINENO, BASH_ARGC, and BASH_ARGV describe execution frames.\nBASHOPTS and SHELLOPTS expose enabled options. BASH_COMPAT selects historical behavior.\nHISTFILE, HISTSIZE, HISTFILESIZE, HISTCONTROL, and HISTIGNORE control history.\nSee help for the associated builtin for usage."
    }
    return "Arguments and options are shown in the synopsis. Returns the command's status."
}

native_shell_help_print :: proc(topic:Native_Shell_Help_Topic,mode:u8) {
    detail,_:=strings.replace_all(native_shell_help_detail(topic),"\n","\n    ")
    switch mode {
    case 'd':fmt.printf("%s - %s\n",topic.name,topic.description)
    case 's':fmt.printf("%s: %s\n",topic.name,topic.synopsis)
    case 'm':fmt.printf("NAME\n    %s - %s\n\nSYNOPSIS\n    %s\n\nDESCRIPTION\n    %s\n\n    %s\n\nSEE ALSO\n    bash(1)\n\nIMPLEMENTATION\n    Terminal+ native Odin shell\n",topic.name,topic.description,topic.synopsis,topic.description,detail)
    case:fmt.printf("%s: %s\n    %s\n\n    %s\n",topic.name,topic.synopsis,topic.description,detail)
    }
}

native_shell_builtin_help :: proc(args:[]string)->bool {
    if len(args)<2||args[1]!="--help" {return false}
    switch args[0] {case "test","[","true","false",":","echo":return false}
    for topic in native_shell_help_topics() {
        if topic.name==args[0] {native_shell_help_print(topic,0);return true}
    }
    return false
}

native_shell_help_builtin :: proc(shell:^Native_Shell,args:[]string)->int {
    description,synopsis,manual:bool;index:=1
    for index<len(args)&&len(args[index])>1&&args[index][0]=='-' {
        argument:=args[index]
        if argument=="--" {index+=1;break}
        for flag in transmute([]u8)argument[1:] {
            switch flag {case 'd':description=true;case 's':synopsis=true;case 'm':manual=true;case:fmt.eprintf("help: -%c: invalid option\nhelp: usage: help [-dms] [pattern ...]\n",flag);return 2}
        }
        index+=1
    }
    topics:=native_shell_help_topics()
    if index==len(args) {
        fmt.println("Terminal+ native Odin shell\nThese shell commands are defined internally. Type `help name' for details.\nA star (*) next to a name means that the command is disabled.\n")
        for topic in topics {marker:=" ";if shell.compat.disabled[topic.name] {marker="*"};fmt.printf("%s%s\n",marker,topic.synopsis)}
        return 0
    }
    mode:u8
    if synopsis {mode='s'};if manual {mode='m'};if description {mode='d'}
    matched:=false;heading:=false
    for pattern in args[index:] {
        prefix_found,exact_found:bool
        for topic in topics {if strings.has_prefix(topic.name,pattern) {prefix_found=true};if topic.name==pattern {exact_found=true}}
        if !prefix_found&&!heading {
            glob_found:=false
            for topic in topics {if posix.fnmatch(strings.clone_to_cstring(pattern),strings.clone_to_cstring(topic.name),{})==0 {glob_found=true;break}}
            if glob_found {
                label:="keyword";if len(args[index:])>1 {label="keywords"}
                fmt.printf("Shell commands matching %s `%s'\n\n",label,strings.join(args[index:],", "));heading=true
            }
        }
        for topic in topics {
            found:=strings.has_prefix(topic.name,pattern)
            if exact_found {found=topic.name==pattern}
            if !prefix_found {found=posix.fnmatch(strings.clone_to_cstring(pattern),strings.clone_to_cstring(topic.name),{})==0}
            if found {native_shell_help_print(topic,mode);matched=true}
        }
    }
    if !matched {fmt.eprintf("help: no help topics match `%s'. Try `help help'.\n",strings.join(args[index:],", "));return 1}
    return 0
}
