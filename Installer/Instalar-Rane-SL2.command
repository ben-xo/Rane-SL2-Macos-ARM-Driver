#!/bin/bash
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
PKG="$DIR/RaneSL2-macOS-Universal.pkg"

clear
echo "=========================================================="
echo "   INSTALADOR DRIVER RANE SL2 (Apple Silicon M1/M2/M3/M4) "
echo "   Idea original y proyecto por: pepelee (PPLEE)          "
echo "   Instagram: https://www.instagram.com/pepeleedj/        "
echo "=========================================================="
echo ""

if [ ! -f "$PKG" ]; then
    echo "Error: No se encuentra $PKG en esta carpeta."
    read -p "Pulsa ENTER para salir..."
    exit 1
fi

echo "Eliminando bloqueo de cuarentena de macOS (Gatekeeper)..."
xattr -cr "$DIR" 2>/dev/null || true

echo "Instalando Rane SL2 CoreAudio Driver, SL2Api (Serato DJ) y Panel de Control..."
echo "(Te pedira la contrasena de inicio de sesion de tu Mac)"
echo ""
sudo installer -pkg "$PKG" -target /

echo ""
echo "=========================================================="
echo "   INSTALACION COMPLETADA CON EXITO — by pepelee          "
echo "   Instagram: @pepeleedj (instagram.com/pepeleedj/)       "
echo "=========================================================="
echo " - Driver CoreAudio: /Library/Audio/Plug-Ins/HAL/SL2Device.driver"
echo " - Libreria Serato DJ (2.5.5): /Library/Frameworks/SL2Api.framework"
echo " - App de control: /Applications/SL 2 Control Panel.app"
echo " - Utilidades CLI: /usr/local/bin/sl2panel, sl2dump, sl2flash"
echo " - Motor de audio (coreaudiod) recargado."
echo " - No es necesario reiniciar el Mac."
echo ""
read -p "Pulsa ENTER para cerrar esta ventana..."
