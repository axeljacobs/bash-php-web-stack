#!/bin/bash

print_green() {
  echo -e "\e[32m$1\e[0m"
}
print_red() {
  echo -e "\e[31m$1\e[0m"
}

# Check root
#------------
if [[ $EUID -ne 0 ]]; then
  print_red "This script must be run as root."
  exit 1
fi