# Kiln: drop straight into the NPU chat on interactive console login.
# Ctrl-C (or typing 'exit') leaves you at a normal shell prompt.
# Disable with:  export KILN_NO_CHAT=1   (or create /etc/kiln-no-chat)
case "$-" in
	*i*)
		if [ -z "$KILN_NO_CHAT" ] && [ ! -e /etc/kiln-no-chat ] && [ -t 0 ] \
		   && command -v kiln-chat >/dev/null 2>&1; then
			export KILN_NO_CHAT=1   # don't re-enter from sub-shells
			kiln-chat
			echo "[kiln] back at the shell. Run 'kiln-chat' to talk again."
		fi
		;;
esac
