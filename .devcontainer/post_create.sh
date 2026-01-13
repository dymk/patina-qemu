#!/bin/bash +x

sudo chown -R vscode:vscode /home/vscode/.cache/pip
pip install --upgrade -r pip-requirements.txt

# shellcheck disable=SC2016
echo 'eval "$(fzf --bash)"' >> ~/.bashrc
