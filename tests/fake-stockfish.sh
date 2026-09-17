#!/bin/sh
# Minimal UCI engine for tests: fixed evaluation and a two-move principal variation.
while IFS= read -r line; do
	case "$line" in
	uci)
		echo "id name FakeFish"
		echo "uciok"
		;;
	isready) echo "readyok" ;;
	go*)
		case "$line" in
		"go depth "*) depth=${line#go depth } ;;
		*) exit 1 ;;
		esac
		case "$depth" in *[!0-9]* | "") exit 1 ;; esac
		echo "info depth 4 score cp 10 nodes 1 pv e7e5 g1f3"
		sleep "${GAMBITO_TEST_ENGINE_DELAY:-0.3}"
		echo "info depth $depth score cp 35 nodes 1 pv e7e5 g1f3"
		echo "bestmove e7e5"
		;;
	quit) exit 0 ;;
	esac
done
