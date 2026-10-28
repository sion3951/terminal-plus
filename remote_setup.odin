package main

// Runs on the authenticated SSH PTY before attaching tmux. Package-manager
// output and administrator prompts remain interactive in the same tab.
// Installing needs an explicit choice; cancellation never opens an ordinary
// shell in place of the requested persistent session.
REMOTE_SESSION_SETUP :: `
minor_setup_root() {
    if [ "$(id -u)" = 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo -- "$@"
    elif command -v doas >/dev/null 2>&1; then
        doas "$@"
    else
        printf '\r\n%s\r\n' 'Administrator access is needed, but sudo and doas are unavailable. Use the setup shell to install tmux with your administrator account.'
        return 1
    fi
}
minor_setup_install() {
    case "$minor_setup_manager" in
        pacman) minor_setup_root pacman -S --needed tmux ;;
        apt-get) minor_setup_root apt-get update && minor_setup_root apt-get install tmux ;;
        dnf) minor_setup_root dnf install tmux ;;
        zypper) minor_setup_root zypper install tmux ;;
        apk) minor_setup_root apk add tmux ;;
        yum) minor_setup_root yum install tmux ;;
        xbps-install) minor_setup_root xbps-install tmux ;;
        pkg) minor_setup_root pkg install tmux ;;
        *)
            printf '\r\n%s\r\n' 'No supported package manager was found. Open the setup shell to install tmux, then exit that shell to continue.'
            return 1 ;;
    esac
}
if ! command -v tmux >/dev/null 2>&1; then
    printf '\r\n%s\r\n%s\r\n' \
        'Set up persistent sessions on this remote machine' \
        'tmux keeps your programs running when you close this app or reboot your local machine.'
    minor_setup_manager=
    for minor_setup_candidate in pacman apt-get dnf zypper apk yum xbps-install pkg; do
        if command -v "$minor_setup_candidate" >/dev/null 2>&1; then
            minor_setup_manager=$minor_setup_candidate
            break
        fi
    done
    if [ -n "$minor_setup_manager" ]; then
        printf '\r\nInstall tmux using %s. Administrator and package confirmation prompts will appear here.\r\n' "$minor_setup_manager"
    else
        printf '\r\n%s\r\n' 'Automatic installation is unavailable on this machine. You can install tmux in the setup shell below.'
    fi
    while ! command -v tmux >/dev/null 2>&1; do
        printf '\r\n%s\r\n%s' \
            '[i] Install tmux   [s] Open setup shell   [r] Check again   [q] Disconnect' \
            'Choose i, s, r, or q, then press Enter: '
        if ! IFS= read -r minor_setup_answer; then
            printf '\r\n%s\r\n' 'Setup disconnected. Reopen this tab to try again.'
            exit 127
        fi
        case "$minor_setup_answer" in
            i|I|install|y|Y|yes)
                if ! minor_setup_install; then
                    printf '\r\n%s\r\n' 'Installation did not finish. Review the message above, retry, or open the setup shell to resolve it.'
                fi ;;
            s|S|shell)
                printf '\r\n%s\r\n%s\r\n' \
                    'Opening a temporary setup shell on this remote machine.' \
                    'Install tmux, then type exit to return here and start your persistent session.'
                minor_setup_shell=${SHELL:-/bin/sh}
                if [ ! -x "$minor_setup_shell" ]; then minor_setup_shell=/bin/sh; fi
                "$minor_setup_shell" -l ;;
            r|R|retry) ;;
            q|Q|n|N|no|cancel|exit)
                printf '\r\n%s\r\n' 'Setup cancelled. Reopen this tab when you are ready to continue.'
                exit 127 ;;
            *) printf '\r\n%s\r\n' 'Choose i to install, s for a setup shell, r to check again, or q to disconnect.' ;;
        esac
        hash -r 2>/dev/null || :
    done
    printf '\r\n%s\r\n\r\n' 'tmux is ready. Opening your persistent session...'
fi
`
