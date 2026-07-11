# Kiln: welcome banner on interactive console login (buildroot image). Lists the NPU
# commands. Models are user-supplied / auto-discovered, so name none here. Disable
# with /etc/kiln-no-motd. (On the Armbian install path the install-status banner is
# kiln-motd.sh instead; this static one ships in the flashable image.)
case "$-" in
	*i*)
		if [ -z "$KILN_MOTD" ] && [ ! -e /etc/kiln-no-motd ] && [ -t 1 ]; then
			export KILN_MOTD=1   # print once, not from sub-shells
			printf '\n'
			printf '  ==================================================================\n'
			printf '   Kiln  -  LLM + vision on the RK3576 NPU  (mainline kernel)\n'
			printf '  ==================================================================\n'
			printf '   kiln-chat             chat with an LLM on the NPU\n'
			printf '   kiln-vision <img>     classify/detect an image on the NPU\n'
			printf '   kiln-config           settings / models    kiln-doctor  health\n'
			printf '                         e.g.  kiln-vision /opt/models/test.jpg\n'
			printf '  ==================================================================\n\n'
		fi
		;;
esac
