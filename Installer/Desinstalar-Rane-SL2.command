#!/bin/bash
set -e

clear
echo "=========================================================="
echo "   DESINSTALADOR DRIVER RANE SL2                          "
echo "=========================================================="
echo ""
echo "Se eliminaran el driver SL2Device.driver, SL2Api.framework y el panel de control."
echo "(Te pedira la contrasena de inicio de sesion de tu Mac)"
echo ""

sudo rm -rf "/Library/Audio/Plug-Ins/HAL/SL2Device.driver"
sudo rm -rf "/Library/Frameworks/SL2Api.framework"
sudo rm -rf "/Library/PreferencePanes/SL 2 Audio Control Panel.prefPane"
sudo rm -rf "/Library/Extensions/SL2.10.9.kext"
sudo rm -f "/usr/local/bin/sl2panel"
sudo launchctl kickstart -kp system/com.apple.audio.coreaudiod >/dev/null 2>&1 || sudo killall coreaudiod >/dev/null 2>&1 || true

echo ""
echo "Driver Rane SL2 desinstalado correctamente."
echo ""
read -p "Pulsa ENTER para cerrar esta ventana..."
