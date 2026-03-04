#!/bin/bash
export LUKS_PATH="$HOME/yubikey_luks"

# LUKS vault helpers require Linux (dm-crypt/cryptsetup)
if [[ "$(uname -s)" == "Darwin" ]]; then
  function unlock_vault {
    echo "LUKS containers are not supported on macOS."
  }
  function lock_vault {
    echo "LUKS containers are not supported on macOS."
  }
else
  function unlock_vault {
    echo -n "enter your yubikey pin and press enter:"
    read -s KEYPIN
    echo -n "$(ykchalresp -2 "$KEYPIN")" | sudo cryptsetup open "$LUKS_PATH" luks && sudo mount /dev/mapper/luks "$HOME/luks" && (echo ""; echo "Successfully unlocked vault, mounted at $HOME/luks")
  }

  function lock_vault {
    sudo umount "$HOME/luks"; sudo cryptsetup close luks
  }
fi
