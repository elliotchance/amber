#!/bin/sh
# install.sh installs amber from the latest release on Linux or macOS:
#
#   curl -fsSL https://raw.githubusercontent.com/elliotchance/amber/main/install.sh | sh
#
# It's installed in ~/.local/bin, or AMBER_INSTALL_DIR if it's set. Running it
# again updates amber to the latest release.

set -eu

repo=https://github.com/elliotchance/amber
dir=${AMBER_INSTALL_DIR:-$HOME/.local/bin}

case $(uname -s) in
Linux) os=linux ;;
Darwin) os=macos ;;
*)
	echo "amber only runs on Linux and macOS" >&2
	exit 1
	;;
esac

case $(uname -m) in
x86_64 | amd64) arch=x86-64 ;;
arm64 | aarch64) arch=arm64 ;;
*)
	echo "There's no amber binary for $(uname -m)" >&2
	exit 1
	;;
esac

for command in curl unzip; do
	if ! command -v $command >/dev/null; then
		echo "$command must be installed first" >&2
		exit 1
	fi
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

name=amber-$os-$arch
echo "Downloading $name.zip"
curl -fsSL -o "$tmp/$name.zip" "$repo/releases/latest/download/$name.zip"
unzip -q "$tmp/$name.zip" -d "$tmp"

mkdir -p "$dir"
mv "$tmp/amber" "$dir/amber"
chmod +x "$dir/amber"
echo "Installed $dir/amber ($("$dir/amber" version))"

case ":$PATH:" in
*":$dir:"*) ;;
*) echo "$dir isn't in your PATH, add it to run amber" ;;
esac
