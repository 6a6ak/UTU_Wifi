#!/bin/bash

# Define some flashy colors
GREEN='\033[0;32m'
LIGHT_CYAN='\033[1;36m'
NC='\033[0m'  # No Color

# The hacker-ish header
clear
echo -e "${GREEN}"
cat << "EOF"

EOF
echo -e "${LIGHT_CYAN}WIFI Viewer${NC}"
echo -e "${GREEN}===============================${NC}\n"

function menu {
    echo "1) List Wi-Fi networks"
    echo "2) Show saved Wi-Fi passwords"
    echo "3) Show Wi-Fi frequencies and signal strengths"
    echo "0) Exit"
    echo "Enter your choice (1/2/3/0): "
}

function find_interface {
    echo "wlp3s0"
}

function list_wifi {
    nmcli dev wifi list
}

function show_passwords {
    DIR="/etc/NetworkManager/system-connections"

    if [ ! -d "$DIR" ]; then
        echo "Directory $DIR doesn't exist! Are you sure you're on Ubuntu or using NetworkManager?"
        exit 1
    fi

    for profile in $DIR/*; do
        echo "Network: $(basename "$profile")"
        echo "Password: $(grep 'psk=' "$profile" | sed 's/psk=//')"
        echo "-----------------------"
    done
}

function show_frequencies {
    interface=$(find_interface)

    if [ -z "$interface" ]; then
        echo "Couldn't find a wireless interface!"
        exit 1
    fi

    echo "Scanning available Wi-Fi networks on $interface..."
    echo "-----------------------------------"

    sudo iwlist $interface scan | grep -E 'ESSID|Frequency|Quality' | while read -r line; do
        case "$line" in
            *ESSID*)
                essid=$(echo $line | cut -d\" -f2)
                echo "Network: $essid"
                ;;
            *Frequency*)
                frequency=$(echo $line | awk '{print $2}' | cut -d: -f2)
                echo "Frequency: $frequency"
                ;;
            *Quality*)
                signal=$(echo $line | awk '{print $1}' | cut -d= -f2)
                echo "Signal Strength: $signal"
                echo "-----------------------------------"
                ;;
        esac
    done
}

while true; do
    menu
    read choice
    case "$choice" in
        1) list_wifi ;;
        2) show_passwords ;;
        3) show_frequencies ;;
        0) echo "Peace out! ✌️"; exit 0 ;;
        *) echo "Invalid choice. Rock on and try again! 🎸";;
    esac
done
