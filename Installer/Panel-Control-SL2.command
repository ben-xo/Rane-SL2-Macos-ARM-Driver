#!/bin/bash
clear
echo "=========================================================="
echo "   PANEL DE CONTROL RANE SL2 — by pepelee (@pepeleedj)    "
echo "   Instagram: https://www.instagram.com/pepeleedj/        "
echo "=========================================================="
echo ""
# La app SL 2 Control Panel si esta instalada; si no, el estado en Terminal.
if [ -d "/Applications/SL 2 Control Panel.app" ]; then
    open "/Applications/SL 2 Control Panel.app"
    exit 0
elif [ -x "/usr/local/bin/sl2panel" ]; then
    /usr/local/bin/sl2panel status
else
    echo "La herramienta sl2panel aun no esta instalada en /usr/local/bin/sl2panel."
    echo "Ejecuta primero Instalar-Rane-SL2.command o RaneSL2-macOS-Universal.pkg"
fi
echo ""
read -p "Pulsa ENTER para cerrar esta ventana..."
