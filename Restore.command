#!/bin/bash
# Double-click to undo everything firetv-declutter changed on your Fire TV.
cd "$(dirname "$0")" && exec bash ./firetv-declutter.sh --restore
