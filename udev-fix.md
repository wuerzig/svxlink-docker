# /etc/udev/rules.d/99-svxlink-usb-audio.rules
ACTION=="add|change", SUBSYSTEM=="input", ATTRS{idVendor}=="0d8c", ATTRS{idProduct}=="0012", ENV{LIBINPUT_IGNORE_DEVICE}="1", ENV{ID_INPUT}="", ENV{ID_INPUT_KEY}=""

KERNEL=="hidraw*", ATTRS{idVendor}=="0d8c", ATTRS{idProduct}=="0012", MODE="0660", GROUP="plugdev", SYMLINK+="hidraw-radio"
