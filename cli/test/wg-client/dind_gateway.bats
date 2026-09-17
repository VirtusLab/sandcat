#!/usr/bin/env bats

setup() {
	load test_helper
	# shellcheck source=../../../cli/templates/devcontainer/sandcat/scripts/wg-client-init.sh
	source "$SCT_TEMPLATEDIR/devcontainer/sandcat/scripts/wg-client-init.sh"
}

teardown() {
	unstub_all
}

@test "setup_dind_gateway NATs the compose subnet into wg0 and drops other forwards" {
	stub iptables \
		"-t nat -A POSTROUTING -s 172.26.0.0/16 -o wg0 -j MASQUERADE : :" \
		"-A FORWARD -s 172.26.0.0/16 -o wg0 -j ACCEPT : :" \
		"-A FORWARD -i wg0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT : :" \
		"-A FORWARD -j DROP : :"

	run setup_dind_gateway 172.26.0.0/16
	assert_success
}
