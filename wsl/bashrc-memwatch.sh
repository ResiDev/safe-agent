# >>> memwatch >>>
# Tells you if the last WSL shutdown was an OOM crash. Remove with: memwatch-uninstall
if [ -e "${XDG_STATE_HOME:-$HOME/.local/state}/memwatch/UNREAD" ]; then
  printf '\033[1;31m!! Last WSL shutdown was an OOM crash.\033[0m Run \033[1mmemwatch-report\033[0m for the trace (\033[1mmemwatch-ack\033[0m to dismiss)\n'
fi
# <<< memwatch <<<
