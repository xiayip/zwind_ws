#!/bin/bash

# check if pip is installed
if ! command -v pip &> /dev/null; then
    echo "pip3 not found, installing pip..."
    sudo apt update
    sudo apt install -y python3-pip
fi

# check if vcs tool is installed
if ! command -v vcs &> /dev/null; then
    # install vcs tool
    echo "vcs not found, installing vcs..."
    sudo pip install vcstool
fi

# check if git-lfs is installed
if ! command -v git-lfs &> /dev/null; then
    echo "git-lfs not found, installing git-lfs..."
    sudo apt-get update
    sudo apt-get install git-lfs
fi

vcs import < dev.repos --skip-existing --repos --debug

# Configure extra docker run arguments
cat > ./docker/.dockerargs <<EOF
-v $HOME/.ssh:/home/admin/.ssh:ro
-v $(pwd)/openclaw_data:/home/admin/.openclaw
EOF
