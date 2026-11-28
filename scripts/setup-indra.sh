#!/bin/bash
# Install the local OCR runtime where Forel can find it even from Finder.
set -euo pipefail
runtime_dir="${FOREL_INDRA_RUNTIME_DIR:-$HOME/Library/Application Support/Forel/Indra}"
python_command="${FOREL_INDRA_PYTHON:-}"
if [ -z "$python_command" ]; then
    for candidate in python3.13 python3.12 python3.11 python3.10 python3; do
        if command -v "$candidate" >/dev/null 2>&1; then
            python_command="$candidate"
            break
        fi
    done
fi
if [ -z "$python_command" ]; then
    echo "Install Python 3.10 or newer, then run this script again." >&2
    exit 1
fi
"$python_command" -m venv "$runtime_dir"
"$runtime_dir/bin/python" -m pip install 'indra-ocr==1.1.2'
# Download/load the models now, instead of blocking the first folder event.
"$runtime_dir/bin/python" -c 'import indra_ocr; indra_ocr.load(threads=1)'
"$runtime_dir/bin/indra-ocr" --version
echo "Indra OCR is ready. Documents are processed locally."
