#!/bin/bash
set -e

clear
echo "=========================================================="
echo "   DESINSTALADOR DRIVER RANE SL2                          "
echo "=========================================================="
echo ""
echo "Se eliminaran el driver SL2Device.driver, el firmware instalado, SL2Api.framework, la app SL 2 Control Panel y las utilidades de Terminal."
echo "(Te pedira la contrasena de inicio de sesion de tu Mac)"
echo ""

sudo rm -rf "/Library/Audio/Plug-Ins/HAL/SL2Device.driver"
sudo rm -rf "/Library/Audio/Plug-Ins/HAL/SL2Device.firmware"
sudo rm -rf "/Library/Frameworks/SL2Api.framework"
sudo rm -rf "/Applications/SL 2 Control Panel.app"
sudo rm -rf "/Library/PreferencePanes/SL 2 Audio Control Panel.prefPane"   # instalado por versiones anteriores
sudo rm -rf "/Library/Extensions/SL2.10.9.kext"
sudo rm -f "/usr/local/bin/sl2panel" "/usr/local/bin/sl2dump" "/usr/local/bin/sl2flash"
sudo launchctl kickstart -kp system/com.apple.audio.coreaudiod >/dev/null 2>&1 || sudo killall coreaudiod >/dev/null 2>&1 || true

echo ""
echo "Driver Rane SL2 desinstalado correctamente."
echo ""
read -p "Pulsa ENTER para cerrar esta ventana..."
